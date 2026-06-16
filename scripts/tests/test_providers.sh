#!/usr/bin/env bash
# test_providers.sh — tests for the provider-alias feature (claude-providers).
# Hermetic: runs entirely inside a sandboxed $HOME via make_sandbox.
#
# As the feature lands, sections are added below. The first and most
# safety-critical section is the account-detection regression: provider
# dirs (~/.claude-prov-*) must be invisible to cma_detect_accounts so they
# never get merged into real-account auth or unify.
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

# ---------------------------------------------------------------------------
# Section 1 — account-detection regression (the linchpin)
# ---------------------------------------------------------------------------

# Two real accounts and the shared dir.
make_account acct1
make_account acct2
mkdir -p "$SHARED_DIR"

# A provider-alias dir that looks account-like (has projects/ + .claude.json)
# — exactly the shape that would be wrongly detected without the exclusion.
mkdir -p "$HOME/${ACCOUNT_PREFIX}prov-deepseek/projects"
printf '{"name":"deepseek"}\n' > "$HOME/${ACCOUNT_PREFIX}prov-deepseek/.claude.json"
# A second provider dir to be sure the prefix match isn't accidental.
mkdir -p "$HOME/${ACCOUNT_PREFIX}prov-groq/projects"
printf '{"name":"groq"}\n' > "$HOME/${ACCOUNT_PREFIX}prov-groq/.claude.json"

detected="$(cma_detect_accounts)"

it "real accounts are still detected"
echo "$detected" | grep -q "${ACCOUNT_PREFIX}acct1$" ; assert_eq 0 $? "acct1 detected"
echo "$detected" | grep -q "${ACCOUNT_PREFIX}acct2$" ; assert_eq 0 $? "acct2 detected"

it "provider-alias dirs are excluded from detection"
echo "$detected" | grep -q "prov-deepseek" ; assert_eq 1 $? "prov-deepseek excluded"
echo "$detected" | grep -q "prov-groq" ;     assert_eq 1 $? "prov-groq excluded"

it "detection count is exactly the real accounts (no provider leakage)"
n="$(echo "$detected" | grep -c .)"
assert_eq "2" "$n" "exactly 2 detected accounts"

it "shared dir is never counted as an account"
echo "$detected" | grep -q -- "-shared" ; assert_eq 1 $? "shared excluded"

# ---------------------------------------------------------------------------
# Section 2 — providers_resolve.py against a deterministic fixture catalog
# (offline; proves transport detection, model selection, classification,
#  key-alias normalization, and unmapped handling without any network).
# ---------------------------------------------------------------------------
RESOLVE="$SCRIPTS_DIR/providers_resolve.py"
FIX="$HOME/fixture"
mkdir -p "$FIX"

cat > "$FIX/catalog.json" <<'JSON'
{
  "acme": {
    "env": ["ACME_API_KEY"],
    "api": "https://api.acme.com/anthropic",
    "npm": "@ai-sdk/anthropic",
    "models": {
      "big":   {"id":"acme-big","reasoning":true,"release_date":"2025-05-01","limit":{"context":200000},"cost":{"input":3,"output":15},"tool_call":true},
      "small": {"id":"acme-small","reasoning":false,"release_date":"2024-01-01","limit":{"context":32000},"cost":{"input":0.1,"output":0.4},"tool_call":true}
    }
  },
  "beta": {
    "env": ["BETA_API_KEY"],
    "api": "https://api.beta.ai/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "flagship": {"id":"beta-x","reasoning":false,"release_date":"2025-06-01","limit":{"context":128000},"cost":{"input":1,"output":5},"tool_call":true}
    }
  }
}
JSON

cat > "$FIX/key-aliases.json" <<'JSON'
{ "LEGACY_BETA_KEY": "beta" }
JSON

# Read a field for a given key_var out of the resolver JSON output.
rfield() { # rfield JSON KEYVAR FIELD
  python3 -c 'import json,sys
recs=json.load(open(sys.argv[1]))
m={r["key_var"]:r for r in recs}
print(m[sys.argv[2]][sys.argv[3]])' "$1" "$2" "$3"
}

OUT="$HOME/resolved.json"
python3 "$RESOLVE" --models-dev "$FIX/catalog.json" \
  --key-aliases "$FIX/key-aliases.json" \
  --keys "ACME_API_KEY,BETA_API_KEY,LEGACY_BETA_KEY,GITHUB_TOKEN,FOO_API_KEY" > "$OUT"
rc=$?

it "resolver runs and emits valid JSON"
assert_eq 0 "$rc" "resolver exit 0"
python3 -c 'import json,sys;json.load(open(sys.argv[1]))' "$OUT" 2>/dev/null
assert_eq 0 $? "output is valid JSON"

it "native transport detected from @ai-sdk/anthropic npm"
assert_eq "native" "$(rfield "$OUT" ACME_API_KEY transport)" "acme native"
assert_eq "resolved" "$(rfield "$OUT" ACME_API_KEY status)" "acme resolved"

it "strong model = reasoning/newest; fast model = lowest input cost"
assert_eq "acme-big" "$(rfield "$OUT" ACME_API_KEY strong_model)" "strong=reasoning model"
assert_eq "acme-small" "$(rfield "$OUT" ACME_API_KEY fast_model)" "fast=cheapest model"

it "openai-compatible npm => router transport"
assert_eq "router" "$(rfield "$OUT" BETA_API_KEY transport)" "beta router"
assert_eq "https://api.beta.ai/v1" "$(rfield "$OUT" BETA_API_KEY base_url)" "beta base_url from catalog"

it "key-aliases.json normalizes a differently-named key var"
assert_eq "beta" "$(rfield "$OUT" LEGACY_BETA_KEY provider_id)" "LEGACY_BETA_KEY -> beta"

it "VCS token is skipped, unknown llm key is unmapped"
assert_eq "skipped" "$(rfield "$OUT" GITHUB_TOKEN status)" "GITHUB_TOKEN skipped"
assert_eq "vcs" "$(rfield "$OUT" GITHUB_TOKEN classification)" "GITHUB_TOKEN vcs"
assert_eq "unmapped" "$(rfield "$OUT" FOO_API_KEY status)" "FOO_API_KEY unmapped"

summary
