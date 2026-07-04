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
  },
  "opencode": {
    "env": ["OPENCODE_API_KEY"],
    "api": "https://opencode.ai/zen/v1",
    "npm": "@ai-sdk/openai-compatible",
    "models": {
      "big-pickle": {"id":"big-pickle","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":200000},"cost":{"input":0,"output":0}},
      "deepseek-v4-flash-free": {"id":"deepseek-v4-flash-free","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":200000},"cost":{"input":0,"output":0}},
      "nemotron-3-ultra-free": {"id":"nemotron-3-ultra-free","reasoning":true,"tool_call":true,"release_date":"2026-04-01","limit":{"context":1000000},"cost":{"input":0,"output":0}},
      "ling-2.6-flash-free": {"id":"ling-2.6-flash-free","reasoning":false,"tool_call":true,"release_date":"2026-03-01","limit":{"context":262100},"cost":{"input":0,"output":0}},
      "trinity-large-preview-free": {"id":"trinity-large-preview-free","reasoning":false,"tool_call":true,"release_date":"2026-02-01","limit":{"context":131072},"cost":{"input":0,"output":0}}
    }
  }
}
JSON

cat > "$FIX/key-aliases.json" <<'JSON'
{ "LEGACY_BETA_KEY": "beta", "XIAOMI_MIMO_API_KEY": "xiaomi", "ZEN_API_KEY": "opencode", "ApiKey_Opencode_Zen": "opencode" }
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
  },
  "opencode": {
    "strong_model": "big-pickle",
    "fast_model": "deepseek-v4-flash-free"
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
  --keys "ACME_API_KEY,BETA_API_KEY,ZAI_API_KEY,LEGACY_BETA_KEY,XIAOMI_MIMO_API_KEY,ZEN_API_KEY,ApiKey_Opencode_Zen,GITHUB_TOKEN,FOO_API_KEY" > "$OUT"
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
cond=1; [[ "$(rfield "$OUT" XIAOMI_MIMO_API_KEY strong_model)" != "mimo-v2.5-pro-ultraspeed" ]] && cond=0; assert_eq 0 "$cond" "ultraspeed not strong"
cond=1; [[ "$(rfield "$OUT" XIAOMI_MIMO_API_KEY fast_model)" != "mimo-v2.5-pro-ultraspeed" ]] && cond=0; assert_eq 0 "$cond" "ultraspeed not fast"

it "opencode resolves from the key-alias mapping on ZEN_API_KEY"
assert_eq "opencode" "$(rfield "$OUT" ZEN_API_KEY provider_id)" "opencode provider_id"
assert_eq "resolved" "$(rfield "$OUT" ZEN_API_KEY status)" "opencode resolved"

it "ApiKey_Opencode_Zen also resolves to opencode via secondary key-alias"
assert_eq "opencode" "$(rfield "$OUT" ApiKey_Opencode_Zen provider_id)" "ApiKey_Opencode_Zen -> opencode"
assert_eq "resolved" "$(rfield "$OUT" ApiKey_Opencode_Zen status)" "ApiKey_Opencode_Zen resolved"

it "opencode uses router transport (openai-compatible npm)"
assert_eq "router" "$(rfield "$OUT" ZEN_API_KEY transport)" "opencode router"

it "opencode base_url from catalog (zen/v1 endpoint)"
assert_eq "https://opencode.ai/zen/v1" "$(rfield "$OUT" ZEN_API_KEY base_url)" "opencode zen/v1 base"

it "opencode override forces big-pickle as strong (beats nemotron-3-ultra-free auto-selection)"
assert_eq "big-pickle" "$(rfield "$OUT" ZEN_API_KEY strong_model)" "strong=big-pickle"
cond=1; [[ "$(rfield "$OUT" ZEN_API_KEY strong_model)" != "nemotron-3-ultra-free" ]] && cond=0; assert_eq 0 "$cond" "nemotron not strong"

it "opencode override forces deepseek-v4-flash-free as fast (beats trinity auto-selection)"
assert_eq "deepseek-v4-flash-free" "$(rfield "$OUT" ZEN_API_KEY fast_model)" "fast=deepseek-v4-flash-free"
cond=1; [[ "$(rfield "$OUT" ZEN_API_KEY fast_model)" != "trinity-large-preview-free" ]] && cond=0; assert_eq 0 "$cond" "trinity not fast"

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
                       "f":{"id":"mimo-v2-flash","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":256000},"cost":{"input":0.1,"output":0.4}}}},
  "opencode":{"env":["OPENCODE_API_KEY"],"api":"https://opencode.ai/zen/v1","npm":"@ai-sdk/openai-compatible",
             "models":{"bp":{"id":"big-pickle","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":200000},"cost":{"input":0,"output":0}},
                       "df":{"id":"deepseek-v4-flash-free","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":200000},"cost":{"input":0,"output":0}},
                       "nu":{"id":"nemotron-3-ultra-free","reasoning":true,"tool_call":true,"release_date":"2026-04-01","limit":{"context":1000000},"cost":{"input":0,"output":0}}}}
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
export ZEN_API_KEY="dummy-zen"
export ApiKey_Opencode_Zen="dummy-zen-2"
export GITHUB_TOKEN="dummy-gh"
SH

