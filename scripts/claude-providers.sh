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
VERIFY="${CMA_PROVIDERS_VERIFY:-$LIB_DIR/providers-verify.sh}"
SEMANTIC="${CMA_PROVIDERS_SEMANTIC:-$LIB_DIR/providers-semantic.sh}"
MODEL_VERIFY="$LIB_DIR/model_verify.py"
PROVIDERS_GENERATE="$LIB_DIR/providers_generate.py"
KEY_ALIASES="$LIB_DIR/providers/key-aliases.json"
OVERRIDES="$LIB_DIR/providers/overrides.json"
CACHE="$(cma_providers_dir)/models.dev.cache.json"
VERIFIED_CACHE="$(cma_providers_dir)/verification_cache.json"

# shellcheck disable=SC2034  # ASSUME_YES reserved for --yes prompt suppression (not yet wired into cmds)
NO_VERIFY=0 OFFLINE=0 DRY_RUN=0 ASSUME_YES=0 MULTI=0
REFRESH_ALIASES=0 QUIET=0
MAX_ALIASES=5 MIN_SCORE=25 VERIFY_CONCURRENCY=5

usage() {
  cat <<EOF
Usage: claude-providers [SUBCOMMAND] [options]

Subcommands:
  sync                 (default) discover + create/refresh all provider aliases
  sync --multi         verify ALL models per provider, create multiple aliases
  list                 list only VALIDATED + VERIFIED provider aliases
  list-all             list every installed provider alias (any status)
  list-faulty          list only aliases with an issue (failed/unverified/pending)
  show <id>            show details for one provider
  verify <id> [--deep] re-run verification for one provider + persist status
                       (layers 1-3; --deep also runs the live superpowers-TUI layer 4)
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
    # shellcheck disable=SC2015  # C (cma_die) is desired when A&&B fails: die if cache absent/invalid
    [[ -s "$CACHE" ]] && _catalog_valid "$CACHE" \
      || cma_die "offline and no valid models.dev cache at $CACHE — run once online first"
    cma_warn "offline: using cached catalog ($CACHE)"
    return 0
  fi
  if (( fresh )); then return 0; fi
  cma_require curl
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
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
  # -e (not -f): a process-substitution / FIFO keys file (e.g. --keys-file
  # <(...)) is a legitimate way to supply keys and is NOT a POSIX "regular
  # file" per -f, but it is a readable, existing path per -e.
  [[ -e "$CMA_KEYS_FILE" ]] || cma_die "keys file not found: $CMA_KEYS_FILE (pass --keys-file)"
  # `|| true`: a keys file with no assignments must yield an empty list, not a
  # grep exit-1 that aborts the script under `set -e`/pipefail.
  local names
  names="$( { grep -oE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_][A-Za-z0-9_]*=' "$CMA_KEYS_FILE" || true; } \
    | sed -E 's/^[[:space:]]*(export[[:space:]]+)?//; s/=$//' \
    | sort -u )"
  # Keep only vars whose VALUE is non-empty. A declared-but-empty key
  # (e.g. `export SARVAM_API_KEY=`) must NOT spawn a provider alias — it would
  # only fail at launch with "$VAR is empty (set it in ...)". Source the keys
  # file in a subshell (it may `exit` at top level or carry set -u-hostile
  # refs) and print just the NAMES (never values) that resolve to a value.
  # shellcheck source=/dev/null  # $CMA_KEYS_FILE is the user's runtime keys file
  ( set +e; set -a +u; . "$CMA_KEYS_FILE" >/dev/null 2>&1; set +a
    while IFS= read -r _n; do
      [[ -z "$_n" ]] && continue
      eval "_v=\"\${$_n:-}\""
      [[ -n "$_v" ]] && printf '%s\n' "$_n"
    done <<< "$names"
  ) | sort -u
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
  while IFS=$'\t' read -r status pid alias keyvar transport base model fast ctx_limit max_out; do
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
      # Disable nounset while sourcing: the user-controlled keys file may
      # contain dangling references (e.g. `export X=$UNSET`), which under the
      # inherited `set -u` would abort the source mid-file — silently leaving
      # every key defined after that point unexported, so those providers fail
      # verification ("unverified") and a stream of "unbound variable" errors
      # spams stderr. `+u` makes the source tolerant; it is subshell-local.
      # shellcheck source=/dev/null  # runtime user keys file, path only known at execution
      vstatus="$( ( [[ -e "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; bash "$VERIFY" "${vargs[@]}" 2>/dev/null ) )" || true
      [[ -z "$vstatus" ]] && vstatus="unverified"
    fi

    if [[ "$vstatus" == "failed" ]]; then
      cma_warn "provider '$pid' FAILED verification — alias NOT activated"
      cma_status_write "$pid" failed "$model" existence
      n_disabled=$((n_disabled+1))
      continue
    fi

    cma_link_shared_items "$cdir"
    cma_provider_write_env "$pid" "$keyvar" "$transport" "$base" "$model" "$fast" "$cdir" "$ctx_limit" "$max_out" "$alias"
    cma_provider_write_alias "$alias" "$pid"

    # Layer bookkeeping. vstatus here is 'verified' (existence+tool-call passed)
    # or 'unverified' (existence probe inconclusive). failing_layer records the
    # FIRST layer that did not pass ("" when none failed).
    local flayer=""
    if [[ "$vstatus" == "verified" ]]; then
      # Layer 3: semantic code-visibility. Only attempt when verification is on
      # and we are not offline; a 'skip' (precondition absent) NEVER downgrades.
      if (( ! NO_VERIFY )) && (( ! OFFLINE )); then
        local sstatus
        # shellcheck source=/dev/null  # runtime user keys file, path only known at execution
        sstatus="$( ( [[ -e "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; \
                      bash "$SEMANTIC" --provider "$pid" --model "$model" --key-var "$keyvar" \
                        ${base:+--base-url "$base"} 2>/dev/null ) )" || true
        if [[ "$sstatus" == "unverified" ]]; then
          vstatus="unverified"; flayer="semantic"
        fi
        # 'verified' | 'skip' | '' -> keep the existence verdict (verified).
      fi
    else
      # existence probe was inconclusive -> the layer that did not pass is existence.
      flayer="existence"
    fi
    cma_status_write "$pid" "$vstatus" "$model" "$flayer"
    cma_log "provider '$pid' -> alias '$alias' [$transport] model=$model ($vstatus${flayer:+/$flayer})"
    n_created=$((n_created+1))
  done < <(jq -r '.[] | [.status,.provider_id,.alias,.key_var,.transport,.base_url,.strong_model,.fast_model,.context_limit,.max_output] | @tsv' <<<"$records")

  cma_log "sync done: $n_created active, $n_disabled disabled (failed verify), $n_skipped not-resolved"
  cma_log "reload your shell or: source $ALIAS_FILE"
}

