#!/usr/bin/env bash
# test_rc_safety.sh — regression tests for the rc-file DATA-LOSS defect that
# corrupted the operator's real ~/.bashrc.
#
# ROOT CAUSE (proven end-to-end): several toolkit paths MODIFY the user's shell
# rc files with NO backup and NO safety gate —
#   * cma_prune_stale_alias_sources rewrote the whole rc via `mv`, dropping a
#     stale `source ".../aliases.sh"` line but leaving its `# Claude multi-account
#     aliases` header ORPHANED;
#   * cma_ensure_alias_file / install.sh appended a fresh header+source line;
# and with BASH_ENV=~/.bashrc exported, every non-interactive bash ran the
# prune->ensure cycle. During a window when aliases.sh was missing the cycle
# repeated ~90 times, piling up ~90 orphaned header lines — and, with no backup
# ever taken, the original .bashrc body was lost with no recovery point.
#
# These tests pin the fix: (a) a pristine .cma-orig backup taken once and never
# overwritten; (b) rate-limited rolling backups + NO orphan accumulation;
# (c) prune removes the header+source block as a unit and self-heals orphans;
# (d) a safe-rewrite sanity gate that parks a bad candidate instead of
# publishing it; (e) refuse-to-modify when the backup cannot be taken.
#
# HERMETIC: every write goes through make_sandbox ($HOME := mktemp temp dir).
# The real ~/.bashrc / ~/.zshrc are NEVER touched.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
# lib.sh sets -e; this harness asserts on failures, so relax it.
set +e

# The managed header, spelled literally so the test is robust whether or not the
# code under test exposes it as a constant (it does not, pre-fix).
hdr='# Claude multi-account aliases'
count_header() { local n; n="$(grep -c -x -F -- "$hdr" "$1" 2>/dev/null)"; echo "${n:-0}"; }
# Count how many of the passed paths actually exist. Callers pass an already
# expanded glob (e.g. "$rc".cma-backup.*); with no match bash leaves the literal
# pattern, which -e correctly reports as absent. Avoids parsing `ls` output.
count_glob()   { local c=0 f; for f in "$@"; do [[ -e "$f" ]] && c=$((c + 1)); done; echo "$c"; }

# ── (a) pristine .cma-orig backup taken once, never overwritten ──────────────
it "(a) a modification writes a pristine .cma-orig backup, and never overwrites it"
rc="$SANDBOX_HOME/a.bashrc"
printf 'keepme\n%s\nsource "%s"\n' "$hdr" "$SANDBOX_HOME/gone-a/aliases.sh" > "$rc"
orig_snapshot="$(cat "$rc")"
cma_prune_stale_alias_sources "$rc"
assert_file "$rc.cma-orig" ".cma-orig created on first modification"
assert_eq "$orig_snapshot" "$(cat "$rc.cma-orig" 2>/dev/null)" ".cma-orig holds the pristine pre-modification content"
# A second, DIFFERENT modification must NOT bury the true original.
printf 'keepme2\n%s\nsource "%s"\n' "$hdr" "$SANDBOX_HOME/gone-a2/aliases.sh" > "$rc"
cma_prune_stale_alias_sources "$rc"
assert_eq "$orig_snapshot" "$(cat "$rc.cma-orig" 2>/dev/null)" ".cma-orig NOT overwritten by a later modification"

# ── (b) rate-limited rolling backups ─────────────────────────────────────────
it "(b) rolling rc backups are rate-limited on byte-identical content"
rc="$SANDBOX_HOME/brate.bashrc"
printf 'stable content\n' > "$rc"
i=0; while (( i < 25 )); do cma_backup_rc_file "$rc"; i=$((i+1)); done
assert_eq 1 "$(count_glob "$rc".cma-orig)"      "exactly one pristine .cma-orig after 25 identical backups"
assert_eq 1 "$(count_glob "$rc".cma-backup.*)"  "exactly one rolling backup (not 25) for identical content"