# A pre-existing real account alias must survive untouched.
cma_write_alias claude1 "$HOME/.claude-acct1"

bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >/dev/null 2>&1
sync_rc=$?

it "sync exits cleanly"
assert_eq 0 "$sync_rc" "sync rc"

it "sync persists per-provider verification status (--no-verify -> unverified)"
# With --no-verify, vstatus defaults to 'unverified' for every resolved
# provider, and cmd_sync must record it in the status cache so the list family
# + activation gate have a source of truth.
assert_file "$(cma_status_cache)" "status cache written by sync"
assert_eq "unverified" "$(cma_status_read acme)"    "acme status persisted"
assert_eq "unverified" "$(cma_status_read mistral)" "mistral status persisted"
assert_eq "unverified" "$(cma_status_read opencode)" "opencode status persisted"
assert_file_not_contains "$(cma_status_cache)" "dummy-" "no dummy key values leaked into status cache"

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

it "opencode env file created with router transport + zen/v1 base + pinned models"
assert_file "$PDIR/opencode.env" "opencode env"
grep -qE "^CMA_PROVIDER_TRANSPORT='?router'?" "$PDIR/opencode.env" ; assert_eq 0 $? "opencode router transport"
grep -qE "^CMA_PROVIDER_BASE_URL='?https://opencode.ai/zen/v1'?" "$PDIR/opencode.env" ; assert_eq 0 $? "opencode zen/v1 base"
grep -qE "^CMA_PROVIDER_MODEL='?big-pickle'?" "$PDIR/opencode.env" ; assert_eq 0 $? "opencode strong model big-pickle"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?deepseek-v4-flash-free'?" "$PDIR/opencode.env" ; assert_eq 0 $? "opencode fast model deepseek-v4-flash-free"
# The resolver picks the first key that maps to 'opencode' after alphabetical sort
# by present_key_vars: ApiKey_Opencode_Zen < ZEN_API_KEY, so it wins as keyvar.
grep -qE "^CMA_PROVIDER_KEYVAR='?ApiKey_Opencode_Zen'?" "$PDIR/opencode.env" ; assert_eq 0 $? "opencode keyvar ApiKey_Opencode_Zen"

it "opencode alias written via cma_run_provider"
grep -q '^alias opencode="cma_run_provider opencode"' "$ALIAS_FILE" ; assert_eq 0 $? "opencode alias"

it "opencode config dir created and shared items symlinked"
assert_dir "$HOME/.claude-prov-opencode" "opencode config dir"
assert_symlink_to "$HOME/.claude-prov-opencode/plugins" "$SHARED_DIR/plugins" "opencode plugins linked"

it "opencode provider dir excluded from account detection"
det="$(cma_detect_accounts)"
echo "$det" | grep -q "prov-opencode" ; assert_eq 1 $? "prov-opencode excluded from detection"

it "the existing claudeN alias is untouched"
grep -q '^alias claude1=' "$ALIAS_FILE" ; assert_eq 0 $? "claude1 still present"

it "provider dirs remain excluded from account detection after sync"
det="$(cma_detect_accounts)"
echo "$det" | grep -q "prov-acme" ; assert_eq 1 $? "prov-acme excluded"

it "no secret values leaked into env files or alias file"
grep -rq "dummy-acme\|dummy-beta\|dummy-mistral\|dummy-xiaomi\|dummy-zen" "$PDIR" "$ALIAS_FILE" ; assert_eq 1 $? "no key values present"

it "sync is idempotent — second run does not duplicate aliases"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >/dev/null 2>&1
c2="$(grep -c 'cma_run_provider acme"' "$ALIAS_FILE")"
assert_eq "1" "$c2" "still one acme alias after re-sync"
c2x="$(grep -c 'cma_run_provider xiaomi"' "$ALIAS_FILE")"
assert_eq "1" "$c2x" "still one xiaomi alias after re-sync"
c2z="$(grep -c 'cma_run_provider opencode"' "$ALIAS_FILE")"
assert_eq "1" "$c2z" "still one opencode alias after re-sync"

