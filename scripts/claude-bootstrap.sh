#!/usr/bin/env bash
# claude-bootstrap.sh — Clean-slate provisioning for a fresh machine that
# has Claude Code installed but ZERO accounts logged in. Creates N empty
# per-account dirs, wires them to a single shared store, and registers the
# `claudeN` aliases. After this runs the user just needs to `claudeN /login`
# each account once to authenticate.
#
# Differences from install.sh + claude-unify.sh:
#   * install.sh assumes ≥1 pre-existing `~/.claude-*` dir to merge.
#     bootstrap creates them from nothing.
#   * No content to merge → no `.preunify.*` backups, no rsync, no jq
#     settings-merge. Just `mkdir` and `ln -s`.
#
# Modes:
#   * --count N            Create claude1..claudeN (default: 2)
#   * --aliases a,b,c      Custom alias names instead of claude1, claude2...
#   * --dir-of NAME=PATH   Override the config dir for a given alias (can
#                          be repeated). Default is ~/.claude-<alias>.
#   * --yes                Non-interactive; accept all defaults.
#
# Examples:
#   bash claude-bootstrap.sh --count 2 --yes
#   bash claude-bootstrap.sh --aliases personal,work --yes
#   bash claude-bootstrap.sh --aliases work --dir-of work=$HOME/.claude-work --yes

set -euo pipefail

if (( BASH_VERSINFO[0] < 4 )); then
  for newer in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$newer" ]] && exec "$newer" "$0" "$@"
  done
  echo "claude-bootstrap requires bash 4+. Install via: brew install bash" >&2
  exit 1
fi

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

COUNT=2
ALIASES=()
declare -A DIR_OVERRIDES=()
NONINTERACTIVE=0

