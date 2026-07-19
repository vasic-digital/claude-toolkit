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
        command mv -f "$_tt" "$prev"
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
      command mv -f "$out" "$f"
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
    # The claude-code-router config dir and any *.lock dir are not accounts.
    [[ "$(basename "$d")" == "${ACCOUNT_PREFIX}code-router" ]] && continue
    [[ "$(basename "$d")" == *.lock ]] && continue
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
  if (( changed )); then command mv -f "$tmp" "$rc"; cma_log "pruned stale aliases.sh source line(s) from $rc"; else rm -f "$tmp"; fi
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
    command mv -f "$tmp" "$ALIAS_FILE"
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
      command mv -f "$tmp_cb" "$ALIAS_FILE"
      cma_log "migrated stale CLAUDE_BIN -> $_new_cb"
    fi
  fi
  # Migration: the 'export CLAUDE_BIN=' header line is entirely missing (corrupted
  # alias file -- every alias launches an empty command). Prepend it so the
  # inline self-heal in cma_run/cma_run_provider does not have to fire on every
  # single invocation. Idempotent: does nothing when the line is already present.
  if ! grep -q '^export CLAUDE_BIN=' "$ALIAS_FILE" 2>/dev/null; then
    local _cb_new; _cb_new="$(cma_resolve_claude_bin)"
    local _cb_tmp; _cb_tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
    {
      printf '# Managed by claude-multi-account. Do not edit by hand; use\n'
      printf '# ~/.local/bin/claude-add-account to add accounts.\n'
      printf 'export CLAUDE_BIN="%s"\n' "$_cb_new"
      cat "$ALIAS_FILE"
    } > "$_cb_tmp" && command mv -f "$_cb_tmp" "$ALIAS_FILE"
    cma_log "restored missing export CLAUDE_BIN line -> $_cb_new"
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
  #   * 'claude-session'   — the per-project auto-session naming integration,
  #   * 'CLAUDE_CODE_MAX_OUTPUT_TOKENS' — token-guard isolation (native must not
  #     inherit a provider's clamped output cap / auto-compact window), and
  #   * 'claude-cwd-hook'  — the optional project-agnostic pre-launch working-dir
  #     hook (lets a consuming project bind each alias to its own checkout).
  # A stale wrapper lacking ANY would silently misbehave (wrong endpoint,
  # unnamed sessions, or no per-alias cwd) and must self-heal on the next
  # install/ensure. The earlier bug checked only the first marker, so wrappers
  # predating auto-session never regained it.
  local _cma_run_body
  _cma_run_body="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE" 2>/dev/null)"
  if grep -q '^cma_run()' "$ALIAS_FILE" \
     && { ! grep -q 'unset ANTHROPIC_' <<<"$_cma_run_body" \
          || ! grep -q 'claude-session' <<<"$_cma_run_body" \
          || ! grep -q 'claude-cwd-hook' <<<"$_cma_run_body" \
          || ! grep -q '_cma_hook_root' <<<"$_cma_run_body" \
	          || ! grep -qF '! git rev-parse --show-toplevel >/dev/null 2>&1' <<<"$_cma_run_body" \
          || ! grep -q 'apply-color' <<<"$_cma_run_body" \
          || ! grep -q 'command -v "\${CLAUDE_BIN:-}"' <<<"$_cma_run_body" \
          || ! grep -qF 'ANTHROPIC_DEFAULT_OPUS_MODEL' <<<"$_cma_run_body" \
          || ! grep -qF 'CLAUDE_CODE_MAX_OUTPUT_TOKENS' <<<"$_cma_run_body"; }; then
    local tmp_run; tmp_run="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
    awk '
      /^cma_run\(\) ?\{/ { skip=1 }
      skip && /^}/    { skip=0; next }
      !skip           { print }
    ' "$ALIAS_FILE" > "$tmp_run"
    command mv -f "$tmp_run" "$ALIAS_FILE"
    cma_log "migrated outdated cma_run (claude-bin-self-heal + provider-env isolation + tier-default-model isolation + token-guard isolation (CLAUDE_CODE_MAX_OUTPUT_TOKENS/AUTO_COMPACT_WINDOW) + auto-session + project-scoped cwd-hook)"
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
  # Self-heal CLAUDE_BIN: the alias file normally exports it at the top, but if
  # that header line is missing (corrupted or hand-edited alias file) every
  # invocation would silently expand to an empty command ("-bash: : command
  # not found"). Mirrors cma_resolve_claude_bin inline so the function body is
  # self-contained regardless of the header state. §11.4.185.
  if ! command -v "${CLAUDE_BIN:-}" >/dev/null 2>&1; then
    if command -v claude >/dev/null 2>&1; then
      CLAUDE_BIN="$(command -v claude)"
    else
      for _cma_cb in "$HOME/.local/bin/claude" "$HOME/.npm-global/bin/claude" \
                     /opt/homebrew/bin/claude /usr/local/bin/claude; do
        [ -x "$_cma_cb" ] && { CLAUDE_BIN="$_cma_cb"; break; }
      done
      if ! command -v "${CLAUDE_BIN:-}" >/dev/null 2>&1; then
        printf 'cma_run: claude binary not found — check PATH or re-run install.sh\n' >&2
        return 127
      fi
    fi
  fi
  # Provider-env isolation: native claudeN must talk to the real Anthropic API.
  # A provider alias run earlier in THIS shell exports ANTHROPIC_BASE_URL etc.;
  # those persist and would otherwise leak into this native launch (claude1
  # silently using a provider's endpoint). Clear them so native is always clean.
  # The 4 ANTHROPIC_DEFAULT_*_MODEL tier-map vars are exported by
  # cma_run_provider (native transport) and PERSIST after that alias returns; a
  # subsequent native claudeN launch MUST clear them too, else the opus/sonnet/
  # haiku/fable tier resolution silently points at the previous provider's
  # serving model instead of the real Anthropic tier.
  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
  unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL
  # Token-guard isolation: cma_run_provider exports CLAUDE_CODE_MAX_OUTPUT_TOKENS
  # (output cap, clamped <=128000) and CLAUDE_CODE_AUTO_COMPACT_WINDOW (input
  # compact trigger) for every provider alias; BOTH persist in this shell after
  # that alias returns. A subsequent native claudeN launch MUST clear them, else
  # native inherits a provider's (possibly small) output cap or compact window
  # instead of the real Anthropic per-model defaults — silently capping native's
  # output or early-compacting its context. Parallels the ANTHROPIC_DEFAULT_*
  # tier-map isolation above.
  unset CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW
  # Working-dir hook (opt-in; no-op when absent). Resolution order:
  #   1. CMA_CWD_HOOK env var               — explicit user override
  #   2. <git-toplevel>/.claude-cwd-hook     — per-project hook (each repo
  #      gets its own multitrack resolver, preventing a single global hook
  #      from hijacking every project’s sessions)
  #   3. ~/.local/bin/claude-cwd-hook        — global fallback
  # The hook runs before claude-session (below) so auto-session keys to the
  # resolved worktree root. Escape hatch: MULTITRACK_DISABLE=1 (honored
  # inside the hook itself; the toolkit does not check it).
  local _cma_cwd_hook _cma_cwd_label _cma_cwd_target
  if [[ -n "${CMA_CWD_HOOK:-}" ]]; then
    _cma_cwd_hook="$CMA_CWD_HOOK"
  else
    local _cma_hook_root
    _cma_hook_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [[ -x "$_cma_hook_root/.claude-cwd-hook" ]]; then
      _cma_cwd_hook="$_cma_hook_root/.claude-cwd-hook"
    else
      _cma_cwd_hook="$HOME/.local/bin/claude-cwd-hook"
    fi
  fi
  if [[ -x "$_cma_cwd_hook" ]] && ! git rev-parse --show-toplevel >/dev/null 2>&1; then
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
  # <kebab>" (no shell metacharacters), so eval-splitting is safe and works in
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
  # ('CLAUDE_CODE_AUTO_COMPACT_WINDOW'), the SHARED_DIR-based proxy resolution
  # ('_cma_proxy_dir', replacing a broken $LIB_DIR that disabled all proxies),
  # the family proxy discovery ('_family_id', kimi_proxy for all kimi-*), the
  # Kimi OAuth launch-time token freshness block
  # ('kimi-code/credentials/kimi-code.json'), the both-transports session flags
  # ('_cma_session_flags'), or the both-transports output cap
  # ('_cma_out_guard' — clamped <=128000, so the marker is the clamped export
  # 'CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"', distinct from the bare token
  # already present in the pre-clamp unset/raw-export body).
  # Each marker lives only in the current heredoc, so once regenerated the
  # function stops re-triggering.
  if grep -q '^cma_run_provider()' "$ALIAS_FILE"; then
    local _prov_body
    _prov_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
    # shellcheck disable=SC2016  # '>| "$tmp"' is a literal code marker grepped for, not a var to expand
    if ! grep -q 'claude-sync-state' <<<"$_prov_body" || \
       ! grep -q 'set -a +u' <<<"$_prov_body" || \
       ! grep -q 'claude-session' <<<"$_prov_body" || \
       ! grep -q 'apply-color' <<<"$_prov_body" || \
       ! grep -q '_cma_compact_cap' <<<"$_prov_body" || \
       ! grep -q '_cma_proxy_dir' <<<"$_prov_body" || \
       ! grep -qF '_family_id' <<<"$_prov_body" || \
       ! grep -qF 'kimi-code/credentials/kimi-code.json' <<<"$_prov_body" || \
       ! grep -qF '_cma_out_guard' <<<"$_prov_body" || \
       ! grep -qF '_cma_session_flags' <<<"$_prov_body" || \
       ! grep -qF 'command -v cma_log' <<<"$_prov_body" || \
       ! grep -qF '_cma_force' <<<"$_prov_body" || \
       ! grep -qF '>| "$tmp"' <<<"$_prov_body" || \
       ! grep -qF 'unset ANTHROPIC_BASE_URL' <<<"$_prov_body" || \
       ! grep -qF '! git rev-parse --show-toplevel >/dev/null 2>&1' <<<"$_prov_body" || \
       ! grep -qF 'command -v "${CLAUDE_BIN:-}"' <<<"$_prov_body" || \
       ! grep -qF 'ANTHROPIC_DEFAULT_OPUS_MODEL' <<<"$_prov_body" || \
       ! grep -qF 'CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"' <<<"$_prov_body" || \
       ! grep -qF '_cma_ccr_self' <<<"$_prov_body" || \
       ! grep -qF 'ccr default-claude-code -- "$@"' <<<"$_prov_body" || \
       ! grep -qF 'ccr --help' <<<"$_prov_body" || \
       ! grep -qF '_pp_try' <<<"$_prov_body"; then
      local tmp_prov; tmp_prov="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
      # Drop only the function block; preserve everything before and after it.
      awk '
        /^cma_run_provider\(\) ?\{/ { skip=1 }
        skip && /^}/            { skip=0; next }
        !skip                   { print }
      ' "$ALIAS_FILE" >| "$tmp_prov"
      command mv -f "$tmp_prov" "$ALIAS_FILE"
      cma_log "migrated outdated cma_run_provider (claude-bin-self-heal + sync-state + nounset keys + noclobber-safe >| write + auto-compact-window-cap-200k + activation-gate + env-isolation + tier-default-model map+isolation + output-token-clamp-128k-both-transports + kimi-oauth-freshness + family-proxy-discovery + session-flags-both-transports + cwd-hook-gated + ccr-self-loop-guard + ccr-launch-grammar-fix + ccr-identity-help + proxy-port-squatter-guard)"
    fi
  fi
  if ! grep -q '^cma_run_provider()' "$ALIAS_FILE"; then
    cat >> "$ALIAS_FILE" <<'EOF'

