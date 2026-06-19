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
  },
  "zai-coding-plan": {
    "env": ["ZAI_API_KEY"],
    "api": "https://api.z.ai/api/coding/paas/v4",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "glm-5.2": {"id":"glm-5.2","name":"GLM-5.2","reasoning":true,"tool_call":true,"release_date":"2026-06-13","limit":{"context":1000000},"cost":{"input":0,"output":0}},
      "glm-4.7": {"id":"glm-4.7","name":"GLM-4.7","reasoning":true,"tool_call":true,"release_date":"2025-12-22","limit":{"context":204800},"cost":{"input":0,"output":0}}
    }
  },
  "xiaomi": {
    "env": ["XIAOMI_API_KEY"],
    "api": "https://api.xiaomimimo.com/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "mimo-v2.5-pro-ultraspeed": {"id":"mimo-v2.5-pro-ultraspeed","name":"MiMo V2.5 Pro Ultraspeed","reasoning":true,"tool_call":true,"release_date":"2026-07-01","limit":{"context":1000000},"cost":{"input":0,"output":0}},
      "mimo-v2.5-pro":            {"id":"mimo-v2.5-pro","name":"MiMo V2.5 Pro","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":1000000},"cost":{"input":2,"output":8}},
      "mimo-v2-flash":            {"id":"mimo-v2-flash","name":"MiMo V2 Flash","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":256000},"cost":{"input":0.1,"output":0.4}}
    }
  }
}
JSON

cat > "$FIX/key-aliases.json" <<'JSON'
{ "LEGACY_BETA_KEY": "beta", "XIAOMI_MIMO_API_KEY": "xiaomi" }
JSON

# A fixture overrides file mirroring the real shipped providers/overrides.json for
# xiaomi: pins native transport, the /anthropic base_url, and the live-served model
# ids — proving the override BEATS the resolver's catalog-derived defaults (router
# transport from the openai-compatible npm, the /v1 catalog api, and the stale
# ultraspeed model that auto-selection would otherwise pick as strongest).
cat > "$FIX/overrides.json" <<'JSON'
{
  "xiaomi": {
    "transport": "native",
    "base_url": "https://api.xiaomimimo.com/anthropic",
    "strong_model": "mimo-v2.5-pro",
    "fast_model": "mimo-v2-flash"
  }
}
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
  --overrides "$FIX/overrides.json" \
  --keys "ACME_API_KEY,BETA_API_KEY,ZAI_API_KEY,LEGACY_BETA_KEY,XIAOMI_MIMO_API_KEY,GITHUB_TOKEN,FOO_API_KEY" > "$OUT"
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

it "zai-coding-plan resolves from env key match on ZAI_API_KEY"
assert_eq "zai-coding-plan" "$(rfield "$OUT" ZAI_API_KEY provider_id)" "zai-coding-plan provider_id"
assert_eq "resolved" "$(rfield "$OUT" ZAI_API_KEY status)" "zai-coding-plan resolved"

it "zai-coding-plan uses coding paas endpoint and router transport"
assert_eq "https://api.z.ai/api/coding/paas/v4" "$(rfield "$OUT" ZAI_API_KEY base_url)" "coding endpoint"
assert_eq "router" "$(rfield "$OUT" ZAI_API_KEY transport)" "zai-coding-plan router"

it "zai-coding-plan strong model = glm-5.2 (newest+reasoning), fast model = glm-4.7"
assert_eq "glm-5.2" "$(rfield "$OUT" ZAI_API_KEY strong_model)" "strong=glm-5.2"
assert_eq "glm-4.7" "$(rfield "$OUT" ZAI_API_KEY fast_model)" "fast=glm-4.7"

it "xiaomi resolves from the key-alias mapping on XIAOMI_MIMO_API_KEY"
assert_eq "xiaomi" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY provider_id)" "xiaomi provider_id"
assert_eq "resolved" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY status)" "xiaomi resolved"

it "xiaomi override forces native transport (beats openai-compatible npm)"
assert_eq "native" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY transport)" "xiaomi native"

