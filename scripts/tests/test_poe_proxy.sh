#!/usr/bin/env bash
# test_poe_proxy.sh — hermetic unit tests for scripts/proxy/poe_proxy.py.
#
# Poe rejects requests with too many tool definitions (empirically >~216) with a
# misleading `400 Invalid 'tools': Field required`, and rejects tools that omit
# a `parameters` field. The proxy fixes both: it injects a default `parameters`
# and caps the tool list (dropping only overflow MCP tools, never a built-in).
# These tests exercise fix_tools / cap_tools / fix_request directly via python3.
#
# No network, no Poe key, no running server required.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
source "$TESTS_DIR/lib/assert.sh"
set +e

PROXY="$SCRIPTS_DIR/proxy/poe_proxy.py"

# Run a python snippet that imports the proxy module by path and prints a value.
# $1 = extra env assignments (e.g. "POE_MAX_TOOLS=50"), $2 = python body.
px() {
  local env_pairs="$1" body="$2"
  env $env_pairs python3 - "$PROXY" <<PY
import importlib.util, sys
spec = importlib.util.spec_from_file_location("pp", sys.argv[1])
pp = importlib.util.module_from_spec(spec); spec.loader.exec_module(pp)
$body
PY
}

it "poe_proxy module imports and exposes fix_tools/cap_tools/fix_request"
out="$(px "" 'print(all(hasattr(pp,n) for n in ("fix_tools","cap_tools","fix_request")))')"
assert_eq "True" "$out" "all three functions present"

it "fix_tools injects a default parameters object when a tool omits it"
out="$(px "" '
tools=[{"type":"function","function":{"name":"ping","description":"p"}}]
f=pp.fix_tools(tools)
print(f[0]["function"]["parameters"]=={"type":"object","properties":{}})')"
assert_eq "True" "$out" "missing parameters filled with empty object schema"

it "fix_tools adds properties to a bare {\"type\":\"object\"} parameters (Poe requires it)"
# Live-verified against api.poe.com (v1.14.0): parameters without a properties
# key is rejected as `400 Invalid '"'"'tools'"'"': Field required` — this was the
# root cause of poe aliases failing real Claude Code launches.
out="$(px "" '
tools=[{"type":"function","function":{"name":"noop","description":"zero-arg tool","parameters":{"type":"object"}}}]
f=pp.fix_tools(tools)
p=f[0]["function"]["parameters"]
print(p=={"type":"object","properties":{}})')"
assert_eq "True" "$out" "bare object schema gains properties:{}"

it "fix_tools preserves existing properties and fills missing type"
out="$(px "" '
tools=[{"type":"function","function":{"name":"calc","description":"d","parameters":{"properties":{"e":{"type":"string"}}}}}]
f=pp.fix_tools(tools)
p=f[0]["function"]["parameters"]
print(p["type"]=="object" and p["properties"]=={"e":{"type":"string"}})')"
assert_eq "True" "$out" "existing properties kept, type defaults to object"

it "cap_tools is a no-op when tool count is within the limit"
out="$(px "POE_MAX_TOOLS=200" '
tools=[{"type":"function","function":{"name":f"t{i}","parameters":{"type":"object","properties":{}}}} for i in range(50)]
capped,dropped=pp.cap_tools(tools)
print(len(capped),dropped)')"
assert_eq "50 0" "$out" "50 tools <= 200 -> unchanged, nothing dropped"

it "cap_tools caps to POE_MAX_TOOLS and preserves ALL built-in (non-mcp) tools"
out="$(px "POE_MAX_TOOLS=100" '
builtin=[{"type":"function","function":{"name":f"b{i}","parameters":{"type":"object","properties":{}}}} for i in range(30)]
mcp=[{"type":"function","function":{"name":f"mcp__srv__t{i}","parameters":{"type":"object","properties":{}}}} for i in range(400)]
capped,dropped=pp.cap_tools(builtin+mcp)
names=[t["function"]["name"] for t in capped]
kept_builtin=sum(1 for n in names if not n.startswith("mcp__"))
print(len(capped),dropped,kept_builtin)')"
# 430 tools, cap 100 -> keep 100 (all 30 builtin + 70 mcp), drop 330
assert_eq "100 330 30" "$out" "capped to 100, dropped 330, all 30 built-ins kept"

it "cap_tools default limit is 200 (dropping overflow) when POE_MAX_TOOLS unset"
out="$(px "" '
tools=[{"type":"function","function":{"name":f"mcp__s__{i}","parameters":{"type":"object","properties":{}}}} for i in range(417)]
capped,dropped=pp.cap_tools(tools)
print(len(capped),dropped)')"
assert_eq "200 217" "$out" "417 -> 200 with default cap, 217 dropped"

it "fix_request applies BOTH the parameters fix and the tool cap end to end"
out="$(px "POE_MAX_TOOLS=200" '
body={"model":"claude-sonnet-4.6",
      "tools":[{"type":"function","function":{"name":"builtin_no_params"}}]
             +[{"type":"function","function":{"name":f"mcp__s__{i}","parameters":{"type":"object","properties":{}}}} for i in range(417)]}
out=pp.fix_request(body)
t=out["tools"]
first_has_params="parameters" in t[0]["function"]
print(len(t),first_has_params)')"
assert_eq "200 True" "$out" "418 tools -> capped to 200 and the param-less built-in fixed & kept"

summary
