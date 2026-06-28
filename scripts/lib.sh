#!/usr/bin/env bash
# lib.sh — shared functions for the Claude multi-account toolkit.
# Sourced by the other scripts; no side effects on its own.

set -euo pipefail

# Which rc files to source the alias file from. macOS interactive shell is
# zsh; touching .bashrc there just creates noise the user has to clean up.
# On Linux we keep both because either may be the login shell.
if [[ "$(uname -s)" == "Darwin" ]]; then
  CMA_RC_FILES=("$HOME/.zshrc")
else
  CMA_RC_FILES=("$HOME/.bashrc" "$HOME/.zshrc")
fi

# Resolve paths the user can override. SHARED_DIR is the single canonical
# location for cross-account state; ALIAS_FILE is the rc-sourced file we
# manage aliases through; ACCOUNT_PREFIX is the dir-name prefix for new
# per-account config directories.
: "${SHARED_DIR:=$HOME/.claude-shared}"
: "${ALIAS_FILE:=$HOME/.local/share/claude-multi-account/aliases.sh}"
: "${ACCOUNT_PREFIX:=.claude-}"

CLAUDE_BIN_DEFAULT="${CLAUDE_BIN:-$HOME/.local/bin/claude}"

cma_log()  { printf '\033[36m[cma]\033[0m %s\n' "$*" >&2; }
cma_warn() { printf '\033[33m[cma warn]\033[0m %s\n' "$*" >&2; }
cma_err()  { printf '\033[31m[cma err]\033[0m %s\n' "$*" >&2; }
cma_die()  { cma_err "$*"; exit 1; }

cma_require() {
  command -v "$1" >/dev/null 2>&1 || cma_die "missing required tool: $1"
}

# Keys inside .claude.json that must NEVER leak across accounts (auth + identity).
# Everything else in .claude.json — projects map, UX state, caches, etc. — is
# safely shareable. New auth keys should be added here, not assumed shareable.
CMA_CLAUDE_JSON_PRIVATE_KEYS='["userID","oauthAccount","firstStartTime","claudeCodeFirstTokenDate"]'