it "list family splits by status: list=verified, list-all=all, list-faulty=faulty"
# Section 3 synced with --no-verify, so every provider is 'unverified'.
# list (verified-only) hides them; list-all + list-faulty show them.
la_out="$(bash "$PROVIDERS_SH" list-all 2>/dev/null)"
echo "$la_out" | grep -q "acme"; assert_eq 0 $? "list-all shows unverified acme"
lf_out="$(bash "$PROVIDERS_SH" list-faulty 2>/dev/null)"
echo "$lf_out" | grep -q "acme"; assert_eq 0 $? "list-faulty shows unverified acme"
l_out="$(bash "$PROVIDERS_SH" list 2>/dev/null)"
echo "$l_out" | grep -q "acme" && _seen=1 || _seen=0
assert_eq 0 "$_seen" "list (verified-only) hides unverified acme"
# Mark acme verified -> now it appears under list and disappears from list-faulty.
cma_status_write acme verified acme-big ""
l_out2="$(bash "$PROVIDERS_SH" list 2>/dev/null)"
echo "$l_out2" | grep -q "acme"; assert_eq 0 $? "list shows acme once verified"
lf_out2="$(bash "$PROVIDERS_SH" list-faulty 2>/dev/null)"
echo "$lf_out2" | grep -q "acme" && _seen2=1 || _seen2=0
assert_eq 0 "$_seen2" "list-faulty hides acme once verified"
# Restore acme to unverified so later sections see the sync-time state.
cma_status_write acme unverified acme-big semantic

it "remove deletes alias + env, backs up config dir"
bash "$PROVIDERS_SH" remove beta >/dev/null 2>&1
cond=0; [[ -f "$PDIR/beta.env" ]] && cond=1; assert_eq 0 "$cond" "beta env gone"
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
  # alias exist and $HOME/api_keys.sh defines ACME_API_KEY. Mark it verified so
  # the launch-time activation gate permits the launch and the zsh indirect
  # key-read (${!var}) path this test targets is actually exercised.
  cma_status_write acme verified acme-big ""
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

# ---------------------------------------------------------------------------
# Section 5 — cross-alias session visibility. Sessions created under any
# alias (claudeN or provider) must be visible from every other alias after
# sync-state runs. This proves the .claude.json merge includes provider dirs.
# ---------------------------------------------------------------------------
SYNC_SH="$SCRIPTS_DIR/claude-sync-state.sh"

# Create two accounts and one provider dir, each with a .claude.json that
# contains a unique session entry.
make_account xacct1
make_account xacct2
mkdir -p "$HOME/${ACCOUNT_PREFIX}prov-zen"
# Provider dir needs the same marker files as a real provider dir.
mkdir -p "$HOME/${ACCOUNT_PREFIX}prov-zen/projects"

# Each .claude.json has a unique project/session entry to prove merge.
cat > "$HOME/${ACCOUNT_PREFIX}xacct1/.claude.json" <<'JSON'
{"projects":{"/tmp/projectA":{"sessionId":"sess-a1","lastActive":"2026-06-20T10:00:00Z"}}}
JSON
cat > "$HOME/${ACCOUNT_PREFIX}xacct2/.claude.json" <<'JSON'
{"projects":{"/tmp/projectB":{"sessionId":"sess-b2","lastActive":"2026-06-20T11:00:00Z"}}}
JSON
cat > "$HOME/${ACCOUNT_PREFIX}prov-zen/.claude.json" <<'JSON'
{"projects":{"/tmp/projectC":{"sessionId":"sess-cz","lastActive":"2026-06-20T12:00:00Z"}}}
JSON

it "sync-state merge includes provider dirs"
# Run sync-state all to merge .claude.json across accounts + providers.
bash "$SYNC_SH" all 2>/dev/null
sync_rc=$?
assert_eq 0 "$sync_rc" "sync-state all exit 0"

it "session from account1 is visible in account2 after sync"
acct2_has_a1="$(python3 -c "import json; d=json.load(open('$HOME/${ACCOUNT_PREFIX}xacct2/.claude.json')); print('sess-a1' in str(d))" 2>/dev/null)"
assert_eq "True" "$acct2_has_a1" "acct2 sees sess-a1"

it "session from provider dir is visible in account1 after sync"
acct1_has_cz="$(python3 -c "import json; d=json.load(open('$HOME/${ACCOUNT_PREFIX}xacct1/.claude.json')); print('sess-cz' in str(d))" 2>/dev/null)"
assert_eq "True" "$acct1_has_cz" "acct1 sees sess-cz"

