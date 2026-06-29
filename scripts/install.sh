#!/usr/bin/env bash
# install.sh — One-shot bootstrap for the Claude multi-account toolkit.
# Idempotent; safe to re-run after pulling updates.
#
# What it does, in order:
#   1. Detect tooling (jq, rsync, awk, pandoc) and fail fast if missing.
#   2. Symlink every script into ~/.local/bin (creates the dir if needed).
#   3. Ensure ~/.local/bin is on PATH for future shells.
#   4. Create the managed alias file at $ALIAS_FILE and source it from
#      ~/.bashrc and ~/.zshrc (whichever exist).
#   5. Run claude-unify.sh to merge any existing account dirs.
#   6. Run claude-export-docs.sh to refresh the PDF/HTML alongside the
#      markdown doc.

set -euo pipefail

# macOS ships bash 3.2 which lacks `mapfile`. If a newer bash is available
# (Homebrew installs it at /opt/homebrew/bin/bash on Apple Silicon, or
# /usr/local/bin/bash on Intel), re-exec with it. Otherwise tell the user
# how to install it.
if (( BASH_VERSINFO[0] < 4 )); then
  for newer in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$newer" ]] && exec "$newer" "$0" "$@"
  done
  echo "claude-toolkit requires bash 4+. Install via: brew install bash" >&2
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

cma_log "platform: $(cma_os)"

# 1. Required tooling. pandoc is needed only for doc export; the rest are
# load-bearing for unify/add-account.
for t in rsync jq awk; do cma_require "$t"; done
command -v pandoc >/dev/null 2>&1 || cma_warn "pandoc not found — PDF/HTML export will be skipped"

# 1b. Node deps for the optional TOON utility (scripts/toon.mjs, and the
# toon_encode.py wrapper that shells out to it). Soft by design: the toolkit's
# core (unify/add-account) needs no Node, so a missing npm is a warning, not a
# hard failure. Idempotent — npm install is a no-op once @toon-format/toon is
# already present. (node_modules/ is gitignored; this is how the dep arrives.)
_cma_repo_root="$(cd "$LIB_DIR/.." && pwd)"
if [[ -f "$_cma_repo_root/package.json" ]]; then
  if command -v npm >/dev/null 2>&1; then
    cma_log "installing Node deps for the TOON utility (npm install) ..."
    ( cd "$_cma_repo_root" && npm install --no-audit --no-fund --silent ) \
      || cma_warn "npm install failed — scripts/toon.mjs (TOON utility) may be unavailable"
  else
    cma_warn "npm not found — scripts/toon.mjs (TOON utility) unavailable until you run 'npm install' in $_cma_repo_root"
  fi
fi
unset _cma_repo_root

# 2. Symlink the scripts onto PATH.
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
for f in "$LIB_DIR"/claude-*.sh; do
  name="$(basename "$f" .sh)"
  link="$BIN_DIR/$name"
  if [[ -L "$link" || -e "$link" ]]; then
    if [[ "$(cma_realpath "$link")" != "$(cma_realpath "$f")" ]]; then
      mv "$link" "${link}.preunify.$(date +%Y%m%d%H%M%S)"
      ln -s "$f" "$link"
      cma_log "linked $link -> $f"
    fi
  else
    ln -s "$f" "$link"
    cma_log "linked $link -> $f"
  fi
done

# 3. Make sure ~/.local/bin is on PATH for new shells. We add to .bashrc
# and .zshrc once; existing shells need a manual reload.
# shellcheck disable=SC2016  # $HOME/$PATH are intentionally unexpanded literals written into rc files
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
for rc in "${CMA_RC_FILES[@]}"; do
  [[ -f "$rc" ]] || continue
  if ! grep -F -q "$PATH_LINE" "$rc"; then
    printf '\n# Claude multi-account: ensure ~/.local/bin is on PATH\n%s\n' "$PATH_LINE" >> "$rc"
    cma_log "added PATH line to $rc"
  fi
done

# 4. Alias file + rc sourcing.
cma_ensure_alias_file

# Re-register any pre-existing aliases from $HOME/.bashrc into the managed
# alias file, then comment out the originals so they're not duplicated.
migrate_inline_aliases() {
  local rc="$1"
  [[ -f "$rc" ]] || return 0
  local tmp; tmp="$(mktemp)"
  local changed=0
  while IFS= read -r line; do
    if [[ "$line" =~ ^alias[[:space:]]+(claude[0-9a-zA-Z_-]+)=.*CLAUDE_CONFIG_DIR=([^[:space:]\"]+) ]]; then
      local a="${BASH_REMATCH[1]}" d="${BASH_REMATCH[2]}"
      d="${d//\"/}"
      d="${d/#\$HOME/$HOME}"
      d="${d/#~/$HOME}"
      cma_write_alias "$a" "$d"
      printf '# migrated to %s: %s\n' "$ALIAS_FILE" "$line" >> "$tmp"
      changed=1
    else
      printf '%s\n' "$line" >> "$tmp"
    fi
  done < "$rc"
  if (( changed )); then
    cp -p "$rc" "${rc}.preunify.$(date +%Y%m%d%H%M%S)"
    mv "$tmp" "$rc"
    cma_log "migrated inline claude* aliases in $rc -> $ALIAS_FILE"
  else
    rm -f "$tmp"
  fi
}
for rc in "${CMA_RC_FILES[@]}"; do
  migrate_inline_aliases "$rc"
done

# 4b. Copy proxy scripts for provider compatibility (e.g. Poe tool format fix).
PROXY_SRC="$LIB_DIR/proxy"
PROXY_DST="$SHARED_DIR/proxy"
if [[ -d "$PROXY_SRC" ]]; then
  mkdir -p "$PROXY_DST"
  cp "$PROXY_SRC"/*.py "$PROXY_DST/" 2>/dev/null && chmod +x "$PROXY_DST"/*.py 2>/dev/null
  cma_log "copied proxy scripts to $PROXY_DST"
fi

# 5. Unify whatever accounts exist now.
if (( $(cma_detect_accounts | wc -l) > 0 )); then
  cma_log "running claude-unify.sh"
  "$LIB_DIR/claude-unify.sh"
else
  cma_warn "no ~/${ACCOUNT_PREFIX}* dirs detected — add one with claude-add-account.sh"
fi

# 6. Refresh docs if pandoc is available.
if command -v pandoc >/dev/null 2>&1 && [[ -f "$HOME/Documents/Claude_Multi_Account_Fine_Tuning.md" ]]; then
  cma_log "running claude-export-docs.sh"
  "$LIB_DIR/claude-export-docs.sh" || cma_warn "doc export failed (continuing)"
fi

cat <<EOF

[done] claude-multi-account installed.

  Scripts on PATH:  $BIN_DIR/claude-{unify,add-account,remove-account,list-accounts,rollback,export-docs}
  Alias file:       $ALIAS_FILE
  Shared store:     $SHARED_DIR

Open a new shell (or run: source $ALIAS_FILE) so the aliases load, then:
  claude-list-accounts            # see what's wired up
  claude-add-account              # add another account interactively
EOF
