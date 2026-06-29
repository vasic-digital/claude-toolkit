#!/usr/bin/env bash
# test_verify_scripts.sh — hermetic coverage for the two verification helpers
# that previously had ZERO tests:
#
#   * scripts/model_verify.py     — HTTP model-probe/scoring engine
#   * scripts/providers-verify.sh — provider key/model verification adapter
#
# Both scripts are fundamentally network-driven (they probe live LLM endpoints),
# so this file deliberately exercises only their NON-network surface — and does
# so non-vacuously:
#
#   model_verify.py     : py_compile (syntax), --help, argparse required-arg
#                         handling, the CMA_PROBE_KEY guard, the no-models guard
#                         (all of which return BEFORE any HTTP), plus its many
#                         pure helper functions imported directly as a module
#                         (endpoint normalisation, anti-bluff detection, response
#                         extraction across OpenAI/Anthropic/Google shapes, tool/
#                         reasoning detection, request building, catalog
#                         enrichment, and the local cache round-trip).
#   providers-verify.sh : bash -n (syntax), unknown-arg validation, and the
#                         offline "strategy 3 / no verifier binary" path proving
#                         --offline gates the HTTP probe even with a key present.
#
# NOT covered here (needs live providers / network — see verify_providers_live.sh
# and a real LLMsVerifier build): the actual HTTP probes, the LLMsVerifier-binary
# strategy 1, and the curl /models strategy 2 success/auth-reject branches.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# Keep Python from scattering __pycache__/*.pyc into the real source tree when
# the pure-function tests import model_verify; everything else stays in $HOME.
export PYTHONDONTWRITEBYTECODE=1

MODEL_VERIFY="$SCRIPTS_DIR/model_verify.py"
PROVIDERS_VERIFY="$SCRIPTS_DIR/providers-verify.sh"

HAVE_PY=0
command -v python3 >/dev/null 2>&1 && HAVE_PY=1

# pyval BODY — run a Python snippet with model_verify importable as `mv` and
# print whatever the snippet prints. Used to assert on the pure helpers.
pyval() {
  python3 -c "import sys; sys.path.insert(0, '$SCRIPTS_DIR'); import model_verify as mv
$1"
}

# ===========================================================================
# model_verify.py
# ===========================================================================

