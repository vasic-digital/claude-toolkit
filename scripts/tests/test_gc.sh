#!/usr/bin/env bash
# test_gc.sh — exercises claude-gc.sh:
#   * dry-run (the default) never deletes anything
#   * retention keeps the newest N per original path AND anything <D days old
#     (the "OR", not just the newest-N half of the rule)
#   * --apply removes exactly the computed candidates, nothing else
#   * a lookalike name that doesn't match .preunify.<14-digit-ts> is never
#     touched, even under maximally aggressive retention flags
#   * the path-escape guard (cma_gc_guard) refuses a target outside
#     $SHARED_DIR / $HOME/.claude*
#   * reported sizes are real `du -sk` measurements, not invented
#   * basic CLI hygiene (--help, rejecting a bad --keep-n value)

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox

run_gc() { "$SCRIPTS_DIR/claude-gc.sh" "$@"; }

# ---------------------------------------------------------------------------
# Fixture helpers
# ---------------------------------------------------------------------------

# Portable epoch -> 14-digit timestamp (Darwin/Linux `date` split), used only
# to fabricate backups with controlled ages. Mirrors the split claude-gc.sh's
# own _cma_gc_ts_to_epoch uses for the reverse conversion, so a round trip
# through both is guaranteed consistent.
_gc_epoch_to_ts() {
  local epoch="$1"
  case "$(uname -s)" in
    Darwin*) date -j -r "$epoch" +%Y%m%d%H%M%S 2>/dev/null ;;
    *)       date -d "@$epoch" +%Y%m%d%H%M%S 2>/dev/null ;;
  esac
}
_gc_days_ago_ts() {
  local days="$1" now; now="$(date +%s)"
  _gc_epoch_to_ts "$(( now - days * 86400 ))"
}

# _gc_make_backup STEM DAYS_AGO SIZE_KB -> creates a directory
# "$STEM.preunify.<ts N days ago>" containing a SIZE_KB file, echoes the
# created path. This is the exact shape backup_and_remove (claude-unify.sh)
# produces for a directory item; a file item (e.g. stats-cache.json) would be
# a plain file, but the discovery/retention logic treats both identically —
# tests here just use directories throughout for simplicity.
_gc_make_backup() {
  local stem="$1" days="$2" kb="$3" ts d
  ts="$(_gc_days_ago_ts "$days")"
  d="${stem}.preunify.${ts}"
  mkdir -p "$d"
  dd if=/dev/zero of="$d/blob" bs=1024 count="$kb" 2>/dev/null
  printf '%s\n' "$d"
}

_gc_assert_gone() {
  local path="$1" msg="$2" cond=1
  [[ ! -e "$path" ]] && cond=0
  assert_eq 0 "$cond" "$msg"
}

# ---------------------------------------------------------------------------

it "dry-run (the default) deletes nothing"
# THREE backups of the same original path, two of them older than the 30-day
# window. The default policy keeps the newest 2 per path, so exactly one is a
# removal candidate — which is what makes the "DRY RUN"/"would free" lines
# appear at all. With only two backups the policy correctly keeps both, prints
# "nothing to remove", and those lines are legitimately absent: the earlier
# fixture asserted them without ever arranging a candidate.
b0="$(_gc_make_backup "$SHARED_DIR/plugins/cache" 90 200)"
b1="$(_gc_make_backup "$SHARED_DIR/plugins/cache" 45 300)"
b2="$(_gc_make_backup "$SHARED_DIR/plugins/cache" 2   100)"
out="$(run_gc 2>&1)"; rc=$?
assert_eq 0 "$rc" "dry-run exits 0"
grep -q "DRY RUN" <<<"$out"; assert_eq 0 $? "output announces DRY RUN"
grep -q "would free" <<<"$out"; assert_eq 0 $? "output reports what would be freed"
assert_dir "$b1" "45-day backup still present after dry-run"
assert_dir "$b2" "2-day backup still present after dry-run"

