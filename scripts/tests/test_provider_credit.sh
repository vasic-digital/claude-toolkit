#!/usr/bin/env bash
# test_provider_credit.sh — credit-aware model selection (the operator's
# MANDATORY rule): with purchased credit pick the STRONGEST PAID model, with no
# credit pick the STRONGEST FREE model the account can use.
#
# Everything here is hermetic and offline: providers_resolve.py is a pure
# function of (catalog, keys, key-aliases, overrides, credit cache), so the
# whole policy matrix can be proven without a single network call or API key.
#
# Anti-vacuous-pass discipline: a selector that ignored credit entirely and
# always returned the same model would satisfy any single assertion below. The
# guards in Section 9 therefore assert that the SAME catalog yields DIFFERENT
# models under different credit states, and that the limits move with them.
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
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.

RESOLVE="$SCRIPTS_DIR/providers_resolve.py"
VERIFY="$SCRIPTS_DIR/model_verify.py"
FIX="$HOME/creditfix"
mkdir -p "$FIX"

# ---------------------------------------------------------------------------
# Fixture catalog. Deliberately shaped so every tier decision picks a DIFFERENT
# model id and a DIFFERENT context/output pair — that is what makes the
# assertions falsifiable rather than decorative.
#
#   mixedcorp : free AND paid models  -> the real decision
#   freecorp  : only free models      -> paid preference must fall through
#   paidcorp  : only paid models      -> free preference must fall through
#   opaquecorp: no pricing at all     -> tier "unknown", never guessed free
#   emptycorp : no models at all      -> unmapped, no alias
# ---------------------------------------------------------------------------
cat > "$FIX/catalog.json" <<'JSON'
{
  "mixedcorp": {
    "env": ["MIXEDCORP_API_KEY"],
    "api": "https://api.mixedcorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "mc-paid-flagship": {"id":"mc-paid-flagship","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":1000000,"output":131072},"cost":{"input":3,"output":15}},
      "mc-paid-mini":     {"id":"mc-paid-mini","reasoning":false,"tool_call":true,"release_date":"2025-01-01","limit":{"context":128000,"output":16384},"cost":{"input":0.5,"output":1}},
      "mc-free-flagship": {"id":"mc-free-flagship","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":400000,"output":64000},"cost":{"input":0,"output":0}},
      "mc-free-mini":     {"id":"mc-free-mini","reasoning":false,"tool_call":true,"release_date":"2024-01-01","limit":{"context":32000,"output":8192},"cost":{"input":0,"output":0}}
    }
  },
  "freecorp": {
    "env": ["FREECORP_API_KEY"],
    "api": "https://api.freecorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "fc-big":   {"id":"fc-big","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":500000,"output":50000},"cost":{"input":0,"output":0}},
      "fc-small": {"id":"fc-small","reasoning":false,"tool_call":true,"release_date":"2024-01-01","limit":{"context":64000,"output":8000},"cost":{"input":0,"output":0}}
    }
  },
  "paidcorp": {
    "env": ["PAIDCORP_API_KEY"],
    "api": "https://api.paidcorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "pc-big":   {"id":"pc-big","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":300000,"output":30000},"cost":{"input":9,"output":30}},
      "pc-small": {"id":"pc-small","reasoning":false,"tool_call":true,"release_date":"2024-01-01","limit":{"context":16000,"output":4000},"cost":{"input":1,"output":2}}
    }
  },
  "opaquecorp": {
    "env": ["OPAQUECORP_API_KEY"],
    "api": "https://api.opaquecorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "oc-a": {"id":"oc-a","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":222000,"output":22000}},
      "oc-b": {"id":"oc-b","reasoning":false,"tool_call":true,"release_date":"2024-01-01","limit":{"context":11000,"output":1100}}
    }
  },
  "emptycorp": {
    "env": ["EMPTYCORP_API_KEY"],
    "api": "https://api.emptycorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {}
  },
  "markedcorp": {
    "env": ["MARKEDCORP_API_KEY"],
    "api": "https://api.markedcorp.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "vendor/model-x:free": {"id":"vendor/model-x:free","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":150000,"output":15000}},
      "vendor/model-x":      {"id":"vendor/model-x","reasoning":true,"tool_call":true,"release_date":"2026-06-02","limit":{"context":150000,"output":15000},"cost":{"input":2,"output":6}}
    }
  }
}
JSON

ALL_KEYS="MIXEDCORP_API_KEY,FREECORP_API_KEY,PAIDCORP_API_KEY,OPAQUECORP_API_KEY,EMPTYCORP_API_KEY,MARKEDCORP_API_KEY"

# Read a field for a given key_var out of the resolver JSON output.
rfield() { # rfield JSON KEYVAR FIELD
  python3 -c 'import json,sys
recs=json.load(open(sys.argv[1]))
m={r["key_var"]:r for r in recs}
print(m[sys.argv[2]][sys.argv[3]])' "$1" "$2" "$3"
}

# Write a credit cache with a chosen version and age, so the version gate and
# the TTL gate can each be exercised independently.
mkcredits() { # mkcredits OUTFILE VERSION AGE_SECONDS 'pid=state,pid=state'
  python3 - "$@" <<'PY'
import json, sys, time
out, version, age, spec = sys.argv[1], sys.argv[2], float(sys.argv[3]), sys.argv[4]
providers = {}
for pair in spec.split(","):
    if not pair.strip():
        continue
    pid, state = pair.split("=")
    providers[pid] = {"credit": state, "signal": "balance_endpoint",
                      "detail": "fixture"}
data = {"_cached_at": time.time() - age, "providers": providers}
if version != "none":
    data["_cache_version"] = int(version)
json.dump(data, open(out, "w"), indent=2)
PY
}

run_resolve() { # run_resolve OUTFILE [extra args...]
  local out="$1"; shift
  python3 "$RESOLVE" --models-dev "$FIX/catalog.json" --keys "$ALL_KEYS" "$@" > "$out"
}