# Deep-merge every account's .claude.json so each account's file ends up with
# its OWN auth keys + the UNION of all other top-level keys (rightmost-wins
# for scalar conflicts, recursive object merge for `projects` and friends).
#
# Args: one or more account config dirs.
# Side effect: rewrites each $acct/.claude.json in place. Skips an account
# that doesn't yet have a .claude.json (e.g. brand-new dir before first login).
cma_merge_claude_json() {
  local accts=("$@")
  (( ${#accts[@]} >= 1 )) || return 0
  cma_require jq

  # Build the merged "shared portion" (everything except private keys).
  local shared_tmp; shared_tmp="$(mktemp)"
  printf '{}\n' > "$shared_tmp"
  local acct prev="$shared_tmp"
  for acct in "${accts[@]}"; do
    local f="$acct/.claude.json"
    [[ -s "$f" ]] || continue
    local next; next="$(mktemp)"
    # $a (accumulator) * ($b stripped of private keys). jq's `*` is recursive
    # deep-merge for objects; rightmost wins on scalar conflicts.
    if ! jq -s --argjson priv "$CMA_CLAUDE_JSON_PRIVATE_KEYS" '
      . as [$a, $b]
      | ($b | with_entries(select(.key as $k | $priv | index($k) | not))) as $shared_b
      | ($a // {}) * ($shared_b // {})
    ' "$prev" "$f" > "$next"; then
      rm -f "$next"
      cma_warn ".claude.json in $acct is not valid JSON — skipping its contribution"
      continue
    fi
    rm -f "$prev"
    prev="$next"
  done

  # Now $prev holds the merged shared portion. Write each account's file with
  # its own private keys overlaid on top of the shared portion.
  for acct in "${accts[@]}"; do
    local f="$acct/.claude.json" out
    out="$(mktemp)"
    if [[ -s "$f" ]]; then
      # Guard against set -e: a corrupt $f makes jq fail, which would abort
      # the whole loop and leave the remaining accounts unsynced.
      if ! jq -s --argjson priv "$CMA_CLAUDE_JSON_PRIVATE_KEYS" '
        . as [$shared, $own]
        | ($own | with_entries(select(.key as $k | $priv | index($k)))) as $priv_only
        | ($shared // {}) * $priv_only
      ' "$prev" "$f" > "$out" 2>/dev/null; then
        rm -f "$out"
        cma_warn ".claude.json for $acct could not be merged (invalid JSON?) — leaving original alone"
        continue
      fi
    else
      # New account, no existing .claude.json. Seed with shared content only.
      cp "$prev" "$out"
    fi
    # Final sanity: only replace if the output is parseable JSON.
    if jq -e . "$out" >/dev/null 2>&1; then
      mv "$out" "$f"
    else
      rm -f "$out"
      cma_warn "merged .claude.json for $acct was invalid — leaving original file untouched"
    fi
  done
  rm -f "$prev"
}

# Detect Linux vs macOS for platform-specific commands.
cma_os() {
  case "$(uname -s)" in
    Linux*)   echo linux ;;
    Darwin*)  echo macos ;;
    *)        echo unknown ;;
  esac
}

# Portable realpath. BSD/macOS `readlink` has no `-f`, so `readlink -f` is a hard
# error there (prints "illegal option -- f", returns empty) even after a bash-4
# re-exec, because /usr/bin/readlink stays BSD. This resolves a path to its
# canonical absolute form by walking the symlink chain with single-arg
# `readlink` (supported everywhere) plus `pwd -P` — the same technique every
# script's LIB_DIR resolver uses. Safe under `set -e`.
cma_realpath() {
  local p="$1" t dir base
  while [ -L "$p" ]; do
    t="$(readlink "$p")"
    case "$t" in /*) p="$t" ;; *) p="$(dirname "$p")/$t" ;; esac
  done
  dir="$(cd "$(dirname "$p")" 2>/dev/null && pwd -P)" || dir="$(dirname "$p")"
  base="$(basename "$p")"
  printf '%s/%s\n' "$dir" "$base"
}

# Find all existing Claude account config directories under $HOME, matching
# the convention `.claude-<name>`. Echoes absolute paths, one per line,
# sorted. The default `~/.claude` is intentionally excluded because we treat
# it as the shared user-scope spot, not an account dir.
cma_detect_accounts() {
  local d
  while IFS= read -r d; do
    [[ "$d" == *"-shared" ]] && continue
    # Provider-alias dirs (~/.claude-prov-<id>, created by claude-providers)
    # are account-like for SHARED state but must NEVER be merged into
    # real-account auth/identity or unify, so they're excluded from detection
    # exactly like *-shared. This is the linchpin that keeps the existing
    # claudeN accounts and add-account untouched by the provider feature.
    [[ "$(basename "$d")" == "${ACCOUNT_PREFIX}prov-"* ]] && continue
    # Empty dirs always count (a brand-new account before any claude run).
    if [[ -z "$(ls -A "$d" 2>/dev/null)" ]]; then
      echo "$d"
      continue
    fi
    # Non-empty: must look like a Claude account (at least one tell-tale
    # file/dir). Filters out dirs that merely match the `.claude-*` prefix
    # but belong to other tools (e.g. `.claude-server-commander`).
    if [[ -d "$d/projects" || -d "$d/todos" || -d "$d/plugins" \
       || -f "$d/.claude.json" || -f "$d/.credentials.json" \
       || -f "$d/history.jsonl" ]]; then
      echo "$d"
    fi
  done < <(find "$HOME" -maxdepth 1 -type d -name "${ACCOUNT_PREFIX}*" 2>/dev/null | sort)
}

# Read all aliases of the form `alias name=...` from $ALIAS_FILE and print
# their names (one per line). Returns nothing if the file is absent.
cma_existing_aliases() {
  [[ -f "$ALIAS_FILE" ]] || return 0
  awk -F'[ =]+' '/^[[:space:]]*alias[[:space:]]+/{print $2}' "$ALIAS_FILE"
}

# Suggest the next free `claude<N>` alias by scanning current aliases.
# E.g., if claude1 and claude2 exist, returns "claude3".
cma_suggest_alias() {
  local highest=0 n
  for a in $(cma_existing_aliases); do
    if [[ "$a" =~ ^claude([0-9]+)$ ]]; then
      n="${BASH_REMATCH[1]}"
      (( n > highest )) && highest="$n"
    fi
  done
  echo "claude$((highest + 1))"
}

# Validate that an alias name is safe to embed in a generated `alias ...=`
# line — strictly alphanumeric + underscore/hyphen, starting with a letter.
cma_validate_alias() {
  [[ "$1" =~ ^[a-zA-Z][a-zA-Z0-9_-]*$ ]] || cma_die "invalid alias name: $1"
}

# Ensure $ALIAS_FILE exists with the header sentinel and is sourced from
# the user's rc files. Idempotent — safe to call repeatedly.
cma_ensure_alias_file() {
  mkdir -p "$(dirname "$ALIAS_FILE")"
  if [[ ! -f "$ALIAS_FILE" ]]; then
    cat > "$ALIAS_FILE" <<EOF
# Managed by claude-multi-account. Do not edit by hand; use
# ~/.local/bin/claude-add-account to add accounts.
export CLAUDE_BIN="${CLAUDE_BIN_DEFAULT}"
EOF
  fi
  # Migration: rewrite any pre-wrapper alias lines that invoke $CLAUDE_BIN
  # directly so they go through cma_run instead. Pre-existing installs need
  # this on the first re-run of install.sh after the runtime-sync feature
  # landed; idempotent (a line already using cma_run is left alone).
  if grep -qE '^alias[[:space:]]+[^=]+=.*CLAUDE_CONFIG_DIR=[^ ]+[[:space:]]+\\?\$CLAUDE_BIN"$' "$ALIAS_FILE"; then
    local tmp; tmp="$(mktemp)"
    sed -E 's|(^alias[[:space:]]+[^=]+=)"(CLAUDE_CONFIG_DIR=[^ ]+)[[:space:]]+\\?\$CLAUDE_BIN"$|\1"\2 cma_run"|' "$ALIAS_FILE" > "$tmp"
    mv "$tmp" "$ALIAS_FILE"
    cma_log "migrated existing aliases in $ALIAS_FILE to use cma_run wrapper"
  fi
  # Ensure the cma_run wrapper is present in the alias file. This is the
  # runtime hook that keeps .claude.json projects/session state synchronized
  # across every account: pull merged state before launch, push back after exit.
  if ! grep -q '^cma_run\(\)' "$ALIAS_FILE"; then
    cat >> "$ALIAS_FILE" <<'EOF'

# Wrapper: keeps .claude.json projects/session index synced across every
# logged-in account. Pulls merged state from every account into the launching
# one before claude runs; pushes the post-session state back out after exit.
# Cheap (jq deep-merge of one ~50KB file per account), runs unconditionally.
cma_run() {
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" pull "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  "$CLAUDE_BIN" "$@"
  local rc=$?
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" push "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  return $rc
}
EOF
  fi
  # Ensure the cma_run_provider wrapper is present. This launches Claude Code
  # against a non-Anthropic provider: it reads the per-provider non-secret env
  # file, injects the API key from the keys file at launch (the toolkit never
  # persists secrets itself), then runs claude directly (native transport) or
  # via claude-code-router (router transport). Self-contained: the user's shell
  # sources only this alias file, not lib.sh.
  #
  # Migration: if cma_run_provider exists but its body is missing the
  # sync-state call, it's an outdated version that breaks cross-provider
  # /resume. Remove ONLY the function block (keeping any alias lines that
  # follow it) so the correct version gets re-appended below.
  #
  # The detection MUST be scoped to the function body and match the real
  # on-disk text. Two prior bugs lived here:
  #   1. cma_run also contains a sync-state call, so a whole-file grep can
  #      never tell an outdated provider wrapper from a current one.
  #   2. The emitted text is `…/claude-sync-state" pull` — a quote precedes
  #      the space — so grepping for "claude-sync-state pull" (with a space)
  #      never matched, making the migration mis-fire on EVERY alias write.
  #      That chopped previously-written aliases (and claudeN aliases that
  #      come after the functions), corrupting the alias file.
  # We now extract the function body (cma_run_provider() .. its closing
  # brace) and match the bare command name, which is quote/space agnostic.
  # Regenerate when the installed function predates EITHER fix: the
  # cross-provider sync-state calls ('claude-sync-state'), or the
  # nounset-safe keys sourcing ('set -a +u'). Both markers live only in the
  # current heredoc, so once regenerated the function stops re-triggering.
  if grep -q '^cma_run_provider()' "$ALIAS_FILE"; then
    local _prov_body
    _prov_body="$(awk '/^cma_run_provider\(\)/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
    if ! printf '%s\n' "$_prov_body" | grep -q 'claude-sync-state' || \
       ! printf '%s\n' "$_prov_body" | grep -q 'set -a +u'; then
      local tmp_prov; tmp_prov="$(mktemp)"
      # Drop only the function block; preserve everything before and after it.
      awk '
        /^cma_run_provider\(\)/ { skip=1 }
        skip && /^}/            { skip=0; next }
        !skip                   { print }
      ' "$ALIAS_FILE" > "$tmp_prov"
      mv "$tmp_prov" "$ALIAS_FILE"
      cma_log "migrated outdated cma_run_provider (sync-state + nounset-safe keys)"
    fi
  fi
  if ! grep -q '^cma_run_provider\(\)' "$ALIAS_FILE"; then
    cat >> "$ALIAS_FILE" <<'EOF'

cma_run_provider() {
  local id="$1"; shift 2>/dev/null || true
  local pdir="$HOME/.local/share/claude-multi-account/providers"
  local envf="$pdir/$id.env"
  if [[ ! -f "$envf" ]]; then
    printf 'claude-providers: unknown provider %s (missing %s)\n' "$id" "$envf" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$envf"
  local keysf="${CMA_KEYS_FILE:-$HOME/api_keys.sh}"
  # Disable nounset while sourcing the user-controlled keys file: it may have
  # dangling refs (e.g. `export X=$UNSET`) that would abort the source under a
  # caller's `set -u`, leaving the token empty. Save/restore so we never change
  # the user's interactive shell options.
  if [[ -f "$keysf" ]]; then
    case $- in *u*) local _cma_had_u=1 ;; *) local _cma_had_u=0 ;; esac
    set -a +u; source "$keysf"; set +a
    (( _cma_had_u )) && set -u
  fi
  # Indirect-expand the key var name. ${!var} is bash-only and a fatal error in
  # zsh (the default macOS interactive shell this alias file is sourced into),
  # so use eval, which works in both. CMA_PROVIDER_KEYVAR is a validated env
  # var name ([A-Za-z_][A-Za-z0-9_]*), so this eval is safe.
  local token=""
  eval "token=\"\${$CMA_PROVIDER_KEYVAR:-}\""
  if [[ -z "$token" ]]; then
    printf 'claude-providers: $%s is empty (set it in %s)\n' "$CMA_PROVIDER_KEYVAR" "$keysf" >&2
    return 1
  fi
  export CLAUDE_CONFIG_DIR="$CMA_PROVIDER_CONFIG_DIR"
  # Sync .claude.json projects/session index across ALL accounts and providers
  # so sessions created under any alias are visible from every other alias.
  # Pull merged state before launch; push post-session state after exit.
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" pull "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  local rc
  local _proxy_pid=""
  if [[ "${CMA_PROVIDER_TRANSPORT:-native}" == "router" ]]; then
    if ! command -v ccr >/dev/null 2>&1; then
      printf 'claude-providers: provider %s needs claude-code-router.\n  Install: npm install -g @musistudio/claude-code-router\n' "$id" >&2
      return 127
    fi
    # Upsert THIS provider into ccr config with the live key (regenerated each
    # launch, chmod 600 — never stored by the toolkit), set it as the active
    # route, then launch through ccr.
    local cfg="$HOME/.claude-code-router/config.json" base="$CMA_PROVIDER_BASE_URL"
    # Create the dir + config with restrictive perms from the start: this file
    # will hold the live API key, so it must never be group/world readable,
    # even transiently or if a later jq rewrite fails.
    ( umask 077; mkdir -p "$HOME/.claude-code-router"
      [[ -f "$cfg" ]] || echo '{"Providers":[],"Router":{}}' > "$cfg" )
    chmod 600 "$cfg" 2>/dev/null || true
    case "$base" in
      */chat/completions|*/v1beta/models/|*/v1beta/models) ;;
      *) base="${base%/}/chat/completions" ;;
    esac
    # Start compatibility proxy if the provider needs one (e.g. Poe requires
    # `parameters` in tool definitions; Claude Code sometimes omits it).
    # Check for provider-specific proxy or base proxy (poe2 -> poe_proxy).
    local _base_id="${CMA_PROVIDER_ID%%[0-9]*}"
    local _proxy_script=""
    if [[ -x "$LIB_DIR/proxy/${CMA_PROVIDER_ID}_proxy.py" ]]; then
      _proxy_script="$LIB_DIR/proxy/${CMA_PROVIDER_ID}_proxy.py"
    elif [[ -x "$LIB_DIR/proxy/${_base_id}_proxy.py" ]]; then
      _proxy_script="$LIB_DIR/proxy/${_base_id}_proxy.py"
    fi
    if [[ -n "$_proxy_script" ]]; then
      local _proxy_port=3457
      python3 "$_proxy_script" --port "$_proxy_port" &
      _proxy_pid=$!
      local _waited=0
      while ! lsof -i :$_proxy_port >/dev/null 2>&1 && (( _waited < 25 )); do
        sleep 0.2
        _waited=$((_waited + 1))
      done
      base="http://127.0.0.1:${_proxy_port}/v1/chat/completions"
      cma_log "started proxy for $CMA_PROVIDER_ID on port $_proxy_port (pid=$_proxy_pid)"
    fi
    if command -v jq >/dev/null 2>&1; then
      local tmp; tmp="$(mktemp)"; chmod 600 "$tmp" 2>/dev/null || true
      # Pass the secret through the environment ($ENV.tok), never as a jq argv
      # argument — argv is visible in ps/proc to other local users.
      if CMA_TOK="$token" jq --arg n "$CMA_PROVIDER_ID" --arg u "$base" \
            --arg s "$CMA_PROVIDER_MODEL" --arg f "${CMA_PROVIDER_FAST_MODEL:-$CMA_PROVIDER_MODEL}" '
          .Providers = ([ .Providers[]? | select(.name != $n) ]
            + [{name:$n, api_base_url:$u, api_key:$ENV.CMA_TOK, models:[$s,$f],
                transformer:{use:["cleancache","streamoptions"]}}])
          | .Router.default = ($n + "," + $s)
          | .Router.background = ($n + "," + $f)
        ' "$cfg" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$cfg"; chmod 600 "$cfg" 2>/dev/null || true
        ccr restart >/dev/null 2>&1 || true
      else
        rm -f "$tmp"
      fi
    fi
    ccr code "$@"; rc=$?
    # Stop proxy if we started one
    if [[ -n "$_proxy_pid" ]]; then
      kill "$_proxy_pid" 2>/dev/null || true
      cma_log "stopped proxy for $CMA_PROVIDER_ID (pid=$_proxy_pid)"
    fi
  else
    export ANTHROPIC_BASE_URL="$CMA_PROVIDER_BASE_URL"
    export ANTHROPIC_AUTH_TOKEN="$token"
    export ANTHROPIC_MODEL="$CMA_PROVIDER_MODEL"
    [[ -n "${CMA_PROVIDER_FAST_MODEL:-}" ]] && export ANTHROPIC_SMALL_FAST_MODEL="$CMA_PROVIDER_FAST_MODEL"
    "$CLAUDE_BIN" "$@"; rc=$?
  fi
  # Push post-session state back to all accounts/providers for cross-alias visibility.
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" push "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  return $rc
}
EOF
  fi
  local rc src_line="source \"$ALIAS_FILE\""
  for rc in "${CMA_RC_FILES[@]}"; do
    [[ -f "$rc" ]] || continue
    if ! grep -F -q "$src_line" "$rc"; then
      printf '\n# Claude multi-account aliases\n%s\n' "$src_line" >> "$rc"
      cma_log "added source line to $rc"
    fi
  done
}