it "session from provider dir is visible in account2 after sync"
acct2_has_cz="$(python3 -c "import json; d=json.load(open('$HOME/${ACCOUNT_PREFIX}xacct2/.claude.json')); print('sess-cz' in str(d))" 2>/dev/null)"
assert_eq "True" "$acct2_has_cz" "acct2 sees sess-cz"

it "session from account1 is visible in provider dir after sync"
zen_has_a1="$(python3 -c "import json; d=json.load(open('$HOME/${ACCOUNT_PREFIX}prov-zen/.claude.json')); print('sess-a1' in str(d))" 2>/dev/null)"
assert_eq "True" "$zen_has_a1" "prov-zen sees sess-a1"

it "session from account2 is visible in provider dir after sync"
zen_has_b2="$(python3 -c "import json; d=json.load(open('$HOME/${ACCOUNT_PREFIX}prov-zen/.claude.json')); print('sess-b2' in str(d))" 2>/dev/null)"
assert_eq "True" "$zen_has_b2" "prov-zen sees sess-b2"

it "cma_run_provider wrapper has sync-state pull+push in alias file"
grep -q 'claude-sync-state.*pull' "$ALIAS_FILE" ; assert_eq 0 $? "pull present in wrapper"
grep -q 'claude-sync-state.*push' "$ALIAS_FILE" ; assert_eq 0 $? "push present in wrapper"

it "cma_run wrapper also has sync-state pull+push"
# Extract the FULL cma_run body (header → its column-0 closing brace) instead of a
# fixed `grep -A<N>` window: the body grows (provider-env isolation + auto session
# blocks), and a fixed window silently drops late markers like 'push' (which now
# sits ~30 lines in). Same robust pattern as test_claude.sh's _cma_run_body.
_run_body="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
printf '%s\n' "$_run_body" | grep -q 'claude-sync-state.*pull' ; assert_eq 0 $? "cma_run pull"
printf '%s\n' "$_run_body" | grep -q 'claude-sync-state.*push' ; assert_eq 0 $? "cma_run push"

it "cma_run has provider-env isolation (clears leaked ANTHROPIC_* before native launch)"
printf '%s\n' "$_run_body" | grep -q 'unset ANTHROPIC_BASE_URL' ; assert_eq 0 $? "cma_run unsets ANTHROPIC_BASE_URL"

it "migration regenerating cma_run does NOT drop it (BRE empty-group \\(\\) bug regression)"
# Reproduce the exact failure: an OLD-format alias file with a cma_run lacking
# the 'unset ANTHROPIC_' marker, followed by cma_run_provider() and a claudeN
# alias. The buggy guard `grep '^cma_run\(\)'` matched cma_run_provider() too
# (empty capture group = matches "cma_run" prefix), so after stripping cma_run
# the re-append was skipped and the function vanished. With literal `()` it must
# strip-and-re-append cma_run, keep cma_run_provider, and preserve the alias.
_mig="$ALIAS_FILE.migtest"
cat > "$_mig" <<'OLDFMT'
export CLAUDE_BIN="/usr/bin/true"

cma_run() {
  "$CLAUDE_BIN" "$@"
}

cma_run_provider() {
  echo old
}

alias claude1="CLAUDE_CONFIG_DIR=$HOME/.claude-acct1 cma_run"
OLDFMT
( ALIAS_FILE="$_mig" cma_ensure_alias_file ) >/dev/null 2>&1
mig_run="$(grep -c '^cma_run()' "$_mig")"
mig_prov="$(grep -c '^cma_run_provider()' "$_mig")"
mig_alias="$(grep -c '^alias claude1=' "$_mig")"
mig_unset="$(grep -c 'unset ANTHROPIC_BASE_URL' "$_mig")"
assert_eq 1 "$mig_run"   "cma_run re-appended after migration (not dropped)"
assert_eq 1 "$mig_prov"  "cma_run_provider preserved"
assert_eq 1 "$mig_alias" "claudeN alias preserved through migration"
assert_eq 1 "$mig_unset" "regenerated cma_run carries the env-isolation fix"
rm -f "$_mig"

