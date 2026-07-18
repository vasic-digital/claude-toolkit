#!/usr/bin/env bash
# test_128k_output_clamp.sh — permanent regression guard (§11.4.135) for the
# 128000 output-token clamp + native token-guard isolation.
#
# Background (§11.4.102/§11.4.108 remediation). Claude Code fatally aborts any
# length-truncated response with "…exceeded the 128000 output token maximum…
# set CLAUDE_CODE_MAX_OUTPUT_TOKENS". The literal 128000 originates in this
# toolkit: cma_run_provider used to re-export the model's THEORETICAL
# limit.output (deepseek 384000, xiaomi 131072) as CLAUDE_CODE_MAX_OUTPUT_TOKENS
# on the native transport ONLY; the CLI hard-caps unknown/custom models to
# 128000, requests 128000, and echoes it in the fatal.
#
# Two-part fix, both proven here:
#   (A) CLAMP the exported cap to min(CMA_PROVIDER_MAX_OUTPUT, 128000) — missing/
#       non-numeric -> 128000 (never empty) — and export it ONCE for BOTH
#       transports (router AND native), so behaviour is transport-independent.
#   (B) ISOLATION: cma_run (the native claudeN launcher) MUST unset
#       CLAUDE_CODE_MAX_OUTPUT_TOKENS + CLAUDE_CODE_AUTO_COMPACT_WINDOW, which
#       cma_run_provider exports for EVERY provider alias and which PERSIST into
#       a subsequent native launch (wrongly capping native output / early
#       compacting native context).
#
# §11.4.108 DELIVERY seam: both wrappers are TEMPLATES written into the user's
# installed aliases.sh; a change reaches the deployed artifact ONLY when each
# per-function migration guard's marker set forces a re-emit. This test proves,
# on the artifact cma_ensure_alias_file actually emits, that:
#   (a) configured > 128000  -> exported 128000  (clamp)             [arithmetic]
#   (b) configured < 128000  -> exported unchanged                   [arithmetic]
#   (c) missing/non-numeric  -> 128000, never empty                 [arithmetic]
#   (c') huge all-digit (>2^63-1) -> 128000, never leaked unclamped [arithmetic]
#   (c'') floor: 0/00 -> 128000; leading zeros decimal, not octal   [arithmetic]
#   (d) the clamp export is present for BOTH transports; the RAW unclamped
#       export is GONE                                              [static]
#   (e) cma_run's isolation unset clears BOTH token guards          [static+sink]
#   (f) the migration seam RE-DEPLOYS the clamp + isolation when a pre-fix
#       (marker-less) body lacks them — RED-polarity per §11.4.115.
#
# §1.1 load-bearing: reverting fix (A) (clamp block / provider guard marker)
# breaks (a)-(d)+(f); reverting fix (B) (cma_run unset / cma_run guard marker)
# breaks (e)+(f).
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
# lib.sh enables `set -e`; the harness asserts on non-zero exits, so relax it.
set +e

