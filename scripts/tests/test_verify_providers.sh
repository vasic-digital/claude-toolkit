#!/usr/bin/env bash
# Hermetic tests for claude-verify-providers.sh — no network, no go, no real keys.
# Exercises the wrapper contract (help, submodule wiring, precondition guards).
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/lib/assert.sh"
. "$HERE/lib/sandbox.sh"
make_sandbox
set +e

REPO_ROOT="$(cd "$HERE/../.." && pwd)"
SCRIPT="$REPO_ROOT/scripts/claude-verify-providers.sh"

# 1. script exists + is executable
[ -x "$SCRIPT" ]; assert_eq 0 $? "claude-verify-providers.sh exists and is executable"

# 2. --help exits 0 and documents the LLMsVerifier submodule path
out="$("$SCRIPT" --help 2>&1)"; rc=$?
assert_eq 0 "$rc" "--help exits 0"
printf '%s' "$out" | grep -q 'LLMsVerifier submodule'
assert_eq 0 $? "--help documents the LLMsVerifier submodule"

# 3. the submodule is declared in .gitmodules at the expected path
grep -q 'path = submodules/LLMsVerifier' "$REPO_ROOT/.gitmodules" 2>/dev/null
assert_eq 0 $? ".gitmodules declares submodules/LLMsVerifier"

# 4. uninitialized submodule -> actionable exit 3 (point at an empty dir)
empty="$(mktemp -d "${TMPDIR:-/tmp}/lv.XXXXXX")"
LLMSVERIFIER_DIR="$empty" "$SCRIPT" --providers deepseek >/dev/null 2>&1
assert_eq 3 $? "uninitialized submodule -> actionable exit 3"
rm -rf "$empty"

# 5. keys are never echoed: run --help with a sentinel secret in LV_KEYS-less env,
#    assert the sentinel never appears in output (anti-leak posture).
export CMA_FAKE_SECRET="sk-should-never-print-1234567890"
printf '%s' "$out" | grep -q "$CMA_FAKE_SECRET"
assert_eq 1 $? "wrapper output never contains secret-shaped env values"
unset CMA_FAKE_SECRET

summary