usage() {
  cat <<EOF
Usage: $(basename "$0") [--count N] [--aliases a,b,c] [--dir-of NAME=PATH]... [--yes]

Provision a fresh host with N shared-store-backed Claude Code accounts.
Use BEFORE first \`claude /login\` on any account.

  --count N         Create claude1..claudeN. Default: 2.
  --aliases a,b,c   Comma-separated custom names. Overrides --count.
  --dir-of NAME=PATH  Override config dir for a specific alias. Repeatable.
  --yes, -y         Non-interactive; use defaults without prompting.
  -h, --help        Show this help.

What it does:
  1. Verifies prereqs (jq, rsync, awk; warns on missing pandoc).
  2. Creates \$SHARED_DIR (default ~/.claude-shared) and seeds placeholders.
  3. For each alias, mkdir its config dir and symlink every shared item
     in. Touches an empty .credentials.json so list-accounts doesn't
     mis-report it as "no creds".
  4. Registers the alias in the managed alias file.
  5. Symlinks scripts into ~/.local/bin and ensures rc files load aliases.

After it finishes, run:  claude<N> /login   for each account.
EOF
}

while (( $# )); do
  case "$1" in
    -h|--help)   usage; exit 0 ;;
    --count)     COUNT="$2"; shift 2 ;;
    --aliases)   IFS=',' read -r -a ALIASES <<< "$2"; shift 2 ;;
    --dir-of)
      [[ "$2" == *=* ]] || cma_die "--dir-of expects NAME=PATH, got: $2"
      local_name="${2%%=*}" local_path="${2#*=}"
      DIR_OVERRIDES[$local_name]="$local_path"
      shift 2 ;;
    --yes|-y)    NONINTERACTIVE=1; shift ;;
    *)           cma_die "unknown arg: $1 (try --help)" ;;
  esac
done

# Validate prereqs up front.
cma_require jq
cma_require rsync
cma_require awk

# Default alias list: claude1..claudeN.
if (( ${#ALIASES[@]} == 0 )); then
  [[ "$COUNT" =~ ^[0-9]+$ ]] || cma_die "--count must be a positive integer"
  (( COUNT >= 1 )) || cma_die "--count must be >= 1"
  for ((i=1; i<=COUNT; i++)); do ALIASES+=("claude$i"); done
fi

# Validate each alias name and compute its config dir.
declare -A CONFIG_DIR_OF=()
for a in "${ALIASES[@]}"; do
  cma_validate_alias "$a"
  if [[ -n "${DIR_OVERRIDES[$a]:-}" ]]; then
    CONFIG_DIR_OF[$a]="${DIR_OVERRIDES[$a]}"
  else
    CONFIG_DIR_OF[$a]="$HOME/${ACCOUNT_PREFIX}${a}"
  fi
done

# Show plan and confirm.
cma_log "platform: $(cma_os)"
cma_log "shared store: $SHARED_DIR"
cma_log "planned accounts:"
for a in "${ALIASES[@]}"; do
  printf '  %-12s -> %s\n' "$a" "${CONFIG_DIR_OF[$a]}" >&2
done

# Refuse to clobber existing account dirs — bootstrap is for fresh hosts.
for a in "${ALIASES[@]}"; do
  d="${CONFIG_DIR_OF[$a]}"
  if [[ -e "$d" ]]; then
    cma_die "refusing to overwrite existing $d (use claude-add-account.sh for incremental adds)"
  fi
done
if cma_existing_aliases | grep -qx -e "$(printf '%s\n' "${ALIASES[@]}")"; then
  for a in "${ALIASES[@]}"; do
    if cma_existing_aliases | grep -qx "$a"; then
      cma_die "alias '$a' already registered in $ALIAS_FILE"
    fi
  done
fi

# Proceed when --yes was passed OR no terminal is available to prompt from
# (CI, test sandbox, SSH without a PTY) — the prompt defaults to "yes", so a
# non-interactive bootstrap is the expected, non-blocking behavior.
if (( ! NONINTERACTIVE )) && cma_can_prompt; then
  read -r -p "Proceed? [Y/n] " ans < /dev/tty
  [[ -z "$ans" || "$ans" =~ ^[Yy] ]] || cma_die "aborted"
fi

# --- 1. Symlink the toolkit scripts onto PATH (idempotent). ---
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
for f in "$LIB_DIR"/claude-*.sh; do
  name="$(basename "$f" .sh)"
  link="$BIN_DIR/$name"
  if [[ -L "$link" || -e "$link" ]]; then
    [[ "$(readlink "$link" 2>/dev/null)" == "$f" ]] && continue
    mv "$link" "${link}.prebootstrap.$(date +%Y%m%d%H%M%S)"
  fi
  ln -s "$f" "$link"
  cma_log "linked $link -> $f"
done

# --- 2. PATH and alias-file sourcing in rc files. ---
# shellcheck disable=SC2016  # $HOME/$PATH are intentionally unexpanded literals written into rc files
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
for rc in "${CMA_RC_FILES[@]}"; do
  [[ -f "$rc" ]] || continue
  if ! grep -F -q "$PATH_LINE" "$rc"; then
    printf '\n# Claude multi-account: ensure ~/.local/bin is on PATH\n%s\n' "$PATH_LINE" >> "$rc"
    cma_log "added PATH line to $rc"
  fi
done
cma_ensure_alias_file

# --- 3. Build the shared store with placeholders. ---
# These match SHARED_ITEMS in claude-unify.sh + claude-add-account.sh.
SHARED_DIRS=(projects todos tasks plans file-history paste-cache
             shell-snapshots session-env telemetry sessions backups
             cache plugins)
SHARED_FILES=(stats-cache.json history.jsonl settings.json CLAUDE.md)

mkdir -p "$SHARED_DIR"
for d in "${SHARED_DIRS[@]}"; do mkdir -p "$SHARED_DIR/$d"; done
for f in "${SHARED_FILES[@]}"; do [[ -e "$SHARED_DIR/$f" ]] || : > "$SHARED_DIR/$f"; done

# Seed an empty settings.json so jq merges work later when accounts log in.
if [[ ! -s "$SHARED_DIR/settings.json" ]]; then
  printf '{}\n' > "$SHARED_DIR/settings.json"
fi
cma_log "seeded $SHARED_DIR"

# --- 4. Provision each account dir + symlinks + alias. ---
for a in "${ALIASES[@]}"; do
  d="${CONFIG_DIR_OF[$a]}"
  mkdir -p "$d"
  for item in "${SHARED_DIRS[@]}" "${SHARED_FILES[@]}"; do
    ln -s "$SHARED_DIR/$item" "$d/$item"
  done
  # Touch the three private files so the account dir is shaped correctly
  # before `claude /login` populates them. .credentials.json gets a
  # placeholder JSON object so list-accounts reports CREDS:yes once the
  # user logs in — until login, the dir is intentionally empty/private.
  : > "$d/.claude.json"
  : > "$d/mcp-needs-auth-cache.json"
  # NOTE: .credentials.json is intentionally NOT created — Claude Code's
  # /login writes it. Touching it pre-emptively can break the auth flow.
  cma_write_alias "$a" "$d"
  cma_log "provisioned $a -> $d"
done

# --- 5. CLAUDE.md user-scope memory symlink to default plugin root. ---
DEFAULT_DIR="${DEFAULT_DIR:-$HOME/.claude}"
if [[ -d "$DEFAULT_DIR" && ! -e "$DEFAULT_DIR/CLAUDE.md" ]]; then
  ln -s "$SHARED_DIR/CLAUDE.md" "$DEFAULT_DIR/CLAUDE.md"
  cma_log "linked $DEFAULT_DIR/CLAUDE.md -> shared"
fi

# --- Final report. ---
cat <<EOF

[done] bootstrap complete. ${#ALIASES[@]} account(s) provisioned.

Next steps:
  1. Reload your shell so aliases load:
       exec \$SHELL -l
       # or:  source $ALIAS_FILE
  2. Log in to each account (one-time, writes its .credentials.json):
$(for a in "${ALIASES[@]}"; do printf '       %s /login\n' "$a"; done)
  3. Verify:
       claude-list-accounts

Shared store:  $SHARED_DIR
Alias file:    $ALIAS_FILE
Add more later with:  claude-add-account
EOF