it "retention keeps the newest N per path and anything newer than D days (default policy: N=2, D=30)"
# Group "settings": 4 backups at 60d/45d/20d/2d. Only 60d and 45d are BOTH
# outside the newest-2 window AND older than 30 days -> removed. 20d and 2d
# are the newest 2 -> kept.
s60="$(_gc_make_backup "$SHARED_DIR/settings.json" 60 10)"
s45="$(_gc_make_backup "$SHARED_DIR/settings.json" 45 10)"
s20="$(_gc_make_backup "$SHARED_DIR/settings.json" 20 10)"
s02="$(_gc_make_backup "$SHARED_DIR/settings.json" 2  10)"
# Group "roster": 5 backups at 35d/32d/25d/15d/1d. By RANK ALONE only 15d and
# 1d would be "newest 2" -- but 25d is younger than the 30-day floor, so the
# retention policy's OR must save it too even though it is rank #3, not
# newest. This isolates the "anything newer than D days" half of the rule
# from the "newest N" half (the settings group above only exercises the
# newest-N half, since its two survivors are newest-by-rank AND recent).
r35="$(_gc_make_backup "$SHARED_DIR/roster.json" 35 10)"
r32="$(_gc_make_backup "$SHARED_DIR/roster.json" 32 10)"
r25="$(_gc_make_backup "$SHARED_DIR/roster.json" 25 10)"
r15="$(_gc_make_backup "$SHARED_DIR/roster.json" 15 10)"
r01="$(_gc_make_backup "$SHARED_DIR/roster.json" 1  10)"
run_gc --apply >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "--apply exits 0"
_gc_assert_gone "$s60" "settings 60d backup removed (beyond newest-2 AND beyond 30d)"
_gc_assert_gone "$s45" "settings 45d backup removed (beyond newest-2 AND beyond 30d)"
assert_dir "$s20" "settings 20d backup kept (newest-2 by rank)"
assert_dir "$s02" "settings 2d backup kept (newest-2 by rank)"
_gc_assert_gone "$r35" "roster 35d backup removed (not newest-2, and >=30d)"
_gc_assert_gone "$r32" "roster 32d backup removed (not newest-2, and >=30d)"
assert_dir "$r25" "roster 25d backup KEPT despite rank #3 -- saved by the <30-day rule, not by newest-N"
assert_dir "$r15" "roster 15d backup kept (newest-2 by rank, also recent)"
assert_dir "$r01" "roster 1d backup kept (newest-2 by rank, also recent)"
# The unrelated group from the previous test (both entries newest-by-rank,
# since only 2 exist for keep-n=2) must be untouched by this apply too.
assert_dir "$b1" "unrelated cache group untouched by this apply (fewer than N -> always newest)"
assert_dir "$b2" "unrelated cache group untouched by this apply (fewer than N -> always newest)"

it "--apply actually removes the expected candidates and only those"
acct="$(make_account gc3)"
g1a="$(_gc_make_backup "$acct/jobs" 40 50)"
g1b="$(_gc_make_backup "$acct/jobs" 5  60)"
g2a="$(_gc_make_backup "$acct/daemon" 90 70)"
g2b="$(_gc_make_backup "$acct/daemon" 80 80)"
g2c="$(_gc_make_backup "$acct/daemon" 10 90)"
# Only one backup ever existed for this path -- "newest N" never has fewer
# than N to compare against, so a lone backup is ALWAYS kept regardless of
# age. Deliberate: this is what keeps claude-rollback.sh's safety property
# intact even under an aggressive --keep-days.
g3="$(_gc_make_backup "$acct/stats-cache.json" 200 20)"
lookalike="$acct/notes.preunify.badshape"
: > "$lookalike"
out="$(run_gc --apply --keep-n 2 --keep-days 30 2>&1)"; rc=$?
assert_eq 0 "$rc" "--apply exits 0"
_gc_assert_gone "$g2a" "daemon 90d backup removed (rank #1 of 3, beyond 30d)"
assert_dir "$g1a" "jobs 40d backup kept (only 2 exist for this path, keep-n=2)"
assert_dir "$g1b" "jobs 5d backup kept (only 2 exist for this path, keep-n=2)"
assert_dir "$g2b" "daemon 80d backup kept (newest-2 by rank)"
assert_dir "$g2c" "daemon 10d backup kept (newest-2 by rank)"
assert_dir "$g3" "lone 200d backup kept (fewer than N backups exist for this path)"
assert_file "$lookalike" "lookalike file untouched (wrong name shape, never even a candidate)"
# "only those": exactly one removal line in this run's output.
removed_count="$(grep -c "removed" <<<"$out")"
assert_eq 1 "$removed_count" "exactly one candidate actually removed this run"