# ---------------------------------------------------------------------------
# Section 1 — NO credit recorded at all => conservative free-only.
# This is the default state of a fresh install: nothing has probed a balance,
# so nothing may be spent.
# ---------------------------------------------------------------------------
U_OUT="$HOME/r-unknown.json"
run_resolve "$U_OUT"
rc=$?

it "resolver runs with no credit cache and emits valid JSON"
assert_eq 0 "$rc" "resolver exit 0"
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$U_OUT" 2>/dev/null
assert_eq 0 $? "output is valid JSON"

it "unknown credit is reported honestly, not guessed"
assert_eq "unknown" "$(rfield "$U_OUT" MIXEDCORP_API_KEY credit_status)" "credit_status unknown"
assert_eq "none"    "$(rfield "$U_OUT" MIXEDCORP_API_KEY credit_signal)" "signal none"
rfield "$U_OUT" MIXEDCORP_API_KEY credit_detail | grep -qi 'no usable credit probe'
assert_eq 0 $? "credit_detail says why it is unknown"

it "unknown credit picks the strongest FREE model (never spends on a guess)"
assert_eq "mc-free-flagship" "$(rfield "$U_OUT" MIXEDCORP_API_KEY strong_model)" "strong=free flagship"
assert_eq "free" "$(rfield "$U_OUT" MIXEDCORP_API_KEY model_tier)" "tier=free"

it "the fast model stays in the SAME tier (a free alias cannot bill via fast)"
assert_eq "mc-free-mini" "$(rfield "$U_OUT" MIXEDCORP_API_KEY fast_model)" "fast=free mini"

it "limits are re-derived from the FREE model that was actually selected"
assert_eq "400000" "$(rfield "$U_OUT" MIXEDCORP_API_KEY context_limit)" "context=free flagship's"
assert_eq "64000"  "$(rfield "$U_OUT" MIXEDCORP_API_KEY max_output)"    "max_output=free flagship's"

it "the paid model's limits do NOT leak into a free selection"
cond=1; [[ "$(rfield "$U_OUT" MIXEDCORP_API_KEY context_limit)" != "1000000" ]] && cond=0
assert_eq 0 "$cond" "context is not mc-paid-flagship's 1000000"
cond=1; [[ "$(rfield "$U_OUT" MIXEDCORP_API_KEY max_output)" != "131072" ]] && cond=0
assert_eq 0 "$cond" "max_output is not mc-paid-flagship's 131072"

it "selection_reason records the decision so it is auditable, not magic"
reason="$(rfield "$U_OUT" MIXEDCORP_API_KEY selection_reason)"
grep -q 'credit=unknown' <<<"$reason";      assert_eq 0 $? "reason names the credit status"
grep -q 'signal=none' <<<"$reason";         assert_eq 0 $? "reason names the signal used"
grep -q 'policy=auto' <<<"$reason";          assert_eq 0 $? "reason names the policy"
grep -q 'selected tier=free' <<<"$reason";  assert_eq 0 $? "reason names the chosen tier"
grep -q 'free=2 paid=2' <<<"$reason";       assert_eq 0 $? "reason shows the candidate counts"

# ---------------------------------------------------------------------------
# Section 2 — credit AVAILABLE => strongest PAID model.
# ---------------------------------------------------------------------------
mkcredits "$FIX/credits-available.json" 1 0 "mixedcorp=available,freecorp=available,paidcorp=available,opaquecorp=available,markedcorp=available"
A_OUT="$HOME/r-available.json"
run_resolve "$A_OUT" --credits "$FIX/credits-available.json"

it "a fresh, correctly-versioned cache is consumed (cache HIT)"
assert_eq "available" "$(rfield "$A_OUT" MIXEDCORP_API_KEY credit_status)" "credit available"
assert_eq "balance_endpoint" "$(rfield "$A_OUT" MIXEDCORP_API_KEY credit_signal)" "signal from cache"

it "credit available picks the strongest PAID model"
assert_eq "mc-paid-flagship" "$(rfield "$A_OUT" MIXEDCORP_API_KEY strong_model)" "strong=paid flagship"
assert_eq "paid" "$(rfield "$A_OUT" MIXEDCORP_API_KEY model_tier)" "tier=paid"

it "the fast model is the cheapest PAID one, not a free one"
assert_eq "mc-paid-mini" "$(rfield "$A_OUT" MIXEDCORP_API_KEY fast_model)" "fast=paid mini"

it "limits are re-derived from the PAID model that was actually selected"
assert_eq "1000000" "$(rfield "$A_OUT" MIXEDCORP_API_KEY context_limit)" "context=paid flagship's"
# The flagship's catalog limit.output is 131072; v1.24.0 bounds every derived
# cap by Claude Code's own 128000 custom-model ceiling (see derive_limits).
# The point of this assertion is that the limits track the SELECTED model —
# a 1000000 context proves that — not that the raw number survives unbounded.
assert_eq "128000"  "$(rfield "$A_OUT" MIXEDCORP_API_KEY max_output)"    "max_output=paid flagship's, bounded by the CLI ceiling"

it "selection_reason explains the paid choice"
grep -q 'credit available -> strongest paid' <<<"$(rfield "$A_OUT" MIXEDCORP_API_KEY selection_reason)"
assert_eq 0 $? "reason states the rule that fired"

# ---------------------------------------------------------------------------
# Section 3 — credit EXHAUSTED => strongest FREE model.
# ---------------------------------------------------------------------------
mkcredits "$FIX/credits-exhausted.json" 1 0 "mixedcorp=exhausted,freecorp=exhausted,paidcorp=exhausted,opaquecorp=exhausted,markedcorp=exhausted"
E_OUT="$HOME/r-exhausted.json"
run_resolve "$E_OUT" --credits "$FIX/credits-exhausted.json"

it "exhausted credit picks the strongest FREE model"
assert_eq "exhausted" "$(rfield "$E_OUT" MIXEDCORP_API_KEY credit_status)" "credit exhausted"
assert_eq "mc-free-flagship" "$(rfield "$E_OUT" MIXEDCORP_API_KEY strong_model)" "strong=free flagship"
assert_eq "free" "$(rfield "$E_OUT" MIXEDCORP_API_KEY model_tier)" "tier=free"