# --- input-context token-limit guard (CLAUDE_CODE_AUTO_COMPACT_WINDOW) --------
# Fixes "400 exceeded model token limit: 262144 (requested: 311786)": the
# emitted cma_run_provider must export CLAUDE_CODE_AUTO_COMPACT_WINDOW from the
# provider's resolved CMA_PROVIDER_CONTEXT_LIMIT so Claude Code auto-compacts
# before overflowing a smaller provider's input window. The export is guarded so
# an unknown/empty limit is NOT exported, and sits BEFORE the transport branch
# so it applies to both native and router transports.
it "emitted cma_run_provider exports CLAUDE_CODE_AUTO_COMPACT_WINDOW from CMA_PROVIDER_CONTEXT_LIMIT (input token-limit guard)"
_acw_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
# shellcheck disable=SC2016  # literal EMITTED code, not for expansion here
printf '%s\n' "$_acw_body" | grep -qF 'CLAUDE_CODE_AUTO_COMPACT_WINDOW="$CMA_PROVIDER_CONTEXT_LIMIT"'
assert_eq 0 $? "auto-compact-window exported from CMA_PROVIDER_CONTEXT_LIMIT"
# shellcheck disable=SC2016
printf '%s\n' "$_acw_body" | grep -q 'CMA_PROVIDER_CONTEXT_LIMIT:-'
assert_eq 0 $? "export is guarded by [[ -n \${CMA_PROVIDER_CONTEXT_LIMIT:-} ]]"

it "cma_run_provider does NOT export the window when CMA_PROVIDER_CONTEXT_LIMIT is empty/unknown"
# Static-body check: the export line is conditional — immediately preceded by
# the [[ -n "${CMA_PROVIDER_CONTEXT_LIMIT:-}" ]] guard — so an empty/unknown
# limit never exports a bogus window.
# shellcheck disable=SC2016
printf '%s\n' "$_acw_body" | grep -B1 'export CLAUDE_CODE_AUTO_COMPACT_WINDOW' | grep -q 'CMA_PROVIDER_CONTEXT_LIMIT:-'
assert_eq 0 $? "export CLAUDE_CODE_AUTO_COMPACT_WINDOW is guarded on the preceding line"

it "migration regenerates an outdated cma_run_provider that lacks the auto-compact-window guard"
# Mirror the cma_run migration regression above, for the new marker. Build an
# OLD-format alias file whose cma_run_provider carries ALL other current markers
# (claude-sync-state, set -a +u, claude-session, apply-color, '>| "$tmp"') but is
# MISSING CLAUDE_CODE_AUTO_COMPACT_WINDOW. Rather than hand-write the body, take
# the CURRENT emitted body and strip only the two auto-compact lines (the export
# plus its guard continuation) so the body stays valid bash and migration fires
# solely on the absent marker.
_mig2="$ALIAS_FILE.migtest2"
{
  printf 'export CLAUDE_BIN="/usr/bin/true"\n\n'
  printf '%s\n' "$_acw_body" | grep -v 'CLAUDE_CODE_AUTO_COMPACT_WINDOW' | grep -v 'CMA_PROVIDER_CONTEXT_LIMIT:-'
  printf '\nalias kimi-for-coding="cma_run_provider kimi-for-coding"\n'
} > "$_mig2"
bash -n "$_mig2"; assert_eq 0 $? "old-format alias file parses (bash -n)"
grep -q 'CLAUDE_CODE_AUTO_COMPACT_WINDOW' "$_mig2"; assert_eq 1 $? "old body lacks auto-compact-window marker (pre-migration)"
( ALIAS_FILE="$_mig2" cma_ensure_alias_file ) >/dev/null 2>&1
mig2_prov="$(grep -c '^cma_run_provider()' "$_mig2")"
mig2_alias="$(grep -c '^alias kimi-for-coding=' "$_mig2")"
mig2_acw="$(printf '%s\n' "$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$_mig2")" | grep -c 'export CLAUDE_CODE_AUTO_COMPACT_WINDOW')"
assert_eq 1 "$mig2_prov"  "exactly one cma_run_provider() after migration"
assert_eq 1 "$mig2_alias" "kimi-for-coding alias preserved through migration"
assert_eq 1 "$mig2_acw"   "regenerated cma_run_provider now exports auto-compact-window"
rm -f "$_mig2"

# --- set -e/pipefail guard: a provider whose alias line is absent ------------
# claude-providers.sh runs `set -euo pipefail`. cmd_list/cmd_remove resolve the
# alias name via `grep ... | sed | head -1`; under pipefail a no-match grep
# (exit 1) aborted the subshell/function. A provider .env can legitimately have
# no alias line (manual edit, partial setup). These EXECUTE the real script.
it "claude-providers list-all does NOT abort on a provider with no alias line"
# Exercised via list-all (not list): ghost has no status entry -> 'pending', so
# verified-only `list` would filter it out BEFORE the alias-less grep runs.
# list-all shows every status, so ghost passes the filter and the alias-less
# grep|sed|head pipeline is actually exercised (the pipefail-abort regression).
mkdir -p "$PDIR"
cat > "$PDIR/ghost.env" <<'GHOST'
CMA_PROVIDER_ID='ghost'
CMA_PROVIDER_TRANSPORT='native'
CMA_PROVIDER_BASE_URL='https://ghost.example/anthropic'
CMA_PROVIDER_MODEL='ghost-model'
CMA_PROVIDER_FAST_MODEL='ghost-fast'
CMA_PROVIDER_KEYVAR='GHOST_API_KEY'
GHOST
list_out="$(bash "$PROVIDERS_SH" list-all 2>/dev/null)"; list_rc=$?
assert_eq 0 "$list_rc" "list-all exits 0 (no abort on the alias-less provider)"
printf '%s\n' "$list_out" | grep -q 'ghost'; assert_eq 0 $? "list-all still shows the alias-less provider"