# Extract a single wrapper body from the emitted alias file, using the same
# literal-parens anchors the migration guards use (cma_run_provider( never
# collides with cma_run().
prov_body() { awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE"; }
run_body()  { awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE"; }

# Extract the DEPLOYED clamp block (literal-substring anchors — no regex
# escaping) into a probe function, then evaluate the ACTUAL emitted clamp code
# with a given CMA_PROVIDER_MAX_OUTPUT. This is a real §11.4.108 runtime
# signature on the artifact, not a re-implemented copy.
clamp_eval() {
  local input_present="$1" input_val="${2:-}" probe out
  probe="$(mktemp "${TMPDIR:-/tmp}/clamp-probe.XXXXXX.sh")"
  {
    echo 'clamp_probe() {'
    prov_body | awk 'index($0,"local _cma_out=\"${CMA_PROVIDER_MAX_OUTPUT"){f=1} f{print} f&&index($0,"export CLAUDE_CODE_MAX_OUTPUT_TOKENS=\"$_cma_out\""){exit}'
    echo '  printf "%s" "$CLAUDE_CODE_MAX_OUTPUT_TOKENS"'
    echo '}'
  } > "$probe"
  if [[ "$input_present" == "unset" ]]; then
    # Truly-unset CMA_PROVIDER_MAX_OUTPUT (env -u), the "missing" case.
    out="$(env -u CMA_PROVIDER_MAX_OUTPUT bash -c 'source "$1"; clamp_probe' _ "$probe")"
  else
    out="$(CMA_PROVIDER_MAX_OUTPUT="$input_val" bash -c 'source "$1"; clamp_probe' _ "$probe")"
  fi
  rm -f "$probe"
  printf '%s' "$out"
}

# --- fresh install -----------------------------------------------------------
it "cma_ensure_alias_file emits an alias file with both wrappers"
cma_ensure_alias_file
assert_file "$ALIAS_FILE" "alias file created"
# Control needle (§11.4.201): the extractor CAN see a known-present string in
# each body, so a later ZERO count is a real absence, not a blind probe.
assert_eq 1 "$(prov_body | grep -cF 'unset ANTHROPIC_BASE_URL')" "control needle: prov_body extractor is not blind"
assert_eq 1 "$(run_body  | grep -cF 'unset ANTHROPIC_BASE_URL')" "control needle: run_body extractor is not blind"

# --- (a)/(b)/(c) clamp arithmetic on the DEPLOYED clamp block ----------------
it "clamp: configured > 128000 -> 128000 (deepseek 384000, xiaomi 131072)"
assert_eq 128000 "$(clamp_eval val 384000)" "384000 clamps to 128000"
assert_eq 128000 "$(clamp_eval val 131072)" "131072 clamps to 128000"

it "clamp: configured <= 128000 -> unchanged"
assert_eq 8192   "$(clamp_eval val 8192)"   "8192 unchanged (github-models/upstage)"
assert_eq 127999 "$(clamp_eval val 127999)" "127999 unchanged (off-by-one below cap)"
assert_eq 128000 "$(clamp_eval val 128000)" "128000 unchanged (exactly the cap)"

it "clamp: missing/non-numeric -> 128000, never empty"
assert_eq 128000 "$(clamp_eval val '')"    "empty -> 128000"
assert_eq 128000 "$(clamp_eval unset)"     "unset  -> 128000"
assert_eq 128000 "$(clamp_eval val abc)"   "non-numeric -> 128000"
assert_eq 128000 "$(clamp_eval val 12x8)"  "partly-numeric -> 128000"

# --- (c') huge all-digit value -> 128000, never leaked unclamped -------------
# A user-settable CMA_HELIXAGENT_MAX_OUTPUT flows verbatim through 'jq --argjson'
# into CMA_PROVIDER_MAX_OUTPUT. A value past the shell integer max (2^63-1, 19
# digits) would make '[ N -gt 128000 ]' error and, via the failed '&&', leak the
# raw value UNCLAMPED — resurrecting the ">128000" fatal. The length-guard must
# collapse any 7+-digit value to the cap BEFORE the arithmetic runs.
it "clamp: huge all-digit value (>2^63-1) -> 128000, never exported unclamped (F2)"
assert_eq 128000 "$(clamp_eval val 99999999999999999999999)" "23-digit -> 128000 (no overflow leak)"
assert_eq 128000 "$(clamp_eval val 9223372036854775808)"     "2^63 (19-digit) -> 128000"
assert_eq 128000 "$(clamp_eval val 1000000)"                 "7-digit 1,000,000 -> 128000"
assert_eq 128000 "$(clamp_eval val 999999)"                  "6-digit 999,999 (> cap) -> 128000"

# --- (c'') floor at 1; leading zeros are decimal, not octal ------------------
# 0 must NEVER export CLAUDE_CODE_MAX_OUTPUT_TOKENS=0 (a zero cap). Leading-zero
# forms are decimal: a big one (0128001, 7 chars) is collapsed by the length
# guard (never re-read as octal); a small one (007) tests as decimal 7 and
# exports "007", which Claude Code parses as decimal 7 (min-semantics decision).
it "clamp: floor 0/00 -> 128000; leading zeros not octal (F3)"
assert_eq 128000 "$(clamp_eval val 0)"       "0 -> 128000 (floor, never a zero cap)"
assert_eq 128000 "$(clamp_eval val 00)"      "00 -> 128000 (floor)"
assert_eq 128000 "$(clamp_eval val 0128001)" "leading-zero 7-digit -> 128000 (not octal)"
assert_eq 007    "$(clamp_eval val 007)"     "leading-zero small stays decimal-7 (exports 007 -> parsed as 7)"

# --- (d) clamp export present for BOTH transports; RAW export GONE ------------
it "cma_run_provider exports the CLAMPED cap once (BOTH transports), never the raw value"
assert_eq 1 "$(prov_body | grep -cF 'export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"')" "clamped export present"
assert_eq 1 "$(prov_body | grep -cF -- '-gt 128000')" "clamp comparison present"
assert_eq 0 "$(prov_body | grep -cF 'export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$CMA_PROVIDER_MAX_OUTPUT"')" "raw unclamped export removed"

# --- (e) cma_run isolation unset present -------------------------------------
it "cma_run (native) unset list clears BOTH token guards"
assert_eq 1 "$(run_body | grep -cF 'unset CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW')" "native token-guard unset line"

# --- (f) migration guard RE-DEPLOYS clamp + isolation (RED-polarity §11.4.115) -
# Simulate an OLDER installed body predating the clamp/isolation: strip every
# line carrying the CLAUDE_CODE_MAX_OUTPUT_TOKENS marker from BOTH bodies
# (removes each guard's re-emit marker).
it "RED: a pre-fix body (marker stripped) lacks the clamp export AND the isolation unset"
_tmp="$(mktemp "${TMPDIR:-/tmp}/cma-red.XXXXXX")"
grep -v 'CLAUDE_CODE_MAX_OUTPUT_TOKENS' "$ALIAS_FILE" > "$_tmp" && mv "$_tmp" "$ALIAS_FILE"
assert_eq 0 "$(prov_body | grep -cF 'export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"')" "defect reproduced: clamp export absent"
assert_eq 0 "$(run_body  | grep -cF 'unset CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW')" "defect reproduced: isolation unset absent"

it "GREEN: the migration seam re-emits the clamp + isolation on the next ensure"
cma_ensure_alias_file
assert_eq 1 "$(prov_body | grep -cF 'export CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"')" "clamp export restored"
assert_eq 1 "$(run_body  | grep -cF 'unset CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW')" "isolation unset restored"
assert_eq 128000 "$(clamp_eval val 384000)" "clamp arithmetic still 384000->128000 after re-emit"
assert_eq 8192   "$(clamp_eval val 8192)"   "clamp arithmetic still 8192->unchanged after re-emit"

# --- (e-sink) native cma_run clears the leaked token guards from the child ----
# Strongest §11.4.69 signature: what the launched `claude` child actually
# inherits. A stub records the two guard vars; cma_run must have cleared both
# (they were exported as a "leak" before the call, exactly as a prior
# cma_run_provider would leave them).
it "native cma_run clears leaked token guards from the launched child (sink-side)"
_stub="$SANDBOX_HOME/claude_stub"
_child="$SANDBOX_HOME/child_token_env.txt"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for v in CLAUDE_CODE_MAX_OUTPUT_TOKENS CLAUDE_CODE_AUTO_COMPACT_WINDOW; do\n'
  printf '  if [ -n "${!v+x}" ]; then echo "$v=SET"; else echo "$v=UNSET"; fi\n'
  printf 'done > "$TOK_OUT"\nexit 0\n'
} > "$_stub"
chmod +x "$_stub"
: > "$_child"
(
  # shellcheck disable=SC1090
  source "$ALIAS_FILE"
  export CLAUDE_BIN="$_stub" TOK_OUT="$_child"
  # Leak both guards as a prior cma_run_provider launch would leave them.
  export CLAUDE_CODE_MAX_OUTPUT_TOKENS=64000 CLAUDE_CODE_AUTO_COMPACT_WINDOW=200000
  cma_run --iso-probe >/dev/null 2>&1
)
assert_lines "$_child" 2 "stub recorded both token guards"
assert_eq 0 "$(grep -c '=SET$'   "$_child")" "no token guard leaked into the native claude child"
assert_eq 2 "$(grep -c '=UNSET$' "$_child")" "both token guards UNSET for the native claude child"

summary