it "exhausted credit never selects a paid model when a free one exists"
cond=1; [[ "$(rfield "$E_OUT" MIXEDCORP_API_KEY strong_model)" != "mc-paid-flagship" ]] && cond=0
assert_eq 0 "$cond" "paid flagship not selected"
cond=1; [[ "$(rfield "$E_OUT" MIXEDCORP_API_KEY fast_model)" != "mc-paid-mini" ]] && cond=0
assert_eq 0 "$cond" "paid mini not selected"

it "limits follow the free selection under exhausted credit"
assert_eq "400000" "$(rfield "$E_OUT" MIXEDCORP_API_KEY context_limit)" "context=free flagship's"
assert_eq "64000"  "$(rfield "$E_OUT" MIXEDCORP_API_KEY max_output)"    "max_output=free flagship's"

it "selection_reason explains the free choice"
grep -q 'no credit -> strongest free' <<<"$(rfield "$E_OUT" MIXEDCORP_API_KEY selection_reason)"
assert_eq 0 $? "reason states the no-credit rule"

# ---------------------------------------------------------------------------
# Section 4 — providers with only ONE tier available.
# The tier preference is an ordering, not a hard filter: it must fall through
# and SAY that it fell through.
# ---------------------------------------------------------------------------
it "a provider with ONLY free models still resolves when credit IS available"
assert_eq "resolved" "$(rfield "$A_OUT" FREECORP_API_KEY status)" "freecorp resolved"
assert_eq "fc-big"   "$(rfield "$A_OUT" FREECORP_API_KEY strong_model)" "strong=fc-big"
assert_eq "free"     "$(rfield "$A_OUT" FREECORP_API_KEY model_tier)" "tier=free (no paid to prefer)"
assert_eq "500000"   "$(rfield "$A_OUT" FREECORP_API_KEY context_limit)" "limits from fc-big"
grep -q 'no paid/unknown model in catalog; fell through' <<<"$(rfield "$A_OUT" FREECORP_API_KEY selection_reason)"
assert_eq 0 $? "reason admits it fell through to free"

it "a provider with ONLY free models is unaffected by having no credit"
assert_eq "fc-big" "$(rfield "$E_OUT" FREECORP_API_KEY strong_model)" "same pick with no credit"
assert_eq "free"   "$(rfield "$E_OUT" FREECORP_API_KEY model_tier)" "tier=free"

it "a provider with ONLY paid models resolves to paid even with NO credit"
# There is no free alternative to fall back to. Refusing to emit an alias would
# be worse than emitting one the live verification gate can reject on 402.
assert_eq "resolved" "$(rfield "$E_OUT" PAIDCORP_API_KEY status)" "paidcorp resolved"
assert_eq "pc-big"   "$(rfield "$E_OUT" PAIDCORP_API_KEY strong_model)" "strong=pc-big"
assert_eq "paid"     "$(rfield "$E_OUT" PAIDCORP_API_KEY model_tier)" "tier=paid, stated plainly"
assert_eq "300000"   "$(rfield "$E_OUT" PAIDCORP_API_KEY context_limit)" "limits from pc-big"
grep -q 'no free/unknown model in catalog; fell through' <<<"$(rfield "$E_OUT" PAIDCORP_API_KEY selection_reason)"
assert_eq 0 $? "reason admits the forced paid fallback"

it "a provider with NO models at all is unmapped, never a broken alias"
assert_eq "unmapped" "$(rfield "$E_OUT" EMPTYCORP_API_KEY status)" "emptycorp unmapped"
assert_eq "None"     "$(rfield "$E_OUT" EMPTYCORP_API_KEY strong_model)" "no strong model"
assert_eq "None"     "$(rfield "$E_OUT" EMPTYCORP_API_KEY context_limit)" "no context limit"
assert_eq "None"     "$(rfield "$E_OUT" EMPTYCORP_API_KEY max_output)" "no max_output"

# ---------------------------------------------------------------------------
# Section 5 — pricing we do NOT know is "unknown", never assumed free.
# 399 of the 5696 catalogued models carry no usable cost; calling them free
# would be a guess that spends money.
# ---------------------------------------------------------------------------
it "models with no pricing data are tier 'unknown', not silently 'free'"
assert_eq "unknown" "$(rfield "$E_OUT" OPAQUECORP_API_KEY model_tier)" "tier=unknown"
assert_eq "oc-a"    "$(rfield "$E_OUT" OPAQUECORP_API_KEY strong_model)" "strongest unknown-cost model"
assert_eq "222000"  "$(rfield "$E_OUT" OPAQUECORP_API_KEY context_limit)" "limits still re-derived"
grep -q 'free=0 paid=0 unknown=2' <<<"$(rfield "$E_OUT" OPAQUECORP_API_KEY selection_reason)"
assert_eq 0 $? "reason shows zero free and zero paid candidates"

it "an unknown-cost provider resolves the same way regardless of credit"
assert_eq "oc-a" "$(rfield "$A_OUT" OPAQUECORP_API_KEY strong_model)" "same pick with credit"
assert_eq "unknown" "$(rfield "$A_OUT" OPAQUECORP_API_KEY model_tier)" "still unknown tier"

it "a ':free' id is honoured as a free marker when pricing is absent"
# markedcorp's ':free' variant has no cost block at all; the priced sibling is
# newer and would win on capability. With no credit the marker must decide.
assert_eq "vendor/model-x:free" "$(rfield "$E_OUT" MARKEDCORP_API_KEY strong_model)" "marker wins with no credit"
assert_eq "free" "$(rfield "$E_OUT" MARKEDCORP_API_KEY model_tier)" "tier=free from marker"

it "with credit, the priced sibling wins over the ':free' marker"
assert_eq "vendor/model-x" "$(rfield "$A_OUT" MARKEDCORP_API_KEY strong_model)" "paid sibling with credit"
assert_eq "paid" "$(rfield "$A_OUT" MARKEDCORP_API_KEY model_tier)" "tier=paid"

