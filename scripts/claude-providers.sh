#!/usr/bin/env bash
# claude-providers.sh — create/refresh/list/remove Claude Code aliases for
# non-Anthropic LLM providers, fully dynamically.
#
# Pipeline (sync): read the API-key VARIABLE NAMES from the keys file, fetch +
# cache the models.dev catalog, resolve each LLM key into a concrete provider
# record (provider id, alias, base URL, transport, strong/fast model) via
# providers_resolve.py, optionally verify with LLMsVerifier, then generate for
# each provider: a non-secret env file, a shell alias (cma_run_provider <id>),
# a config dir (~/.claude-prov-<id>) linking all shared items (so every plugin
# is available), and the always-on plugin set. Idempotent + re-runnable.
#
# Subcommands:
#   sync   (default)  discover + create/refresh all provider aliases
#   list              show installed provider aliases + model overrides
#   show <id>         detail for one provider
#   remove <id>       remove a provider alias + config dir
#   add  --from-key VAR [--id ID]   register a key→provider mapping, then sync
#
# Nothing about providers/models is hardcoded — everything derives from
# models.dev + the editable providers/key-aliases.json and overrides.json.
set -euo pipefail

_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

# --- knobs ------------------------------------------------------------------
: "${CMA_KEYS_FILE:=$HOME/api_keys.sh}"
: "${CMA_MODELS_DEV_URL:=https://models.dev/api.json}"
: "${CMA_MODELS_DEV_TTL:=86400}"        # cache lifetime in seconds (24h)
: "${CMA_PROVIDER_DIR_PREFIX:=${ACCOUNT_PREFIX}prov-}"
# Always-on plugins (keys as they appear in settings.json enabledPlugins).
: "${CMA_ALWAYS_ON_PLUGINS:=superpowers@anthropics systematic-debugging@anthropics frontend-design@anthropics code-review@anthropics}"

RESOLVER="$LIB_DIR/providers_resolve.py"
VERIFY="$LIB_DIR/providers-verify.sh"
MODEL_VERIFY="$LIB_DIR/model_verify.py"
PROVIDERS_GENERATE="$LIB_DIR/providers_generate.py"
KEY_ALIASES="$LIB_DIR/providers/key-aliases.json"
OVERRIDES="$LIB_DIR/providers/overrides.json"
CACHE="$(cma_providers_dir)/models.dev.cache.json"
VERIFIED_CACHE="$(cma_providers_dir)/verification_cache.json"

NO_VERIFY=0 OFFLINE=0 DRY_RUN=0 ASSUME_YES=0 MULTI=0
MAX_ALIASES=5 MIN_SCORE=25 VERIFY_CONCURRENCY=5

usage() {
  cat <<EOF
Usage: claude-providers [SUBCOMMAND] [options]

Subcommands:
  sync                 (default) discover + create/refresh all provider aliases
  sync --multi         verify ALL models per provider, create multiple aliases
  list                 list installed provider aliases and their model overrides
  show <id>            show details for one provider
  remove <id>          remove a provider alias + its config dir (backed up)
  add --from-key VAR [--id PROVIDER]   register a key->provider mapping then sync

Options:
  --keys-file PATH     keys file to read var names from (default: \$CMA_KEYS_FILE or ~/api_keys.sh)
  --no-verify          skip LLMsVerifier/HTTP verification (aliases still created)
  --offline            do not fetch models.dev; require the local cache
  --dry-run            print what would change; write nothing
  --multi              with sync: verify all models, create multiple aliases per provider
  --max-aliases N      max aliases per provider (default: 5)
  --min-score N        minimum verification score (default: 25)
  --verify-concurrency N  concurrent model verifications (default: 5)
  -y, --yes            assume yes to prompts
  -h, --help           this help
EOF
}