# --- subcommand: verify ------------------------------------------------------
# claude-providers verify <id> [--deep]
# Re-run verification for ONE already-installed provider and persist status.
# --deep also runs the live superpowers-TUI (layer 4); without it, layers 1-3.
cmd_verify() {
  local id="${1:-}" deep=0; shift 2>/dev/null || true
  [[ "${1:-}" == "--deep" ]] && deep=1
  [[ -n "$id" ]] || cma_die "usage: claude-providers verify <id> [--deep]"
  local envf; envf="$(cma_providers_dir)/$id.env"
  [[ -f "$envf" ]] || cma_die "unknown provider: $id (run: claude-providers sync)"
  # shellcheck source=/dev/null
  ( set -a +u; . "$envf"; set +a
    local base="$CMA_PROVIDER_BASE_URL" model="$CMA_PROVIDER_MODEL" keyvar="$CMA_PROVIDER_KEYVAR"
    local vst sst flayer=""
    vst="$( ( [[ -e "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; \
              bash "$VERIFY" --provider "$id" --model "$model" --key-var "$keyvar" ${base:+--base-url "$base"} 2>/dev/null ) )" || true
    [[ -z "$vst" ]] && vst=unverified
    if [[ "$vst" == "failed" ]]; then cma_status_write "$id" failed "$model" existence; echo "failed"; return; fi
    if [[ "$vst" != "verified" ]]; then cma_status_write "$id" unverified "$model" existence; echo "unverified"; return; fi
    sst="$( ( [[ -e "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; \
              bash "$SEMANTIC" --provider "$id" --model "$model" --key-var "$keyvar" ${base:+--base-url "$base"} 2>/dev/null ) )" || true
    if [[ "$sst" == "unverified" ]]; then cma_status_write "$id" unverified "$model" semantic; echo "unverified"; return; fi
    if (( deep )); then
      # Capture the exit code into a variable BEFORE it is consumed by the
      # `if`/`fi` test below — `$?` immediately after an `if cond; then …; fi`
      # whose condition was false is the if-STATEMENT's own status (0 per
      # POSIX when no branch ran), never the condition command's real code, so
      # reading `$?` after the `fi` would silently and permanently disable the
      # FAIL-demotes branch below.
      local tui_rc=0
      bash "$LIB_DIR/verify_superpowers_tui.sh" --alias "$id" >/dev/null 2>&1 || tui_rc=$?
      if [[ "$tui_rc" -eq 0 ]]; then
        cma_status_write "$id" verified "$model" ""; echo "verified"; return
      fi
      # layer-4 SKIP or FAIL: SKIP keeps verified-through-3; FAIL demotes.
      # verify_superpowers_tui.sh exits 0 on PASS *and* on SKIP (honest), 1 on FAIL.
      if [[ "$tui_rc" -eq 1 ]]; then cma_status_write "$id" unverified "$model" superpowers_tui; echo "unverified"; return; fi
    fi
    cma_status_write "$id" verified "$model" ""; echo "verified" )
}