# ---------------------------------------------------------------------------
# Section 6 — human overrides always win.
# ---------------------------------------------------------------------------
cat > "$FIX/overrides-pin.json" <<'JSON'
{ "mixedcorp": { "strong_model": "mc-paid-flagship", "fast_model": "mc-paid-mini" } }
JSON
P_OUT="$HOME/r-pinned.json"
run_resolve "$P_OUT" --credits "$FIX/credits-exhausted.json" --overrides "$FIX/overrides-pin.json"

it "an explicit strong_model pin beats the credit rule (human decision wins)"
assert_eq "mc-paid-flagship" "$(rfield "$P_OUT" MIXEDCORP_API_KEY strong_model)" "pin applied despite no credit"
assert_eq "mc-paid-mini"     "$(rfield "$P_OUT" MIXEDCORP_API_KEY fast_model)" "fast pin applied"

it "a pin still re-derives limits from the PINNED model"
assert_eq "1000000" "$(rfield "$P_OUT" MIXEDCORP_API_KEY context_limit)" "context from pinned model"
assert_eq "128000"  "$(rfield "$P_OUT" MIXEDCORP_API_KEY max_output)"    "max_output from pinned model, bounded by the CLI ceiling"

it "a pin is recorded as a pin, with the tier it lands in and the credit state"
reason="$(rfield "$P_OUT" MIXEDCORP_API_KEY selection_reason)"
grep -q 'OVERRIDE PIN' <<<"$reason";        assert_eq 0 $? "reason flags the override"
grep -q 'credit=exhausted' <<<"$reason";    assert_eq 0 $? "reason still shows the credit state"
assert_eq "paid" "$(rfield "$P_OUT" MIXEDCORP_API_KEY model_tier)" "tier of the pinned model is reported"

it "credit can be pinned per provider in overrides.json"
cat > "$FIX/overrides-credit.json" <<'JSON'
{ "mixedcorp": { "credit": "available" } }
JSON
C_OUT="$HOME/r-creditpin.json"
run_resolve "$C_OUT" --overrides "$FIX/overrides-credit.json"
assert_eq "available" "$(rfield "$C_OUT" MIXEDCORP_API_KEY credit_status)" "pinned credit status"
assert_eq "override"  "$(rfield "$C_OUT" MIXEDCORP_API_KEY credit_signal)" "signal=override"
assert_eq "mc-paid-flagship" "$(rfield "$C_OUT" MIXEDCORP_API_KEY strong_model)" "paid model selected"

it "an overrides.json credit pin BEATS a contradicting probe cache"
CP_OUT="$HOME/r-creditpin-vs-cache.json"
run_resolve "$CP_OUT" --credits "$FIX/credits-exhausted.json" --overrides "$FIX/overrides-credit.json"
assert_eq "available" "$(rfield "$CP_OUT" MIXEDCORP_API_KEY credit_status)" "pin wins over cache"
assert_eq "override"  "$(rfield "$CP_OUT" MIXEDCORP_API_KEY credit_signal)" "signal=override"
assert_eq "mc-paid-flagship" "$(rfield "$CP_OUT" MIXEDCORP_API_KEY strong_model)" "paid selected"
# ...and a provider NOT covered by the pin still follows the cache.
assert_eq "exhausted" "$(rfield "$CP_OUT" PAIDCORP_API_KEY credit_status)" "unpinned provider still uses cache"

# ---------------------------------------------------------------------------
# Section 7 — the operator can force free-only or paid-allowed per provider.
# ---------------------------------------------------------------------------
cat > "$FIX/overrides-policy.json" <<'JSON'
{
  "mixedcorp": { "model_policy": "free" },
  "paidcorp":  { "model_policy": "paid" },
  "freecorp":  { "model_policy": "bogus-value" }
}
JSON
POL_OUT="$HOME/r-policy.json"
run_resolve "$POL_OUT" --credits "$FIX/credits-available.json" --overrides "$FIX/overrides-policy.json"

it "model_policy=free forces the free model even when credit IS available"
assert_eq "free" "$(rfield "$POL_OUT" MIXEDCORP_API_KEY model_policy)" "policy=free recorded"
assert_eq "available" "$(rfield "$POL_OUT" MIXEDCORP_API_KEY credit_status)" "credit really is available"
assert_eq "mc-free-flagship" "$(rfield "$POL_OUT" MIXEDCORP_API_KEY strong_model)" "free model forced"
assert_eq "400000" "$(rfield "$POL_OUT" MIXEDCORP_API_KEY context_limit)" "limits follow the forced choice"
grep -q 'operator pinned model_policy=free' <<<"$(rfield "$POL_OUT" MIXEDCORP_API_KEY selection_reason)"
assert_eq 0 $? "reason attributes the choice to the operator"

it "model_policy=paid allows paid even when credit is UNKNOWN"
POL2_OUT="$HOME/r-policy-nocredit.json"
run_resolve "$POL2_OUT" --overrides "$FIX/overrides-policy.json"
assert_eq "unknown" "$(rfield "$POL2_OUT" PAIDCORP_API_KEY credit_status)" "credit unknown"
assert_eq "paid" "$(rfield "$POL2_OUT" PAIDCORP_API_KEY model_policy)" "policy=paid recorded"
assert_eq "pc-big" "$(rfield "$POL2_OUT" PAIDCORP_API_KEY strong_model)" "paid model allowed"

it "an unrecognised model_policy degrades to auto and SAYS so"
assert_eq "auto" "$(rfield "$POL_OUT" FREECORP_API_KEY model_policy)" "bogus policy -> auto"
grep -q "ignored unknown model_policy" <<<"$(rfield "$POL_OUT" FREECORP_API_KEY selection_reason)"
assert_eq 0 $? "reason reports the ignored value"

# ---------------------------------------------------------------------------
# Section 8 — credit-cache trust gates. Every rejection must degrade to
# "unknown" (free-only), never to "available".
# ---------------------------------------------------------------------------
it "a MISSING cache file is a cache miss -> unknown -> free"
M_OUT="$HOME/r-missing.json"
run_resolve "$M_OUT" --credits "$FIX/does-not-exist.json"
assert_eq "unknown" "$(rfield "$M_OUT" MIXEDCORP_API_KEY credit_status)" "missing file -> unknown"
assert_eq "mc-free-flagship" "$(rfield "$M_OUT" MIXEDCORP_API_KEY strong_model)" "free model selected"

