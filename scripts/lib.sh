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

# Resolve the Claude Code binary for the alias wrappers. Prefer an explicit
# CLAUDE_BIN, then $PATH, then the common install locations. npm's global prefix
# varies per host (e.g. ~/.npm-global vs ~/.local vs Homebrew), so a fixed
# ~/.local/bin default mis-points on hosts where `npm i -g @anthropic-ai/...`
# landed elsewhere — making EVERY alias launch fail "No such file". Checking
# the real locations keeps a fresh install working without a manual symlink.
cma_resolve_claude_bin() {
  if [ -n "${CLAUDE_BIN:-}" ]; then printf '%s\n' "$CLAUDE_BIN"; return 0; fi
  local c; if c="$(command -v claude 2>/dev/null)"; then printf '%s\n' "$c"; return 0; fi
  local p
  for p in "$HOME/.local/bin/claude" "$HOME/.npm-global/bin/claude" \
           /opt/homebrew/bin/claude /usr/local/bin/claude; do
    [ -x "$p" ] && { printf '%s\n' "$p"; return 0; }
  done
  printf '%s\n' "$HOME/.local/bin/claude"   # fallback (created by install/symlink)
}
CLAUDE_BIN_DEFAULT="$(cma_resolve_claude_bin)"

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
  local shared_tmp; shared_tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  printf '{}\n' > "$shared_tmp"
  local acct prev="$shared_tmp"
  for acct in "${accts[@]}"; do
    local f="$acct/.claude.json"
    [[ -s "$f" ]] || continue
    local next; next="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
    # $a (accumulator) * ($b stripped of private keys). jq's `*` is recursive
    # deep-merge for objects; rightmost wins on scalar conflicts AND on array
    # values (arrays are replaced, not element-unioned — e.g. a per-project
    # prompt-history array takes the last account's copy). This is a deliberate
    # deep-merge trade-off: the projects subtree is unioned at the object-key
    # level (which is what the cross-account session/MCP/memory index needs);
    # blind element-level array union would be wrong for config-style arrays.
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

  # Sticky-true TRUST preservation (§11.4 anti-bluff config hygiene): the jq `*`
  # merge above is last-writer-wins on scalars, so a per-project
  # `projects[<path>].hasTrustDialogAccepted` bit trusted under one alias could be
  # DEMOTED true->false by a later account that lacks it — which made Claude Code's
  # per-workspace trust dialog ("read, edit, and execute files here") reappear on
  # every provider alias. Fix: OR the trust bit across all accounts — once a
  # project path is trusted anywhere, it stays trusted in the merged portion.
  local _tr_files=() _tr_acct
  for _tr_acct in "${accts[@]}"; do [[ -s "$_tr_acct/.claude.json" ]] && _tr_files+=("$_tr_acct/.claude.json"); done
  if (( ${#_tr_files[@]} >= 1 )); then
    local _trusted
    _trusted="$(jq -s '[ .[] | (.projects // {}) | to_entries[]
                        | select(.value.hasTrustDialogAccepted == true) | .key ] | unique' \
                "${_tr_files[@]}" 2>/dev/null || printf '[]')"
    if [[ -n "$_trusted" && "$_trusted" != "[]" ]]; then
      local _tt; _tt="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
      if jq --argjson trusted "$_trusted" '
            .projects //= {}
            | reduce ($trusted[]) as $p (.; .projects[$p].hasTrustDialogAccepted = true)
          ' "$prev" > "$_tt" 2>/dev/null && jq -e . "$_tt" >/dev/null 2>&1; then
        mv "$_tt" "$prev"
      else rm -f "$_tt"; fi
    fi
  fi

  # Now $prev holds the merged shared portion. Write each account's file with
  # its own private keys overlaid on top of the shared portion.
  for acct in "${accts[@]}"; do
    local f="$acct/.claude.json" out
    out="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
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

# Match an rc-file line that sources an aliases.sh, capturing the path:
#   BASH_REMATCH[2] = the (possibly $HOME/~/quoted) target path.
# Anchored so leading-# comment lines (e.g. "# migrated to …/aliases.sh: …")
# never match. Used by the prune + dedup helpers below.
CMA_ALIAS_SRC_RE='^[[:space:]]*(source|\.)[[:space:]]+"?([^"[:space:]]*aliases\.sh)"?[[:space:]]*$'

# Remove rc-file lines that source an aliases.sh whose target no longer exists
# (a stale path from a moved install, or a transient ALIAS_FILE used in testing).
# Without this, a deleted alias file leaves a dangling line that errors
# "-bash: …/aliases.sh: No such file or directory" on every new login shell.
cma_prune_stale_alias_sources() {
  local rc="$1" tmp line target changed=0
  [[ -f "$rc" ]] || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")" || return 0
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $CMA_ALIAS_SRC_RE ]]; then
      target="${BASH_REMATCH[2]}"; target="${target/#\$HOME/$HOME}"; target="${target/#\~/$HOME}"
      if [[ ! -f "$target" ]]; then changed=1; continue; fi
    fi
    printf '%s\n' "$line" >> "$tmp"
  done < "$rc"
  if (( changed )); then mv "$tmp" "$rc"; cma_log "pruned stale aliases.sh source line(s) from $rc"; else rm -f "$tmp"; fi
}