if (( HAVE_PY )); then
  it "model_verify.py compiles cleanly under python3 -W error (py_compile)"
  # Equivalent to `python3 -W error -m py_compile`, but we direct the compiled
  # output into the sandbox (cfile=) so we never write __pycache__ into the repo.
  assert_exit 0 python3 -W error -c \
    'import py_compile,sys; py_compile.compile(sys.argv[1], cfile=sys.argv[2], doraise=True)' \
    "$MODEL_VERIFY" "$HOME/model_verify.compiled.pyc"

  it "model_verify.py imports as a module (top level is side-effect free)"
  imp="$(pyval 'print("IMPORT_OK")' 2>&1)"
  assert_eq "IMPORT_OK" "$imp" "module imports + a helper call works"

  it "model_verify.py --help exits 0 and documents its flags"
  help_out="$(python3 "$MODEL_VERIFY" --help 2>&1)"; rc=$?
  assert_eq 0 "$rc" "--help exit 0"
  echo "$help_out" | grep -q -- "--provider"; assert_eq 0 $? "--help lists --provider"
  echo "$help_out" | grep -q -- "--endpoint"; assert_eq 0 $? "--help lists --endpoint"

  it "model_verify.py errors (exit 2) when required args are missing"
  missing="$( (unset CMA_PROBE_KEY; python3 "$MODEL_VERIFY") 2>&1 )"; rc=$?
  assert_eq 2 "$rc" "argparse exit 2 on missing required args"
  echo "$missing" | grep -qi "required\|--provider\|--endpoint"; assert_eq 0 $? "usage names the required args"

  it "model_verify.py exits 1 without CMA_PROBE_KEY (key check precedes any HTTP)"
  nokey="$( (unset CMA_PROBE_KEY; python3 "$MODEL_VERIFY" \
             --provider x --endpoint http://127.0.0.1 --no-cache --models foo) 2>&1 )"; rc=$?
  assert_eq 1 "$rc" "exit 1 when CMA_PROBE_KEY unset"
  echo "$nokey" | grep -q "CMA_PROBE_KEY"; assert_eq 0 $? "error names CMA_PROBE_KEY"

  it "model_verify.py exits 1 when key is set but no models and no catalog"
  # Returns at model selection, before the ThreadPoolExecutor — so still no HTTP.
  nomodels="$( CMA_PROBE_KEY=dummy-not-real python3 "$MODEL_VERIFY" \
               --provider x --endpoint http://127.0.0.1 --no-cache 2>&1 )"; rc=$?
  assert_eq 1 "$rc" "exit 1 with no models/catalog"
  echo "$nomodels" | grep -q "no models specified"; assert_eq 0 $? "error: no models specified"

  it "normalize_endpoint_for_probe maps /anthropic -> /v1, leaves /v1/... alone"
  assert_eq "https://api.x.com/v1" \
    "$(pyval 'print(mv.normalize_endpoint_for_probe("https://api.x.com/anthropic"))')" "anthropic->v1"
  assert_eq "https://api.x.com/v1/chat/completions" \
    "$(pyval 'print(mv.normalize_endpoint_for_probe("https://api.x.com/v1/chat/completions"))')" "v1 unchanged"

  it "is_bluff_response flags empty + error-in-200-body, accepts real content, trusts non-200"
  assert_eq "True"  "$(pyval 'print(mv.is_bluff_response("",200,{})[0])')"                          "empty body is bluff"
  assert_eq "False" "$(pyval 'print(mv.is_bluff_response("VERIFY_OK",200,{})[0])')"                 "real content not bluff"
  assert_eq "True"  "$(pyval 'print(mv.is_bluff_response("hi",200,{"error":{"message":"boom"}})[0])')" "error-in-200 is bluff"
  assert_eq "False" "$(pyval 'print(mv.is_bluff_response("x",404,{})[0])')"                          "non-200 is honest failure"

  it "extract_response_content handles OpenAI, Anthropic and Google shapes"
  assert_eq "HELLO" "$(pyval 'print(mv.extract_response_content({"choices":[{"message":{"content":"HELLO"}}]},""))')" "openai shape"
  assert_eq "ANT"   "$(pyval 'print(mv.extract_response_content({"content":[{"type":"text","text":"ANT"}]},""))')"     "anthropic shape"
  assert_eq "GOO"   "$(pyval 'print(mv.extract_response_content({"candidates":[{"content":{"parts":[{"text":"GOO"}]}}]},""))')" "google shape"

  it "has_tool_call_support / has_reasoning_support read the right fields"
  assert_eq "True"  "$(pyval 'print(mv.has_tool_call_support({"choices":[{"message":{"tool_calls":[1]}}]}))')" "tool_calls present"
  assert_eq "False" "$(pyval 'print(mv.has_tool_call_support({"choices":[{"message":{"content":"x"}}]}))')"    "no tool_calls"
  assert_eq "True"  "$(pyval 'print(mv.has_reasoning_support({"choices":[{"message":{"reasoning_content":"b"}}]}))')" "reasoning_content present"

  it "build_probe_request picks the right auth header + body per endpoint"
  assert_eq "True True mid" \
    "$(pyval 'u,h,b=mv.build_probe_request("mid","https://api/v1/chat/completions","KEY"); print("Authorization" in h, h["Authorization"].startswith("Bearer"), b["model"])')" \
    "openai-compatible -> Bearer auth"
  assert_eq "True 2023-06-01" \
    "$(pyval 'u,h,b=mv.build_probe_request("mid","https://api/v1/messages","KEY"); print("x-api-key" in h, h.get("anthropic-version"))')" \
    "anthropic -> x-api-key + version"
  assert_eq "https://api.example.com/chat/completions" \
    "$(pyval 'u,h,b=mv.build_probe_request("mid","https://api.example.com","KEY"); print(u)')" \
    "unknown endpoint gets /chat/completions appended"

  it "enrich_from_catalog adds context window, free bonus, and prunes tiny models"
  assert_eq "200000 True True" \
    "$(pyval 'm=[{"model_id":"big","score":25,"capabilities":{}}]
