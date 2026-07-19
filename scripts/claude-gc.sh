#!/usr/bin/env bash
# claude-gc.sh — garbage collector for toolkit-generated backup artifacts.
#
# Every destructive replacement claude-unify.sh makes goes through
# backup_and_remove, which renames the target aside to
# `<path>.preunify.<timestamp>` instead of deleting it, so a rollback can
# always restore it (claude-rollback.sh / claude-unify.sh --rollback). But
# nothing has ever rotated those backups — they accumulate forever. On the
# host this was written against, $SHARED_DIR/plugins alone carried a 2.9GB
# backup nearly two months stale (see
# docs/research/innovations/03-performance-optimization.md §5.1, "`.preunify.*`
# backups are never rotated").
#
# This script finds every `.preunify.<14-digit-timestamp>` backup under
# $SHARED_DIR and every $HOME/.claude* directory, applies a bounded-retention
# policy (keep the newest N per original path, and anything newer than D
# days — the rollback safety property only needs the newest one kept, not
# every one kept forever), and reports what a cleanup would free.
#
# DRY RUN IS THE DEFAULT. Nothing is ever deleted unless --apply is given
# explicitly. Even with --apply, a candidate is only ever removed if it
# passes cma_gc_guard: its basename must match the exact
# `.preunify.<14 digits>` shape AND it must resolve inside $SHARED_DIR or a
# $HOME/.claude* directory. That guard is re-checked immediately before every
# single deletion, independent of how the candidate was discovered — a bug in
# discovery cannot widen what --apply is allowed to touch.
#
# Exit codes: 0 = ran successfully (including "nothing to do" and "nothing
# past retention"); 1 = usage error, missing required tool, or invalid flag
# value (via cma_die).

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

DEFAULT_DIR="${DEFAULT_DIR:-$HOME/.claude}"

# Defaults (overridable by --keep-n / --keep-days / --apply below).
CMA_GC_KEEP_N=2
CMA_GC_KEEP_DAYS=30
CMA_GC_APPLY=0

# ---------------------------------------------------------------------------
# Discovery + safety primitives
# ---------------------------------------------------------------------------

# Strict shape check: a literal ".preunify." followed by EXACTLY 14 digits
# (the width of `date +%Y%m%d%H%M%S` — backup_and_remove's own ts() helper in
# claude-unify.sh) and nothing after. Deliberately strict so a lookalike name
# (wrong digit count, trailing suffix, different separator, a hand-made file
# that merely mentions "preunify") never matches and is never touched.
_cma_gc_is_preunify_name() {
  [[ "$1" =~ \.preunify\.[0-9]{14}$ ]]
}

# Portable "<14-digit timestamp> -> epoch seconds". Same Darwin/Linux `date`
# split already used for mtime reads elsewhere in the toolkit (e.g.
# claude-providers.sh's cache-mtime check, lib.sh's session mtime fallback).
_cma_gc_ts_to_epoch() {
  local ts="$1" y m d H M S
  y="${ts:0:4}"; m="${ts:4:2}"; d="${ts:6:2}"; H="${ts:8:2}"; M="${ts:10:2}"; S="${ts:12:2}"
  case "$(uname -s)" in
    Darwin*) date -j -f '%Y%m%d%H%M%S' "$ts" +%s 2>/dev/null ;;
    *)       date -d "${y}-${m}-${d} ${H}:${M}:${S}" +%s 2>/dev/null ;;
  esac
}

# Every directory this script is ever allowed to touch: $SHARED_DIR plus
# every $HOME/.claude* directory (covers DEFAULT_DIR, every account dir,
# every .claude-prov-* provider dir, .claude-code-router, and $SHARED_DIR
# itself when it uses the default `.claude-shared` name). Printed as
# canonical realpaths, one per line.
cma_gc_allowed_roots() {
  local d
  for d in "$HOME"/.claude*; do
    [[ -e "$d" ]] || continue
    cma_realpath "$d"
  done
  if [[ -n "${SHARED_DIR:-}" && -e "$SHARED_DIR" ]]; then
    case "$SHARED_DIR" in
      "$HOME"/.claude*) ;;  # already covered by the glob above
      *) cma_realpath "$SHARED_DIR" ;;
    esac
  fi
}