it "xiaomi override sets the /anthropic base_url (beats catalog /v1)"
assert_eq "https://api.xiaomimimo.com/anthropic" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY base_url)" "xiaomi /anthropic base"

it "xiaomi strong=mimo-v2.5-pro, fast=mimo-v2-flash (override beats stale ultraspeed)"
assert_eq "mimo-v2.5-pro" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY strong_model)" "strong=mimo-v2.5-pro"
assert_eq "mimo-v2-flash" "$(rfield "$OUT" XIAOMI_MIMO_API_KEY fast_model)" "fast=mimo-v2-flash"

it "the stale mimo-v2.5-pro-ultraspeed id is never selected"
[[ "$(rfield "$OUT" XIAOMI_MIMO_API_KEY strong_model)" != "mimo-v2.5-pro-ultraspeed" ]]; assert_eq 0 $? "ultraspeed not strong"
[[ "$(rfield "$OUT" XIAOMI_MIMO_API_KEY fast_model)"   != "mimo-v2.5-pro-ultraspeed" ]]; assert_eq 0 $? "ultraspeed not fast"

it "VCS token is skipped, unknown llm key is unmapped"
assert_eq "skipped" "$(rfield "$OUT" GITHUB_TOKEN status)" "GITHUB_TOKEN skipped"
assert_eq "vcs" "$(rfield "$OUT" GITHUB_TOKEN classification)" "GITHUB_TOKEN vcs"
assert_eq "unmapped" "$(rfield "$OUT" FOO_API_KEY status)" "FOO_API_KEY unmapped"

# ---------------------------------------------------------------------------
# Section 3 — claude-providers sync end-to-end (offline, fixture catalog)
# Proves: alias creation, env files, config-dir linking, dedupe (one alias per
# provider), idempotency, and that the existing claudeN alias machinery is
# untouched. Uses CLAUDE_BIN=/usr/bin/true and --offline so nothing launches
# or hits the network.
# ---------------------------------------------------------------------------
PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"

# Seed the models.dev cache (offline) with a controlled catalog. mistral is
# present so the real key-aliases.json mapping CODESTRAL_API_KEY->mistral
# collides with MISTRAL_API_KEY -> exercises dedupe.
PCACHE="$HOME/.local/share/claude-multi-account/providers/models.dev.cache.json"
mkdir -p "$(dirname "$PCACHE")"
cat > "$PCACHE" <<'JSON'
{
  "acme":   {"env":["ACME_API_KEY"],"api":"https://api.acme.com/anthropic","npm":"@ai-sdk/anthropic",
             "models":{"b":{"id":"acme-big","reasoning":true,"release_date":"2025-05-01","limit":{"context":200000},"cost":{"input":3,"output":15},"tool_call":true},
                       "s":{"id":"acme-small","reasoning":false,"release_date":"2024-01-01","limit":{"context":32000},"cost":{"input":0.1,"output":0.4},"tool_call":true}}},
  "beta":   {"env":["BETA_API_KEY"],"api":"https://api.beta.ai/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"f":{"id":"beta-x","reasoning":false,"release_date":"2025-06-01","limit":{"context":128000},"cost":{"input":1,"output":5},"tool_call":true}}},
  "mistral":{"env":["MISTRAL_API_KEY"],"api":"https://api.mistral.ai/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"m":{"id":"mistral-large","reasoning":false,"release_date":"2025-04-01","limit":{"context":128000},"cost":{"input":2,"output":6},"tool_call":true}}},
  "zai-coding-plan":{"env":["ZAI_API_KEY"],"api":"https://api.z.ai/api/coding/paas/v4","npm":"@ai-sdk/openai-compatible",
             "models":{"g5.2":{"id":"glm-5.2","reasoning":true,"tool_call":true,"release_date":"2026-06-13","limit":{"context":1000000},"cost":{"input":0,"output":0}},
                       "g4.7":{"id":"glm-4.7","reasoning":true,"tool_call":true,"release_date":"2025-12-22","limit":{"context":204800},"cost":{"input":0,"output":0}}}},
  "xiaomi":{"env":["XIAOMI_API_KEY"],"api":"https://api.xiaomimimo.com/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"u":{"id":"mimo-v2.5-pro-ultraspeed","reasoning":true,"tool_call":true,"release_date":"2026-07-01","limit":{"context":1000000},"cost":{"input":0,"output":0}},
                       "p":{"id":"mimo-v2.5-pro","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":1000000},"cost":{"input":2,"output":8}},
                       "f":{"id":"mimo-v2-flash","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":256000},"cost":{"input":0.1,"output":0.4}}}}
}
JSON

