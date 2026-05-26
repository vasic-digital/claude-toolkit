#!/usr/bin/env bash
# assert.sh — small assertion helpers for the test suite. Each helper
# emits `[PASS]` or `[FAIL]` lines and increments counters in the caller.
# A test file should source this once and then call the helpers inside
# `it` blocks.

TESTS_PASSED="${TESTS_PASSED:-0}"
TESTS_FAILED="${TESTS_FAILED:-0}"
TESTS_FAILURES=()
CURRENT_TEST="${CURRENT_TEST:-(unknown)}"

# Mark the start of an individual test case. Use as:  it "merges history.jsonl"
it() {
  CURRENT_TEST="$*"
  printf '\n  • %s\n' "$CURRENT_TEST"
}

_pass() {
  TESTS_PASSED=$((TESTS_PASSED + 1))
  printf '    \033[32m[PASS]\033[0m %s\n' "$1"
}

_fail() {
  TESTS_FAILED=$((TESTS_FAILED + 1))
  TESTS_FAILURES+=("$CURRENT_TEST :: $1")
  printf '    \033[31m[FAIL]\033[0m %s\n' "$1"
  [[ -n "${2:-}" ]] && printf '           %s\n' "$2"
}

assert_eq() {
  local expected="$1" actual="$2" msg="${3:-equality}"
  if [[ "$expected" == "$actual" ]]; then _pass "$msg ($expected)"
  else _fail "$msg" "want=$expected got=$actual"; fi
}

assert_file() {
  local path="$1" msg="${2:-file exists}"
  if [[ -f "$path" ]]; then _pass "$msg: $path"
  else _fail "$msg" "missing: $path"; fi
}

assert_dir() {
  local path="$1" msg="${2:-dir exists}"
  if [[ -d "$path" ]]; then _pass "$msg: $path"
  else _fail "$msg" "missing dir: $path"; fi
}

assert_symlink_to() {
  local link="$1" expected="$2" msg="${3:-symlink target}"
  if [[ ! -L "$link" ]]; then
    _fail "$msg" "not a symlink: $link"
    return
  fi
  local actual; actual="$(readlink -f "$link")"
  local want;   want="$(readlink -f "$expected" 2>/dev/null || echo "$expected")"
  if [[ "$actual" == "$want" ]]; then _pass "$msg: $link -> $expected"
  else _fail "$msg" "want=$want got=$actual"; fi
}

assert_not_symlink() {
  local p="$1" msg="${2:-not a symlink}"
  if [[ -L "$p" ]]; then _fail "$msg" "is a symlink: $p"
  else _pass "$msg: $p"; fi
}

assert_file_contains() {
  local path="$1" needle="$2" msg="${3:-file contains}"
  if grep -F -q -- "$needle" "$path" 2>/dev/null; then _pass "$msg: '$needle' in $(basename "$path")"
  else _fail "$msg" "'$needle' not found in $path"; fi
}

assert_file_not_contains() {
  local path="$1" needle="$2" msg="${3:-file lacks}"
  if grep -F -q -- "$needle" "$path" 2>/dev/null; then _fail "$msg" "'$needle' found in $path"
  else _pass "$msg: '$needle' absent from $(basename "$path")"; fi
}

assert_jq() {
  local path="$1" expr="$2" expected="$3" msg="${4:-jq check}"
  local actual; actual="$(jq -r "$expr" "$path" 2>/dev/null || echo '<jq-error>')"
  if [[ "$actual" == "$expected" ]]; then _pass "$msg ($expr = $expected)"
  else _fail "$msg" "expr=$expr want=$expected got=$actual"; fi
}

assert_lines() {
  local path="$1" expected="$2" msg="${3:-line count}"
  local actual; actual="$(wc -l < "$path" 2>/dev/null || echo 0)"
  actual="${actual// /}"
  if [[ "$actual" == "$expected" ]]; then _pass "$msg ($expected lines)"
  else _fail "$msg" "want=$expected got=$actual lines in $path"; fi
}

assert_exit() {
  local expected="$1"; shift
  local out; out="$("$@" 2>&1)"; local rc=$?
  if (( rc == expected )); then _pass "exit $expected for: $*"
  else _fail "exit code mismatch" "want=$expected got=$rc cmd=$* out=$out"; fi
}

summary() {
  echo
  if (( TESTS_FAILED == 0 )); then
    printf '\033[32m✓ %d passed, 0 failed\033[0m\n' "$TESTS_PASSED"
    return 0
  fi
  printf '\033[31m✗ %d failed, %d passed\033[0m\n' "$TESTS_FAILED" "$TESTS_PASSED"
  printf '\nFailures:\n'
  for f in "${TESTS_FAILURES[@]}"; do printf '  - %s\n' "$f"; done
  return 1
}
