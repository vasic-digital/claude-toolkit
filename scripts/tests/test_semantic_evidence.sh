#!/usr/bin/env bash
# test_semantic_evidence.sh — guards the layer-3 evidence-mirroring block in
# providers-semantic.sh.
#
# WHY THIS EXISTS (independent-review finding F1). The block that mirrors the
# driver's rc/JSON into stderr sits between `rc=$?` and the verdict `case`,
# while `set -e` is active. Unguarded, an I/O fault inside it (an unreadable
# cache file, a full pipe) aborts the script BEFORE the verdict word is echoed.
# Callers read STDOUT, and claude-providers.sh treats an EMPTY verdict as
# "keep the existence verdict (verified)" — so a definitive layer-3 FAIL would
# silently become a PASS. That is a fail-open in an anti-bluff path: exactly
# the class of defect the layer-3 gate exists to prevent.
#
# HERMETIC: no network, no live provider. providers-semantic.sh honours
# CMA_SEMANTIC_DRIVER, so a stub driver supplies a deterministic rc + JSON.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

REPO_CACHE="$SCRIPTS_DIR/../.local-cache"

# --- stub driver: deterministic rc + a driver-shaped JSON, no network --------
STUB="$SANDBOX_HOME/stub-driver.sh"
sandbox_stub "$STUB" <<'EOF'
#!/usr/bin/env bash
# Mimic the real driver: write the JSON report where the caller expects it,
# then exit with the rc the test asked for via STUB_RC.
out="$STUB_JSON_OUT"
mkdir -p "$(dirname "$out")"
printf '{"round1_sentinel":{"pass":true,"observed":"S"},"round2_judge":{"pass":false,"score":null,"skipped":false,"reason":"stubbed"},"overall_pass":false}\n' > "$out"
exit "${STUB_RC:-1}"
EOF
chmod +x "$STUB"

# providers-semantic.sh writes the driver's stdout to
# "$REPO_ROOT/.local-cache/semantic-last.json"; the stub must land there too.
export STUB_JSON_OUT="$REPO_CACHE/semantic-last.json"

# Judge + fixture preconditions, so the script reaches the driver at all.
JUDGE_ENV="$SANDBOX_HOME/judge.env"
{
  echo "CMA_JUDGE_BASE_URL=https://judge.invalid/v1"
  echo "CMA_JUDGE_MODEL=judge-model"
  echo "CMA_JUDGE_KEYVAR=TEST_JUDGE_KEY"
  echo "CMA_JUDGE_THRESHOLD=2"
} > "$JUDGE_ENV"
export TEST_JUDGE_KEY="judge-key-not-a-real-secret"
export TEST_PROBE_KEY="probe-key-not-a-real-secret"

run_semantic() {
  ( export CMA_SEMANTIC_DRIVER="$STUB" CMA_JUDGE_ENV="$JUDGE_ENV"
    bash "$SCRIPTS_DIR/providers-semantic.sh" --provider testprov \
      --model test-model --key-var TEST_PROBE_KEY --base-url https://prov.invalid/v1 ) 2>"$1"
}

# --- (a) control: the verdict word reaches stdout ---------------------------
it "(a) a driver failure yields the 'unverified' verdict on stdout"
EV_OK="$SANDBOX_HOME/ev-ok.txt"
STUB_RC=1 verdict="$(run_semantic "$EV_OK")"
assert_eq "unverified" "$verdict" "driver rc=1 maps to the 'unverified' verdict word"

it "(a) the evidence carries the driver's rc and JSON (self-diagnosing)"
assert_file_contains "$EV_OK" "driver rc=1" "evidence records the driver exit code"
assert_file_contains "$EV_OK" "round1_sentinel" "evidence mirrors the driver JSON"

# --- (b) F1 REGRESSION GUARD: an I/O fault must NOT swallow the verdict -----
# An unreadable cache file makes the mirroring block's `cat` fail. Under `set -e`
# and unguarded, that aborts before the verdict is echoed => empty stdout =>
# callers read it as "verified". The verdict MUST survive.
it "(b) an unreadable driver-JSON cache does NOT suppress the verdict (no fail-open)"
EV_BAD="$SANDBOX_HOME/ev-bad.txt"
STUB_RC=1 verdict_bad="$( ( export CMA_SEMANTIC_DRIVER="$STUB" CMA_JUDGE_ENV="$JUDGE_ENV" \
      STUB_JSON_OUT="$REPO_CACHE/semantic-last.json"
    # Run once so the cache exists, then make it unreadable for the mirroring step.
    bash "$SCRIPTS_DIR/providers-semantic.sh" --provider testprov --model test-model \
      --key-var TEST_PROBE_KEY --base-url https://prov.invalid/v1 >/dev/null 2>/dev/null
    chmod 000 "$REPO_CACHE/semantic-last.json" 2>/dev/null
    bash "$SCRIPTS_DIR/providers-semantic.sh" --provider testprov --model test-model \
      --key-var TEST_PROBE_KEY --base-url https://prov.invalid/v1 ) 2>"$EV_BAD" )"
chmod 644 "$REPO_CACHE/semantic-last.json" 2>/dev/null

if [[ "$verdict_bad" == "unverified" || "$verdict_bad" == "skip" ]]; then
  _pass "verdict survived an unreadable cache (got '$verdict_bad')"
else
  _fail "evidence mirroring swallowed the verdict — FAIL-OPEN" \
    "stdout was '${verdict_bad}'; an empty verdict is read by claude-providers.sh as 'keep verified', turning a layer-3 FAIL into a PASS"
fi

# --- (c) the mirroring block must never be the thing that decides ------------
it "(c) the evidence block is guarded so it cannot abort the verdict path"
guarded=0
grep -qE '^\} >&2 \|\| true' "$SCRIPTS_DIR/providers-semantic.sh" && guarded=1
assert_eq 1 "$guarded" "the stderr-mirroring block ends with '|| true' so an I/O fault cannot abort before the verdict"

summary