c={"big":{"limit":{"context":200000,"output":8000},"cost":{"input":0}}}
mv.enrich_from_catalog(m,c)
print(m[0]["capabilities"]["context_window"], m[0]["capabilities"].get("is_free"), m[0]["score"]>25)')" \
    "big free model enriched + scored up"
  assert_eq "False True" \
    "$(pyval 'm=[{"model_id":"t","score":25,"capabilities":{},"verified":True}]
c={"t":{"limit":{"context":1000,"output":500},"cost":{"input":1}}}
mv.enrich_from_catalog(m,c)
print(m[0]["verified"], "too small" in m[0]["failure_reason"])')" \
    "sub-threshold context window unverifies the model"

  it "save_cache + load_cache round-trip a fresh cache within TTL"
  assert_eq "True True True" \
    "$(pyval 'import os
p=os.path.join(os.environ["HOME"],"vcache.json")
mv.save_cache(p, {"prov":{"x":1}})
d=mv.load_cache(p)
print(os.path.exists(p), "prov" in d, "_cached_at" in d)')" \
    "cache writes, stamps, and reloads"
else
  it "model_verify.py python coverage (skipped — python3 not installed)"
  _pass "SKIP: python3 absent; py_compile + import + pure-function tests not run"
fi

# ===========================================================================
# providers-verify.sh
# ===========================================================================
# Deeper coverage of this script (strategy 1 LLMsVerifier confirmation, strategy
# 2 curl /models success / 401 / inconclusive branches) needs a built verifier
# binary or a live provider endpoint and is intentionally out of scope here;
# it lives in verify_providers_live.sh. The hermetic surface below is the syntax
# check, arg validation, and the offline / no-binary "strategy 3" contract.

it "providers-verify.sh passes bash -n syntax check"
assert_exit 0 bash -n "$PROVIDERS_VERIFY"

it "providers-verify.sh rejects an unknown arg (exit 2, names it on stderr)"
# Arg parsing happens before any strategy, so this is deterministic on every host.
bogus="$(bash "$PROVIDERS_VERIFY" --bogus-flag 2>&1)"; rc=$?
assert_eq 2 "$rc" "unknown arg exit 2"
echo "$bogus" | grep -q "unknown arg"; assert_eq 0 $? "stderr names the unknown arg"

# Run against a COPY inside the sandbox so the script's VERIFIER_BIN resolves
# relative to $HOME (where no submodules/LLMsVerifier exists) — making strategy 1
# deterministically unavailable regardless of whether the real repo built it.
COPY="$HOME/providers-verify-copy.sh"
cp "$PROVIDERS_VERIFY" "$COPY"

it "providers-verify.sh strategy 3 (no binary, --offline) emits 'unverified' / exit 2"
s3out="$(bash "$COPY" --provider acme --model m --key-var CMA_PV_UNSET --offline 2>"$HOME/s3.err")"; rc=$?
assert_eq 2 "$rc" "strategy-3 exit 2"
assert_eq "unverified" "$s3out" "stdout is the single word 'unverified'"
assert_file_contains "$HOME/s3.err" "LLMsVerifier" "stderr points to building the submodule"

it "providers-verify.sh --offline gates the HTTP probe even with key + base-url set"
# With a real key var AND a base-url present, only --offline should keep it from
# probing the network — proving the OFFLINE guard short-circuits strategy 2.
ofout="$(CMA_PV_KEY="not-a-real-secret" bash "$COPY" \
          --provider acme --model m --key-var CMA_PV_KEY \
          --base-url https://127.0.0.1:9 --offline 2>"$HOME/of.err")"; rc=$?
assert_eq 2 "$rc" "offline still 'unverified' (no probe attempted)"
assert_eq "unverified" "$ofout" "offline path yields 'unverified'"

it "providers-verify.sh never echoes the key value to stdout or stderr"
echo "$ofout" | grep -q "not-a-real-secret"; assert_eq 1 $? "secret absent from stdout"
assert_file_not_contains "$HOME/of.err" "not-a-real-secret" "secret absent from stderr"

summary
