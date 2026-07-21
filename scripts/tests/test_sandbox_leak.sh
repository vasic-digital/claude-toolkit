#!/usr/bin/env bash
# test_sandbox_leak.sh — guard against leaked `cma-test.*` sandbox directories.
#
# WHY THIS EXISTS
# ---------------
# make_sandbox (tests/lib/sandbox.sh) mktemp's a fresh $HOME as
# `$TMPDIR/cma-test.XXXXXX` and registers `trap cleanup_sandbox EXIT` to remove
# it. When that contract breaks the sandbox is never reclaimed, and because the
# sandbox IS $HOME, every Go-building test re-downloads its whole module cache
# into it — a single orphan costs ~500-850 MB of tmpfs. 109 such orphans (35 GB,
# oldest 10 days) had accumulated on this host before the leak was found.
#
# Known ways the EXIT trap contract breaks:
#   1. Calling make_sandbox twice in one file: the second call reassigns
#      SANDBOX_HOME and re-arms the trap, so the FIRST mktemp dir is orphaned
#      with nothing left pointing at it. (test_install.sh hit this; it now
#      routes through a fresh_sandbox helper that cleans up before re-creating.)
#   2. A later `trap ... EXIT` that does not chain cleanup_sandbox — an EXIT
#      trap is replaced, not appended.
#   3. SIGKILL / OOM. Untrappable by definition, so it cannot be fixed in the
#      shell; it is the residual leak source and the reason a periodic sweep of
#      stale cma-test.* dirs is still worth running.
#
# WHAT IT ASSERTS
# ---------------
# Running a representative test leaves NO new cma-test.* directory behind.
#
# Children are pointed at a private TMPDIR *inside this test's own sandbox*.
# That matters twice over: concurrent test runs by other processes cannot make
# this test false-fail (we only ever look at our own root), and anything a child
# does leak is reclaimed by our own cleanup_sandbox — this guard can never
# become the thing it is guarding against.
#
# ANTI-VACUOUS-PASS: a "no new directories" assertion passes trivially if the
# child never created one (e.g. it died at startup). Three controls prevent
# that: we prove a well-behaved child really did create and remove a sandbox,
# we require the representative test to actually pass, and we prove the very
# same detector reports a leak on a planted leftover AND on a SIGKILLed child.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
export SCRIPTS_DIR

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.

# Private temp root for child processes. Inside our own sandbox on purpose:
# isolated from concurrent runs, and swept by our own EXIT trap.
LEAK_ROOT="$SANDBOX_HOME/leakroot"
mkdir -p "$LEAK_ROOT"

# ---------------------------------------------------------------------------
# THE DETECTOR — the single thing under test. Every case below routes through
# it, so the anti-vacuous cases prove the exact code path used by the real ones.
# Mirrors the pattern cleanup_sandbox itself anchors on: basename cma-test.*
# ---------------------------------------------------------------------------
count_sandboxes() {
  find "$1" -maxdepth 1 -name 'cma-test.*' -type d 2>/dev/null | wc -l | tr -d ' '
}

# Run a child with its own empty temp root; echo that root.
new_root() { local r; r="$(mktemp -d "$LEAK_ROOT/root.XXXXXX")"; printf '%s\n' "$r"; }

# ---------------------------------------------------------------------------
it "a well-behaved child creates a sandbox and removes it on exit"
# Establishes NON-VACUITY for the cases below: proves a sandbox is really
# created under our private root, and that the normal EXIT path reclaims it.
root="$(new_root)"
child="$LEAK_ROOT/well-behaved.sh"
cat > "$child" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
printf '%s\n' "\$SANDBOX_HOME" > "$LEAK_ROOT/created.txt"
EOF
TMPDIR="$root" bash "$child" >/dev/null 2>&1
created="$(cat "$LEAK_ROOT/created.txt" 2>/dev/null)"

if [[ -n "$created" ]]; then _pass "child reported its sandbox: $(basename "$created")"
else _fail "child never created a sandbox" "no path recorded — later assertions would be vacuous"; fi

case "$created" in
  "$root"/cma-test.*) _pass "sandbox was created under our private root" ;;
  *) _fail "sandbox landed outside the private root" "got=$created want=$root/cma-test.*" ;;
esac

if [[ -n "$created" && ! -e "$created" ]]; then _pass "sandbox was removed on normal exit"
else _fail "sandbox survived a normal exit" "still present: $created"; fi

assert_eq 0 "$(count_sandboxes "$root")" "detector reports no leftovers after a clean run"

# ---------------------------------------------------------------------------
it "ANTI-VACUOUS-PASS: the detector fires on a planted leftover"
# If this reports 0, the detector is blind and every "0 leaked" above is
# meaningless. Same function, same root shape, only the leftover is planted.
root="$(new_root)"
planted="$root/cma-test.PLANTED"
mkdir -p "$planted/projects"
assert_eq 1 "$(count_sandboxes "$root")" "detector counts a planted cma-test.* dir"

# A non-matching directory must NOT be counted — proves the detector is
# specific and is not just counting every directory it sees.
mkdir -p "$root/not-a-sandbox"
assert_eq 1 "$(count_sandboxes "$root")" "detector ignores non-cma-test dirs"

# ---------------------------------------------------------------------------
it "ANTI-VACUOUS-PASS: the detector fires on a SIGKILLed child"
# Models the real residual leak mechanism: SIGKILL cannot be trapped, so
# cleanup_sandbox never runs. Proves the detector catches a genuinely orphaned
# sandbox, not merely a hand-made directory.
root="$(new_root)"
child="$LEAK_ROOT/killed.sh"
cat > "$child" <<EOF
#!/usr/bin/env bash
set -uo pipefail
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
touch "$LEAK_ROOT/killed-ready"
sleep 30
EOF
rm -f "$LEAK_ROOT/killed-ready"
TMPDIR="$root" bash "$child" >/dev/null 2>&1 &
kpid=$!
for _ in $(seq 100); do [[ -e "$LEAK_ROOT/killed-ready" ]] && break; sleep 0.1; done
kill -9 "$kpid" 2>/dev/null
wait "$kpid" 2>/dev/null

if [[ -e "$LEAK_ROOT/killed-ready" ]]; then _pass "child reached the sandboxed phase before being killed"
else _fail "child never got far enough" "SIGKILL case would be vacuous"; fi

leaked="$(count_sandboxes "$root")"
if (( leaked >= 1 )); then _pass "detector reports the orphan left by SIGKILL ($leaked)"
else _fail "detector missed a SIGKILL orphan" "count=$leaked, expected >= 1"; fi

# ---------------------------------------------------------------------------
it "a representative test leaves no cma-test.* directory behind"
# The actual regression guard. REPRESENTATIVE_TEST is overridable so this can
# be pointed at a heavier file (e.g. verify_helixagent_test.sh, the biggest
# space offender) without editing the test.
rep="${REPRESENTATIVE_TEST:-$TESTS_DIR/test_lib.sh}"
root="$(new_root)"

if [[ -r "$rep" ]]; then
  _pass "representative test is present: $(basename "$rep")"
  TMPDIR="$root" bash "$rep" > "$LEAK_ROOT/rep.log" 2>&1
  rep_rc=$?

  # Require it to have actually run. A crashed test that never reached
  # make_sandbox would leave 0 dirs and pass the leak check for the wrong
  # reason — the precise vacuous pass this guard exists to prevent.
  assert_eq 0 "$rep_rc" "representative test itself passed (so it really ran)"

  assert_eq 0 "$(count_sandboxes "$root")" "no cma-test.* left behind by $(basename "$rep")"
else
  _fail "representative test not readable" "$rep"
fi

summary