# Fake keys file (NAMES only matter; values are dummy and never executed by us).
KEYS="$HOME/api_keys.sh"
cat > "$KEYS" <<'SH'
export ACME_API_KEY="dummy-acme"
export BETA_API_KEY="dummy-beta"
export MISTRAL_API_KEY="dummy-mistral"
export CODESTRAL_API_KEY="dummy-codestral"
export ZAI_API_KEY="dummy-zai"
export XIAOMI_MIMO_API_KEY="dummy-xiaomi"
export GITHUB_TOKEN="dummy-gh"
SH

# A pre-existing real account alias must survive untouched.
cma_write_alias claude1 "$HOME/.claude-acct1"

bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >/dev/null 2>&1
sync_rc=$?

it "sync exits cleanly"
assert_eq 0 "$sync_rc" "sync rc"

PDIR="$HOME/.local/share/claude-multi-account/providers"
it "env files created for each resolved provider"
assert_file "$PDIR/acme.env" "acme env"
assert_file "$PDIR/beta.env" "beta env"
assert_file "$PDIR/mistral.env" "mistral env"

it "provider aliases written via cma_run_provider"
grep -q '^alias acme="cma_run_provider acme"' "$ALIAS_FILE" ; assert_eq 0 $? "acme alias"
grep -q '^alias beta="cma_run_provider beta"' "$ALIAS_FILE" ; assert_eq 0 $? "beta alias"

it "CODESTRAL_API_KEY + MISTRAL_API_KEY dedupe to ONE mistral alias"
c="$(grep -c 'cma_run_provider mistral"' "$ALIAS_FILE")"
assert_eq "1" "$c" "exactly one mistral alias"

it "native vs router transport recorded in env file"
grep -qE "^CMA_PROVIDER_TRANSPORT='?native'?" "$PDIR/acme.env" ; assert_eq 0 $? "acme native"
grep -qE "^CMA_PROVIDER_TRANSPORT='?router'?" "$PDIR/beta.env" ; assert_eq 0 $? "beta router"

it "zai-coding-plan env file created with coding endpoint and strong/fast overrides"
assert_file "$PDIR/zai-coding-plan.env" "zai-coding-plan env"
grep -qE "^CMA_PROVIDER_BASE_URL='?https://api.z.ai/api/coding/paas/v4'?" "$PDIR/zai-coding-plan.env" ; assert_eq 0 $? "coding endpoint"
grep -qE "^CMA_PROVIDER_MODEL='?glm-5.2'?" "$PDIR/zai-coding-plan.env" ; assert_eq 0 $? "strong model glm-5.2"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?glm-4.7'?" "$PDIR/zai-coding-plan.env" ; assert_eq 0 $? "fast model glm-4.7"
grep -qE "^CMA_PROVIDER_TRANSPORT='?router'?" "$PDIR/zai-coding-plan.env" ; assert_eq 0 $? "zai-coding-plan router"

it "zai-coding-plan alias written via cma_run_provider"
grep -q '^alias zai-coding-plan="cma_run_provider zai-coding-plan"' "$ALIAS_FILE" ; assert_eq 0 $? "zai-coding-plan alias"

it "xiaomi env file created with native transport + /anthropic base + pinned models"
assert_file "$PDIR/xiaomi.env" "xiaomi env"
grep -qE "^CMA_PROVIDER_TRANSPORT='?native'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi native transport"
grep -qE "^CMA_PROVIDER_BASE_URL='?https://api.xiaomimimo.com/anthropic'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi /anthropic base"
grep -qE "^CMA_PROVIDER_MODEL='?mimo-v2.5-pro'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi strong model mimo-v2.5-pro"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?mimo-v2-flash'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi fast model mimo-v2-flash"
grep -qE "^CMA_PROVIDER_KEYVAR='?XIAOMI_MIMO_API_KEY'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi keyvar pinned"

