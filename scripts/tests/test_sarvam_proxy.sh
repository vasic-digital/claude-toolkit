#!/usr/bin/env bash
# test_sarvam_proxy.sh — hermetic unit tests for scripts/proxy/sarvam_proxy.py.
#
# Sarvam rejects system messages whose content is an array of content blocks
# (`400 body.messages.0.system.content : Input should be a valid string` —
# reproduced live). The proxy flattens them to joined strings. These tests
# exercise flatten_content / fix_request directly via python3. No network.
set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
source "$TESTS_DIR/lib/assert.sh"
set +e

PROXY="$SCRIPTS_DIR/proxy/sarvam_proxy.py"

it "flatten_content joins text blocks into one string"
out="$(python3 - "$PROXY" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
c=[{"type":"text","text":"You are helpful."},{"type":"text","text":"Be brief."}]
print(m.flatten_content(c)=="You are helpful.\nBe brief.")
PY
)"
assert_eq "True" "$out" "two text blocks joined with newline"

it "flatten_content leaves plain strings untouched"
out="$(python3 - "$PROXY" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
print(m.flatten_content("already a string")=="already a string")
PY
)"
assert_eq "True" "$out" "string content passes through"

it "fix_request flattens content arrays for ALL roles (system AND user)"
out="$(python3 - "$PROXY" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
b={"messages":[
  {"role":"system","content":[{"type":"text","text":"sys one"},{"type":"text","text":"sys two"}]},
  {"role":"user","content":[{"type":"text","text":"usr one"}]}]}
r=m.fix_request(b)
print(r["messages"][0]["content"]=="sys one\nsys two" and r["messages"][1]["content"]=="usr one")
PY
)"
assert_eq "True" "$out" "system and user blocks both flattened (sarvam 400s on either)"

it "fix_request is a no-op when no system content array is present"
out="$(python3 - "$PROXY" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
b={"messages":[{"role":"system","content":"plain"},{"role":"user","content":"hi"}],"model":"m"}
r=m.fix_request(b)
print(r==b)
PY
)"
assert_eq "True" "$out" "already-valid bodies unchanged"

it "fix_request clamps max_tokens above the tier ceiling (4096) but keeps smaller values"
out="$(python3 - "$PROXY" <<'PY'
import importlib.util, sys
spec = importlib.util.spec_from_file_location("sp", sys.argv[1])
m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m)
a=m.fix_request({"max_tokens":64000,"messages":[]})
b=m.fix_request({"max_tokens":2048,"messages":[]})
c=m.fix_request({"messages":[]})
print(a["max_tokens"]==4096 and b["max_tokens"]==2048 and "max_tokens" not in c)
PY
)"
assert_eq "True" "$out" "64000 clamped to 4096; smaller values and absent key untouched"

summary