# Add (or refresh) a single alias entry in $ALIAS_FILE. Idempotent.
# The generated alias wraps `$CLAUDE_BIN` with sync-pull (before launch) and
# sync-push (after exit) so the project/session index inside .claude.json
# stays merged across every logged-in account without manual unify runs.
cma_write_alias() {
  local alias_name="$1" config_dir="$2"
  cma_validate_alias "$alias_name"
  cma_ensure_alias_file
  # Strip any prior line for this alias, then append the new one.
  local tmp; tmp="$(mktemp)"
  grep -v -E "^alias[[:space:]]+${alias_name}=" "$ALIAS_FILE" > "$tmp" || true
  # Note: bash aliases can't take args, so we use a quoted CLAUDE_CONFIG_DIR= prefix
  # plus a wrapped invocation. The wrapper is a shell function reference (cma_run)
  # defined alongside in the alias file (added once by cma_ensure_alias_file).
  printf 'alias %s="CLAUDE_CONFIG_DIR=%s cma_run"\n' \
    "$alias_name" "$config_dir" >> "$tmp"
  mv "$tmp" "$ALIAS_FILE"
}

# Remove an alias line. Idempotent.
cma_remove_alias() {
  local alias_name="$1"
  [[ -f "$ALIAS_FILE" ]] || return 0
  local tmp; tmp="$(mktemp)"
  grep -v -E "^alias[[:space:]]+${alias_name}=" "$ALIAS_FILE" > "$tmp" || true
  mv "$tmp" "$ALIAS_FILE"
}

