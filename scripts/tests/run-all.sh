#!/usr/bin/env bash
# run-all.sh — discover every test_*.sh sibling, run each in its own
# subshell, and tally pass/fail.
#
# Exit code is 0 only if every test file's `summary` returned 0.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
export SCRIPTS_DIR

FILES=()
if (( $# )); then
  for arg in "$@"; do FILES+=("$TESTS_DIR/test_${arg}.sh"); done
else
  # Portable discovery: `mapfile`/`readarray` are bash 4+ and absent on the
  # bash 3.2 that ships with macOS, where this test runner must also run.
  while IFS= read -r _f; do FILES+=("$_f"); done \
    < <(find "$TESTS_DIR" -maxdepth 1 -name 'test_*.sh' -type f | sort)
fi

PASSED=0 FAILED=0 SKIPPED=0 FAILED_FILES=()

# "${FILES[@]+...}" guards against an empty array under `set -u` on bash 3.2,
# which (unlike bash 4.4+) treats "${FILES[@]}" on an empty array as unbound.
for f in "${FILES[@]+"${FILES[@]}"}"; do
  [[ -f "$f" ]] || { echo "missing: $f" >&2; FAILED=$((FAILED+1)); FAILED_FILES+=("$f"); continue; }
  printf '\n\033[1m==> %s\033[0m\n' "$(basename "$f")"
  # Capture output while still streaming it, so we can cross-check the printed
  # result against the exit code (see harness-integrity check below).
  _out="$(mktemp "${TMPDIR:-/tmp}/cma-runall.XXXXXX")"
  bash "$f" 2>&1 | tee "$_out"
  _rc=${PIPESTATUS[0]}

  # HARNESS INTEGRITY (defense in depth): a file's exit code is the ONLY thing
  # this runner tallies, and `summary` is what turns TESTS_FAILED into a
  # non-zero exit. A file that prints [FAIL] but exits 0 means its summary call
  # is missing/bypassed — the failures would otherwise be counted as a PASS.
  # This really happened: test_providers.sh lacked `summary` and hid 5 real
  # failures behind a green run. Never trust a 0 that contradicts the output.
  if (( _rc == 0 )) && grep -q '\[FAIL\]' "$_out"; then
    printf '\033[31m[HARNESS] %s printed [FAIL] but exited 0 — missing summary?\033[0m\n' \
      "$(basename "$f")" >&2
    _rc=1
  fi
  # Visibility: a file that SKIPs on a missing prerequisite exits 0 and would
  # otherwise be indistinguishable from a genuine pass in "ALL GREEN".
  if (( _rc == 0 )) && grep -q '^SKIP' "$_out"; then
    SKIPPED=$((SKIPPED + 1))
  fi
  rm -f "$_out"

  if (( _rc == 0 )); then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_FILES+=("$(basename "$f")")
  fi
done

echo
echo "============================================"
echo "Test files: $((PASSED + FAILED))   passed: $PASSED   failed: $FAILED   (skipped-prereq: $SKIPPED)"
if (( FAILED )); then
  echo "Failed files:"
  for f in "${FAILED_FILES[@]}"; do echo "  - $f"; done
  exit 1
fi
echo "ALL GREEN"