it "a cache with the WRONG schema version is never replayed"
# Same providers, same 'available' verdicts — only the version differs. If the
# gate were absent this would select the paid model.
mkcredits "$FIX/credits-badver.json" 99 0 "mixedcorp=available"
V_OUT="$HOME/r-badver.json"
run_resolve "$V_OUT" --credits "$FIX/credits-badver.json"
assert_eq "unknown" "$(rfield "$V_OUT" MIXEDCORP_API_KEY credit_status)" "v99 rejected -> unknown"
assert_eq "mc-free-flagship" "$(rfield "$V_OUT" MIXEDCORP_API_KEY strong_model)" "falls back to free"
cond=1; [[ "$(rfield "$V_OUT" MIXEDCORP_API_KEY strong_model)" != "mc-paid-flagship" ]] && cond=0
assert_eq 0 "$cond" "stale-schema 'available' did NOT unlock the paid model"

it "a cache with NO schema version at all is rejected"
mkcredits "$FIX/credits-nover.json" none 0 "mixedcorp=available"
NV_OUT="$HOME/r-nover.json"
run_resolve "$NV_OUT" --credits "$FIX/credits-nover.json"
assert_eq "unknown" "$(rfield "$NV_OUT" MIXEDCORP_API_KEY credit_status)" "unversioned -> unknown"

it "a cache older than the 24h TTL is rejected"
mkcredits "$FIX/credits-stale.json" 1 90000 "mixedcorp=available"
S_OUT="$HOME/r-stale.json"
run_resolve "$S_OUT" --credits "$FIX/credits-stale.json"
assert_eq "unknown" "$(rfield "$S_OUT" MIXEDCORP_API_KEY credit_status)" "25h-old cache -> unknown"
assert_eq "mc-free-flagship" "$(rfield "$S_OUT" MIXEDCORP_API_KEY strong_model)" "falls back to free"

it "a cache just INSIDE the TTL is still trusted (the gate is a TTL, not a ban)"
mkcredits "$FIX/credits-fresh.json" 1 3600 "mixedcorp=available"
F_OUT="$HOME/r-fresh.json"
run_resolve "$F_OUT" --credits "$FIX/credits-fresh.json"
assert_eq "available" "$(rfield "$F_OUT" MIXEDCORP_API_KEY credit_status)" "1h-old cache accepted"
assert_eq "mc-paid-flagship" "$(rfield "$F_OUT" MIXEDCORP_API_KEY strong_model)" "paid model selected"

it "a MALFORMED cache file is rejected, not crashed on"
printf '{ this is not json' > "$FIX/credits-broken.json"
B_OUT="$HOME/r-broken.json"
run_resolve "$B_OUT" --credits "$FIX/credits-broken.json"
rc=$?
assert_eq 0 "$rc" "resolver survives a corrupt cache"
assert_eq "unknown" "$(rfield "$B_OUT" MIXEDCORP_API_KEY credit_status)" "corrupt -> unknown"

it "a FUTURE-dated cache beyond clock skew is rejected"
mkcredits "$FIX/credits-future.json" 1 -7200 "mixedcorp=available"
FU_OUT="$HOME/r-future.json"
run_resolve "$FU_OUT" --credits "$FIX/credits-future.json"
assert_eq "unknown" "$(rfield "$FU_OUT" MIXEDCORP_API_KEY credit_status)" "future-dated -> unknown"

it "a provider ABSENT from an otherwise-valid cache is unknown, not inherited"
mkcredits "$FIX/credits-partial.json" 1 0 "mixedcorp=available"
PA_OUT="$HOME/r-partial.json"
run_resolve "$PA_OUT" --credits "$FIX/credits-partial.json"
assert_eq "available" "$(rfield "$PA_OUT" MIXEDCORP_API_KEY credit_status)" "listed provider available"
assert_eq "unknown"   "$(rfield "$PA_OUT" PAIDCORP_API_KEY credit_status)" "unlisted provider unknown"
assert_eq "none"      "$(rfield "$PA_OUT" PAIDCORP_API_KEY credit_signal)" "no signal for unlisted"

# ---------------------------------------------------------------------------
# Section 9 — ANTI-VACUOUS-PASS GUARDS.
#
# Every assertion above is individually satisfiable by a selector that ignores
# credit and always returns one hardcoded model. These guards make that
# impossible: the same catalog must produce DIFFERENT models, DIFFERENT tiers
# and DIFFERENT limits as the credit state changes.
# ---------------------------------------------------------------------------
it "GUARD: the same catalog yields a DIFFERENT strong model per credit state"
s_unknown="$(rfield "$U_OUT" MIXEDCORP_API_KEY strong_model)"
s_avail="$(rfield "$A_OUT" MIXEDCORP_API_KEY strong_model)"
s_exhaust="$(rfield "$E_OUT" MIXEDCORP_API_KEY strong_model)"
cond=1; [[ "$s_avail" != "$s_unknown" ]] && cond=0
assert_eq 0 "$cond" "available($s_avail) != unknown($s_unknown)"
cond=1; [[ "$s_avail" != "$s_exhaust" ]] && cond=0
assert_eq 0 "$cond" "available($s_avail) != exhausted($s_exhaust)"

it "GUARD: the same catalog yields a DIFFERENT fast model per credit state"
f_avail="$(rfield "$A_OUT" MIXEDCORP_API_KEY fast_model)"
f_exhaust="$(rfield "$E_OUT" MIXEDCORP_API_KEY fast_model)"
cond=1; [[ "$f_avail" != "$f_exhaust" ]] && cond=0
assert_eq 0 "$cond" "fast available($f_avail) != exhausted($f_exhaust)"

