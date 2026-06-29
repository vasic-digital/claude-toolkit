#!/usr/bin/env bash
# claude-unify.sh — Unify N Claude Code account config dirs into a single
# shared store so every account sees the same projects/conversations,
# memory, history, todos, plans, plugins, and settings.
#
# Inputs:
#   * Positional args: one or more account config directories. If none
#     are given, all `~/.claude-*` directories are auto-detected (excluding
#     the shared store itself).
#   * Env vars:
#       SHARED_DIR    target shared store (default: ~/.claude-shared)
#       DEFAULT_DIR   user-scope plugin root (default: ~/.claude)
#
# Use --rollback to restore the .preunify.* backups and remove the shared
# store. Safe to re-run any time.

set -euo pipefail

# macOS ships bash 3.2 which lacks `mapfile`. Re-exec under Homebrew bash
# if available; otherwise tell the user how to install it.
if (( BASH_VERSINFO[0] < 4 )); then
  for newer in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$newer" ]] && exec "$newer" "$0" "$@"
  done
  echo "claude-unify requires bash 4+. Install via: brew install bash" >&2
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

DEFAULT_DIR="${DEFAULT_DIR:-$HOME/.claude}"

cma_require rsync
cma_require jq
cma_require awk

# Items each account dir contributes to the shared store. Order matters
# only insofar as we want plugins last so the path-rewrite step has all
# manifest entries to rewrite at once.
SHARED_ITEMS=(
  projects
  todos
  tasks
  plans
  file-history
  paste-cache
  shell-snapshots
  session-env
  telemetry
  sessions
  backups
  cache
  stats-cache.json
  history.jsonl
  settings.json
  plugins
)

PRIVATE_ITEMS=(
  .credentials.json
  .claude.json
  mcp-needs-auth-cache.json
)

ts() { date +%Y%m%d%H%M%S; }

already_linked_to_shared() {
  [[ -L "$1" ]] || return 1
  # cma_realpath (not `readlink -f`, which is absent on BSD/macOS — there the
  # old check always failed, so unify re-linked every item on every re-run).
  [[ "$(cma_realpath "$1")" == "$(cma_realpath "$2")" ]]
}

backup_and_remove() {
  local p="$1"
  [[ -e "$p" || -L "$p" ]] || return 0
  mv "$p" "${p}.preunify.$(ts)"
}

link_to_shared() {
  local item="$1" acct
  for acct in "${ACCOUNTS[@]}"; do
    [[ -d "$acct" ]] || continue
    local target="$acct/$item"
    already_linked_to_shared "$target" "$SHARED_DIR/$item" && continue
    backup_and_remove "$target"
    mkdir -p "$(dirname "$target")"
    ln -s "$SHARED_DIR/$item" "$target"
  done
}

merge_dir_into_shared() {
  local item="$1" acct rc
  mkdir -p "$SHARED_DIR/$item"
  # First pass: each account fills only gaps (--ignore-existing) so the
  # union is preserved across N accounts.
  for acct in "${ACCOUNTS[@]}"; do
    if [[ -d "$acct/$item" && ! -L "$acct/$item" ]]; then
      rc=0
      rsync -a --ignore-existing "$acct/$item/" "$SHARED_DIR/$item/" || rc=$?
      # rsync exit 23/24 are partial transfers ("some files vanished" / "some
      # files couldn't be transferred") that we treat as warnings — common on
      # macOS for `unlinkat: Directory not empty` when symlinks straddle the
      # tree. Anything else is fatal.
      (( rc == 0 || rc == 23 || rc == 24 )) || return $rc
    fi
  done
  # Second pass: overlay every account with rsync -u (update-only) so the file
  # carrying the NEWEST mtime wins each conflict, regardless of how many accounts
  # there are or what they're named. The previous code overlaid only
  # ACCOUNTS[-1] — the alphabetically-last dir, not necessarily the most recently
  # active one — which let a stale lexically-last account clobber fresher content
  # (e.g. memory/*.md) from an earlier account.
  for acct in "${ACCOUNTS[@]}"; do
    if [[ -d "$acct/$item" && ! -L "$acct/$item" ]]; then
      rc=0
      rsync -au "$acct/$item/" "$SHARED_DIR/$item/" || rc=$?
      (( rc == 0 || rc == 23 || rc == 24 )) || return $rc
    fi
  done
}