it "claude-providers remove does NOT abort on a provider with no alias line"
bash "$PROVIDERS_SH" remove ghost >/dev/null 2>&1; rm_rc=$?
assert_eq 0 "$rm_rc" "remove exits 0 (no abort before deleting the env)"
still=0; [[ -f "$PDIR/ghost.env" ]] && still=1
assert_eq 0 "$still" "remove actually deleted the provider env file"

# --- 'null' normalization: a missing JSON field (jq -r -> "null") must never ---
# land in the env file as a bogus value. base/fast/context/max were normalized
# but model+transport were missed -> CMA_PROVIDER_MODEL='null' broke launches.
it "cma_provider_write_env: a 'null' model/transport/base is normalized to empty"
cma_provider_write_env "nulltest" "NT_KEY" "null" "null" "null" "null" "$SANDBOX_HOME/.cdir" "null" "null" >/dev/null 2>&1
_nf="$(cma_providers_dir)/nulltest.env"
grep -q "^CMA_PROVIDER_MODEL=''" "$_nf";     assert_eq 0 $? "null strong_model normalized to empty (not 'null')"
grep -q "^CMA_PROVIDER_TRANSPORT=''" "$_nf"; assert_eq 0 $? "null transport normalized to empty"
grep -q "^CMA_PROVIDER_BASE_URL=''" "$_nf";  assert_eq 0 $? "null base_url normalized to empty"
_hasnull=0; grep -qE "CMA_PROVIDER_(MODEL|TRANSPORT|BASE_URL|FAST_MODEL|CONTEXT_LIMIT|MAX_OUTPUT)='null'" "$_nf" && _hasnull=1
assert_eq 0 "$_hasnull" "no provider field contains the literal string 'null'"

# noclobber regression: cma_run_provider is a FUNCTION that runs in the user's
# interactive shell, which may have `set -o noclobber`. A bare `> "$tmp"` onto the
# just-created mktemp file fails there ("cannot overwrite existing file"), silently
# dropping the router-config update so EVERY router-transport provider breaks. The
# emitted function must use the force-clobber operator `>|`.
it "cma_run_provider router-config write is noclobber-safe (>| not bare >)"
_prov_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
# shellcheck disable=SC2016  # literal $tmp intended: we grep the EMITTED code, not expand it
printf '%s\n' "$_prov_body" | grep -q '>| "\$tmp"'; assert_eq 0 $? "router jq write uses force-clobber >|"
_bare=0
# shellcheck disable=SC2016
printf '%s\n' "$_prov_body" | grep -qE '> "\$tmp"' && _bare=1
assert_eq 0 "$_bare" "no bare '> \$tmp' write remains in cma_run_provider"

it "noclobber proof: bare > is blocked on an existing mktemp file, >| succeeds"
_nc_t="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
_blocked=0; ( set -o noclobber; echo x > "$_nc_t" ) 2>/dev/null || _blocked=1
_forced=0;  ( set -o noclobber; echo y >| "$_nc_t" ) 2>/dev/null && _forced=1
assert_eq 1 "$_blocked" "bare '>' blocked by noclobber"
assert_eq 1 "$_forced"  "'>|' force-clobber works under noclobber"
rm -f "$_nc_t"

# ---------------------------------------------------------------------------
# Section 6 — verification status cache (single source of truth for the list
# family + the launch-time activation gate). Non-secret metadata only.
# ---------------------------------------------------------------------------
# Start from a clean cache: earlier sections (Section 3's `sync`) share this
# sandbox $HOME and already populated status.json, so reset for deterministic
# absolute-count assertions (§11.4.50).
rm -f "$(cma_status_cache)"

it "unknown provider id reads as 'pending'"
assert_eq "pending" "$(cma_status_read no_such_provider)" "unknown id -> pending"

it "cma_status_write persists a status readable by cma_status_read"
cma_status_write st_deepseek verified deepseek-chat ""
assert_eq "verified" "$(cma_status_read st_deepseek)" "wrote + read verified"
assert_jq "$(cma_status_cache)" '.st_deepseek.model' "deepseek-chat" "model persisted"
assert_jq "$(cma_status_cache)" '.st_deepseek.failing_layer' "" "verified has empty failing_layer"

