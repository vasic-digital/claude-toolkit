#!/usr/bin/env bash
# test_provider_tier_default_model.sh — permanent regression guard (§11.4.135)
# for the provider TIER default-model map + cross-alias isolation.
#
# Background (§11.4.134 remediation): a tier-pinned subagent dispatch through a
# non-Anthropic provider must NOT leak a literal claude-* id to that provider's
# native endpoint (xiaomi rejects it — HTTP 400 "Unsupported model"; deepseek
# silently substitutes). cma_run_provider (native branch) therefore exports the
# 4 tier vars — ANTHROPIC_DEFAULT_{OPUS,SONNET,HAIKU,FABLE}_MODEL — mapping each
# Claude Code subagent tier to the provider's real serving model. Because those
# exports PERSIST in the user's interactive shell after the alias returns, BOTH
# wrapper bodies (cma_run + cma_run_provider) must also clear them in their
# unset lists, so a following native OR provider launch never inherits a stale
# tier override.
#
# This guard fixes the §11.4.108 DELIVERY seam: the wrappers are TEMPLATES
# written into the user's installed aliases.sh; a change reaches the deployed
# artifact ONLY when the per-function migration guard's marker set forces a
# re-emit. So this test proves, on the artifact cma_ensure_alias_file actually
# emits, that (a) a fresh install carries all 4 exports; (b) the migration guard
# RE-DEPLOYS them when an older (marker-less) body lacks them — RED-polarity
# per §11.4.115: the defect is reproduced on a pre-fix body, then the migration
# seam flips it GREEN; (c) both unset lists carry the 4 vars; (d) the native
# cma_run unset path really clears a leaked tier var from the launched child
# (sink-side isolation). Reverting fix 1 (guard markers) breaks (b); reverting
# fix 2 (exports/unset) breaks (a)/(c)/(d) — the §1.1 load-bearing property.
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

TIER_VARS="ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL"