# ===========================================================================
# Provider-alias helpers (used by claude-providers.sh)
# ===========================================================================

# The shared items every account/provider dir symlinks into $SHARED_DIR.
# Kept here (single source) so claude-add-account and claude-providers agree.
CMA_SHARED_ITEMS=(
  projects todos tasks plans file-history paste-cache shell-snapshots
  session-env telemetry sessions backups cache plugins
  stats-cache.json history.jsonl settings.json CLAUDE.md
)

cma_providers_dir() { echo "$HOME/.local/share/claude-multi-account/providers"; }

# Symlink every shared item into a config dir (account or provider), creating
# empty placeholders in $SHARED_DIR for any item that doesn't exist yet.
# Idempotent: skips items already present in the target.
cma_link_shared_items() {
  local cdir="$1" item src tgt
  mkdir -p "$SHARED_DIR" "$cdir"
  for item in "${CMA_SHARED_ITEMS[@]}"; do
    src="$SHARED_DIR/$item"; tgt="$cdir/$item"
    if [[ ! -e "$src" ]]; then
      case "$item" in
        *.json|*.jsonl|*.md) : > "$src" ;;
        *) mkdir -p "$src" ;;
      esac
    fi
    [[ -e "$tgt" || -L "$tgt" ]] || ln -s "$src" "$tgt"
  done
}