# --- models.dev catalog: fetch + cache, graceful degrade --------------------
ensure_catalog() {
  mkdir -p "$(dirname "$CACHE")"
  local fresh=0
  if [[ -s "$CACHE" ]] && _catalog_valid "$CACHE"; then
    local age now mtime
    now="$(date +%s)"
    # Platform-specific stat: macOS uses -f %m, Linux uses -c %Y.
    # The old `||` chain broke on Linux because `stat -f` succeeds there too
    # (returning filesystem info, not mtime), so both outputs merged.
    case "$(uname -s)" in
      Darwin*) mtime="$(stat -f %m "$CACHE" 2>/dev/null || echo 0)" ;;
      *)       mtime="$(stat -c %Y "$CACHE" 2>/dev/null || echo 0)" ;;
    esac
    age=$(( now - mtime ))
    (( age < CMA_MODELS_DEV_TTL )) && fresh=1
  fi
  if (( OFFLINE )); then
    [[ -s "$CACHE" ]] && _catalog_valid "$CACHE" \
      || cma_die "offline and no valid models.dev cache at $CACHE — run once online first"
    cma_warn "offline: using cached catalog ($CACHE)"
    return 0
  fi
  if (( fresh )); then return 0; fi
  cma_require curl
  local tmp; tmp="$(mktemp)"
  if curl -s --max-time 45 "$CMA_MODELS_DEV_URL" -o "$tmp" \
     && python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$tmp" 2>/dev/null; then
    mv "$tmp" "$CACHE"
    cma_log "refreshed models.dev catalog -> $CACHE ($(wc -c < "$CACHE") bytes)"
  else
    rm -f "$tmp"
    if [[ -s "$CACHE" ]]; then
      cma_warn "models.dev fetch failed; using stale cache ($CACHE)"
    else
      cma_die "models.dev fetch failed and no cache available"
    fi
  fi
}