# --- subcommand: list family ------------------------------------------------
# The three list subcommands share one row emitter, filtered by status:
#   list         -> only VERIFIED aliases (safe to launch; the default view).
#   list-all     -> every installed alias (the pre-split behavior).
#   list-faulty  -> only non-verified aliases (failed/unverified/pending) —
#                   the "what do I need to fix" view, with the failing layer.
# Status is read from the status cache (cma_status_read); an alias with no
# cache entry reads 'pending'.
# _list_rows <filter>   filter: verified | faulty | all
_list_rows() {
  local filter="$1" pdir; pdir="$(cma_providers_dir)"
  if [[ ! -d "$pdir" ]] || ! compgen -G "$pdir/*.env" >/dev/null; then
    echo "No provider aliases installed. Run: claude-providers sync"
    return 0
  fi
  printf '%-14s %-16s %-10s %-12s %-24s\n' ALIAS PROVIDER STATUS LAYER STRONG_MODEL
  local f
  for f in "$pdir"/*.env; do
    local id status layer keep=0
    # shellcheck disable=SC1090
    id="$( ( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_ID" ) )"
    status="$(cma_status_read "$id")"
    case "$filter" in
      verified) [[ "$status" == "verified" ]] && keep=1 ;;
      faulty)   [[ "$status" != "verified" ]] && keep=1 ;;
      all)      keep=1 ;;
    esac
    (( keep )) || continue
    layer="$(cma_status_all | awk -F'\t' -v i="$id" '$1==i{print $5}')"
    # shellcheck disable=SC1090
    ( set -a; . "$f"; set +a
      # `|| alias=""` is LOAD-BEARING: under `set -euo pipefail` a no-match grep
      # (exit 1, propagated by pipefail) would abort the subshell — and the whole
      # listing — for any provider whose alias line is absent.
      alias="$(grep -E "cma_run_provider $CMA_PROVIDER_ID(\"| )" "$ALIAS_FILE" 2>/dev/null | sed -E 's/^alias ([^=]+)=.*/\1/' | head -1)" || alias=""
      printf '%-14s %-16s %-10s %-12s %-24s\n' \
        "${alias:-?}" "$CMA_PROVIDER_ID" "$status" "${layer:--}" "$CMA_PROVIDER_MODEL" )
  done
}
cmd_list()        { _list_rows verified; }
cmd_list_all()    { _list_rows all; }
cmd_list_faulty() { _list_rows faulty; }