it "cma_status_write upserts (overwrites same id, no duplicate record)"
cma_status_write st_deepseek unverified deepseek-chat semantic
assert_eq "unverified" "$(cma_status_read st_deepseek)" "upsert changed status"
assert_jq "$(cma_status_cache)" '.st_deepseek.failing_layer' "semantic" "failing_layer recorded"
assert_jq "$(cma_status_cache)" '. | length' "1" "still exactly one record (upsert, not append)"

it "cma_status_all lists every record as tab-separated rows"
cma_status_write st_groq failed llama-3 existence
assert_eq "2" "$(cma_status_all | wc -l | tr -d ' ')" "two records listed"
_all="$(cma_status_all)"
printf '%s\n' "$_all" | grep -qF "st_groq	failed	llama-3	" ; assert_eq 0 $? "groq row present with fields"

it "no secret/key material is ever written into the status cache"
assert_file_not_contains "$(cma_status_cache)" "sk-" "no bearer-token prefix in cache"
assert_file_not_contains "$(cma_status_cache)" "Bearer" "no Authorization header in cache"

# Clean the status cache so later sections start fresh.
rm -f "$(cma_status_cache)"

# ---------------------------------------------------------------------------
# Section 7 — launch-time activation gate in cma_run_provider. Only a
# 'verified' alias brings up Claude Code; others refuse with an actionable
# message. --force overrides. Uses acme (native transport, from Section 3) +
# CLAUDE_BIN=/usr/bin/true so a permitted launch exits 0 without a real claude.
# ---------------------------------------------------------------------------

it "activation gate: unverified alias refuses to launch (rc 3, actionable message)"
cma_status_write acme unverified acme-big semantic
_g_out="$( ( source "$ALIAS_FILE"; cma_run_provider acme ) 2>&1 )"; _g_rc=$?
assert_eq 3 "$_g_rc" "unverified alias returns 3 (gate refused)"
printf '%s\n' "$_g_out" | grep -q 'not launching'; assert_eq 0 $? "gate prints 'not launching'"
printf '%s\n' "$_g_out" | grep -q 'claude-providers sync'; assert_eq 0 $? "gate suggests re-verify via sync"

it "activation gate: failed alias also refuses"
cma_status_write acme failed acme-big existence
( source "$ALIAS_FILE"; cma_run_provider acme ) >/dev/null 2>&1; assert_eq 3 $? "failed alias returns 3"

it "activation gate: pending (no cache entry) refuses"
rm -f "$(cma_status_cache)"
( source "$ALIAS_FILE"; cma_run_provider acme ) >/dev/null 2>&1; assert_eq 3 $? "pending alias returns 3"

it "activation gate: verified alias launches (CLAUDE_BIN=/usr/bin/true -> rc 0)"
cma_status_write acme verified acme-big ""
( source "$ALIAS_FILE"; cma_run_provider acme ) >/dev/null 2>&1; assert_eq 0 $? "verified alias launches"

it "activation gate: --force overrides a non-verified status (both arg positions)"
cma_status_write acme failed acme-big existence
( source "$ALIAS_FILE"; cma_run_provider acme --force ) >/dev/null 2>&1; assert_eq 0 $? "--force after id launches"
( source "$ALIAS_FILE"; cma_run_provider --force acme ) >/dev/null 2>&1; assert_eq 0 $? "--force before id launches"

it "activation gate is present in the emitted cma_run_provider body"
_gate_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
printf '%s\n' "$_gate_body" | grep -qF '_cma_force'; assert_eq 0 $? "emitted body carries the --force/gate marker"

rm -f "$(cma_status_cache)"

# ---------------------------------------------------------------------------
# Section 8 — 'list --refresh-aliases --quiet': rebuild alias lines from the
# cached env files with NO network (the session hook's fast path). Requires the
# env file to persist CMA_PROVIDER_ALIAS (written by cma_provider_write_env).
# ---------------------------------------------------------------------------

it "env files persist CMA_PROVIDER_ALIAS (the no-network refresh source)"
assert_file_contains "$PDIR/acme.env" "CMA_PROVIDER_ALIAS='acme'" "acme env carries its alias name"

it "--refresh-aliases rebuilds a removed alias line from cache (no network)"
cma_remove_alias acme
grep -q '^alias acme="cma_run_provider acme"' "$ALIAS_FILE" && _pre=1 || _pre=0
assert_eq 0 "$_pre" "acme alias line removed (precondition)"
bash "$PROVIDERS_SH" list --refresh-aliases --quiet >/dev/null 2>&1
grep -q '^alias acme="cma_run_provider acme"' "$ALIAS_FILE"; assert_eq 0 $? "acme alias restored by refresh"