merge_history_jsonl() {
  local acct srcs=() tmp; tmp="$(mktemp)"
  for acct in "${ACCOUNTS[@]}"; do
    local f="$acct/history.jsonl"
    if [[ -f "$f" && ! -L "$f" ]]; then srcs+=("$f"); fi
  done
  if [[ -f "$SHARED_DIR/history.jsonl" && ! -L "$SHARED_DIR/history.jsonl" ]]; then
    srcs+=("$SHARED_DIR/history.jsonl")
  fi
  # Feed the files straight to awk rather than cat'ing them together first: awk
  # starts a fresh record at every file boundary, so a source missing its
  # trailing newline cannot fuse its last line onto the next file's first line
  # (plain `cat` would). Write via a temp file so we never truncate shared while
  # it is also one of the inputs.
  if (( ${#srcs[@]} )); then
    awk 'NF && !seen[$0]++' "${srcs[@]}" > "$tmp"
    mv "$tmp" "$SHARED_DIR/history.jsonl"
  else
    : > "$SHARED_DIR/history.jsonl"
    rm -f "$tmp"
  fi
  return 0
}

merge_settings_json() {
  local acct files=() resolved
  for acct in "${ACCOUNTS[@]}"; do
    local f="$acct/settings.json"
    if [[ -L "$f" ]]; then
      resolved="$(cma_realpath "$f")"  # readlink -f is unavailable on BSD/macOS
      if [[ -f "$resolved" ]]; then files+=("$resolved"); fi
    elif [[ -f "$f" ]]; then
      files+=("$f")
    fi
  done
  # De-duplicate. On re-runs both account symlinks resolve to the same
  # shared file, and passing the same path twice plus redirecting back to
  # it truncates the file before jq reads it.
  if (( ${#files[@]} > 1 )); then
    mapfile -t files < <(printf '%s\n' "${files[@]}" | awk '!seen[$0]++')
  fi
  case "${#files[@]}" in
    0) return 0 ;;
    1) cp -p "${files[0]}" "$SHARED_DIR/settings.json.tmp"
       mv "$SHARED_DIR/settings.json.tmp" "$SHARED_DIR/settings.json" ;;
    *)
      # Right-most file's top-level keys win, except enabledPlugins which
      # is the union across all accounts (any "true" survives).
      # We bind the slurped array to $all so the inner reductions don't
      # iterate over the values of the partially-merged outer object.
      # Write to a temp file first so we never truncate-then-read shared.
      # enabledPlugins is an "any true survives" union: a plugin enabled in ANY
      # account stays enabled, regardless of account order. A plain `+`/`*` merge
      # would let the lexically-last account's `false` clobber an earlier `true`.
      # Guard the jq so a single malformed account settings.json warns + skips
      # instead of aborting the whole unify under `set -e` (it is item 15 of 16).
      if jq -s '
        . as $all
        | (reduce $all[] as $x ({}; . * $x))
        | .enabledPlugins = (reduce $all[] as $x ({};
            reduce ($x.enabledPlugins // {} | to_entries[]) as $e (.;
              .[$e.key] = ((.[$e.key] // false) or $e.value))))
      ' "${files[@]}" > "$SHARED_DIR/settings.json.tmp" 2>/dev/null; then
        mv "$SHARED_DIR/settings.json.tmp" "$SHARED_DIR/settings.json"
      else
        rm -f "$SHARED_DIR/settings.json.tmp"
        cma_warn "settings.json: one or more account files are invalid JSON; merge skipped"
      fi
      ;;
  esac
  return 0
}

merge_file_into_shared() {
  local item="$1" acct newest=""
  for acct in "${ACCOUNTS[@]}"; do
    local f="$acct/$item"
    if [[ -L "$f" ]]; then continue; fi
    if [[ ! -f "$f" ]]; then continue; fi
    if [[ -z "$newest" || "$f" -nt "$newest" ]]; then newest="$f"; fi
  done
  if [[ -n "$newest" ]]; then cp -p "$newest" "$SHARED_DIR/$item"; fi
  return 0
}

absorb_default_plugins() {
  [[ -d "$DEFAULT_DIR/plugins" && ! -L "$DEFAULT_DIR/plugins" ]] || return 0
  mkdir -p "$SHARED_DIR/plugins"
  local rc=0
  rsync -a --ignore-existing "$DEFAULT_DIR/plugins/" "$SHARED_DIR/plugins/" || rc=$?
  (( rc == 0 || rc == 23 || rc == 24 )) || return $rc
  return 0
}

rewrite_plugin_paths() {
  local f="$SHARED_DIR/plugins/installed_plugins.json"
  if [[ -f "$f" ]]; then
    local tmp; tmp="$(mktemp)"
    jq --arg shared "$SHARED_DIR" '
      .plugins |= with_entries(
        .value |= map(
          if ((.installPath // "") | test(".*/plugins/cache/"))
          then .installPath = ($shared + "/plugins/cache/" + (.installPath | sub(".*/plugins/cache/"; "")))
          else . end
        )
      )' "$f" > "$tmp" && mv "$tmp" "$f"
  fi
  local km="$SHARED_DIR/plugins/known_marketplaces.json"
  if [[ -f "$km" ]]; then
    local tmp; tmp="$(mktemp)"
    jq --arg shared "$SHARED_DIR" '
      with_entries(
        if ((.value.installLocation // "") | test(".*/plugins/marketplaces/"))
        then .value.installLocation = ($shared + "/plugins/marketplaces/" + (.value.installLocation | sub(".*/plugins/marketplaces/"; "")))
        else . end
      )' "$km" > "$tmp" && mv "$tmp" "$km"
  fi
}

# Repoint ~/.claude/plugins/cache and ~/.claude/plugins/marketplaces at
# the shared store so future user-scope installs land in one place.
link_default_plugin_subdirs() {
  for sub in cache marketplaces; do
    local src="$SHARED_DIR/plugins/$sub" tgt="$DEFAULT_DIR/plugins/$sub"
    [[ -d "$src" ]] || continue
    already_linked_to_shared "$tgt" "$src" && continue
    mkdir -p "$DEFAULT_DIR/plugins"
    backup_and_remove "$tgt"
    ln -s "$src" "$tgt"
  done
}

# CLAUDE.md (user-scope memory) lives at ~/.claude/CLAUDE.md by default.
# We promote it to the shared store and symlink all three locations (each
# account dir + ~/.claude) so any account writing user memory updates the
# same file.
sync_claude_md() {
  local shared_md="$SHARED_DIR/CLAUDE.md" src
  if [[ ! -f "$shared_md" ]]; then
    if [[ -f "$DEFAULT_DIR/CLAUDE.md" && ! -L "$DEFAULT_DIR/CLAUDE.md" ]]; then
      cp -p "$DEFAULT_DIR/CLAUDE.md" "$shared_md"
    else
      for acct in "${ACCOUNTS[@]}"; do
        if [[ -f "$acct/CLAUDE.md" && ! -L "$acct/CLAUDE.md" ]]; then
          cp -p "$acct/CLAUDE.md" "$shared_md"; break
        fi
      done
    fi
    [[ -f "$shared_md" ]] || return 0
  fi
  local targets=("$DEFAULT_DIR/CLAUDE.md")
  for acct in "${ACCOUNTS[@]}"; do targets+=("$acct/CLAUDE.md"); done
  for tgt in "${targets[@]}"; do
    [[ -d "$(dirname "$tgt")" ]] || continue
    already_linked_to_shared "$tgt" "$shared_md" && continue
    backup_and_remove "$tgt"
    ln -s "$shared_md" "$tgt"
  done
}

rollback() {
  cma_log "rollback: restoring .preunify.* backups"
  local root
  local roots=("$DEFAULT_DIR" "$DEFAULT_DIR/plugins" "$SHARED_DIR")
  for root in "${ACCOUNTS[@]}"; do roots+=("$root"); done
  for root in "${roots[@]}"; do
    [[ -d "$root" ]] || continue
    while IFS= read -r -d '' bk; do
      local orig="${bk%.preunify.*}"
      [[ -L "$orig" ]] && rm -f "$orig"
      [[ -e "$orig" ]] || { mv "$bk" "$orig"; cma_log "restored $orig"; }
    done < <(find "$root" -maxdepth 1 -name '*.preunify.*' -print0 2>/dev/null)
  done
  if [[ -d "$SHARED_DIR" ]]; then
    mv "$SHARED_DIR" "${SHARED_DIR}.removed.$(ts)"
    cma_log "moved $SHARED_DIR aside"
  fi
}

usage() {
  cat <<EOF
Usage: $(basename "$0") [--rollback] [account-dir ...]

Without args, auto-detects all ~/${ACCOUNT_PREFIX}* directories.
With --rollback, restores .preunify.* backups and removes the shared store.

Env: SHARED_DIR=$SHARED_DIR DEFAULT_DIR=$DEFAULT_DIR
EOF
}

# === main ===

ACCOUNTS=()
DO_ROLLBACK=0
while (( $# )); do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --rollback) DO_ROLLBACK=1; shift ;;
    --) shift; while (( $# )); do ACCOUNTS+=("$1"); shift; done ;;
    -*) cma_die "unknown flag: $1" ;;
    *)  ACCOUNTS+=("$1"); shift ;;
  esac
done

if (( ${#ACCOUNTS[@]} == 0 )); then
  mapfile -t ACCOUNTS < <(cma_detect_accounts)
fi

(( ${#ACCOUNTS[@]} >= 1 )) || cma_die "no account dirs given and none auto-detected at ~/${ACCOUNT_PREFIX}*"

cma_log "accounts: ${ACCOUNTS[*]}"
cma_log "shared:   $SHARED_DIR"

if (( DO_ROLLBACK )); then rollback; exit 0; fi

mkdir -p "$SHARED_DIR"
absorb_default_plugins

for item in "${SHARED_ITEMS[@]}"; do
  case "$item" in
    history.jsonl)    merge_history_jsonl ;;
    settings.json)    merge_settings_json ;;
    stats-cache.json) merge_file_into_shared "$item" ;;
    *)                merge_dir_into_shared "$item" ;;
  esac
  [[ "$item" == "plugins" ]] && rewrite_plugin_paths
  link_to_shared "$item"
  cma_log "ok: $item"
done

link_default_plugin_subdirs
sync_claude_md

# Merge the projects/session index inside .claude.json across every account.
# This is the single most important step for cross-account session resume:
# without it, account A's session UUIDs are invisible to account B even though
# the JSONL transcripts are already shared on disk via projects/.
cma_merge_claude_json "${ACCOUNTS[@]}"
cma_log "ok: .claude.json (projects/session index merged; auth keys preserved per-account)"

cma_log "done. shared: $SHARED_DIR"
cma_log "private per-account: ${PRIVATE_ITEMS[*]}"