# Extract API-key VARIABLE NAMES from the keys file WITHOUT executing it.
present_key_vars() {
  [[ -f "$CMA_KEYS_FILE" ]] || cma_die "keys file not found: $CMA_KEYS_FILE (pass --keys-file)"
  # `|| true`: a keys file with no assignments must yield an empty list, not a
  # grep exit-1 that aborts the script under `set -e`/pipefail.
  { grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$CMA_KEYS_FILE" || true; } \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//' \
    | sort -u
}

# Validate that the catalog cache is parseable JSON.
_catalog_valid() { python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$1" 2>/dev/null; }

resolve_records() {
  local keys; keys="$(present_key_vars | paste -sd, -)"
  local args=(--models-dev "$CACHE" --keys "$keys")
  [[ -f "$KEY_ALIASES" ]] && args+=(--key-aliases "$KEY_ALIASES")
  [[ -f "$OVERRIDES" ]] && args+=(--overrides "$OVERRIDES")
  python3 "$RESOLVER" "${args[@]}"
}

# --- subcommand: sync -------------------------------------------------------
cmd_sync() {
  ensure_catalog
  local records; records="$(resolve_records)"
  local total resolved
  total="$(jq 'length' <<<"$records")"
  resolved="$(jq '[.[]|select(.status=="resolved")]|length' <<<"$records")"
  cma_log "discovered $total key vars; $resolved resolve to a provider"

  # Always-on plugins (additive union) — once, before per-provider work.
  if (( ! DRY_RUN )); then
    # shellcheck disable=SC2086
    cma_enable_plugins $CMA_ALWAYS_ON_PLUGINS 2>/dev/null || true
  fi

  # Dedupe by provider_id: one alias per provider even if multiple key vars map
  # to it (e.g. CODESTRAL_API_KEY + MISTRAL_API_KEY both -> mistral).
  local seen=" "
  local n_created=0 n_skipped=0 n_disabled=0
  while IFS=$'\t' read -r status pid alias keyvar transport base model fast; do
    [[ "$status" == "resolved" ]] || { n_skipped=$((n_skipped+1)); continue; }
    case "$seen" in *" $pid "*) cma_warn "provider '$pid' already handled; skipping duplicate key $keyvar"; continue ;; esac
    seen="$seen$pid "

    local cdir="$HOME/${CMA_PROVIDER_DIR_PREFIX}${pid}"
    if (( DRY_RUN )); then
      printf '  would create: alias %-14s -> %-16s [%s] %s\n' "$alias" "$pid" "$transport" "$model"
      continue
    fi

    # Verification (pluggable). verified|unverified -> activate; failed -> disable.
    local vstatus="unverified"
    if (( ! NO_VERIFY )); then
      local vargs=(--provider "$pid" --model "$model" --key-var "$keyvar")
      [[ -n "$base" && "$base" != "null" ]] && vargs+=(--base-url "$base")
      (( OFFLINE )) && vargs+=(--offline)
      # Source keys so the verifier/probe can read the secret (subshell only).
      vstatus="$( ( [[ -f "$CMA_KEYS_FILE" ]] && set -a && . "$CMA_KEYS_FILE" && set +a; bash "$VERIFY" "${vargs[@]}" 2>/dev/null ) )" || true
      [[ -z "$vstatus" ]] && vstatus="unverified"
    fi

    if [[ "$vstatus" == "failed" ]]; then
      cma_warn "provider '$pid' FAILED verification — alias NOT activated"
      n_disabled=$((n_disabled+1))
      continue
    fi

    cma_link_shared_items "$cdir"
    cma_provider_write_env "$pid" "$keyvar" "$transport" "$base" "$model" "$fast" "$cdir"
    cma_provider_write_alias "$alias" "$pid"
    cma_log "provider '$pid' -> alias '$alias' [$transport] model=$model ($vstatus)"
    n_created=$((n_created+1))
  done < <(jq -r '.[] | [.status,.provider_id,.alias,.key_var,.transport,.base_url,.strong_model,.fast_model] | @tsv' <<<"$records")

  cma_log "sync done: $n_created active, $n_disabled disabled (failed verify), $n_skipped not-resolved"
  cma_log "reload your shell or: source $ALIAS_FILE"
}

# --- subcommand: list -------------------------------------------------------
cmd_list() {
  local pdir; pdir="$(cma_providers_dir)"
  if [[ ! -d "$pdir" ]] || ! compgen -G "$pdir/*.env" >/dev/null; then
    echo "No provider aliases installed. Run: claude-providers sync"
    return 0
  fi
  printf '%-14s %-16s %-8s %-26s %-26s\n' ALIAS PROVIDER TRANSPORT STRONG_MODEL FAST_MODEL
  local f
  for f in "$pdir"/*.env; do
    local id keyvar transport base model fast cdir alias
    id=""; transport=""; model=""; fast=""
    # shellcheck disable=SC1090
    ( set -a; . "$f"; set +a
      alias="$(grep -E "cma_run_provider $CMA_PROVIDER_ID(\"| )" "$ALIAS_FILE" 2>/dev/null | sed -E 's/^alias ([^=]+)=.*/\1/' | head -1)"
      printf '%-14s %-16s %-8s %-26s %-26s\n' \
        "${alias:-?}" "$CMA_PROVIDER_ID" "$CMA_PROVIDER_TRANSPORT" "$CMA_PROVIDER_MODEL" "${CMA_PROVIDER_FAST_MODEL:-}" )
  done
}

# --- subcommand: show -------------------------------------------------------
cmd_show() {
  local id="${1:-}"; [[ -n "$id" ]] || cma_die "usage: claude-providers show <id>"
  local f; f="$(cma_providers_dir)/$id.env"
  [[ -f "$f" ]] || cma_die "no such provider: $id"
  echo "# $f"; cat "$f"
}