# Force-enable the always-on plugins in the shared settings.json enabledPlugins
# map (additive union — never removes a user's existing entries). Each arg is a
# plugin key as it appears in enabledPlugins (e.g. "superpowers@anthropics").
cma_enable_plugins() {
  cma_require jq
  local settings="$SHARED_DIR/settings.json" tmp
  mkdir -p "$SHARED_DIR"
  [[ -s "$settings" ]] || printf '{}\n' > "$settings"
  tmp="$(mktemp)"
  local args=() p
  for p in "$@"; do args+=(--arg "p$((${#args[@]}/2))" "$p"); done
  # Build a jq program that sets each provided key true if absent.
  local prog='.enabledPlugins //= {}'
  local i=0
  for p in "$@"; do
    prog+=" | .enabledPlugins[\$p$i] //= true"; i=$((i+1))
  done
  # ${args[@]+...} guards an empty array under set -u on bash 3.2 (reachable
  # via CMA_ALWAYS_ON_PLUGINS="" from non-re-exec'd claude-providers.sh).
  if jq ${args[@]+"${args[@]}"} "$prog" "$settings" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$settings"
  else
    rm -f "$tmp"; cma_warn "could not update enabledPlugins in $settings"
  fi
}

# Write the non-secret per-provider env file consumed by cma_run_provider.
# Args: id keyvar transport base_url model fast_model config_dir
cma_provider_write_env() {
  local id="$1" keyvar="$2" transport="$3" base="$4" model="$5" fast="$6" cdir="$7"
  # Normalize the literal "null" (from a missing JSON field) to empty so it
  # never leaks into the wrapper as a bogus value.
  [[ "$base" == "null" ]] && base=""
  [[ "$fast" == "null" ]] && fast=""
  local pdir; pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
  # Values are single-quoted (with embedded-quote escaping) so sourcing the file
  # in the user's shell is safe regardless of characters in URLs/model ids.
  _cma_q() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
  cat > "$pdir/$id.env" <<EOF
# generated by claude-providers — non-secret. Do not edit by hand.
# Secrets are NEVER stored here; the key is read from the keys file at launch.
CMA_PROVIDER_ID=$(_cma_q "$id")
CMA_PROVIDER_KEYVAR=$(_cma_q "$keyvar")
CMA_PROVIDER_TRANSPORT=$(_cma_q "$transport")
CMA_PROVIDER_BASE_URL=$(_cma_q "$base")
CMA_PROVIDER_MODEL=$(_cma_q "$model")
CMA_PROVIDER_FAST_MODEL=$(_cma_q "$fast")
CMA_PROVIDER_CONFIG_DIR=$(_cma_q "$cdir")
EOF
  unset -f _cma_q
}

