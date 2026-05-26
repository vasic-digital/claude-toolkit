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

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
  if (( NONINTERACTIVE )); then echo "$default"; return; fi
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

# Symlink every shared item into the new account dir. We mirror the same
# list that claude-unify uses so a brand-new account starts in lockstep
# with the others without re-running the full merge.
SHARED_ITEMS=(
  projects todos tasks plans file-history paste-cache shell-snapshots
  session-env telemetry sessions backups cache plugins
  stats-cache.json history.jsonl settings.json CLAUDE.md
)

mkdir -p "$SHARED_DIR"
for item in "${SHARED_ITEMS[@]}"; do
  src="$SHARED_DIR/$item"
  tgt="$CONFIG_DIR/$item"
  # If the shared item doesn't yet exist, create an empty placeholder so
  # the symlink isn't dangling. Directories are mkdir'd, files are touched.
  if [[ ! -e "$src" ]]; then
    case "$item" in
      *.json|*.jsonl|*.md) : > "$src" ;;
      *) mkdir -p "$src" ;;
    esac
  fi
  ln -s "$src" "$tgt"
done
cma_log "linked ${#SHARED_ITEMS[@]} shared items into $CONFIG_DIR"

# Add the alias. lib.sh handles dedupe, rc-file sourcing, etc.
cma_write_alias "$ALIAS_NAME" "$CONFIG_DIR"
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