# --- subcommand: show -------------------------------------------------------
cmd_show() {
  local id="${1:-}"; [[ -n "$id" ]] || cma_die "usage: claude-providers show <id>"
  case "$id" in *[!A-Za-z0-9._-]*) cma_die "invalid provider id: $id" ;; esac
  local f; f="$(cma_providers_dir)/$id.env"
  [[ -f "$f" ]] || cma_die "no such provider: $id"
  echo "# $f"; cat "$f"
}

# --- subcommand: remove -----------------------------------------------------
cmd_remove() {
  local id="${1:-}"; [[ -n "$id" ]] || cma_die "usage: claude-providers remove <id>"
  case "$id" in *[!A-Za-z0-9._-]*) cma_die "invalid provider id: $id" ;; esac
  local f; f="$(cma_providers_dir)/$id.env"
  [[ -f "$f" ]] || cma_die "no such provider: $id"
  # `|| alias=""` is LOAD-BEARING: under `set -euo pipefail` a no-match grep would
  # abort cmd_remove before `rm -f "$f"`, leaving the provider half-removed.
  local alias; alias="$(grep -E "cma_run_provider $id(\"| )" "$ALIAS_FILE" 2>/dev/null | sed -E 's/^alias ([^=]+)=.*/\1/' | head -1)" || alias=""
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
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
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

  while IFS=$'\t' read -r status pid alias keyvar transport base model fast ctx_limit max_out; do
    [[ "$status" == "resolved" ]] || { n_skipped=$((n_skipped+1)); continue; }
    case "$seen" in *" $pid "*) continue ;; esac
    seen="$seen$pid "

    # Get the API key for verification — source keys file in a subshell,
    # then use indirect expansion to read the specific key variable.
    local keysf="${CMA_KEYS_FILE:-$HOME/api_keys.sh}"
    local token=""
    if [[ -f "$keysf" ]]; then
      # Read the key in an isolated subshell (no `bash -c` string interpolation
      # of $keysf, which a quote in the path could break out of). $keyvar is a
      # validated env-var name, so the indirect eval is safe. set +e/+u so a
      # dangling ref or failed source can't abort before the read.
      # shellcheck source=/dev/null  # $keysf is the user's runtime keys file
      token="$( set +e; set -a +u; . "$keysf" 2>/dev/null; set +a; eval "printf '%s' \"\${$keyvar:-}\"" )" || true
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

    # Run model verification — key is passed via env var (not argv) so it
    # does not appear in /proc/<pid>/cmdline or `ps aux` on multi-user hosts.
    local verified_out="$pdir/${pid}_verified.json"
    CMA_PROBE_KEY="$token" python3 "$MODEL_VERIFY" \
      --provider "$pid" \
      --endpoint "$verify_endpoint" \
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
      --context-limit "$ctx_limit" \
      --max-output "$max_out" \
      --account-prefix "$ACCOUNT_PREFIX" \
      --home "$HOME" \
      2>/dev/null > "$manifest_out" || { cma_warn "alias generation failed for '$pid'"; continue; }

    local alias_count; alias_count="$(jq '.alias_count' "$manifest_out" 2>/dev/null || echo 0)"
    cma_log "  $pid: $alias_count aliases generated"

    # Create config dirs and symlinks for each alias
    local i=0
    while (( i < alias_count )); do
      local aname; aname="$(jq -r ".aliases[$i].alias_name // empty" "$manifest_out")"
      local cdir="$HOME/${ACCOUNT_PREFIX}prov-${aname}"

      cma_link_shared_items "$cdir"

      # Write the env file from manifest
      local strong; strong="$(jq -r ".aliases[$i].strong_model // empty" "$manifest_out")"
      local ffast; ffast="$(jq -r ".aliases[$i].fast_model // empty" "$manifest_out")"
      local alias_url; alias_url="$(jq -r ".aliases[$i].base_url // empty" "$manifest_out")"
      local alias_transport; alias_transport="$(jq -r ".aliases[$i].transport // empty" "$manifest_out")"
      local alias_ctx; alias_ctx="$(jq -r ".aliases[$i].context_limit // empty" "$manifest_out")"
      local alias_max; alias_max="$(jq -r ".aliases[$i].max_output // empty" "$manifest_out")"

      cma_provider_write_env "$aname" "$keyvar" "$alias_transport" "$alias_url" "$strong" "$ffast" "$cdir" "$alias_ctx" "$alias_max" "$aname"
      cma_provider_write_alias "$aname" "$aname"

      cma_log "  alias '$aname': strong=$strong fast=$ffast [$alias_transport]"
      n_created=$((n_created+1))
      i=$((i+1))
    done

  done < <(jq -r '.[] | [.status,.provider_id,.alias,.key_var,.transport,.base_url,.strong_model,.fast_model,.context_limit,.max_output] | @tsv' <<<"$records")

  cma_log "multi-sync done: $n_created aliases created across all providers"
  cma_log "reload your shell or: source $ALIAS_FILE"
}