cma_run_provider() {
  # Self-heal CLAUDE_BIN (same as cma_run — §11.4.185). Prevents "-bash: : command
  # not found" when the alias-file header export line is missing. Also resolves
  # the binary for the native-transport path ("$CLAUDE_BIN" "$@") below.
  if ! command -v "${CLAUDE_BIN:-}" >/dev/null 2>&1; then
    if command -v claude >/dev/null 2>&1; then
      CLAUDE_BIN="$(command -v claude)"
    else
      for _cma_cb in "$HOME/.local/bin/claude" "$HOME/.npm-global/bin/claude" \
                     /opt/homebrew/bin/claude /usr/local/bin/claude; do
        [ -x "$_cma_cb" ] && { CLAUDE_BIN="$_cma_cb"; break; }
      done
    fi
  fi
  if ! command -v "${CLAUDE_BIN:-}" >/dev/null 2>&1; then
    printf 'claude-providers: claude binary not found — check PATH or re-run install.sh\n' >&2
    return 127
  fi
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
  # Cross-alias env isolation: unset any ANTHROPIC_*/CLAUDE_CODE_* vars that
  # leaked from a PREVIOUS cma_run_provider invocation in this shell. The
  # transport-specific branches below re-export them from this provider's
  # CMA_PROVIDER_* vars (fresh from source "$envf"), so the unset here is
  # only clearing the leftover from the previous alias — identical to how
  # cma_run (the native claudeN wrapper) isolates its ANTHROPIC_* vars.
  unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL
  # The 4 tier-default-model vars this same wrapper exports (native branch below)
  # also persist into a following alias invocation; clear the previous run's
  # values so this provider re-exports its own from CMA_PROVIDER_MODEL below.
  unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL
  unset CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_MAX_OUTPUT_TOKENS
  # Working-dir hook (same 3-tier resolution as cma_run). This must run
  # BEFORE sync-state pull + session flags so the resolved directory is the
  # session's canonical cwd. Without this, provider aliases ignore the
  # multitrack resolver and launch in whatever $PWD the user happened to be in.
  local _cma_cwd_hook _cma_cwd_label _cma_cwd_target
  if [[ -n "${CMA_CWD_HOOK:-}" ]]; then
    _cma_cwd_hook="$CMA_CWD_HOOK"
  else
    local _cma_hook_root
    _cma_hook_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
    if [[ -x "$_cma_hook_root/.claude-cwd-hook" ]]; then
      _cma_cwd_hook="$_cma_hook_root/.claude-cwd-hook"
    else
      _cma_cwd_hook="$HOME/.local/bin/claude-cwd-hook"
    fi
  fi
  if [[ -x "$_cma_cwd_hook" ]] && ! git rev-parse --show-toplevel >/dev/null 2>&1; then
    _cma_cwd_label="$(basename "${CLAUDE_CONFIG_DIR:-claude}")"; _cma_cwd_label="${_cma_cwd_label#.claude-}"
    _cma_cwd_target="$("$_cma_cwd_hook" "$_cma_cwd_label" 2>/dev/null || true)"
    if [[ -n "$_cma_cwd_target" && -d "$_cma_cwd_target" ]]; then cd "$_cma_cwd_target" 2>/dev/null || true; fi
  fi
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
  # Kimi Code OAuth sentinel: the OAuth token is SHORT-LIVED (~15 min), so a
  # sync-time snapshot is stale by the next launch. Freshness order:
  #  1. the LIVE kimi-code credentials file, when unexpired (60s skew);
  #  2. a CLI-triggered refresh (kimi -p hi) followed by a re-read of 1;
  #  3. the token-file snapshot written at sync (last resort only).
  if [[ "$CMA_PROVIDER_KEYVAR" == "_CMA_KIMICODE_OAUTH_" ]]; then
    local _cma_kcred="$HOME/.kimi-code/credentials/kimi-code.json"
    if [[ -f "$_cma_kcred" ]] && command -v jq >/dev/null 2>&1; then
      local _cma_kexp; _cma_kexp="$(jq -r '.expires_at // 0' "$_cma_kcred" 2>/dev/null || echo 0)"
      if (( _cma_kexp > $(date +%s) + 60 )); then
        token="$(jq -r '.access_token // ""' "$_cma_kcred" 2>/dev/null)"
      fi
    fi
    if [[ -z "$token" && -f "$_cma_kcred" ]] && command -v kimi >/dev/null 2>&1; then
      timeout 20 kimi -p "hi" --output-format text >/dev/null 2>&1 || true
      token="$(jq -r '.access_token // ""' "$_cma_kcred" 2>/dev/null)"
    fi
    if [[ -z "$token" ]]; then
      local _cma_ktok="$pdir/${CMA_PROVIDER_ID}.token"
      [[ -f "$_cma_ktok" ]] && token="$(cat "$_cma_ktok" 2>/dev/null)" || token=""
    fi
  else
    eval "token="\${$CMA_PROVIDER_KEYVAR:-}""
  fi
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
  # NOTE: this caps INPUT context; CLAUDE_CODE_MAX_OUTPUT_TOKENS (set just
  # below, before the transport branch, BOTH transports, clamped <=128000)
  # caps OUTPUT — the two are independent halves of the guard.
  # Auto-compact cap: only lower the window; never raise it above ~200K.
  # Providers with >200K context (DeepSeek 1M, Xiaomi 1M) do not need this
  # guard — exporting their full window disables auto-compaction until ~987K,
  # filling the session before compacting. CMA_AUTO_COMPACT_CAP overrides.
  local _cma_compact_cap="${CMA_AUTO_COMPACT_CAP:-200000}"
  if [[ -n "${CMA_PROVIDER_CONTEXT_LIMIT:-}" && "${CMA_PROVIDER_CONTEXT_LIMIT}" -le "$_cma_compact_cap" ]]; then
    export CLAUDE_CODE_AUTO_COMPACT_WINDOW="$CMA_PROVIDER_CONTEXT_LIMIT"
  fi
  # _cma_out_guard (v1.16.0) + <=128000 clamp (§11.4.108/§11.4.111): output-
  # token cap for BOTH transports, not just native. Without it, router
  # providers run with Claude Code's generic default output cap (128000 for
  # models it does not know) and long reasoning responses die with "Claude's
  # response exceeded the 128000 output token maximum". The value starts from
  # the provider model's REAL output limit (models.dev limit.output via
  # CMA_PROVIDER_MAX_OUTPUT); proxies may clamp further API-side
  # (sarvam_proxy's tier clamp). Exported ONCE here, before the transport
  # branch, so router AND native behave identically (previously only the
  # native branch re-exported it — an unclamped, transport-asymmetric raw
  # value).
  # Catalog caveat (live-proven on nvidia5): when limit.output >=
  # limit.context the "output" number is really the context size — exporting
  # it makes Claude Code request that many completion tokens, and
  # input+request overshoots the shared window (400 "maximum context length
  # is N … you requested M"). Only a genuinely separate output budget
  # (output < context) is exported.
  # Clamp caveat (live-proven, 128k Tier-1): exporting the model's THEORETICAL
  # limit.output when it exceeds the CLI's own custom-model ceiling (deepseek
  # 384000, xiaomi 131072) makes Claude Code request its OWN unknown-model
  # ceiling (128000) and then FATALLY abort any length-truncated response:
  # "…exceeded the 128000 output token maximum… set
  # CLAUDE_CODE_MAX_OUTPUT_TOKENS". The CLI hard-caps custom models to 128000
  # regardless, so any value >128000 is pointless — clamp to
  # min(CMA_PROVIDER_MAX_OUTPUT, 128000).
  # Sanitize-then-decide order is load-bearing (POSIX-shape so it behaves
  # identically whether this body is sourced by bash or zsh), and NO
  # arithmetic ever runs on an unsanitized value ([ N -gt .. ] errors past
  # 2^63-1, and (( )) errors on non-integers — CMA_PROVIDER_MAX_OUTPUT traces
  # to the user-settable CMA_HELIXAGENT_MAX_OUTPUT, fed via 'jq --argjson'
  # which preserves huge-int digits verbatim, so both shapes are reachable):
  #   1. empty / non-plain-integer (negatives, "1e6", "12.5") / zero -> NO
  #      export: no real output budget is known, and the CLI's own
  #      unknown-model default (128000) applies exactly as if the catalog had
  #      no entry. (The pre-merge always-export-128000 default was
  #      effect-equivalent for known models but could resurrect the nvidia5
  #      overshoot on small-context catalog-gap models — the conditional
  #      no-export subsumes it safely.)
  #   2. >18 digits: past intmax — no test/(( )) arithmetic is safe. Any real
  #      context (<=18 digits) is smaller, so with a usable context this is
  #      the mislabel shape (-> NO export); with no usable context it
  #      collapses to the 128000 cap WITHOUT arithmetic on the raw value.
  #   3. <=18 digits (test-safe): floor 0/00/000 to no-export, apply the
  #      nvidia5 mislabel skip (output >= context -> NO export), then the
  #      128000 clamp. A leading-zero form like 007 tests as 7 here, stays
  #      <=128000, and exports as "007" (Claude Code parses it as decimal 7 —
  #      min-semantics); a leading-zero 19+ digit form was already collapsed
  #      by rule 2, so it is NEVER re-read as octal.
  local _cma_out="${CMA_PROVIDER_MAX_OUTPUT:-}" _cma_octx="${CMA_PROVIDER_CONTEXT_LIMIT:-}"
  case "$_cma_octx" in
    ''|*[!0-9]*) _cma_octx="" ;;
    *) [ "${#_cma_octx}" -le 18 ] || _cma_octx="" ;;
  esac
  case "$_cma_out" in
    ''|*[!0-9]*) _cma_out="" ;;
    *) if [ "${#_cma_out}" -gt 18 ]; then
         if [ -n "$_cma_octx" ]; then _cma_out=""; else _cma_out=128000; fi
       elif [ "$_cma_out" -lt 1 ]; then _cma_out=""
       elif [ -n "$_cma_octx" ] && [ "$_cma_out" -ge "$_cma_octx" ]; then _cma_out=""
       elif [ "$_cma_out" -gt 128000 ]; then _cma_out=128000
       fi ;;
  esac
  if [ -n "$_cma_out" ]; then
    export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"
  fi
  # Sync .claude.json projects/session index across ALL accounts and providers
  # so sessions created under any alias are visible from every other alias.
  # Pull merged state before launch; push post-session state after exit.
  if [[ -x "$HOME/.local/bin/claude-sync-state" ]]; then
    "$HOME/.local/bin/claude-sync-state" pull "$CLAUDE_CONFIG_DIR" 2>/dev/null || true
  fi
  # _cma_session_flags (v1.17.0): per-project session resolution applies to
  # BOTH transports — previously the flags block lived only in the native
  # branch, so every router alias (kimi-*, poe, openrouter, …) always opened
  # a FRESH session and could never see the project session another alias
  # left behind. It also now covers conversation args: `alias -p "…"` used to
  # skip resolution entirely (verbatim-args rule) and start a new session
  # every time. Explicit session selectors and non-conversation subcommands
  # are always left verbatim.
  local _cma_psf=""
  if [[ -x "$HOME/.local/bin/claude-session" ]]; then
    if [[ $# -eq 0 ]]; then
      _cma_psf="$("$HOME/.local/bin/claude-session" flags "$CLAUDE_CONFIG_DIR" 2>/dev/null || true)"
      "$HOME/.local/bin/claude-session" hint "$CMA_PROVIDER_ID" 2>/dev/null || true
      eval "set -- $_cma_psf"
      # Auto-apply this provider alias's color to the session (idempotent).
      "$HOME/.local/bin/claude-session" apply-color "$CLAUDE_CONFIG_DIR" "$CMA_PROVIDER_ID" 2>/dev/null || true
      _cma_pcolor=1
    else
      case "$1" in
        --resume|--session-id|--continue|--fork-session|-c) ;;
        agents|mcp|export|doctor|install|update|config|plugin|setup|acp|server|web|provider) ;;
        *)
          # existing-id (NOT latest-id): latest-id falls back to the
          # deterministic UUID for never-used projects, and injecting --resume
          # with a session that was never created fails hard ("No conversation
          # found with session ID"). Inject only for a session that EXISTS.
          _cma_psf="$("$HOME/.local/bin/claude-session" existing-id "$CLAUDE_CONFIG_DIR" 2>/dev/null || true)"
          [[ -n "$_cma_psf" ]] && set -- --resume "$_cma_psf" "$@"
          ;;
      esac
    fi
  fi
  local rc
  local _proxy_pid=""
  if [[ "${CMA_PROVIDER_TRANSPORT:-native}" == "router" ]]; then
    if ! command -v ccr >/dev/null 2>&1; then
      printf 'claude-providers: provider %s needs claude-code-router.\n  Install: npm install -g @musistudio/claude-code-router\n' "$id" >&2
      return 127
    fi
    # Identity check (live issue 2026-07-18, revised 2026-07-19): a
    # DIFFERENT tool named ccr on PATH (e.g. CCS's profile manager,
    # `ccs`) shadows the real router and fails cryptically downstream —
    # "Profile 'code' was not found or is disabled" — because
    # `ccr code` to it means "launch profile 'code'". The current ccr
    # CLI no longer has a `version` subcommand (positional args are
    # profile names), so we identify via --help, which shows the
    # distinctive "ccr start" / "ccr serve" router commands.
    local _ccr_help; _ccr_help="$(ccr --help 2>&1 | head -10)"
    case "$_ccr_help" in
      *"ccr start"*|*"ccr serve"*) ;;
      *) printf 'claude-providers: ccr on PATH is not @musistudio/claude-code-router (found: "%s").\n  Fix PATH, remove the shadowing ccr, or: npm install -g @musistudio/claude-code-router\n' "$_ccr_help" >&2
         return 127 ;;
    esac
    # Upsert THIS provider into ccr config with the live key (regenerated each
    # launch, chmod 600 — never stored by the toolkit), set it as the active
    # route, then launch through ccr.
    local cfg="$HOME/.claude-code-router/config.json" base="$CMA_PROVIDER_BASE_URL"
    # Self-reference guard: when THIS provider's base_url IS the ccr gateway
    # itself (the HelixAgent/HelixLLM facade -> http://127.0.0.1:3456), upserting a
    # provider whose api_base_url is ccr registers a ccr->ccr self-loop and
    # rewrites .Router.default to point at it. Under ccr v3.0.6 the live route is
    # app_config (config.json is not re-imported on restart), so the write is
    # inert-for-routing AND a latent re-onboarding hazard. Skip the upsert+restart
    # for a ccr-self base; `ccr default-claude-code` then uses ccr's existing (app_config) route.
    local _cma_ccr_self=0
    case "${base#*://}" in
      127.0.0.1:3456|127.0.0.1:3456/*|localhost:3456|localhost:3456/*) _cma_ccr_self=1 ;;
    esac
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
    local _family_id="${CMA_PROVIDER_ID%%-*}"
    local _proxy_script=""
    if [[ -x "$_cma_proxy_dir/${CMA_PROVIDER_ID}_proxy.py" ]]; then
      _proxy_script="$_cma_proxy_dir/${CMA_PROVIDER_ID}_proxy.py"
    elif [[ -x "$_cma_proxy_dir/${_base_id}_proxy.py" ]]; then
      _proxy_script="$_cma_proxy_dir/${_base_id}_proxy.py"
    elif [[ -x "$_cma_proxy_dir/${_family_id}_proxy.py" ]]; then
      # Family fallback: all kimi-* aliases share kimi_proxy.py (the
      # moonshot-flavored schema normalizer), like all poe* share poe_proxy.py.
      _proxy_script="$_cma_proxy_dir/${_family_id}_proxy.py"
    fi
    if [[ -n "$_proxy_script" ]]; then
      # Port-squatter guard (live-proven 2026-07-19: `poe: FAIL tools-params`).
      # The old code hardcoded 3457 and then waited on `lsof -i :3457`, i.e. it
      # only asked "is SOMETHING listening?" — which any squatter satisfies. On
      # this host ccr itself had held 3457 for 21h, so python3 could never bind,
      # the wait returned instantly, and `base` was pointed at ccr. Every
      # request then bypassed the proxy's schema fixes and Poe rejected the
      # tool definitions ("Field required: parameters") — the exact thing
      # poe_proxy.py exists to prevent, silently disabled.
      # Fix: find a genuinely free port, then confirm OUR pid owns it.
      local _proxy_port=3457 _pp_try=0
      while lsof -i ":$_proxy_port" >/dev/null 2>&1 && (( _pp_try < 20 )); do
        _proxy_port=$((_proxy_port + 1)); _pp_try=$((_pp_try + 1))
      done
      python3 "$_proxy_script" --port "$_proxy_port" &
      _proxy_pid=$!
      local _waited=0
      # Wait for OUR process to be listening — not merely for the port to be busy.
      while ! lsof -a -p "$_proxy_pid" -i ":$_proxy_port" >/dev/null 2>&1 && (( _waited < 25 )); do
        kill -0 "$_proxy_pid" 2>/dev/null || break   # proxy died: stop waiting
        sleep 0.2
        _waited=$((_waited + 1))
      done
      if ! lsof -a -p "$_proxy_pid" -i ":$_proxy_port" >/dev/null 2>&1; then
        # Never point at a foreign listener. Fall back to the provider's direct
        # endpoint and say so loudly, rather than silently losing the shims.
        command -v cma_log >/dev/null 2>&1 && \
          cma_log "WARNING: proxy for $CMA_PROVIDER_ID did not start on port $_proxy_port — using the direct endpoint (schema shims INACTIVE)" || true
        _proxy_pid=""
        _proxy_script=""
      fi
    fi
    if [[ -n "$_proxy_script" ]]; then
      base="http://127.0.0.1:${_proxy_port}/v1/chat/completions"
      # cma_log is a lib.sh helper; the self-contained alias file has no such
      # function, so guard the call to avoid a 'cma_log: command not found' on
      # every proxied launch.
      command -v cma_log >/dev/null 2>&1 && cma_log "started proxy for $CMA_PROVIDER_ID on port $_proxy_port (pid=$_proxy_pid)" || true
    fi
    if (( ! _cma_ccr_self )) && command -v jq >/dev/null 2>&1; then
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
        command mv -f "$tmp" "$cfg"; chmod 600 "$cfg" 2>/dev/null || true
        ccr restart >/dev/null 2>&1 || true
      else
        rm -f "$tmp"
      fi
    fi
    ccr default-claude-code -- "$@"; rc=$?
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
    # Map Claude Code's subagent TIER aliases (opus/sonnet/haiku/fable) to this
    # provider's real serving model, so a tier-pinned subagent dispatch never leaks
    # a literal claude-* id to a native provider endpoint (which rejects it — xiaomi
    # HTTP 400 "Unsupported model" — or silently substitutes — deepseek 200).
    export ANTHROPIC_DEFAULT_OPUS_MODEL="$CMA_PROVIDER_MODEL"
    export ANTHROPIC_DEFAULT_SONNET_MODEL="$CMA_PROVIDER_MODEL"
    export ANTHROPIC_DEFAULT_HAIKU_MODEL="${CMA_PROVIDER_FAST_MODEL:-$CMA_PROVIDER_MODEL}"
    export ANTHROPIC_DEFAULT_FABLE_MODEL="$CMA_PROVIDER_MODEL"
    # Session flags are applied ABOVE for both transports (v1.17.0) — see
    # _cma_session_flags. CLAUDE_CODE_MAX_OUTPUT_TOKENS is exported ABOVE too,
    # before the transport branch, CLAMPED to <=128000 for BOTH transports —
    # see the _cma_out_guard/output-token-clamp block. (Was formerly
    # re-exported here as the RAW, unclamped CMA_PROVIDER_MAX_OUTPUT — the
    # origin of the "128000" fatal.) CLAUDE_CODE_AUTO_COMPACT_WINDOW caps
    # INPUT — the two are independent halves of the guard.
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
  command mv -f "$tmp" "$ALIAS_FILE"
}

# Remove an alias line. Idempotent.
cma_remove_alias() {
  local alias_name="$1"
  [[ -f "$ALIAS_FILE" ]] || return 0
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  grep -v -E "^alias[[:space:]]+${alias_name}=" "$ALIAS_FILE" > "$tmp" || true
  command mv -f "$tmp" "$ALIAS_FILE"
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
  daemon jobs
)
# NOTE (§11.4 own-settings): settings.json is DELIBERATELY NOT in the shared set.
# Each config dir gets its OWN settings.json so per-alias permissions/model/hooks
# never leak across aliases/providers, while the plugin CACHE (`plugins`),
# history (`history.jsonl`), memory (`CLAUDE.md`) and sessions stay shared. Each
# dir's own settings.json is seeded from + kept enabledPlugins-synced with the
# shared template $SHARED_DIR/settings.json by cma_own_settings_seed (so
# superpowers et al. stay enabled everywhere). See cma_link_shared_items +
# cma_enable_plugins below.
# NOTE (daemon/jobs): `daemon` is Claude Code's background-agent registry
# (roster.json + dispatch). It MUST be shared or a background agent started
# under one alias is invisible to every other alias — the registry is
# config-dir-scoped, not session-scoped. `jobs` is its sibling job store.
# daemon/roster.json is union-merged (not last-wins) — see
# merge_daemon_roster in claude-unify.sh.

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
    command mv -f "$tmp" "$f"
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

# Union daemon/roster.json files into one registry. workers are merged by id
# with the newer updatedAt winning per worker; proto and supervisorPid come
# from the newest roster; top-level updatedAt is the max. Used by
# claude-unify.sh (merge_daemon_roster) and cma_migrate_daemon_dirs_once.
# Usage: cma_union_rosters OUTFILE roster1.json [roster2.json ...]
cma_union_rosters() {
  local out="$1"; shift
  command -v jq >/dev/null 2>&1 || return 1
  (( $# >= 1 )) || return 1
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  if jq -s '
    def newer($a; $b): if (($a.updatedAt // 0) >= ($b.updatedAt // 0)) then $a else $b end;
    ([.[] | {u: (.updatedAt // 0), p: (.proto // 1), s: (.supervisorPid // null), w: (.workers // {})}])
    | (map(.u) | max // 0) as $maxu
    | (sort_by(.u) | last) as $newest
    | (reduce .[] as $r ({}; . as $acc
        | reduce ($r.w | to_entries[]) as $e ($acc;
            if ($acc[$e.key] == null) then . + {($e.key): $e.value}
            else . + {($e.key): newer($acc[$e.key]; $e.value)} end))) as $workers
    | {proto: $newest.p, supervisorPid: $newest.s, updatedAt: $maxu, workers: $workers}
  ' "$@" >| "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    command mv -f "$tmp" "$out"
    return 0
  fi
  rm -f "$tmp"
  return 1
}

# One-time migration for pre-v1.17.0 LOCAL daemon/jobs dirs under provider
# dirs: their contents (including background-agent rosters) must not be
# stranded when daemon/jobs become shared items. Merges every real provider
# daemon/jobs dir into $SHARED_DIR (roster.json excluded), backs it up,
# replaces it with the shared symlink, then union-merges every collected
# roster.json (incl. the shared one) with cma_union_rosters. Idempotent via a
# marker file; cma_link_shared_items handles all NEW provider dirs.
cma_migrate_daemon_dirs_once() {
  command -v rsync >/dev/null 2>&1 || return 0
  local marker="$SHARED_DIR/.daemon-migration-done"
  [[ -e "$marker" ]] && return 0
  local d item tgt roster_tmp=""
  for d in "$HOME/${CMA_PROVIDER_DIR_PREFIX:-.claude-prov-}"*/; do
    [[ -d "$d" ]] || continue
    for item in daemon jobs; do
      tgt="$d$item"
      [[ -d "$tgt" && ! -L "$tgt" ]] || continue
      mkdir -p "$SHARED_DIR/$item"
      rsync -a --exclude 'roster.json' "$tgt/" "$SHARED_DIR/$item/" 2>/dev/null || true
      if [[ -f "$tgt/roster.json" ]]; then
        # Stash roster CONTENT before the dir moves — collecting paths and
        # unioning afterwards would read the just-moved (missing) files.
        [[ -z "$roster_tmp" ]] && roster_tmp="$(mktemp -d "${TMPDIR:-/tmp}/cma.XXXXXX")"
        cp "$tgt/roster.json" "$roster_tmp/$(printf '%s' "$d" | md5sum | cut -c1-12).json"
      fi
      # Same backup convention as unify's backup_and_remove (defined there,
      # not in lib.sh): rename to <path>.preunify.<timestamp> — recoverable.
      command mv -f "$tgt" "${tgt}.preunify.$(date +%Y%m%d%H%M%S)"
      ln -s "$SHARED_DIR/$item" "$tgt"
    done
  done
  local srcs=()
  [[ -f "$SHARED_DIR/daemon/roster.json" && ! -L "$SHARED_DIR/daemon/roster.json" ]] && \
    srcs+=("$SHARED_DIR/daemon/roster.json")
  [[ -n "$roster_tmp" ]] && srcs+=("$roster_tmp"/*.json)
  if (( ${#srcs[@]} )); then
    cma_union_rosters "$SHARED_DIR/daemon/roster.json" "${srcs[@]}" || \
      cma_warn "daemon roster union failed during migration — last-wins file kept"
  fi
  [[ -n "$roster_tmp" ]] && rm -rf "$roster_tmp"
  # $SHARED_DIR may not exist yet (fresh host / first sync before any shared
  # item was linked). claude-providers.sh runs under `set -e`, so an unguarded
  # `: > $marker` onto a missing directory ABORTS the whole cmd_sync (captured
  # live: "line 1166: …/.claude-shared/.daemon-migration-done: No such file or
  # directory" -> sync exit 1, zero providers registered). The marker is only
  # a skip-optimization — the migration loop itself is idempotent (symlinked
  # dirs are skipped) — so a failed marker write must never kill the sync.
  mkdir -p "$SHARED_DIR" 2>/dev/null || true
  : > "$marker" 2>/dev/null || true
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
    command mv -f "$tmp" "$own"
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
    command mv -f "$tmp" "$settings"
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
  # Only BOOTSTRAP the alias file when it is absent — do NOT re-run the full
  # cma_ensure_alias_file (header + self-heal migrations) on every alias write.
  # Those migrations are install/invocation-time concerns; running them per
  # alias line made `--refresh-aliases` non-idempotent — a migration could
  # reposition the cma_run_provider function relative to the alias lines
  # (body byte-identical, only its position moved), so a second refresh no
  # longer produced an identical file (§ idempotence; see test_providers.sh
  # "--refresh-aliases is idempotent"). Existence is all this function needs.
  [[ -f "$ALIAS_FILE" ]] || cma_ensure_alias_file
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  grep -v -E "^alias[[:space:]]+${alias_name}=" "$ALIAS_FILE" > "$tmp" || true
  printf 'alias %s="cma_run_provider %s"\n' "$alias_name" "$id" >> "$tmp"
  command mv -f "$tmp" "$ALIAS_FILE"
}

# Install (idempotently) the provider session-refresh hook into $ALIAS_FILE. On
# every interactive shell start the hook re-writes provider aliases from cache
# (NO network) and, when the status cache is older than CMA_PROVIDERS_SYNC_TTL
# (default 24h), kicks a detached full sync (§11.4.89 background — never blocks
# the shell). Bracketed by markers so a re-install replaces the block atomically
# (no duplication across re-installs).
cma_install_session_hook() {
  cma_ensure_alias_file
  local begin='# cma-providers-session-refresh BEGIN'
  local end='# cma-providers-session-refresh END'
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  # Drop any existing block (BEGIN..END inclusive), then append the fresh one.
  awk -v b="$begin" -v e="$end" '
    $0==b{skip=1} !skip{print} $0==e{skip=0}' "$ALIAS_FILE" > "$tmp"
  {
    printf '%s\n' "$begin"
    cat <<'HOOK'
cma_providers_session_refresh() {
  command -v claude-providers >/dev/null 2>&1 || return 0
  # No-network: re-write alias functions from the cached env files.
  claude-providers list --quiet --refresh-aliases >/dev/null 2>&1 || true
  # TTL-triggered background full sync (detached; never blocks the shell).
  local ttl="${CMA_PROVIDERS_SYNC_TTL:-86400}"
  local sf="$HOME/.local/share/claude-multi-account/providers/status.json"
  if [ -f "$sf" ]; then
    local now mtime age
    now="$(date +%s)"
    mtime="$(date -r "$sf" +%s 2>/dev/null || stat -c %Y "$sf" 2>/dev/null || echo "$now")"
    age=$(( now - mtime ))
    if [ "$age" -gt "$ttl" ]; then
      ( nohup claude-providers sync >/dev/null 2>&1 & disown ) 2>/dev/null || true
    fi
  fi
}
cma_providers_session_refresh
HOOK
    printf '%s\n' "$end"
  } >> "$tmp"
  command mv -f "$tmp" "$ALIAS_FILE"
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