# ── (b) NO orphaned-header accumulation across ~90 prune->ensure cycles ───────
it "(b) prune->ensure cycle does NOT accumulate orphaned header lines (~90 corruption cannot recur)"
rc="$SANDBOX_HOME/b90.bashrc"
af_missing="$SANDBOX_HOME/gone-b/aliases.sh"     # target stays missing => 'dead' block, the incident's window
printf '%s\nsource "%s"\n' "$hdr" "$af_missing" > "$rc"
N=90; i=0
while (( i < N )); do
  # (1) the session hook's prune step, then (2) cma_ensure_alias_file's
  # append-if-not-sourced step — the incident's two independent writers.
  cma_prune_stale_alias_sources "$rc" >/dev/null 2>&1
  if ! cma_rc_sources_alias_file "$rc" "$af_missing"; then
    printf '\n%s\nsource "%s"\n' "$hdr" "$af_missing" >> "$rc"
  fi
  i=$((i+1))
done
hc="$(count_header "$rc")"
if (( hc <= 1 )); then _pass "header lines bounded after $N cycles (got $hc)"
else _fail "orphaned headers accumulated across cycles" "got $hc after $N cycles (pre-fix piles up ~$((N+1)))"; fi

# ── (c) prune removes the header+source block as a UNIT (no orphan) ───────────
it "(c) prune removes the managed header+source block together (no orphan left)"
rc="$SANDBOX_HOME/c.bashrc"
printf 'alpha\n%s\nsource "%s"\nbeta\n' "$hdr" "$SANDBOX_HOME/gone-c/aliases.sh" > "$rc"
cma_prune_stale_alias_sources "$rc"
assert_eq 0 "$(count_header "$rc")" "managed header removed together with its stale source line"
assert_file_not_contains "$rc" "gone-c" "stale source line removed"
{ grep -qxF alpha "$rc" && grep -qxF beta "$rc"; }; assert_eq 0 $? "surrounding user lines preserved"

it "(c) prune collapses pre-existing orphaned headers (self-heal), keeps the live block"
rc="$SANDBOX_HOME/cheal.bashrc"
live_af="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$live_af")"; printf '# managed alias file\n' > "$live_af"
{
  printf '%s\n' "$hdr"                 # orphan header 1
  printf 'user line 1\n'
  printf '%s\n' "$hdr"                 # orphan header 2 (back-to-back)
  printf '%s\n' "$hdr"                 # live block header
  printf 'source "%s"\n' "$live_af"    # live source (target EXISTS)
  printf 'user line 2\n'
} > "$rc"
cma_prune_stale_alias_sources "$rc"
assert_eq 1 "$(count_header "$rc")" "orphaned headers collapsed to the single live block"
cma_rc_sources_alias_file "$rc" "$live_af"; assert_eq 0 $? "live managed source line preserved"
{ grep -qxF 'user line 1' "$rc" && grep -qxF 'user line 2' "$rc"; }; assert_eq 0 $? "user lines preserved"

# ── (d) safe-rewrite sanity gate ─────────────────────────────────────────────
it "(d) sanity gate parks a syntactically-broken candidate; live rc left UNTOUCHED"
rc="$SANDBOX_HOME/d.bashrc"
# Dropping the stale source line here would leave `if true; then` / `fi` — a
# bash syntax error. The gate must refuse to publish that.
printf 'if true; then\n  source "%s"\nfi\n' "$SANDBOX_HOME/gone-d/aliases.sh" > "$rc"
before="$(cat "$rc")"
cma_prune_stale_alias_sources "$rc" >/dev/null 2>&1
assert_eq "$before" "$(cat "$rc")" "live rc left untouched when the pruned candidate fails bash -n"
if (( $(count_glob "$rc".rejected.*) >= 1 )); then _pass "broken candidate parked as .rejected.*"
else _fail "candidate not parked" "no $rc.rejected.* file was created"; fi

it "(d) gate rejects an empty candidate over a non-empty rc (unintended full truncation)"
rc="$SANDBOX_HOME/dempty.bashrc"; printf 'a\nb\nc\n' > "$rc"
cand="$(mktemp "${TMPDIR:-/tmp}/cma-cand.XXXXXX")"; : > "$cand"     # empty candidate
_cma_rc_rewrite_ok "$rc" "$cand" 0; rej=$?; rm -f "$cand"
assert_eq 1 "$rej" "empty candidate with 0 intended removals is rejected"