it "xiaomi alias written via cma_run_provider"
grep -q '^alias xiaomi="cma_run_provider xiaomi"' "$ALIAS_FILE" ; assert_eq 0 $? "xiaomi alias"

it "config dir created and shared items symlinked"
assert_dir "$HOME/.claude-prov-acme" "acme config dir"
assert_symlink_to "$HOME/.claude-prov-acme/plugins" "$SHARED_DIR/plugins" "plugins linked"

it "xiaomi config dir created and shared items symlinked"
assert_dir "$HOME/.claude-prov-xiaomi" "xiaomi config dir"
assert_symlink_to "$HOME/.claude-prov-xiaomi/plugins" "$SHARED_DIR/plugins" "xiaomi plugins linked"

it "xiaomi provider dir excluded from account detection"
det="$(cma_detect_accounts)"
echo "$det" | grep -q "prov-xiaomi" ; assert_eq 1 $? "prov-xiaomi excluded from detection"

it "the existing claudeN alias is untouched"
grep -q '^alias claude1=' "$ALIAS_FILE" ; assert_eq 0 $? "claude1 still present"

it "provider dirs remain excluded from account detection after sync"
det="$(cma_detect_accounts)"
echo "$det" | grep -q "prov-acme" ; assert_eq 1 $? "prov-acme excluded"

it "no secret values leaked into env files or alias file"
grep -rq "dummy-acme\|dummy-beta\|dummy-mistral\|dummy-xiaomi" "$PDIR" "$ALIAS_FILE" ; assert_eq 1 $? "no key values present"

it "sync is idempotent — second run does not duplicate aliases"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >/dev/null 2>&1
c2="$(grep -c 'cma_run_provider acme"' "$ALIAS_FILE")"
assert_eq "1" "$c2" "still one acme alias after re-sync"
c2x="$(grep -c 'cma_run_provider xiaomi"' "$ALIAS_FILE")"
assert_eq "1" "$c2x" "still one xiaomi alias after re-sync"

it "list reports installed providers"
list_out="$(bash "$PROVIDERS_SH" list 2>/dev/null)"
echo "$list_out" | grep -q "acme" ; assert_eq 0 $? "list shows acme"

it "remove deletes alias + env, backs up config dir"
bash "$PROVIDERS_SH" remove beta >/dev/null 2>&1
[[ -f "$PDIR/beta.env" ]] ; assert_eq 1 $? "beta env gone"
grep -q 'cma_run_provider beta"' "$ALIAS_FILE" ; assert_eq 1 $? "beta alias gone"

# ---------------------------------------------------------------------------
# Section 4 — cross-shell wrapper smoke test (regression for the zsh
# `bad substitution` bug from ${!var} indirection). The alias file is sourced
# into the user's interactive shell, which is zsh on macOS — so the emitted
# cma_run_provider MUST work under zsh, not just bash. Guarded by zsh presence.
# ---------------------------------------------------------------------------
if command -v zsh >/dev/null 2>&1; then
  it "cma_run_provider runs under zsh (native transport) without bad substitution"
  # acme is the native-transport provider created in Section 3; its env file +
  # alias exist and $HOME/api_keys.sh defines ACME_API_KEY.
  z_out="$(CLAUDE_BIN=/usr/bin/true HOME="$HOME" zsh -c '
    emulate -L zsh
    source "'"$ALIAS_FILE"'" 2>&1
    cma_run_provider acme </dev/null
    echo "RC=$?"' 2>&1)"
  echo "$z_out" | grep -qi 'bad substitution' ; assert_eq 1 $? "no zsh bad substitution"
  echo "$z_out" | grep -q 'RC=0' ; assert_eq 0 $? "wrapper exits 0 under zsh"
else
  it "zsh smoke test (skipped — zsh not installed)"
  _pass "zsh not present; bash path covered elsewhere"
fi

summary