it "a non-backup file that merely looks similar is never removed, even under maximally aggressive retention"
lone="$(_gc_make_backup "$SHARED_DIR/aggressive-target" 1 15)"
similar1="$SHARED_DIR/aggressive-target.preunify.txt"            # no digits at all
similar2="$SHARED_DIR/aggressive-target.preunify.202601011200"   # 12 digits, too short
similar3="$SHARED_DIR/aggressive-target.preunify.2026010112000099" # 16 digits, too long
similar4="$SHARED_DIR/aggressive-targetpreunify.20260101120000"  # missing the dot before "preunify"
for f in "$similar1" "$similar2" "$similar3" "$similar4"; do : > "$f"; done
# --keep-n 0 --keep-days 0 disables BOTH halves of the retention floor, so
# the one genuine backup here is forced into the removal set -- proving the
# lookalikes survive because of the strict name-shape guard, not because
# retention happened to spare them.
run_gc --apply --keep-n 0 --keep-days 0 >/dev/null 2>&1
_gc_assert_gone "$lone" "the one genuine backup IS removed under --keep-n 0 --keep-days 0"
assert_file "$similar1" "lookalike (no digits) survives aggressive --apply"
assert_file "$similar2" "lookalike (12 digits) survives aggressive --apply"
assert_file "$similar3" "lookalike (16 digits) survives aggressive --apply"
assert_file "$similar4" "lookalike (missing dot before preunify) survives aggressive --apply"

it "path-escape guard refuses a target outside \$SHARED_DIR / \$HOME/.claude*"
# Source claude-gc.sh to unit-test cma_gc_guard directly (same technique
# test_lib.sh uses for lib.sh) -- this is the one property that cannot be
# observed end-to-end, since discovery never scans outside the allowed roots
# in the first place. lib.sh's `set -euo pipefail` comes along for the ride;
# restore the harness's tolerant mode right after, exactly like test_lib.sh.
# shellcheck source=../claude-gc.sh
source "$SCRIPTS_DIR/claude-gc.sh"
set +e
outside_dir="$SANDBOX_HOME/not-a-claude-dir"
mkdir -p "$outside_dir"
outside_target="$outside_dir/evil.preunify.20260101000000"
: > "$outside_target"
cma_gc_guard "$outside_target"
assert_eq 1 $? "guard refuses a well-shaped name living outside the allowed roots"
assert_file "$outside_target" "guard call alone never deletes anything"
# Sanity check the guard isn't just always-false: the same shape, INSIDE an
# allowed root, must be accepted.
inside_target="$SHARED_DIR/evil.preunify.20260101000000"
: > "$inside_target"
cma_gc_guard "$inside_target"
assert_eq 0 $? "guard accepts the identical name shape inside an allowed root"
rm -f "$inside_target" "$outside_target"

it "sizes reported are real (du -sk), not invented"
# The size must belong to a backup that is actually a REMOVAL CANDIDATE, or it
# is never printed. One backup aged 1 day is kept by both rules (newest-2 and
# within-30-days), so nothing was reported and the assertion could not pass.
# Three old backups of one path make the oldest a candidate; its independently
# measured du -sk size is what must appear in the output.
sized="$(_gc_make_backup "$SHARED_DIR/sized-target" 90 777)"
_gc_make_backup "$SHARED_DIR/sized-target" 60 100 >/dev/null
_gc_make_backup "$SHARED_DIR/sized-target" 45 100 >/dev/null
real_kb="$(du -sk "$sized" | awk '{print $1}')"
out="$(run_gc 2>&1)"
grep -q "${real_kb}KB" <<<"$out"; assert_eq 0 $? "dry-run output contains the independently-measured du -sk size (${real_kb}KB)"

it "--help prints usage and never deletes anything"
out="$(run_gc --help 2>&1)"; rc=$?
assert_eq 0 "$rc" "--help exits 0"
grep -q "^Usage:" <<<"$out"; assert_eq 0 $? "--help output starts with Usage:"
grep -q -- "--apply" <<<"$out"; assert_eq 0 $? "--help documents --apply"
assert_dir "$sized" "backup from the previous test untouched by --help"

it "rejects a non-numeric --keep-n value"
out="$(run_gc --keep-n notanumber 2>&1)"; rc=$?
cond=1; [[ "$rc" -ne 0 ]] && cond=0
assert_eq 0 "$cond" "non-numeric --keep-n exits non-zero"
grep -q "keep-n" <<<"$out"; assert_eq 0 $? "error message mentions --keep-n"

summary