# --- subcommand: remove -----------------------------------------------------
cmd_remove() {
  local id="${1:-}"; [[ -n "$id" ]] || cma_die "usage: claude-providers remove <id>"
  local f; f="$(cma_providers_dir)/$id.env"
  [[ -f "$f" ]] || cma_die "no such provider: $id"
  local alias; alias="$(grep -E "cma_run_provider $id(\"| )" "$ALIAS_FILE" 2>/dev/null | sed -E 's/^alias ([^=]+)=.*/\1/' | head -1)"
  [[ -n "$alias" ]] && cma_remove_alias "$alias"
  rm -f "$f"
  local cdir="$HOME/${CMA_PROVIDER_DIR_PREFIX}${id}"
  if [[ -d "$cdir" ]]; then
    mv "$cdir" "${cdir}.preunify.$(date +%Y%m%d%H%M%S)"
    cma_log "backed up + removed config dir $cdir"
  fi
  cma_log "removed provider '$id' (alias '${alias:-none}')"
}

# --- subcommand: add --------------------------------------------------------
cmd_add() {
  local from_key="" pid=""
  while (( $# )); do
    case "$1" in
      --from-key) from_key="$2"; shift 2 ;;
      --id) pid="$2"; shift 2 ;;
      *) cma_die "add: unknown arg $1" ;;
    esac
  done
  [[ -n "$from_key" && -n "$pid" ]] || cma_die "usage: claude-providers add --from-key VAR --id PROVIDER_ID"
  cma_require jq
  mkdir -p "$(dirname "$KEY_ALIASES")"
  [[ -s "$KEY_ALIASES" ]] || echo '{}' > "$KEY_ALIASES"
  local tmp; tmp="$(mktemp)"
  jq --arg k "$from_key" --arg p "$pid" '.[$k]=$p' "$KEY_ALIASES" > "$tmp" && mv "$tmp" "$KEY_ALIASES"
  cma_log "registered $from_key -> $pid in $KEY_ALIASES"
  cmd_sync
}