# Write (or refresh) a provider alias: alias <name>="cma_run_provider <id>".
cma_provider_write_alias() {
  local alias_name="$1" id="$2"
  cma_validate_alias "$alias_name"
  cma_ensure_alias_file
  local tmp; tmp="$(mktemp)"
  grep -v -E "^alias[[:space:]]+${alias_name}=" "$ALIAS_FILE" > "$tmp" || true
  printf 'alias %s="cma_run_provider %s"\n' "$alias_name" "$id" >> "$tmp"
  mv "$tmp" "$ALIAS_FILE"
}

# True only when the toolkit may prompt the user interactively. Scripts read
# confirmations from /dev/tty (so prompts survive `curl | bash`), so this
# probes /dev/tty rather than stdin. It returns false when:
#   * CMA_NONINTERACTIVE=1 is exported — a global "never prompt" switch for
#     automation, CI, and the test suite (deterministic regardless of TTY); or
#   * no terminal is available — CI, a test sandbox, an SSH command with no PTY.
# When it returns false, callers MUST fall back to their non-interactive
# default instead of blocking or erroring on a failed read. This is what makes
# toolkit execution always non-interactive off a terminal.
cma_can_prompt() {
  [[ "${CMA_NONINTERACTIVE:-}" == 1 ]] && return 1
  ( exec </dev/tty ) 2>/dev/null
}