it "GUARD: context_limit MOVES with the selection (limits are not a constant)"
c_avail="$(rfield "$A_OUT" MIXEDCORP_API_KEY context_limit)"
c_exhaust="$(rfield "$E_OUT" MIXEDCORP_API_KEY context_limit)"
cond=1; [[ "$c_avail" != "$c_exhaust" ]] && cond=0
assert_eq 0 "$cond" "context available($c_avail) != exhausted($c_exhaust)"
o_avail="$(rfield "$A_OUT" MIXEDCORP_API_KEY max_output)"
o_exhaust="$(rfield "$E_OUT" MIXEDCORP_API_KEY max_output)"
cond=1; [[ "$o_avail" != "$o_exhaust" ]] && cond=0
assert_eq 0 "$cond" "max_output available($o_avail) != exhausted($o_exhaust)"

it "GUARD: model_tier actually varies (not hardcoded to one value)"
tiers="$(printf '%s\n%s\n%s\n' \
  "$(rfield "$A_OUT" MIXEDCORP_API_KEY model_tier)" \
  "$(rfield "$E_OUT" MIXEDCORP_API_KEY model_tier)" \
  "$(rfield "$E_OUT" OPAQUECORP_API_KEY model_tier)" | sort -u | grep -c .)"
assert_eq "3" "$tiers" "free, paid and unknown tiers all occur"

it "GUARD: across the whole matrix at least 4 DISTINCT models are selected"
# A selector returning a fixed model, or one keyed only on provider, cannot
# reach this count.
distinct="$(python3 - "$U_OUT" "$A_OUT" "$E_OUT" "$P_OUT" <<'PY'
import json, sys
ids = set()
for path in sys.argv[1:]:
    for rec in json.load(open(path)):
        for field in ("strong_model", "fast_model"):
            if rec.get(field):
                ids.add(rec[field])
print(len(ids))
PY
)"
cond=1; [[ "$distinct" -ge 4 ]] && cond=0
assert_eq 0 "$cond" "distinct selected model ids across matrix = $distinct (>=4)"

it "GUARD: every mixedcorp model id is reachable under some credit state"
# Proves the four fixture models are genuinely selectable, so an assertion
# expecting one of them is testing behaviour rather than an accident.
for want in mc-paid-flagship mc-paid-mini mc-free-flagship mc-free-mini; do
  found=1
  for f in "$U_OUT" "$A_OUT" "$E_OUT"; do
    if [[ "$(rfield "$f" MIXEDCORP_API_KEY strong_model)" == "$want" || \
          "$(rfield "$f" MIXEDCORP_API_KEY fast_model)" == "$want" ]]; then
      found=0; break
    fi
  done
  assert_eq 0 "$found" "$want is reachable"
done

it "GUARD: the credit audit fields are never empty on a resolved record"
python3 - "$A_OUT" "$E_OUT" "$U_OUT" <<'PY'
import json, sys
bad = []
for path in sys.argv[1:]:
    for rec in json.load(open(path)):
        if rec.get("status") != "resolved":
            continue
        for field in ("credit_status", "credit_signal", "model_policy",
                      "model_tier", "selection_reason"):
            if not rec.get(field):
                bad.append((path, rec["key_var"], field))
sys.exit(1 if bad else 0)
PY
assert_eq 0 $? "all resolved records carry a full credit audit trail"

it "GUARD: credit fields exist even on skipped/unmapped records"
SK_OUT="$HOME/r-skipped.json"
python3 "$RESOLVE" --models-dev "$FIX/catalog.json" --keys "GITHUB_TOKEN,NOSUCH_API_KEY" > "$SK_OUT"
assert_eq "skipped"  "$(rfield "$SK_OUT" GITHUB_TOKEN status)" "vcs key skipped"
assert_eq "unknown"  "$(rfield "$SK_OUT" GITHUB_TOKEN credit_status)" "credit field present"
assert_eq "unmapped" "$(rfield "$SK_OUT" NOSUCH_API_KEY status)" "unknown key unmapped"
assert_eq "unknown"  "$(rfield "$SK_OUT" NOSUCH_API_KEY model_tier)" "tier field present"

