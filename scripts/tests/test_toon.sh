#!/usr/bin/env bash
# test_toon.sh — hermetic tests for the TOON utility (toon.mjs + toon_encode.py).
# Encodes JSON into token-efficient TOON, decodes it back to JSON, and exercises
# the Python wrapper. SKIPs (exit 0) when node or the @toon-format/toon package
# is unavailable, mirroring test_export.sh's pandoc/PDF-engine skip exactly.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

# toon.mjs hard-requires Node plus the @toon-format/toon package (installed by
# install.sh via npm). On hosts without that tooling, SKIP rather than fail —
# the feature is genuinely unavailable, matching how test_export.sh SKIPs when
# pandoc/a PDF engine is missing. The encode-of-{} probe doubles as a dep check:
# if the package is absent, the import throws and node exits non-zero.
if ! command -v node >/dev/null 2>&1 || \
   ! node "$SCRIPTS_DIR/toon.mjs" encode '{}' >/dev/null 2>&1; then
  echo "SKIP: TOON prerequisites (node + @toon-format/toon) not installed"
  exit 0
fi

make_sandbox

it "encode emits a tabular TOON header and rows for an array of objects"
out_file="$HOME/encode.out"
printf '%s' '{"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}' \
  | node "$SCRIPTS_DIR/toon.mjs" encode > "$out_file" 2>&1
rc=$?
assert_eq 0 "$rc" "encode exits 0"
assert_file_contains "$out_file" "users[2]{id,name}:" "tabular header declared once"
assert_file_contains "$out_file" "1,Alice" "first record row present"
assert_file_contains "$out_file" "2,Bob" "second record row present"

it "encode then decode round-trips back to the original JSON"
toon_file="$HOME/rt.toon"
printf '%s' '{"users":[{"id":1,"name":"Alice"},{"id":2,"name":"Bob"}]}' \
  | node "$SCRIPTS_DIR/toon.mjs" encode > "$toon_file" 2>&1
json_file="$HOME/rt.json"
node "$SCRIPTS_DIR/toon.mjs" decode "$(cat "$toon_file")" > "$json_file" 2>&1
rc=$?
assert_eq 0 "$rc" "decode exits 0"
assert_file_contains "$json_file" '"Alice"' "decoded JSON round-trips the value"

it "python wrapper (toon_encode.py) encodes JSON from stdin"
py_file="$HOME/py.out"
printf '%s' '{"a":[{"k":1}]}' | python3 "$SCRIPTS_DIR/toon_encode.py" > "$py_file" 2>&1
rc=$?
assert_eq 0 "$rc" "toon_encode.py exits 0"
assert_file_contains "$py_file" "a[1]{k}:" "python wrapper emits TOON with field k"

it "encode rejects invalid JSON with a non-zero exit"
printf 'not json' | node "$SCRIPTS_DIR/toon.mjs" encode > /dev/null 2>&1
rc=$?
nonzero=$(( rc != 0 ))
assert_eq 1 "$nonzero" "invalid JSON exits non-zero (rc=$rc)"

summary