# True if $rc already sources a file resolving to $2 (across `.`/`source` and
# $HOME/~/absolute forms), so we never append a duplicate source line.
cma_rc_sources_alias_file() {
  local rc="$1" want="$2" line target want_real
  [[ -f "$rc" ]] || return 1
  want_real="$(cma_realpath "$want" 2>/dev/null || printf '%s' "$want")"
  while IFS= read -r line || [[ -n "$line" ]]; do
    if [[ "$line" =~ $CMA_ALIAS_SRC_RE ]]; then
      target="${BASH_REMATCH[2]}"; target="${target/#\$HOME/$HOME}"; target="${target/#\~/$HOME}"
      [[ "$(cma_realpath "$target" 2>/dev/null || printf '%s' "$target")" == "$want_real" ]] && return 0
    fi
  done < "$rc"
  return 1
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
  # shellcheck disable=SC2016  # $CLAUDE_BIN is a literal in the regex/sed pattern, not a shell expansion
  if grep -qE '^alias[[:space:]]+[^=]+=.*CLAUDE_CONFIG_DIR=[^ ]+[[:space:]]+\\?\$CLAUDE_BIN"$' "$ALIAS_FILE"; then
    local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
    # shellcheck disable=SC2016  # $CLAUDE_BIN is a literal in the sed pattern, matching alias file content
    sed -E 's|(^alias[[:space:]]+[^=]+=)"(CLAUDE_CONFIG_DIR=[^ ]+)[[:space:]]+\\?\$CLAUDE_BIN"$|\1"\2 cma_run"|' "$ALIAS_FILE" > "$tmp"
    mv "$tmp" "$ALIAS_FILE"
    cma_log "migrated existing aliases in $ALIAS_FILE to use cma_run wrapper"
  fi
  # Migration: an existing alias file may carry a stale CLAUDE_BIN pointing at a
  # path that does not exist on THIS host (e.g. ~/.local/bin/claude when npm put
  # claude in ~/.npm-global/bin — the amber.local case). If the recorded
  # CLAUDE_BIN is not executable, rewrite it to a resolved one so every alias
  # launch finds claude without a manual symlink.
  local _cur_cb _cur_cb_exp _new_cb
  # `|| _cur_cb=""` is LOAD-BEARING: under `set -euo pipefail` a no-match grep
  # (an older/hand-edited alias file with no `export CLAUDE_BIN=` line) would
  # abort cma_ensure_alias_file mid-run.
  _cur_cb="$(grep -m1 '^export CLAUDE_BIN=' "$ALIAS_FILE" 2>/dev/null)" || _cur_cb=""
  _cur_cb="${_cur_cb#export CLAUDE_BIN=}"; _cur_cb="${_cur_cb#\"}"; _cur_cb="${_cur_cb%\"}"
  _cur_cb_exp="${_cur_cb/#\$HOME/$HOME}"; _cur_cb_exp="${_cur_cb_exp/#\~/$HOME}"
  if [[ -n "$_cur_cb" && ! -x "$_cur_cb_exp" ]]; then
    _new_cb="$(cma_resolve_claude_bin)"
    if [[ "$_new_cb" != "$_cur_cb" && -x "${_new_cb/#\$HOME/$HOME}" ]]; then
      local tmp_cb; tmp_cb="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
      sed "s|^export CLAUDE_BIN=.*|export CLAUDE_BIN=\"$_new_cb\"|" "$ALIAS_FILE" > "$tmp_cb"
      mv "$tmp_cb" "$ALIAS_FILE"
      cma_log "migrated stale CLAUDE_BIN -> $_new_cb"
    fi
  fi
  # Migration: regenerate an outdated cma_run that lacks the provider-env
  # isolation guard (the 'unset ANTHROPIC_' marker). Without it, a native
  # claudeN launched in a shell that previously ran a provider alias would
  # INHERIT that provider's exported ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL and
  # talk to the wrong API (e.g. claude1 hitting xiaomi's endpoint). Drop only
  # the function block; the correct version is re-appended below.
  # NOTE: match with LITERAL parens `^cma_run()` — NOT `^cma_run\(\)`. In both
  # grep BRE and awk ERE, `\(\)` is an *empty capture group* that matches the
  # empty string, so `^cma_run\(\)` matches any line starting with "cma_run",
  # INCLUDING "cma_run_provider()". That false match made the re-append guard
  # below think cma_run still existed after it was stripped, dropping the
  # function entirely. Literal `()` matches only the real cma_run() header.
  # Regenerate cma_run if its body is missing ANY current marker:
  #   * 'unset ANTHROPIC_' — provider-env isolation (native must not inherit a
  #     provider endpoint left exported in the shell),
  #   * 'claude-session'   — the per-project auto-session naming integration, and
  #   * 'claude-cwd-hook'  — the optional project-agnostic pre-launch working-dir
  #     hook (lets a consuming project bind each alias to its own checkout).
  # A stale wrapper lacking ANY would silently misbehave (wrong endpoint,
  # unnamed sessions, or no per-alias cwd) and must self-heal on the next
  # install/ensure. The earlier bug checked only the first marker, so wrappers
  # predating auto-session never regained it.
  local _cma_run_body
  _cma_run_body="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE" 2>/dev/null)"
  if grep -q '^cma_run()' "$ALIAS_FILE" \
     && { ! printf '%s\n' "$_cma_run_body" | grep -q 'unset ANTHROPIC_' \
          || ! printf '%s\n' "$_cma_run_body" | grep -q 'claude-session' \
          || ! printf '%s\n' "$_cma_run_body" | grep -q 'claude-cwd-hook' \
          || ! printf '%s\n' "$_cma_run_body" | grep -q 'apply-color'; }; then
    local tmp_run; tmp_run="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
    awk '
      /^cma_run\(\) ?\{/ { skip=1 }
      skip && /^}/    { skip=0; next }
      !skip           { print }
    ' "$ALIAS_FILE" > "$tmp_run"
    mv "$tmp_run" "$ALIAS_FILE"
    cma_log "migrated outdated cma_run (provider-env isolation + auto-session)"
  fi
  # Ensure the cma_run wrapper is present in the alias file. This is the
  # runtime hook that keeps .claude.json projects/session state synchronized
  # across every account: pull merged state before launch, push back after exit.
  if ! grep -q '^cma_run()' "$ALIAS_FILE"; then
    cat >> "$ALIAS_FILE" <<'EOF'