# The mandatory last line of defense before any deletion (§ header comment).
# Returns 0 only if PATH's basename strictly matches the preunify shape AND
# its canonical form resolves inside one of cma_gc_allowed_roots. Refuses
# (return 1, cma_warn) everything else. Does not trust its caller: it
# re-validates both conditions even for a path that discovery already
# produced.
cma_gc_guard() {
  local target="${1:-}" real base root
  if [[ -z "$target" ]]; then
    cma_warn "gc guard: refusing empty path"
    return 1
  fi
  real="$(cma_realpath "$target")"
  base="$(basename "$real")"
  if ! _cma_gc_is_preunify_name "$base"; then
    cma_warn "gc guard: refusing (not a .preunify.<14-digit-timestamp> name): $real"
    return 1
  fi
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    case "$real" in
      "$root"|"$root"/*) return 0 ;;
    esac
  done < <(cma_gc_allowed_roots)
  cma_warn "gc guard: refusing (outside \$SHARED_DIR / \$HOME/.claude*): $real"
  return 1
}

# Find every path shaped like a preunify backup under the allowed roots.
# Scoped to .claude* trees only (never a blind $HOME scan), so a
# coincidentally-matching name living anywhere else on the filesystem is
# never even considered. maxdepth 3 (relative to each root) mirrors the
# depths CONFIRMED to hold every real backup on the host this was measured
# against: $SHARED_DIR/plugins/cache.preunify.* (depth 3), an account dir's
# own jobs.preunify.* / daemon.preunify.* (depth 1), and a whole-dir backup
# sitting directly under $HOME (depth 0, handled by the name check below
# rather than `find`). The `find -name` glob here is intentionally LOOSE
# (matches any lookalike too) — strict filtering happens downstream in
# cma_gc_records via cma_gc_guard, so nothing loose ever reaches --apply.
cma_gc_discover() {
  local root base
  while IFS= read -r root; do
    [[ -n "$root" ]] || continue
    base="$(basename "$root")"
    if _cma_gc_is_preunify_name "$base"; then
      printf '%s\n' "$root"
    elif [[ -d "$root" ]]; then
      find "$root" -maxdepth 3 -name '*.preunify.*' -print 2>/dev/null || true
    fi
  done < <(cma_gc_allowed_roots) | sort -u
}

# ---------------------------------------------------------------------------
# Sizing (real `du -sk`, never invented) + retention math
# ---------------------------------------------------------------------------

_cma_gc_size_kb() {
  du -sk "$1" 2>/dev/null | awk '{print $1}'
}

# KB -> human string ("2.9G", "512.0K", ...). Plain awk (no GNU `numfmt`,
# which is absent on macOS) — matches the portability rule this repo already
# follows for awk (2-arg match/substr, no GNU-only extensions).
_cma_gc_human() {
  awk -v kb="$1" 'BEGIN {
    split("K M G T P", u, " ")
    v = kb; i = 1
    while (v >= 1024 && i < 5) { v /= 1024; i++ }
    printf "%.1f%s", v, u[i]
  }'
}

# Discover, guard, and size every candidate. Prints one TSV record per
# surviving candidate:
#   group_key <TAB> ts <TAB> epoch <TAB> kb <TAB> path
# group_key (dirname + original-path stem, i.e. the path BEFORE
# backup_and_remove renamed it aside) is what "newest N per original path"
# groups by — mirrors the `${bk%.preunify.*}` stem extraction claude-unify.sh
# rollback() itself already uses.
cma_gc_records() {
  local p real base dir stem ts epoch kb
  while IFS= read -r p; do
    [[ -n "$p" ]] || continue
    cma_gc_guard "$p" || continue
    real="$(cma_realpath "$p")"
    base="$(basename "$real")"
    dir="$(dirname "$real")"
    stem="${base%.preunify.*}"
    ts="${base##*.preunify.}"
    epoch="$(_cma_gc_ts_to_epoch "$ts" || true)"
    [[ -n "$epoch" ]] || continue   # unparseable timestamp: skip, never guess
    kb="$(_cma_gc_size_kb "$real" || true)"
    [[ -n "$kb" ]] || kb=0
    printf '%s/%s\t%s\t%s\t%s\t%s\n' "$dir" "$stem" "$ts" "$epoch" "$kb" "$real"
  done < <(cma_gc_discover)
}

# Reads unsorted records (cma_gc_records' shape) on stdin and prints one
# "kb<TAB>age_days<TAB>path" line per REMOVAL CANDIDATE: every record that is
# neither among the newest KEEP_N for its group_key, nor younger than
# KEEP_DAYS days. Sorting by group_key,ts (ascending, lexicographic — safe
# because ts is a fixed-width 14-digit number) puts each group's entries in
# chronological order, so "the last KEEP_N seen for a key" == "the newest
# KEEP_N for that key".
cma_gc_plan() {
  local keep_n="$1" keep_days="$2" now="$3"
  sort -t "$(printf '\t')" -k1,1 -k2,2 | awk -F'\t' -v keepn="$keep_n" -v keepdays="$keep_days" -v now="$now" '
    {
      rows[NR] = $0
      total[$1]++
    }
    END {
      for (r = 1; r <= NR; r++) {
        split(rows[r], f, "\t")
        k = f[1]; epoch = f[3]; kb = f[4]; path = f[5]
        seen[k]++
        is_newest = (seen[k] > total[k] - keepn)
        age_days = int((now - epoch) / 86400)
        is_recent = (age_days < keepdays)
        if (!is_newest && !is_recent) printf "%s\t%s\t%s\n", kb, age_days, path
      }
    }
  '
}

# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------

usage() {
  cat <<EOF
Usage: $(basename "$0") [--apply] [--keep-n N] [--keep-days D] [-h|--help]

Garbage-collects toolkit-generated .preunify.<timestamp> backups (created by
claude-unify.sh's backup_and_remove) under \$SHARED_DIR and every
\$HOME/.claude* directory. Nothing rotates these on its own — they
accumulate forever until this is run.

Retention: for each ORIGINAL path, the newest N backups are always kept, and
any backup newer than D days is kept regardless of N. Everything else is a
removal candidate. This preserves claude-rollback.sh's safety property (the
newest backup for a path is always recoverable) without keeping every backup
forever.

DEFAULT IS A DRY RUN: candidates and their real (du -sk) sizes are printed
and nothing is deleted, until you pass --apply.

Options:
  --apply            actually delete removal candidates (default: dry-run)
  --dry-run          explicit no-op spelling of the default
  --keep-n N         keep the newest N backups per original path (default: 2)
  --keep-days D      keep any backup newer than D days regardless of N (default: 30)
  -h, --help         show this help

Env: SHARED_DIR=$SHARED_DIR  DEFAULT_DIR=$DEFAULT_DIR
EOF
}

main() {
  while (( $# )); do
    case "$1" in
      --apply)     CMA_GC_APPLY=1; shift ;;
      --dry-run)   CMA_GC_APPLY=0; shift ;;
      --keep-n)
        [[ -n "${2:-}" ]] || cma_die "--keep-n requires a value"
        CMA_GC_KEEP_N="$2"; shift 2 ;;
      --keep-days)
        [[ -n "${2:-}" ]] || cma_die "--keep-days requires a value"
        CMA_GC_KEEP_DAYS="$2"; shift 2 ;;
      -h|--help)   usage; exit 0 ;;
      *)           cma_die "unknown flag: $1 (try --help)" ;;
    esac
  done

  [[ "$CMA_GC_KEEP_N" =~ ^[0-9]+$ ]]    || cma_die "--keep-n must be a non-negative integer, got: $CMA_GC_KEEP_N"
  [[ "$CMA_GC_KEEP_DAYS" =~ ^[0-9]+$ ]] || cma_die "--keep-days must be a non-negative integer, got: $CMA_GC_KEEP_DAYS"

  cma_require du
  cma_require awk
  cma_require find
  cma_require sort

  cma_log "scanning \$SHARED_DIR ($SHARED_DIR) and \$HOME/.claude* for .preunify.<timestamp> backups"
  cma_log "policy: keep newest $CMA_GC_KEEP_N per original path, keep anything newer than $CMA_GC_KEEP_DAYS days"

  local now; now="$(date +%s)"
  local records; records="$(cma_gc_records)"
  if [[ -z "$records" ]]; then
    cma_log "no .preunify.<timestamp> backups found under the allowed roots — nothing to do"
    return 0
  fi

  local plan; plan="$(printf '%s\n' "$records" | cma_gc_plan "$CMA_GC_KEEP_N" "$CMA_GC_KEEP_DAYS" "$now")"
  if [[ -z "$plan" ]]; then
    cma_log "every backup found is within retention (newest $CMA_GC_KEEP_N per path, or <$CMA_GC_KEEP_DAYS days old) — nothing to remove"
    return 0
  fi

  if (( CMA_GC_APPLY )); then
    cma_log "--apply given — removing candidates:"
  else
    cma_log "DRY RUN (default; pass --apply to actually delete) — removal candidates:"
  fi

  local total_kb=0 kb age path human
  while IFS="$(printf '\t')" read -r kb age path; do
    [[ -n "$path" ]] || continue
    total_kb=$(( total_kb + kb ))
    human="$(_cma_gc_human "$kb")"
    if (( CMA_GC_APPLY )); then
      if cma_gc_guard "$path"; then
        rm -rf -- "$path"
        cma_log "  removed    ${kb}KB (~${human})  age=${age}d  $path"
      else
        cma_log "  SKIPPED (guard refused; not deleted)  $path"
      fi
    else
      cma_log "  candidate  ${kb}KB (~${human})  age=${age}d  $path"
    fi
  done <<< "$plan"

  human="$(_cma_gc_human "$total_kb")"
  if (( CMA_GC_APPLY )); then
    cma_log "freed: ${total_kb}KB (~${human}) total"
  else
    cma_log "would free: ${total_kb}KB (~${human}) total — re-run with --apply to delete"
  fi
}

# Allow this file to be sourced (the test suite unit-tests cma_gc_guard and
# _cma_gc_is_preunify_name directly, the same way test_lib.sh sources lib.sh)
# without running main. `(return 0 2>/dev/null)` succeeds only inside a
# sourced context; it fails when the file is executed directly, since `return`
# outside a function/sourced script is illegal there.
if ! (return 0 2>/dev/null); then
  main "$@"
fi