# ---------------------------------------------------------------------------
# Section 10 — model_verify.py: cost classification, credit-aware ranking, the
# probe's status-code interpretation, and key redaction. All offline: the
# functions are imported and called directly, no sockets.
# ---------------------------------------------------------------------------
it "model_verify classifies free/paid/unknown exactly like the resolver"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("mv", sys.argv[1] + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
spec2 = importlib.util.spec_from_file_location("pr", sys.argv[1] + "/providers_resolve.py")
pr = importlib.util.module_from_spec(spec2); spec2.loader.exec_module(pr)

cases = [
    ({"id": "a", "cost": {"input": 0, "output": 0}}, "free"),
    ({"id": "b", "cost": {"input": 1, "output": 2}}, "paid"),
    ({"id": "c", "cost": {"input": 0, "output": 5}}, "paid"),
    ({"id": "d"}, "unknown"),
    ({"id": "e", "cost": {}}, "unknown"),
    ({"id": "f", "cost": {"input": 0}}, "unknown"),
    ({"id": "vendor/x:free"}, "free"),
]
for model, want in cases:
    got = pr.model_cost_tier(model)
    assert got == want, f"resolver: {model} -> {got}, want {want}"
    enriched = mv.enrich_from_catalog(
        [{"model_id": model["id"], "score": 0, "verified": True,
          "capabilities": {}}],
        {model["id"]: model})
    assert enriched[0]["credit_tier"] == want, \
        f"model_verify: {model} -> {enriched[0]['credit_tier']}, want {want}"
PY
assert_eq 0 $? "both engines agree on all 7 pricing shapes"

it "model_verify's paid-model probe reads HTTP status codes honestly"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("mv", sys.argv[1] + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)

# (status, body) -> expected credit verdict
cases = [
    ((200, {"choices": [{"message": {"content": "hi"}}]}), "available"),
    ((402, {"error": {"message": "Payment Required"}}),    "exhausted"),
    ((400, {"error": {"message": "Insufficient Balance"}}), "exhausted"),
    ((403, {"error": {"message": "insufficient_quota"}}),  "exhausted"),
    ((401, {"error": {"message": "invalid api key"}}),     "unknown"),
    ((429, {"error": {"message": "rate limit exceeded"}}), "unknown"),
    ((503, {"error": {"message": "upstream down"}}),       "unknown"),
    ((404, {"error": {"message": "no such model"}}),       "unknown"),
    ((0,   {"_error": "timed out"}),                       "unknown"),
    ((200, {"error": {"message": "model overloaded"}}),    "unknown"),
]
for (status, body), want in cases:
    mv.http_post_json = lambda *a, **k: (status, body, 5)
    got = mv.probe_paid_model("m", "https://x.invalid/v1", "sk-secret", 1)
    assert got["credit"] == want, f"{status} {body} -> {got['credit']}, want {want}"
PY
assert_eq 0 $? "all 10 status/body combinations classify correctly"

it "a balance endpoint verdict is computed from granted minus spent"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("mv", sys.argv[1] + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)

spec_cfg = {"url": "https://x.invalid/credits", "auth": "bearer",
            "signals": [{"path": ["data", "total_credits"], "type": "balance",
                         "minus": ["data", "total_usage"]}]}
cases = [
    ((200, {"data": {"total_credits": 10.0, "total_usage": 3.0}}), "available"),
    ((200, {"data": {"total_credits": 3.0,  "total_usage": 3.0}}), "exhausted"),
    ((200, {"data": {"total_credits": 1.0,  "total_usage": 9.0}}), "exhausted"),
    ((200, {"data": {}}),                                          "unknown"),
    ((401, {}),                                                    "unknown"),
    ((500, {}),                                                    "unknown"),
]
for (status, body), want in cases:
    mv.http_get_json = lambda *a, **k: (status, body)
    got = mv.probe_balance_endpoint(spec_cfg, "sk-secret", 1)
    assert got["credit"] == want, f"{status} {body} -> {got['credit']}, want {want}"

# Decimal STRINGS are accepted (DeepSeek sends "110.00", not 110.0), while a
# boolean must never be coerced into a number.
str_cfg = {"url": "https://x.invalid/b", "signals": [
    {"path": ["balance_infos", 0, "total_balance"], "type": "balance"}]}
for body, want in (({"balance_infos": [{"total_balance": "110.00"}]}, "available"),
                   ({"balance_infos": [{"total_balance": "0.00"}]},   "exhausted"),
                   ({"balance_infos": [{"total_balance": "junk"}]},   "unknown"),
                   ({"balance_infos": []},                            "unknown"),
                   ({"balance_infos": [{"total_balance": True}]},     "unknown")):
    mv.http_get_json = lambda *a, **k: (200, body)
    got = mv.probe_balance_endpoint(str_cfg, "sk-secret", 1)
    assert got["credit"] == want, f"{body} -> {got['credit']}, want {want}"
PY
assert_eq 0 $? "balance arithmetic, string balances and failure modes are correct"

it "ORDERED signals: an exact-but-null field falls through to the coarser one"
# This is the live OpenRouter shape: limit_remaining is null on an uncapped key,
# so the verdict must come from is_free_tier — and a boolean_negated signal must
# invert correctly (is_free_tier=false means the account HAS bought credits).
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("mv", sys.argv[1] + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)

cfg = {"url": "https://x.invalid/key", "signals": [
    {"path": ["data", "limit_remaining"], "type": "balance"},
    {"path": ["data", "is_free_tier"], "type": "boolean_negated"}]}
cases = [
    # limit_remaining present -> it decides, is_free_tier ignored entirely.
    ({"data": {"limit_remaining": 5.0, "is_free_tier": True}},  "available"),
    ({"data": {"limit_remaining": 0.0, "is_free_tier": False}}, "exhausted"),
    # limit_remaining null -> fall through to the negated boolean.
    ({"data": {"limit_remaining": None, "is_free_tier": False}}, "available"),
    ({"data": {"limit_remaining": None, "is_free_tier": True}},  "exhausted"),
    # neither present -> honest unknown.
    ({"data": {}}, "unknown"),
]
for body, want in cases:
    mv.http_get_json = lambda *a, **k: (200, body)
    got = mv.probe_balance_endpoint(cfg, "sk-secret", 1)
    assert got["credit"] == want, f"{body} -> {got['credit']}, want {want}"
PY
assert_eq 0 $? "signal precedence and boolean negation are correct"

it "SECURITY: an API key never survives into a cached credit detail"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json
spec = importlib.util.spec_from_file_location("mv", sys.argv[1] + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)

secret = "sk-live-ABCDEF1234567890secret"
# A provider that echoes the credential back in its error body.
mv.http_post_json = lambda *a, **k: (
    403, {"error": {"message": f"insufficient balance for key {secret}"}}, 5)
rec = mv.probe_paid_model("m", "https://x.invalid/v1", secret, 1)
blob = json.dumps(rec)
assert secret not in blob, "raw key leaked into the credit record"
assert "[REDACTED]" in blob, "key was not replaced by a redaction marker"
assert rec["credit"] == "exhausted", "redaction broke the verdict"
# And the generic scrubber catches key shapes it was never handed.
assert "sk-otherkey123456" not in mv.redact("token sk-otherkey123456 here")
PY
assert_eq 0 $? "keys are redacted, verdict preserved"

it "the REAL --multi ranking (model_verify.rank_by_credit) puts free above paid with no credit"
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util
spec = importlib.util.spec_from_file_location("mv", sys.argv[1] + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)

def fresh():
    return [
        {"model_id": "paid-strong", "score": 90, "credit_tier": "paid"},
        {"model_id": "free-weak",   "score": 40, "credit_tier": "free"},
        {"model_id": "unk",         "score": 60, "credit_tier": "unknown"},
    ]

# Call the ACTUAL production ranking that decides which model becomes the alias,
# never a re-implementation — so flipping model_verify's real tier order is
# caught here. (This test was previously a bluff gate: it sorted with its own
# inline dict and stayed green when the production sort was mutated.)
firsts = {}
for status, want_first in (("available", "paid-strong"),
                           ("exhausted", "free-weak"),
                           ("unknown",   "free-weak")):
    ordered = mv.rank_by_credit(fresh(), status)
    firsts[status] = ordered[0]["model_id"]
    assert ordered[0]["model_id"] == want_first, \
        f"{status}: real rank_by_credit gave {ordered[0]['model_id']}, want {want_first}"

# Anti-vacuous: funded vs unfunded MUST genuinely differ — catches a
# credit-agnostic ranking even if both branches happened to match a want_first.
assert firsts["available"] != firsts["exhausted"], \
    "ranking is credit-agnostic: available and exhausted chose the same top model"
PY
assert_eq 0 $? "the real --multi tier ordering is decisive (mutating it fails this test)"

it "the credit cache round-trips through model_verify with version + TTL"
python3 - "$SCRIPTS_DIR" "$FIX" <<'PY'
import sys, importlib.util, json, time, os
spec = importlib.util.spec_from_file_location("mv", sys.argv[1] + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
path = os.path.join(sys.argv[2], "rt-credits.json")

cache = mv.load_credit_cache(path)           # missing file
assert cache["providers"] == {}, "missing file should be empty"
cache["providers"]["acme"] = {"credit": "available", "signal": "balance_endpoint"}
mv.save_credit_cache(path, cache)

back = mv.load_credit_cache(path)
assert back["providers"]["acme"]["credit"] == "available", "round-trip failed"
assert back["_cache_version"] == mv.CREDIT_CACHE_VERSION, "version not stamped"

# Version mismatch must wipe it.
data = json.load(open(path)); data["_cache_version"] = 999
json.dump(data, open(path, "w"))
assert mv.load_credit_cache(path)["providers"] == {}, "bad version was replayed"

# Expired must wipe it.
data["_cache_version"] = mv.CREDIT_CACHE_VERSION
data["_cached_at"] = time.time() - (mv.CREDIT_CACHE_TTL_SECONDS + 60)
json.dump(data, open(path, "w"))
assert mv.load_credit_cache(path)["providers"] == {}, "expired cache was replayed"
PY
assert_eq 0 $? "cache version and TTL gates hold in the writer too"

it "the two engines share one cache version (they cannot drift apart)"
mvv="$(python3 -c 'import re,sys;print(re.search(r"^CREDIT_CACHE_VERSION = (\d+)",open(sys.argv[1]).read(),re.M).group(1))' "$SCRIPTS_DIR/model_verify.py")"
prv="$(python3 -c 'import re,sys;print(re.search(r"^CREDIT_CACHE_VERSION = (\d+)",open(sys.argv[1]).read(),re.M).group(1))' "$SCRIPTS_DIR/providers_resolve.py")"
assert_eq "$mvv" "$prv" "model_verify and providers_resolve agree on CREDIT_CACHE_VERSION"

it "the shipped credit-endpoints table is valid JSON with documented sources"
ENDPOINTS="$SCRIPTS_DIR/providers/credit-endpoints.json"
assert_file "$ENDPOINTS" "credit-endpoints.json is shipped"
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$ENDPOINTS" 2>/dev/null
assert_eq 0 $? "credit-endpoints.json parses"
python3 - "$ENDPOINTS" <<'PY'
import json, sys
table = json.load(open(sys.argv[1]))
entries = {k: v for k, v in table.items() if not k.startswith("_")}
assert entries, "table must not be empty"
valid_types = {"balance", "boolean", "boolean_negated"}
for pid, spec in entries.items():
    assert spec.get("url", "").startswith("https://"), f"{pid}: url must be https"
    assert spec.get("doc", "").startswith("http"), f"{pid}: needs a doc citation"
    signals = spec.get("signals") or []
    assert signals, f"{pid}: needs at least one signal"
    for sig in signals:
        assert sig.get("path"), f"{pid}: signal needs a path"
        assert sig.get("type") in valid_types, f"{pid}: bad signal type {sig.get('type')}"
        assert sig.get("desc"), f"{pid}: signal needs a desc for the audit trail"
PY
assert_eq 0 $? "every entry has an https url, ordered typed signals and a doc citation"

it "the shipped table is wired end-to-end through the real probe entry point"
# Feeds the SHIPPED json through run_credit_probe with the network stubbed, so
# a typo in the table (wrong path, wrong type) fails here rather than in prod.
python3 - "$SCRIPTS_DIR" <<'PY'
import sys, importlib.util, json
spec = importlib.util.spec_from_file_location("mv", sys.argv[1] + "/model_verify.py")
mv = importlib.util.module_from_spec(spec); spec.loader.exec_module(mv)
table = json.load(open(sys.argv[1] + "/providers/credit-endpoints.json"))

# Real recorded response shapes for the two shipped providers.
fixtures = {
    "deepseek": ({"is_available": True,
                  "balance_infos": [{"currency": "USD", "total_balance": "12.34"}]},
                 "available"),
    "openrouter": ({"data": {"limit": None, "limit_remaining": None,
                             "usage": 0.00076067, "is_free_tier": False}},
                   "available"),
}
for pid, (body, want) in fixtures.items():
    mv.http_get_json = lambda *a, **k: (200, body)
    got = mv.run_credit_probe(pid, "https://x.invalid/v1", "sk-secret",
                              endpoint_spec=table[pid])
    assert got["credit"] == want, f"{pid}: {got['credit']} != {want}"
    assert got["signal"] == "balance_endpoint", f"{pid}: wrong signal"
    assert got.get("doc"), f"{pid}: doc citation lost"

# Anti-vacuous: the same table must produce the OPPOSITE verdict on an
# unfunded account, or the entries are not actually reading anything.
for pid, body in (("deepseek", {"is_available": False,
                                "balance_infos": [{"total_balance": "0.00"}]}),
                  ("openrouter", {"data": {"limit_remaining": None,
                                           "is_free_tier": True}})):
    mv.http_get_json = lambda *a, **k: (200, body)
    got = mv.run_credit_probe(pid, "https://x.invalid/v1", "sk-secret",
                              endpoint_spec=table[pid])
    assert got["credit"] == "exhausted", f"{pid}: unfunded -> {got['credit']}"
PY
assert_eq 0 $? "shipped deepseek + openrouter entries read funded AND unfunded correctly"

summary
