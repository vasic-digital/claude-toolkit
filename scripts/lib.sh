#!/usr/bin/env bash
# lib.sh — shared functions for the Claude multi-account toolkit.
# Sourced by the other scripts; no side effects on its own.

set -euo pipefail

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

# Detect Linux vs macOS for platform-specific commands.
cma_os() {
  case "$(uname -s)" in
    Linux*)   echo linux ;;
    Darwin*)  echo macos ;;
    *)        echo unknown ;;
  esac
}

# Find all existing Claude account config directories under $HOME, matching
# the convention `.claude-<name>`. Echoes absolute paths, one per line,
# sorted. The default `~/.claude` is intentionally excluded because we treat
# it as the shared user-scope spot, not an account dir.
cma_detect_accounts() {
  find "$HOME" -maxdepth 1 -type d -name "${ACCOUNT_PREFIX}*" 2>/dev/null \
    | grep -v -- "-shared\$" \
    | sort
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
# ~/Documents/scripts/claude-add-account.sh to add accounts.
export CLAUDE_BIN="${CLAUDE_BIN_DEFAULT}"
EOF
  fi
  local rc src_line="source \"$ALIAS_FILE\""
  for rc in "$HOME/.bashrc" "$HOME/.zshrc"; do
    [[ -f "$rc" ]] || continue
    if ! grep -F -q "$src_line" "$rc"; then
      printf '\n# Claude multi-account aliases\n%s\n' "$src_line" >> "$rc"
      cma_log "added source line to $rc"
    fi
  done
}

# Add (or refresh) a single alias entry in $ALIAS_FILE. Idempotent.
cma_write_alias() {
  local alias_name="$1" config_dir="$2"
  cma_validate_alias "$alias_name"
  cma_ensure_alias_file
  # Strip any prior line for this alias, then append the new one.
  local tmp; tmp="$(mktemp)"
  grep -v -E "^alias[[:space:]]+${alias_name}=" "$ALIAS_FILE" > "$tmp" || true
  printf 'alias %s="CLAUDE_CONFIG_DIR=%s \\$CLAUDE_BIN"\n' \
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