it "--refresh-aliases is idempotent"
_rb="$(cat "$ALIAS_FILE")"
bash "$PROVIDERS_SH" list --refresh-aliases --quiet >/dev/null 2>&1
assert_eq "$_rb" "$(cat "$ALIAS_FILE")" "second refresh yields an identical alias file"

it "--quiet suppresses the refresh log line (non-quiet emits it)"
_noisy="$(bash "$PROVIDERS_SH" list --refresh-aliases 2>&1 >/dev/null)"
printf '%s' "$_noisy" | grep -q refreshed; assert_eq 0 $? "non-quiet refresh logs 'refreshed'"
_quiet="$(bash "$PROVIDERS_SH" list --refresh-aliases --quiet 2>&1 >/dev/null)"
printf '%s' "$_quiet" | grep -q refreshed && _q=1 || _q=0
assert_eq 0 "$_q" "quiet refresh suppresses the log"

# ---------------------------------------------------------------------------
# Section 9 — install-time session-sync hook (cma_install_session_hook). The
# hook refreshes aliases from cache on every shell (no network) + kicks a
# detached full sync only when status.json is stale (TTL). Marker-bracketed,
# idempotent. status.json is absent here (Section 7 removed it), so no
# background sync spawns — deterministic.
# ---------------------------------------------------------------------------

it "cma_install_session_hook installs a marker-bracketed refresh block"
cma_install_session_hook
assert_eq "1" "$(grep -c 'cma-providers-session-refresh BEGIN' "$ALIAS_FILE")" "one BEGIN marker"
assert_eq "1" "$(grep -c 'cma-providers-session-refresh END' "$ALIAS_FILE")" "one END marker"
assert_file_contains "$ALIAS_FILE" "list --quiet --refresh-aliases" "hook uses the no-network refresh path"
assert_file_contains "$ALIAS_FILE" "CMA_PROVIDERS_SYNC_TTL" "hook honours the TTL knob"

it "cma_install_session_hook is idempotent (re-install replaces, no duplicate)"
cma_install_session_hook
assert_eq "1" "$(grep -c 'cma-providers-session-refresh BEGIN' "$ALIAS_FILE")" "still one BEGIN after re-install"
assert_eq "1" "$(grep -c 'cma_providers_session_refresh()' "$ALIAS_FILE")" "still one function definition"

it "sourcing the alias file fires the hook without error and with no network"
( source "$ALIAS_FILE" ) >/dev/null 2>&1
assert_eq 0 $? "sourcing (hook fires) succeeds offline"

# ---------------------------------------------------------------------------
# Section — semantic-code-visibility driver (claude-semantic-visibility.sh)
# Hermetic: a fake `go` on PATH "builds" a stub binary that echoes its argv,
# proving the driver caches + forwards flags without a real toolchain/network.
# ---------------------------------------------------------------------------
SEMDRV="$SCRIPTS_DIR/claude-semantic-visibility.sh"
_sem_bin="$HOME/.local-cache/semantic-code-visibility"
mkdir -p "$HOME/fakebin"
# Fake `go`: `go build -o <out> ./cmd/...` writes a stub that prints its args.
cat > "$HOME/fakebin/go" <<'FAKEGO'
#!/usr/bin/env bash
if [[ "$1" == build ]]; then
  out=""; while (($#)); do [[ "$1" == -o ]] && { out="$2"; shift 2; continue; }; shift; done
  printf '#!/usr/bin/env bash\nprintf "SCV-STUB %%s\\n" "$*"\nexit 0\n' > "$out"; chmod +x "$out"; exit 0
fi
exit 0
FAKEGO
chmod +x "$HOME/fakebin/go"

it "claude-semantic-visibility.sh builds (cached) + forwards flags to the binary"
rm -f "$_sem_bin"
out="$( PATH="$HOME/fakebin:$PATH" LLMSVERIFIER_DIR="$SCRIPTS_DIR/../submodules/LLMsVerifier" \
        LV_SEMANTIC_BIN="$_sem_bin" bash "$SEMDRV" --model m --sentinel Z 2>/dev/null )"
printf '%s\n' "$out" | grep -q 'SCV-STUB' ; assert_eq 0 $? "driver execs the built binary"
printf '%s\n' "$out" | grep -q -- '--sentinel Z' ; assert_eq 0 $? "driver forwards flags verbatim"
assert_file "$_sem_bin" "binary was cached under .local-cache"

summary