it "(d) gate rejects a candidate that lost lines the operation did not intend to remove"
rc="$SANDBOX_HOME/dtrunc.bashrc"; printf 'a\nb\nc\nd\ne\n' > "$rc"
cand="$(mktemp "${TMPDIR:-/tmp}/cma-cand.XXXXXX")"; printf 'a\n' > "$cand"  # 4 lost, only 1 intended
_cma_rc_rewrite_ok "$rc" "$cand" 1; rej=$?; rm -f "$cand"
assert_eq 1 "$rej" "candidate shrunk below (src_lines - intended_removed) is rejected"

# ── (e) refuse to modify when the backup cannot be taken ─────────────────────
it "(e) refuse to modify the rc when its backup cannot be taken (unwritable dir)"
subdir="$SANDBOX_HOME/eprotect"
mkdir -p "$subdir"
rc="$subdir/e.bashrc"
printf 'user content that must survive\n' > "$rc"
live_af="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$live_af")"; [[ -f "$live_af" ]] || printf '# af\n' > "$live_af"
before="$(cat "$rc")"
chmod 0500 "$subdir"     # dir unwritable: cannot create <rc>.cma-orig; the FILE itself stays writable
if ( : > "$subdir/.wprobe" ) 2>/dev/null; then
  # Running as root (or a filesystem that ignores the mode): the refuse path is
  # not exercisable, so record a pass rather than a spurious failure.
  rm -f "$subdir/.wprobe"; chmod 0700 "$subdir"
  _pass "skipped: dir mode not enforced for this user (root?) — refuse path not exercisable"
else
  ALIAS_FILE="$live_af"
  CMA_RC_FILES=("$rc")
  cma_ensure_alias_file >/dev/null 2>&1
  chmod 0700 "$subdir"   # restore for reads + cleanup
  assert_eq "$before" "$(cat "$rc")" "rc left UNCHANGED because its backup could not be taken"
  assert_eq 0 "$(count_glob "$rc".cma-orig)" "no half-written .cma-orig left behind"
fi

# ── (f) portable mtime: GNU `stat -c %Y` + BSD `stat -f %m`, never `date -r <path>` ──
# §11.4.68 / §11.4.81. `date -r <path>` reads its arg as EPOCH SECONDS on BSD, so it
# returns 0 for every file on macOS; both `_cma_mtime` and the emitted session-refresh
# hook must use the stat pair. Regression guard for the rc-safety review's NIT-1.
it "(f) _cma_mtime returns a real mtime here and carries the BSD 'stat -f %m' branch"
probe="$SANDBOX_HOME/mtime.probe"; printf x > "$probe"
mt="$(_cma_mtime "$probe")"
{ [[ "$mt" =~ ^[0-9]+$ ]] && (( mt > 0 )); }; assert_eq 0 $? "_cma_mtime returns a positive epoch for a real file here (GNU stat -c %Y branch runs)"
# The macOS branch cannot execute on this GNU host (§11.4.81(C) honest gap): assert
# its presence structurally so a revert to the GNU-only / date-r form is caught.
if declare -f _cma_mtime | grep -q 'stat -f %m'; then _pass "_cma_mtime carries the BSD 'stat -f %m' branch"
else _fail "_cma_mtime lacks the BSD 'stat -f %m' branch" "macOS would return 0 for every file"; fi

it "(f) no BSD-broken 'date -r \$path +%s' mtime idiom survives in lib.sh (helper OR emitted hook)"
# NOTE: the char class MUST include 0-9 — the helper reads `date -r "$1" +%s`
# ($1 is a digit); a letter-only class would silently miss a helper revert and
# only catch the hook's `$sf`. And use `|| true`, NOT `|| echo 0`: grep -c prints
# 0 AND exits 1 on no match, so `|| echo 0` would append a second 0 ("0\n0").
badmtime="$(grep -cE 'date -r "\$[A-Za-z0-9_]+" \+%s' "$SCRIPTS_DIR/lib.sh" 2>/dev/null || true)"
assert_eq 0 "${badmtime:-0}" "lib.sh carries no 'date -r \$path +%s' mtime read (helper + hook both use stat)"

summary
