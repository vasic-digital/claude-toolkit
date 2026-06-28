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

PASSED=0 FAILED=0 FAILED_FILES=()

# "${FILES[@]+...}" guards against an empty array under `set -u` on bash 3.2,
# which (unlike bash 4.4+) treats "${FILES[@]}" on an empty array as unbound.
for f in "${FILES[@]+"${FILES[@]}"}"; do
  [[ -f "$f" ]] || { echo "missing: $f" >&2; FAILED=$((FAILED+1)); FAILED_FILES+=("$f"); continue; }
  printf '\n\033[1m==> %s\033[0m\n' "$(basename "$f")"
  if bash "$f"; then
    PASSED=$((PASSED + 1))
  else
    FAILED=$((FAILED + 1))
    FAILED_FILES+=("$(basename "$f")")
  fi
done

echo
echo "============================================"
echo "Test files: $((PASSED + FAILED))   passed: $PASSED   failed: $FAILED"
if (( FAILED )); then
  echo "Failed files:"
  for f in "${FAILED_FILES[@]}"; do echo "  - $f"; done
  exit 1
fi
echo "ALL GREEN"
