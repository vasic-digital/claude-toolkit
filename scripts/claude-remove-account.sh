#!/usr/bin/env bash
# claude-remove-account.sh — Remove a Claude Code account from the
# multi-account setup. Drops the alias from the managed alias file and
# (optionally) deletes or archives the per-account config directory.
#
# The shared store is left untouched — only this one account's symlinks
# and credentials are removed. Other accounts continue using shared.

set -euo pipefail

LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

ALIAS_NAME=""
DELETE_DIR=0
ARCHIVE_DIR=1
NONINTERACTIVE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") --alias NAME [--delete | --archive] [--yes]

  --alias NAME   Required. Alias to remove (e.g. claude3).
  --delete       Permanently delete the per-account config directory.
  --archive      Move the per-account dir to <dir>.removed.<timestamp>
                 instead of deleting (default).
  --yes          Skip confirmation prompts.
EOF
}

while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --alias)   ALIAS_NAME="$2"; shift 2 ;;
    --delete)  DELETE_DIR=1; ARCHIVE_DIR=0; shift ;;
    --archive) ARCHIVE_DIR=1; DELETE_DIR=0; shift ;;
    --yes|-y)  NONINTERACTIVE=1; shift ;;
    *)         cma_die "unknown arg: $1" ;;
  esac
done

[[ -n "$ALIAS_NAME" ]] || { usage; exit 2; }
cma_validate_alias "$ALIAS_NAME"

# Resolve the config dir by inspecting the existing alias line.
CONFIG_DIR=""
if [[ -f "$ALIAS_FILE" ]]; then
  CONFIG_DIR="$(awk -v a="$ALIAS_NAME" '
    $0 ~ "^alias[[:space:]]+"a"=" {
      match($0, /CLAUDE_CONFIG_DIR=([^ ]+)/, m);
      print m[1]; exit
    }' "$ALIAS_FILE")"
fi
[[ -n "$CONFIG_DIR" ]] || cma_die "alias '$ALIAS_NAME' not found in $ALIAS_FILE"

cma_log "removing alias '$ALIAS_NAME' (config dir: $CONFIG_DIR)"

if (( ! NONINTERACTIVE )); then
  read -r -p "Proceed? [y/N] " ans < /dev/tty
  [[ "$ans" =~ ^[Yy]$ ]] || cma_die "aborted"
fi

cma_remove_alias "$ALIAS_NAME"
cma_log "alias removed from $ALIAS_FILE"

if [[ -d "$CONFIG_DIR" ]]; then
  if (( DELETE_DIR )); then
    rm -rf -- "$CONFIG_DIR"
    cma_log "deleted $CONFIG_DIR"
  else
    mv -- "$CONFIG_DIR" "${CONFIG_DIR}.removed.$(date +%Y%m%d%H%M%S)"
    cma_log "archived $CONFIG_DIR -> ${CONFIG_DIR}.removed.*"
  fi
fi

cat <<EOF

[done] account '$ALIAS_NAME' removed.

Notes:
  * Shared store $SHARED_DIR is untouched — other accounts still work.
  * Reload your shell so the alias change takes effect.
EOF
