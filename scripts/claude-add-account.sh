#!/usr/bin/env bash
# claude-add-account.sh — Add a new Claude Code account to the multi-account
# setup. Creates the per-account config directory, links every shared item
# to the shared store, and registers a shell alias so the new account is
# invocable as e.g. `claude3`.
#
# Modes:
#   * Interactive (default): prompts for alias name and config dir name,
#     showing defaults that follow the existing pattern.
#   * Non-interactive: pass --alias NAME and optionally --dir PATH, e.g.
#     `claude-add-account.sh --alias work --dir ~/.claude-work`.
#
# After this script runs you still need to authenticate the new account
# with Anthropic — the script prints the exact command for that.

set -euo pipefail

# Resolve LIB_DIR through any symlinks (install.sh symlinks into ~/.local/bin).
_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

ALIAS_NAME=""
CONFIG_DIR=""
NONINTERACTIVE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--alias NAME] [--dir PATH] [--yes]

  --alias NAME   Shell alias to create (e.g. claude3 or work). Default:
                 next free claudeN.
  --dir   PATH   Config directory for the new account. Default:
                 ~/${ACCOUNT_PREFIX}<alias>.
  --yes          Skip prompts and use defaults / passed values.
EOF
}

while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --alias)   ALIAS_NAME="$2"; shift 2 ;;
    --dir)     CONFIG_DIR="$2"; shift 2 ;;
    --yes|-y)  NONINTERACTIVE=1; shift ;;
    *)         cma_die "unknown arg: $1" ;;
  esac
done

# Prompt with a default value, return whatever the user types (or default).
prompt() {
  local label="$1" default="$2" answer
  # Use the default when --yes was passed OR no terminal is available to
  # prompt from (CI, test sandbox, SSH without a PTY) — never block.
  if (( NONINTERACTIVE )) || ! cma_can_prompt; then echo "$default"; return; fi
  read -r -p "$label [$default]: " answer < /dev/tty
  echo "${answer:-$default}"
}

[[ -n "$ALIAS_NAME" ]] || ALIAS_NAME="$(cma_suggest_alias)"
ALIAS_NAME="$(prompt "Alias name" "$ALIAS_NAME")"
cma_validate_alias "$ALIAS_NAME"

# Reject if alias already exists in the alias file.
if cma_existing_aliases | grep -qx "$ALIAS_NAME"; then
  cma_die "alias '$ALIAS_NAME' already exists in $ALIAS_FILE"
fi

[[ -n "$CONFIG_DIR" ]] || CONFIG_DIR="$HOME/${ACCOUNT_PREFIX}${ALIAS_NAME}"
CONFIG_DIR="$(prompt "Config directory" "$CONFIG_DIR")"
case "$CONFIG_DIR" in /*) ;; *) CONFIG_DIR="$HOME/$CONFIG_DIR" ;; esac

[[ -d "$CONFIG_DIR" ]] && cma_die "config dir already exists: $CONFIG_DIR (refusing to overwrite)"

mkdir -p "$CONFIG_DIR"
cma_log "created $CONFIG_DIR"

# Symlink every shared item into the new account dir, using the single
# canonical list (CMA_SHARED_ITEMS in lib.sh) so accounts and provider
# aliases stay in lockstep without two copies of the list drifting apart.
cma_link_shared_items "$CONFIG_DIR"
cma_log "linked ${#CMA_SHARED_ITEMS[@]} shared items into $CONFIG_DIR"

# Add the alias. lib.sh handles dedupe, rc-file sourcing, etc.
#
# The status is CHECKED. cma_write_alias used to report success even when the
# write was skipped on lock contention, which left the account on disk with no
# alias while this script printed "[done]" — and the obvious retry then died at
# the "config dir already exists" guard above, with no supported way forward.
# Say what actually happened and name the one command that finishes the job.
if ! cma_write_alias "$ALIAS_NAME" "$CONFIG_DIR"; then
  cma_warn "the alias for '$ALIAS_NAME' was NOT written to $ALIAS_FILE"
  cma_warn "$CONFIG_DIR exists and its shared items are linked — only the alias is missing."
  cma_die  "Finish with:  claude-unify   (re-registers an alias for every detected account)"
fi
cma_log "registered alias: $ALIAS_NAME -> $CONFIG_DIR"

cat <<EOF

[done] new account: $ALIAS_NAME

Next steps:
  1. Reload your shell (or run: source $ALIAS_FILE).
  2. Authenticate the new account:
       $ALIAS_NAME /login
  3. After login, run any project — history, memory, plugins, and
     settings will already match your other accounts via $SHARED_DIR.

To remove this account later:
  $LIB_DIR/claude-remove-account.sh --alias $ALIAS_NAME
EOF