# Extract a single wrapper function's body from the emitted alias file, using the
# same literal-parens anchors the migration guards use (so `cma_run_provider(`
# never collides with `cma_run(`).
prov_body() { awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE"; }
run_body()  { awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE"; }
count_prov_exports() { prov_body | grep -cE '^[[:space:]]*export ANTHROPIC_DEFAULT_(OPUS|SONNET|HAIKU|FABLE)_MODEL='; }

# --- (a) fresh install emits all 4 tier exports -----------------------------
it "cma_run_provider body emits all 4 tier default-model exports on fresh install"
cma_ensure_alias_file
assert_file "$ALIAS_FILE" "alias file created"
assert_eq 4 "$(count_prov_exports)" "4 tier exports in cma_run_provider body"

# --- mapping is correct: opus/sonnet/fable -> strong model, haiku -> fast ----
it "tier exports map opus/sonnet/fable to the strong model and haiku to the fast fallback"
assert_file_contains "$ALIAS_FILE" 'export ANTHROPIC_DEFAULT_OPUS_MODEL="$CMA_PROVIDER_MODEL"' "opus->strong"
assert_file_contains "$ALIAS_FILE" 'export ANTHROPIC_DEFAULT_SONNET_MODEL="$CMA_PROVIDER_MODEL"' "sonnet->strong"
assert_file_contains "$ALIAS_FILE" 'export ANTHROPIC_DEFAULT_FABLE_MODEL="$CMA_PROVIDER_MODEL"' "fable->strong"
assert_file_contains "$ALIAS_FILE" 'export ANTHROPIC_DEFAULT_HAIKU_MODEL="${CMA_PROVIDER_FAST_MODEL:-$CMA_PROVIDER_MODEL}"' "haiku->fast-fallback"

# --- (c) both unset lists carry all 4 tier vars (deployed artifact) ----------
it "cma_run_provider unset list clears all 4 tier vars"
assert_eq 1 "$(prov_body | grep -cE '^[[:space:]]*unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL$')" "provider unset line"

it "cma_run (native) unset list clears all 4 tier vars"
assert_eq 1 "$(run_body | grep -cE '^[[:space:]]*unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL$')" "native unset line"

it "cma_run (native) body does NOT export the tier vars (it must only clear them)"
assert_eq 0 "$(run_body | grep -cE 'export ANTHROPIC_DEFAULT')" "no tier exports in native body"

# --- (b) migration guard RE-DEPLOYS the exports (RED-polarity, §11.4.115) ----
# Simulate an OLDER installed body that predates the tier map: strip every
# ANTHROPIC_DEFAULT line from BOTH wrapper bodies (removes the guard marker).
it "RED: a pre-fix body (marker stripped) has ZERO tier exports"
_tmp="$(mktemp "${TMPDIR:-/tmp}/cma-red.XXXXXX")"
grep -v 'ANTHROPIC_DEFAULT' "$ALIAS_FILE" > "$_tmp" && mv "$_tmp" "$ALIAS_FILE"
assert_eq 0 "$(count_prov_exports)" "defect reproduced: 0 tier exports on pre-fix artifact"
assert_file_not_contains "$ALIAS_FILE" "ANTHROPIC_DEFAULT_OPUS_MODEL" "marker absent (pre-fix)"

it "GREEN: the migration guard re-emits all 4 tier exports on the next ensure"
cma_ensure_alias_file
assert_eq 4 "$(count_prov_exports)" "migration seam restored 4 tier exports"
assert_eq 1 "$(prov_body | grep -cE '^[[:space:]]*unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL$')" "provider unset line restored"
assert_eq 1 "$(run_body  | grep -cE '^[[:space:]]*unset ANTHROPIC_DEFAULT_OPUS_MODEL ANTHROPIC_DEFAULT_SONNET_MODEL ANTHROPIC_DEFAULT_HAIKU_MODEL ANTHROPIC_DEFAULT_FABLE_MODEL$')" "native unset line restored"

# --- (d) sink-side isolation: native cma_run clears a leaked tier var --------
# The strongest signature: what the launched `claude` child actually inherits.
# A stub stands in for the binary and records the 4 vars it received. cma_run
# must have cleared all 4 (they were exported as a "leak" before the call).
it "native cma_run clears all 4 leaked tier vars from the launched child (sink-side)"
_stub="$SANDBOX_HOME/claude_stub"
_child="$SANDBOX_HOME/child_tier_env.txt"
{
  printf '#!/usr/bin/env bash\n'
  printf 'for v in %s; do\n' "$TIER_VARS"
  printf '  if [ -n "${!v+x}" ]; then echo "$v=SET"; else echo "$v=UNSET"; fi\n'
  printf 'done > "$TIER_OUT"\nexit 0\n'
} > "$_stub"
chmod +x "$_stub"
: > "$_child"
# PROVENANCE GATE — see lib/assert.sh:assert_fn_from. The source lives inside
# the subshell below, so the --source form is used: it re-sources in its own
# subshell but asserts HERE, so a failure reaches summary instead of dying with
# the subshell. Guards against the whole sink-side check grading the HOST's
# cma_run, which BASH_ENV has already defined in this shell.
assert_fn_from --source "$ALIAS_FILE" cma_run "cma_run under test comes from the sandbox alias file"
(
  # Load the DEPLOYED wrapper bodies (redefines cma_run with the emitted body).
  # shellcheck disable=SC1090
  source "$ALIAS_FILE"
  # Override CLAUDE_BIN AFTER sourcing (the header re-exports it) + point the
  # stub at its output sink.
  export CLAUDE_BIN="$_stub" TIER_OUT="$_child"
  # Leak all 4 tier vars as a prior cma_run_provider (native branch) would.
  for _v in $TIER_VARS; do export "$_v=LEAKED-provider-model"; done
  # Explicit arg avoids the bare-launch auto-session path; in the sandbox HOME
  # the sync-state/session/cwd-hook helpers are absent, so cma_run just clears
  # env and execs the stub.
  cma_run --iso-probe >/dev/null 2>&1
)
assert_lines "$_child" 4 "stub recorded all 4 tier vars"
assert_eq 0 "$(grep -c '=SET$' "$_child")" "no tier var leaked into the native claude child"
assert_eq 4 "$(grep -c '=UNSET$' "$_child")" "all 4 tier vars UNSET for the native claude child"

summary
