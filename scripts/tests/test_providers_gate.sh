#!/usr/bin/env bash
# test_providers_gate.sh — the live-providers leg only fails the suite for
# providers that are SUPPOSED to work.
#
# Context. The leg runs layers 3-4 against every installed provider env file,
# including providers whose keys are rejected or whose accounts are unfunded.
# Those can never pass a live launch, so counting them as suite failures pinned
# the run permanently red — and a permanently-red gate hides a NEW regression
# just as effectively as a permanently-green one did. (The green one was real:
# this leg previously called _pass on a layer-4 FAIL and reported "40 passed,
# 0 failed" while every router alias was dead.)
#
# The scoping is therefore load-bearing in ONE direction only: it must never
# stop a `verified` provider's failure from failing the suite. That is what this
# test pins. Without it the gate could silently degrade into "never fail",
# recreating the original bluff from the other side.
set -u
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
set +e

LEG="$TESTS_DIR/verify_providers_live.sh"

it "the leg defines a status gate that can be reasoned about"
if [[ -f "$LEG" ]]; then
  _pass "verify_providers_live.sh present"
else
  _fail "verify_providers_live.sh missing" "$LEG"
  summary
fi

# Extract just the gate function and exercise it directly. Sourcing the whole
# leg would execute a live provider sweep.
gate_src="$(sed -n '/^gate_for_status()/,/^}/p' "$LEG")"

it "gate_for_status is extractable (guards against a silent refactor)"
if [[ -n "$gate_src" ]]; then
  _pass "found gate_for_status in the leg"
else
  _fail "gate_for_status not found" "the leg no longer exposes a testable gate — this test cannot protect it"
  summary
fi

eval "$gate_src"

# --- the invariant that must never regress ----------------------------------
it "a VERIFIED provider's failure still fails the suite"
got="$(gate_for_status verified)"
assert_eq "1" "$got" "status=verified must be gated (a real failure), got '$got'"

it "providers that are already known-broken account-side are not counted as suite failures"
for st in failed unverified orphaned; do
  got="$(gate_for_status "$st")"
  assert_eq "0" "$got" "status=$st must NOT fail the suite (account-side, cannot pass a live launch)"
done

it "an unknown or empty status is treated conservatively (not gated)"
for st in "" "some-future-status"; do
  got="$(gate_for_status "$st")"
  assert_eq "0" "$got" "status='$st' must not be gated — only an explicit 'verified' is"
done

# --- anti-vacuous-pass guard -------------------------------------------------
# A gate that returned 0 for EVERYTHING would satisfy every negative case above
# and quietly disable the leg. Prove the function actually discriminates.
it "the gate genuinely discriminates (anti-vacuous-pass guard)"
if [[ "$(gate_for_status verified)" != "$(gate_for_status failed)" ]]; then
  _pass "gate distinguishes verified from failed (not a constant function)"
else
  _fail "gate is a constant function" \
    "gate_for_status returns the same value for 'verified' and 'failed' — the leg can no longer fail for any provider"
fi

# --- the reporting requirement ----------------------------------------------
# Non-gated providers must still be VISIBLE. Silently skipping them would hide
# genuinely dead providers from the operator, which is its own kind of bluff.
it "non-gated providers are reported explicitly, not silently skipped"
if grep -q 'KNOWN-NON-WORKING' "$LEG"; then
  _pass "the leg reports account-side non-working providers on their own line"
else
  _fail "non-gated providers are invisible" \
    "no KNOWN-NON-WORKING reporting found — an ungated provider would vanish from the output entirely"
fi

it "the gated path still calls _fail (the failure route is not orphaned)"
# Both layer-3 and layer-4 must retain a reachable _fail under the gate.
gated_fails="$(grep -c 'if (( gated )); then' "$LEG")"
if (( gated_fails >= 2 )); then
  _pass "both layer-3 and layer-4 retain a gated _fail path ($gated_fails found)"
else
  _fail "a gated failure path is missing" "expected >=2 gated branches, found $gated_fails"
fi

summary