# --- subcommand: sync --multi -----------------------------------------------
# Verify ALL models for each provider, score them, and create multiple aliases
# (provider, provider2, provider3...) with paired strong+fast models.
cmd_sync_multi() {
  cma_require python3
  cma_require jq
  ensure_catalog

  local records; records="$(resolve_records)"
  local total resolved
  total="$(jq 'length' <<<"$records")"
  resolved="$(jq '[.[]|select(.status=="resolved")]|length' <<<"$records")"
  cma_log "multi-sync: discovered $total key vars; $resolved resolve to a provider"

  # Always-on plugins
  if (( ! DRY_RUN )); then
    # shellcheck disable=SC2086
    cma_enable_plugins $CMA_ALWAYS_ON_PLUGINS 2>/dev/null || true
  fi

  local pdir; pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
  local seen=" "
  local n_created=0 n_skipped=0

  while IFS=$'\t' read -r status pid alias keyvar transport base model fast; do
    [[ "$status" == "resolved" ]] || { n_skipped=$((n_skipped+1)); continue; }
    case "$seen" in *" $pid "*) continue ;; esac
    seen="$seen$pid "

    # Get the API key for verification — source keys file in a subshell,
    # then use indirect expansion to read the specific key variable.
    local keysf="${CMA_KEYS_FILE:-$HOME/api_keys.sh}"
    local token=""
    if [[ -f "$keysf" ]]; then
      token="$(bash -c "set -a; source '$keysf' 2>/dev/null; set +a; eval \"echo \${$keyvar:-}\"" 2>/dev/null)" || true
    fi

    if [[ -z "$token" ]]; then
      cma_warn "provider '$pid': \$${keyvar} is empty — skipping multi-alias generation"
      continue
    fi

    # Normalize base URL for verification endpoint
    local verify_endpoint="$base"
    case "$verify_endpoint" in
      */chat/completions|*/v1/messages|*/v1/models*) ;;
      *) verify_endpoint="${verify_endpoint%/}/chat/completions" ;;
    esac

    cma_log "multi-sync: verifying all models for '$pid' at $verify_endpoint..."

    if (( DRY_RUN )); then
      cma_log "  would verify models for '$pid' and generate multi-aliases"
      continue
    fi

    # Run model verification
    local verified_out="$pdir/${pid}_verified.json"
    python3 "$MODEL_VERIFY" \
      --provider "$pid" \
      --endpoint "$verify_endpoint" \
      --key "$token" \
      --catalog "$CACHE" \
      --concurrency "$VERIFY_CONCURRENCY" \
      --cache-file "$VERIFIED_CACHE" \
      --output "$verified_out" \
      --verbose 2>&1 || { cma_warn "verification failed for '$pid'"; continue; }

    local vcount; vcount="$(jq '.verified_count' "$verified_out" 2>/dev/null || echo 0)"
    cma_log "  $pid: $vcount models verified"

    if (( vcount == 0 )); then
      cma_warn "provider '$pid': no models verified — skipping"
      continue
    fi

    # Generate multi-alias configuration
    local manifest_out="$pdir/${pid}_manifest.json"
    python3 "$PROVIDERS_GENERATE" \
      --provider "$pid" \
      --verified "$verified_out" \
      --output-dir "$pdir" \
      --max-aliases "$MAX_ALIASES" \
      --min-score "$MIN_SCORE" \
      --key-var "$keyvar" \
      --transport "$transport" \
      --base-url "$base" \
      --account-prefix "$ACCOUNT_PREFIX" \
      --home "$HOME" \
      2>/dev/null > "$manifest_out" || { cma_warn "alias generation failed for '$pid'"; continue; }

    local alias_count; alias_count="$(jq '.alias_count' "$manifest_out" 2>/dev/null || echo 0)"
    cma_log "  $pid: $alias_count aliases generated"

    # Create config dirs and symlinks for each alias
    local i=0
    while (( i < alias_count )); do
      local aname; aname="$(jq -r ".aliases[$i].alias_name" "$manifest_out")"
      local cdir="$HOME/${ACCOUNT_PREFIX}prov-${aname}"

      cma_link_shared_items "$cdir"

      # Write the env file from manifest
      local strong; strong="$(jq -r ".aliases[$i].strong_model" "$manifest_out")"
      local ffast; ffast="$(jq -r ".aliases[$i].fast_model" "$manifest_out")"
      local alias_url; alias_url="$(jq -r ".aliases[$i].base_url" "$manifest_out")"
      local alias_transport; alias_transport="$(jq -r ".aliases[$i].transport" "$manifest_out")"

      cma_provider_write_env "$aname" "$keyvar" "$alias_transport" "$alias_url" "$strong" "$ffast" "$cdir"
      cma_provider_write_alias "$aname" "$aname"

      cma_log "  alias '$aname': strong=$strong fast=$ffast [$alias_transport]"
      n_created=$((n_created+1))
      i=$((i+1))
    done

  done < <(jq -r '.[] | [.status,.provider_id,.alias,.key_var,.transport,.base_url,.strong_model,.fast_model] | @tsv' <<<"$records")

  cma_log "multi-sync done: $n_created aliases created across all providers"
  cma_log "reload your shell or: source $ALIAS_FILE"
}

# --- arg parsing + dispatch -------------------------------------------------
SUBCMD="sync"
case "${1:-}" in
  sync|list|show|remove|add) SUBCMD="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
esac
POSITIONAL=()
while (( $# )); do
  case "$1" in
    --keys-file) CMA_KEYS_FILE="$2"; shift 2 ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --multi) MULTI=1; shift ;;
    --max-aliases) MAX_ALIASES="$2"; shift 2 ;;
    --min-score) MIN_SCORE="$2"; shift 2 ;;
    --verify-concurrency) VERIFY_CONCURRENCY="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

case "$SUBCMD" in
  sync)   if (( MULTI )); then cmd_sync_multi; else cmd_sync; fi ;;
  list)   cmd_list ;;
  show)   cmd_show "${POSITIONAL[@]:-}" ;;
  remove) cmd_remove "${POSITIONAL[@]:-}" ;;
  add)    cmd_add "${POSITIONAL[@]:-}" ;;
esac