# --- arg parsing + dispatch -------------------------------------------------
SUBCMD="sync"
case "${1:-}" in
  sync|list|list-all|list-faulty|show|verify|remove|add) SUBCMD="$1"; shift ;;
  -h|--help) usage; exit 0 ;;
esac
POSITIONAL=()
while (( $# )); do
  # shellcheck disable=SC2034  # ASSUME_YES (-y/--yes) accepted as a no-op; reserved
  case "$1" in
    --keys-file) CMA_KEYS_FILE="$2"; shift 2 ;;
    --no-verify) NO_VERIFY=1; shift ;;
    --offline) OFFLINE=1; shift ;;
    --dry-run) DRY_RUN=1; shift ;;
    --refresh-aliases) REFRESH_ALIASES=1; shift ;;
    --quiet) QUIET=1; shift ;;
    --multi) MULTI=1; shift ;;
    --max-aliases) MAX_ALIASES="$2"; shift 2 ;;
    --min-score) MIN_SCORE="$2"; shift 2 ;;
    --verify-concurrency) VERIFY_CONCURRENCY="$2"; shift 2 ;;
    -y|--yes) ASSUME_YES=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

# --refresh-aliases: rebuild every provider's alias shell line from its cached
# env file — NO network, NO probe. This is the session hook's fast path (run on
# each interactive shell start). Runs before dispatch so `list --refresh-aliases`
# refreshes then exits without printing the (verified-only) list.
if (( REFRESH_ALIASES )); then
  _rpdir="$(cma_providers_dir)"
  if [[ -d "$_rpdir" ]] && compgen -G "$_rpdir/*.env" >/dev/null; then
    for _rf in "$_rpdir"/*.env; do
      # shellcheck disable=SC1090
      _rid="$( ( set -a; . "$_rf"; set +a; printf '%s' "${CMA_PROVIDER_ID:-}" ) )"
      # shellcheck disable=SC1090
      _ral="$( ( set -a; . "$_rf"; set +a; printf '%s' "${CMA_PROVIDER_ALIAS:-}" ) )"
      [[ -n "$_rid" ]] || continue
      [[ -n "$_ral" ]] || _ral="$_rid"
      cma_provider_write_alias "$_ral" "$_rid" 2>/dev/null || true
    done
  fi
  (( QUIET )) || cma_log "refreshed provider aliases from cache (no network)"
  exit 0
fi

case "$SUBCMD" in
  sync)        if (( MULTI )); then cmd_sync_multi; else cmd_sync; fi ;;
  list)        cmd_list ;;
  list-all)    cmd_list_all ;;
  list-faulty) cmd_list_faulty ;;
  show)        cmd_show "${POSITIONAL[@]:-}" ;;
  verify)      cmd_verify "${POSITIONAL[@]:-}" ;;
  remove)      cmd_remove "${POSITIONAL[@]:-}" ;;
  add)         cmd_add "${POSITIONAL[@]:-}" ;;
esac