# Wrapper: keeps .claude.json projects/session index synced across every
# logged-in account. Pulls merged state from every account into the launching
# one before claude runs; pushes the post-session state back out after exit.
# Cheap (jq deep-merge of one ~50KB file per account), runs unconditionally.
cma_run() {
  # Provider-env isolation: native claudeN must talk to the real Anthropic API.
  # A provider alias run earlier in THIS shell exports ANTHROPIC_BASE_URL etc.;
  # those persist and would otherwise leak into this native launch (claude1
  # silently using a provider's endpoint). Clear them so native is always clean.
  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
  # Optional project-agnostic working-dir hook (opt-in; no-op when absent). A
  # consuming project can bind each alias to its own checkout (e.g. one git
  # worktree per track) so parallel aliases don't contend on a single shared
  # tree. The toolkit knows NOTHING about what the hook resolves — it only cd's
  # into a real directory the hook prints on stdout (nothing printed => stay put).
  # Runs before claude-session below so the auto-session keys to the worktree
  # root. Escape hatch: MULTITRACK_DISABLE=1 (honored inside the hook itself).
  local _cma_cwd_hook="${CMA_CWD_HOOK:-$HOME/.local/bin/claude-cwd-hook}" _cma_cwd_label _cma_cwd_target
  if [[ -x "$_cma_cwd_hook" ]]; then
    _cma_cwd_label="$(basename "${CLAUDE_CONFIG_DIR:-claude}")"; _cma_cwd_label="${_cma_cwd_label#.claude-}"
    _cma_cwd_target="$("$_cma_cwd_hook" "$_cma_cwd_label" 2>/dev/null || true)"
    if [[ -n "$_cma_cwd_target" && -d "$_cma_cwd_target" ]]; then cd "$_cma_cwd_target" 2>/dev/null || true; fi
  fi
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" pull "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  # Auto session-per-project: when launched with NO args, resume (or create) the
  # one long-lived session for this project root, name it after the root dir,
  # trust the workspace, and hint the alias color. Only when bare so explicit
  # user flags (-p, --resume, a prompt, …) are always respected verbatim.
  # claude-session emits only "--resume <uuid>" or "--session-id <uuid> --name
  # <snake>" (no shell metacharacters), so eval-splitting is safe and works in
  # both bash and zsh (zsh does not word-split unquoted expansions).
  local _cma_label=""
  if [[ $# -eq 0 && -x "$HOME/.local/bin/claude-session" ]]; then
    local _cma_sf
    _cma_sf="$("$HOME/.local/bin/claude-session" flags "$CLAUDE_CONFIG_DIR" 2>/dev/null || true)"
    _cma_label="$(basename "${CLAUDE_CONFIG_DIR:-claude}")"; _cma_label="${_cma_label#.claude-}"
    "$HOME/.local/bin/claude-session" hint "$_cma_label" 2>/dev/null || true
    eval "set -- $_cma_sf"
    # Auto-apply the per-alias color: a resumable session's jsonl exists now, so
    # colour it before launch; a brand-new session's file appears during launch,
    # so we colour it again after exit (see post-launch call below).
    "$HOME/.local/bin/claude-session" apply-color "$CLAUDE_CONFIG_DIR" "$_cma_label" 2>/dev/null || true
  fi
  "$CLAUDE_BIN" "$@"
  local rc=$?
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" push "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  [[ -n "$_cma_label" && -x "$HOME/.local/bin/claude-session" ]] && \
    "$HOME/.local/bin/claude-session" apply-color "$CLAUDE_CONFIG_DIR" "$_cma_label" 2>/dev/null || true
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
  # Regenerate when the installed function predates ANY of these: the
  # cross-provider sync-state calls ('claude-sync-state'), the nounset-safe
  # keys sourcing ('set -a +u'), the per-project auto-session integration
  # ('claude-session'), the input-context token-limit guard
  # ('CLAUDE_CODE_AUTO_COMPACT_WINDOW'), or the SHARED_DIR-based proxy resolution
  # ('_cma_proxy_dir', replacing a broken $LIB_DIR that disabled all proxies).
  # Each marker lives only in the current heredoc, so once regenerated the
  # function stops re-triggering.
  if grep -q '^cma_run_provider()' "$ALIAS_FILE"; then
    local _prov_body
    _prov_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
    # shellcheck disable=SC2016  # '>| "$tmp"' is a literal code marker grepped for, not a var to expand
    if ! printf '%s\n' "$_prov_body" | grep -q 'claude-sync-state' || \
       ! printf '%s\n' "$_prov_body" | grep -q 'set -a +u' || \
       ! printf '%s\n' "$_prov_body" | grep -q 'claude-session' || \
       ! printf '%s\n' "$_prov_body" | grep -q 'apply-color' || \
       ! printf '%s\n' "$_prov_body" | grep -q 'CLAUDE_CODE_AUTO_COMPACT_WINDOW' || \
       ! printf '%s\n' "$_prov_body" | grep -q '_cma_proxy_dir' || \
       ! printf '%s\n' "$_prov_body" | grep -qF 'command -v cma_log' || \
       ! printf '%s\n' "$_prov_body" | grep -qF '_cma_force' || \
       ! printf '%s\n' "$_prov_body" | grep -qF '>| "$tmp"'; then
      local tmp_prov; tmp_prov="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
      # Drop only the function block; preserve everything before and after it.
      awk '
        /^cma_run_provider\(\) ?\{/ { skip=1 }
        skip && /^}/            { skip=0; next }
        !skip                   { print }
      ' "$ALIAS_FILE" >| "$tmp_prov"
      mv "$tmp_prov" "$ALIAS_FILE"
      cma_log "migrated outdated cma_run_provider (sync-state + nounset keys + noclobber-safe >| write + auto-compact-window + activation-gate)"
    fi
  fi
  if ! grep -q '^cma_run_provider()' "$ALIAS_FILE"; then
    cat >> "$ALIAS_FILE" <<'EOF'

cma_run_provider() {
  # --force bypasses the activation gate (operator override). Accepted BOTH as
  # the very first arg (direct call: cma_run_provider --force <id>) and as the
  # first arg after the id (alias path: `<alias> --force` expands to
  # cma_run_provider <id> --force). Either way it is consumed, not forwarded.
  local _cma_force=0
  if [[ "${1:-}" == "--force" ]]; then _cma_force=1; shift; fi
  local id="$1"; shift 2>/dev/null || true
  if [[ "${1:-}" == "--force" ]]; then _cma_force=1; shift; fi
  local pdir="$HOME/.local/share/claude-multi-account/providers"
  local envf="$pdir/$id.env"
  if [[ ! -f "$envf" ]]; then
    printf 'claude-providers: unknown provider %s (missing %s)\n' "$id" "$envf" >&2
    return 1
  fi
  # shellcheck disable=SC1090
  source "$envf"
  # Activation gate: only a 'verified' alias launches Claude Code. A non-verified
  # alias (unverified / failed / pending) prints a clear, actionable message and
  # refuses to launch, so a broken provider never surfaces as a confusing
  # in-session error. Status comes from the non-secret status cache; this body is
  # self-contained (no cma_* helpers) so it reads status.json with jq inline.
  if (( ! _cma_force )); then
    local _cma_sf="$pdir/status.json" _cma_st="pending"
    if command -v jq >/dev/null 2>&1 && [[ -s "$_cma_sf" ]]; then
      _cma_st="$(jq -r --arg i "$CMA_PROVIDER_ID" '.[$i].status // "pending"' "$_cma_sf" 2>/dev/null)"
      [[ -n "$_cma_st" && "$_cma_st" != "null" ]] || _cma_st="pending"
    fi
    if [[ "$_cma_st" != "verified" ]]; then
      printf 'claude-providers: alias %s is %s — not launching.\n' "$CMA_PROVIDER_ID" "$_cma_st" >&2
      printf '  Re-verify: claude-providers sync   (re-runs verification for %s)\n' "$CMA_PROVIDER_ID" >&2
      printf '  Override (operator): run the alias with --force\n' >&2
      return 3
    fi
  fi
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
  local token="" _cma_xt=""
  # Suppress xtrace around the indirect key read so an active `set -x` in the
  # user's shell can't echo the secret to the terminal or a redirected log.
  case $- in *x*) _cma_xt=1; set +x ;; esac
  eval "token=\"\${$CMA_PROVIDER_KEYVAR:-}\""
  [[ -n "$_cma_xt" ]] && set -x
  if [[ -z "$token" ]]; then
    printf 'claude-providers: $%s is empty (set it in %s)\n' "$CMA_PROVIDER_KEYVAR" "$keysf" >&2
    return 1
  fi
  export CLAUDE_CONFIG_DIR="$CMA_PROVIDER_CONFIG_DIR"
  # Input-context guard (fixes "400 exceeded model token limit: 262144
  # (requested: 311786)"): tell Claude Code this provider's REAL context window
  # so it auto-compacts (at window-13000) before a request overshoots the
  # provider's hard input limit. Without this, Claude Code assumes Anthropic's
  # own large (~1M) window and lets the prompt grow past a smaller provider's
  # cap. Fully dynamic — the value is CMA_PROVIDER_CONTEXT_LIMIT, resolved from
  # the models.dev catalog (limit.context) per selected model. Applies to BOTH
  # transports (native + router), so every provider alias is protected.
  # NOTE: this caps INPUT context; CLAUDE_CODE_MAX_OUTPUT_TOKENS (set below on
  # the native path) caps OUTPUT — the two are independent halves of the guard.
  [[ -n "${CMA_PROVIDER_CONTEXT_LIMIT:-}" ]] && \
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$CMA_PROVIDER_CONTEXT_LIMIT"
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
    # Proxies live in the INSTALLED share dir (install.sh copies scripts/proxy/*.py
    # to $SHARED_DIR/proxy). This wrapper is self-contained in the alias file and
    # has NO $LIB_DIR (that is a repo-only var), so resolve against SHARED_DIR with
    # the same default lib.sh uses. Using $LIB_DIR here silently disabled EVERY
    # proxy (e.g. Poe 400 "Invalid 'tools': Field required" when Claude Code emits
    # a tool with no `parameters` — the poe_proxy injects it).
    local _cma_proxy_dir="${SHARED_DIR:-$HOME/.claude-shared}/proxy"
    local _base_id="${CMA_PROVIDER_ID%%[0-9]*}"
    local _proxy_script=""
    if [[ -x "$_cma_proxy_dir/${CMA_PROVIDER_ID}_proxy.py" ]]; then
      _proxy_script="$_cma_proxy_dir/${CMA_PROVIDER_ID}_proxy.py"
    elif [[ -x "$_cma_proxy_dir/${_base_id}_proxy.py" ]]; then
      _proxy_script="$_cma_proxy_dir/${_base_id}_proxy.py"
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
      # cma_log is a lib.sh helper; the self-contained alias file has no such
      # function, so guard the call to avoid a 'cma_log: command not found' on
      # every proxied launch.
      command -v cma_log >/dev/null 2>&1 && cma_log "started proxy for $CMA_PROVIDER_ID on port $_proxy_port (pid=$_proxy_pid)" || true
    fi
    if command -v jq >/dev/null 2>&1; then
      local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"; chmod 600 "$tmp" 2>/dev/null || true
      # Pass the secret through the environment ($ENV.tok), never as a jq argv
      # argument — argv is visible in ps/proc to other local users.
      # `>|` (force-clobber), NOT `>`: cma_run_provider runs in the user's
      # interactive shell, which may have `set -o noclobber`. Plain `>` onto the
      # just-created mktemp file fails there ("cannot overwrite existing file"),
      # silently dropping the router-config update so EVERY router provider breaks.
      if CMA_TOK="$token" jq --arg n "$CMA_PROVIDER_ID" --arg u "$base" \
            --arg s "$CMA_PROVIDER_MODEL" --arg f "${CMA_PROVIDER_FAST_MODEL:-$CMA_PROVIDER_MODEL}" '
          .Providers = ([ .Providers[]? | select(.name != $n) ]
            + [{name:$n, api_base_url:$u, api_key:$ENV.CMA_TOK, models:[$s,$f],
                transformer:{use:["cleancache","streamoptions"]}}])
          | .Router.default = ($n + "," + $s)
          | .Router.background = ($n + "," + $f)
        ' "$cfg" >| "$tmp" 2>/dev/null; then
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
      command -v cma_log >/dev/null 2>&1 && cma_log "stopped proxy for $CMA_PROVIDER_ID (pid=$_proxy_pid)" || true
    fi
  else
    export ANTHROPIC_BASE_URL="$CMA_PROVIDER_BASE_URL"
    export ANTHROPIC_AUTH_TOKEN="$token"
    export ANTHROPIC_MODEL="$CMA_PROVIDER_MODEL"
    [[ -n "${CMA_PROVIDER_FAST_MODEL:-}" ]] && export ANTHROPIC_SMALL_FAST_MODEL="$CMA_PROVIDER_FAST_MODEL"
    # Output-token guard: cap Claude Code's output at the provider model's real
    # max (limit.output). This is the OUTPUT half of the token-limit guard; the
    # INPUT half (CLAUDE_CODE_AUTO_COMPACT_WINDOW) is set above for both
    # transports. CMA_PROVIDER_MAX_OUTPUT comes from the catalog via
    # cma_provider_write_env.
    [[ -n "${CMA_PROVIDER_MAX_OUTPUT:-}" ]] && export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$CMA_PROVIDER_MAX_OUTPUT"
    # Auto session-per-project (bare launch only — explicit args win verbatim).
    if [[ $# -eq 0 && -x "$HOME/.local/bin/claude-session" ]]; then
      local _cma_psf
      _cma_psf="$("$HOME/.local/bin/claude-session" flags "$CLAUDE_CONFIG_DIR" 2>/dev/null || true)"
      "$HOME/.local/bin/claude-session" hint "$CMA_PROVIDER_ID" 2>/dev/null || true
      eval "set -- $_cma_psf"
      # Auto-apply this provider alias's color to the session (idempotent).
      "$HOME/.local/bin/claude-session" apply-color "$CLAUDE_CONFIG_DIR" "$CMA_PROVIDER_ID" 2>/dev/null || true
      _cma_pcolor=1
    fi
    "$CLAUDE_BIN" "$@"; rc=$?
  fi
  # Push post-session state back to all accounts/providers for cross-alias visibility.
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" push "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  # Colour a freshly-created session too (its jsonl exists now), so the colour is
  # in place on the next resume even on the very first launch.
  [[ "${_cma_pcolor:-}" == 1 && -x "$HOME/.local/bin/claude-session" ]] && \
    "$HOME/.local/bin/claude-session" apply-color "$CLAUDE_CONFIG_DIR" "$CMA_PROVIDER_ID" 2>/dev/null || true
  return $rc
}
EOF
  fi
  local rc src_line="source \"$ALIAS_FILE\""
  # ${arr[@]+"${arr[@]}"} (not bare "${arr[@]}") so an EMPTY CMA_RC_FILES does not
  # trip "unbound variable" under `set -u` on bash 3.2 (macOS ships 3.2; it errors
  # on empty-array expansion where bash 4.4+ treats it as empty). LOAD-BEARING.
  for rc in ${CMA_RC_FILES[@]+"${CMA_RC_FILES[@]}"}; do
    [[ -f "$rc" ]] || continue
    cma_prune_stale_alias_sources "$rc"   # self-heal: drop dangling aliases.sh source lines
    # Add the canonical source line only if no existing line already sources THIS
    # alias file (matched across .|source and $HOME/~/absolute forms) — prevents
    # duplicate source lines accumulating across re-installs with differing forms.
    if ! cma_rc_sources_alias_file "$rc" "$ALIAS_FILE"; then
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
  # config_dir is interpolated into the alias body and re-parsed by the shell
  # when the alias is invoked. Reject shell metacharacters (injection) and
  # whitespace (an unquoted space would word-split the alias into a bogus
  # command — fail loud rather than write a silently-broken alias). Matched
  # literally per-char to avoid glob-bracket pitfalls.
  local _cma_c
  for _cma_c in '"' '$' '`' \\ ';' '&' '|' '<' '>' '(' ')'; do
    case "$config_dir" in *"$_cma_c"*)
      cma_warn "refusing to write alias '$alias_name': unsafe config dir"
      return 1 ;;
    esac
  done
  case "$config_dir" in *[[:space:]]*)
    cma_warn "refusing to write alias '$alias_name': config dir must not contain whitespace"
    return 1 ;;
  esac
  cma_ensure_alias_file
  # Strip any prior line for this alias, then append the new one.
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
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
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
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
  stats-cache.json history.jsonl CLAUDE.md
)
# NOTE (§11.4 own-settings): settings.json is DELIBERATELY NOT in the shared set.
# Each config dir gets its OWN settings.json so per-alias permissions/model/hooks
# never leak across aliases/providers, while the plugin CACHE (`plugins`),
# history (`history.jsonl`), memory (`CLAUDE.md`) and sessions stay shared. Each
# dir's own settings.json is seeded from + kept enabledPlugins-synced with the
# shared template $SHARED_DIR/settings.json by cma_own_settings_seed (so
# superpowers et al. stay enabled everywhere). See cma_link_shared_items +
# cma_enable_plugins below.

cma_providers_dir() { echo "$HOME/.local/share/claude-multi-account/providers"; }

# --- verification status cache ---------------------------------------------
# Single source of truth for "is this provider alias usable". Holds ONLY
# non-secret metadata: provider id -> {status, model, checked_at, failing_layer}.
# status is one of: verified | unverified | failed | pending. Consumed by the
# list family (claude-providers list/list-all/list-faulty) and the launch-time
# activation gate in cma_run_provider. NO key material ever lands here.
cma_status_cache() { echo "$(cma_providers_dir)/status.json"; }

# cma_status_write <id> <status> [<model> [<failing_layer>]]
# Upserts one record. failing_layer is "" for verified/pending. Atomic write.
cma_status_write() {
  local id="$1" status="$2" model="${3:-}" layer="${4:-}"
  cma_require jq
  local f; f="$(cma_status_cache)"; mkdir -p "$(dirname "$f")"
  [[ -s "$f" ]] || printf '{}\n' > "$f"
  # checked_at: portable UTC ISO-8601 (GNU + BSD date both accept -u +fmt).
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  if jq --arg id "$id" --arg s "$status" --arg m "$model" \
        --arg l "$layer" --arg t "$now" \
        '.[$id] = {status:$s, model:$m, checked_at:$t, failing_layer:$l}' \
        "$f" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"; cma_warn "could not update status cache $f"
  fi
}

# cma_status_read <id> -> status word (pending if absent/unreadable).
cma_status_read() {
  local id="$1" f; f="$(cma_status_cache)"
  [[ -s "$f" ]] || { echo pending; return 0; }
  local s; s="$(jq -r --arg id "$id" '.[$id].status // "pending"' "$f" 2>/dev/null)"
  [[ -n "$s" && "$s" != "null" ]] && echo "$s" || echo pending
}

# cma_status_all -> id<TAB>status<TAB>model<TAB>checked_at<TAB>failing_layer per record.
cma_status_all() {
  local f; f="$(cma_status_cache)"
  [[ -s "$f" ]] || return 0
  jq -r 'to_entries[] | [.key, .value.status, (.value.model // ""),
         (.value.checked_at // ""), (.value.failing_layer // "")] | @tsv' \
     "$f" 2>/dev/null || true
}

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
  # §11.4 own-settings: settings.json is NOT symlinked — give this dir its OWN copy.
  cma_own_settings_seed "$cdir"
}

# List all toolkit-managed config dirs (native accounts + providers). Used to
# fan out per-dir OWN settings.json enabledPlugins-sync.
cma_all_config_dirs() {
  local d
  for d in "$HOME"/.claude-claude* "$HOME"/.claude-prov-*; do
    [[ -d "$d" ]] && printf '%s\n' "$d"
  done
}

# Give a config dir its OWN settings.json (§11.4 own-settings). If it is a symlink
# (legacy shared layout) or absent, seed a REAL copy from the shared template so
# it inherits enabledPlugins + theme. If already a real file, additively merge the
# template's enabledPlugins in (own entries win — never clobber per-alias
# overrides). The shared template $SHARED_DIR/settings.json remains the single
# source of the always-on plugin set.
cma_own_settings_seed() {
  # NOTE: separate `local`s — a single `local a="$1" b="$a/x"` expands $a before
  # it is assigned, which aborts under `set -u` ("a: unbound variable").
  local cdir="${1:-}"
  [ -n "$cdir" ] || return 0
  local own="$cdir/settings.json"
  local tmpl="${SHARED_DIR:-$HOME/.claude-shared}/settings.json"
  local tmp=""
  command -v jq >/dev/null 2>&1 || return 0
  [[ -s "$tmpl" ]] || printf '{}\n' > "$tmpl"
  if [[ -L "$own" || ! -e "$own" ]]; then
    rm -f "$own" 2>/dev/null
    cp "$tmpl" "$own" 2>/dev/null || printf '{}\n' > "$own"
    return 0
  fi
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  if jq -s '.[0] as $own | .[1] as $t
            | $own | .enabledPlugins = (($t.enabledPlugins // {}) + ($own.enabledPlugins // {}))' \
        "$own" "$tmpl" > "$tmp" 2>/dev/null && jq -e . "$tmp" >/dev/null 2>&1; then
    mv "$tmp" "$own"
  else rm -f "$tmp"; fi
}

# Force-enable the always-on plugins in the shared settings.json enabledPlugins
# map (additive union — never removes a user's existing entries). Each arg is a
# plugin key as it appears in enabledPlugins (e.g. "superpowers@anthropics").
cma_enable_plugins() {
  cma_require jq
  local settings="$SHARED_DIR/settings.json" tmp
  mkdir -p "$SHARED_DIR"
  [[ -s "$settings" ]] || printf '{}\n' > "$settings"
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  local args=() p i=0
  # Use a dedicated counter for the jq --arg names: each iteration appends THREE
  # elements (--arg, "pN", value), so deriving the index from ${#args[@]} drifts
  # (it produced p0,p1,p3,p4 for 4 plugins → $p2 undefined → jq failed silently
  # → no plugins enabled). The counter matches the $pN refs in the prog below.
  for p in "$@"; do args+=(--arg "p$i" "$p"); i=$((i+1)); done
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
  # Fan the always-on plugin set out into every managed config dir's OWN
  # settings.json (settings.json is no longer a shared symlink — §11.4
  # own-settings) so enabling a plugin still reaches every alias/provider.
  local _cd
  while IFS= read -r _cd; do [[ -n "$_cd" ]] && cma_own_settings_seed "$_cd"; done < <(cma_all_config_dirs)
}

# Write the non-secret per-provider env file consumed by cma_run_provider.
# Args: id keyvar transport base_url model fast_model config_dir [context_limit [max_output]]
# context_limit and max_output are optional trailing args (default empty).
# cma_run_provider consumes both catalog limits to avoid the 400 "exceeded
# model token limit" error: CMA_PROVIDER_CONTEXT_LIMIT -> CLAUDE_CODE_AUTO_COMPACT_WINDOW
# (INPUT: compact before the prompt overshoots the provider's window) and
# CMA_PROVIDER_MAX_OUTPUT -> CLAUDE_CODE_MAX_OUTPUT_TOKENS (OUTPUT cap).
cma_provider_write_env() {
  local id="$1" keyvar="$2" transport="$3" base="$4" model="$5" fast="$6" cdir="$7"
  local context_limit="${8:-}" max_output="${9:-}" alias_name="${10:-}"
  # Normalize the literal "null" (from a missing JSON field) to empty so it
  # never leaks into the wrapper as a bogus value. transport+model were missed
  # originally — a null strong_model/transport wrote CMA_PROVIDER_MODEL='null'
  # (provider launches with a bogus model). Normalize every field for symmetry.
  [[ "$transport" == "null" ]] && transport=""
  [[ "$base" == "null" ]] && base=""
  [[ "$model" == "null" ]] && model=""
  [[ "$fast" == "null" ]] && fast=""
  [[ "$context_limit" == "null" ]] && context_limit=""
  [[ "$max_output" == "null" ]] && max_output=""
  [[ "$alias_name" == "null" ]] && alias_name=""
  local pdir; pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
  # Values are single-quoted (with embedded-quote escaping) so sourcing the file
  # in the user's shell is safe regardless of characters in URLs/model ids.
  # POSIX single-quote escaping: replace each ' with '\'' via a loop.
  # Portable across all bash versions — avoids ${var/pattern/replacement} with
  # complex escape sequences that break on bash 3.2 and 5.3.
  _cma_q() {
    local _r="" _rem="$1"
    while true; do
      case "$_rem" in *\'*)
        _r="${_r}${_rem%%\'*}'\\''"; _rem="${_rem#*\'}" ;;
        *) _r="${_r}${_rem}"; break ;;
      esac
    done
    printf "'%s'" "$_r"
  }
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
# Context-window limits from the models.dev catalog for the selected strong model.
# CMA_PROVIDER_CONTEXT_LIMIT: input context window (tokens); empty = unknown.
#   -> exported as CLAUDE_CODE_AUTO_COMPACT_WINDOW (input-side guard).
# CMA_PROVIDER_MAX_OUTPUT:    maximum output tokens; empty = unknown.
#   -> exported as CLAUDE_CODE_MAX_OUTPUT_TOKENS (output-side guard).
CMA_PROVIDER_CONTEXT_LIMIT=$(_cma_q "$context_limit")
CMA_PROVIDER_MAX_OUTPUT=$(_cma_q "$max_output")
# Alias name for this provider (used by 'list --refresh-aliases' to rebuild the
# alias shell line with NO network — the session hook's fast path). Empty is OK;
# refresh falls back to the provider id as the alias name.
CMA_PROVIDER_ALIAS=$(_cma_q "$alias_name")
EOF
  unset -f _cma_q
}

# Write (or refresh) a provider alias: alias <name>="cma_run_provider <id>".
cma_provider_write_alias() {
  local alias_name="$1" id="$2"
  cma_validate_alias "$alias_name"
  # The provider id is interpolated into the alias body and re-parsed when the
  # alias is invoked. Provider ids are always [A-Za-z0-9._-]; reject anything
  # else so a hostile catalog/--id value can't inject shell commands.
  case "$id" in
    ''|*[!A-Za-z0-9._-]*)
      cma_warn "refusing to write alias '$alias_name': unsafe provider id"
      return 1 ;;
  esac
  cma_ensure_alias_file
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
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
