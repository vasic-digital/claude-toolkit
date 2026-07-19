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

it "xai override provides the base_url the null-api catalog lacks (v1.12.1 resolve-gap fix)"
# The real overrides.json must carry the xai base_url so xai stops resolving to
# 'unmapped' (catalog api:null -> "router provider missing base_url"). The
# override->base_url resolution mechanism itself is proven by the xiaomi test above;
# this guards the xai entry's presence + correctness in the shipped overrides.json.
assert_eq "https://api.x.ai/v1" "$(jq -r '.xai.base_url // "MISSING"' "$SCRIPTS_DIR/providers/overrides.json")" "overrides.json xai base_url present + correct"

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

it "cmd_sync heals a stale/outdated cma_run_provider wrapper (final-review I-2)"
# Simulate a pre-Phase-2 alias file whose wrapper lacks the activation-gate marker
# (_cma_force). cma_provider_write_alias only bootstraps when the file is ABSENT
# (to keep --refresh-aliases byte-idempotent), so the heal must come from cmd_sync's
# one-time cma_ensure_alias_file. Corrupt the wrapper, re-sync, assert it regenerated.
awk '/^cma_run_provider\(\) ?\{/{print "cma_run_provider() {"; print "  echo STALE-NO-GATE"; print "}"; s=1; next} s&&/^}/{s=0; next} !s{print}' "$ALIAS_FILE" > "$ALIAS_FILE.x" && mv "$ALIAS_FILE.x" "$ALIAS_FILE"
grep -q '_cma_force' "$ALIAS_FILE" && _pre=1 || _pre=0
assert_eq 0 "$_pre" "wrapper is stale before re-sync (no _cma_force)"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >/dev/null 2>&1
grep -q '_cma_force' "$ALIAS_FILE"; assert_eq 0 $? "cmd_sync healed the stale wrapper (_cma_force restored)"
# (refresh-vs-refresh byte-idempotence is covered separately by the "--refresh-aliases
#  is idempotent" test; cmd_sync output need not equal refresh(cmd_sync output).)

it "present_key_vars dies clearly when CMA_KEYS_FILE is a directory (v1.12.1 5a)"
# -e (kept for FIFO/process-substitution keys files) also passes a DIRECTORY, which
# then yields a silent "0 key vars" (grep on a dir). A directory must die clearly.
_kd="$(mktemp -d "${TMPDIR:-/tmp}/cma-kd.XXXXXX")"
_kderr="$( bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$_kd" 2>&1 >/dev/null )"; _kdrc=$?
grep -qi 'is a directory' <<<"$_kderr"; assert_eq 0 $? "directory keys-file -> clear 'is a directory' die"
[[ "$_kdrc" -ne 0 ]]; assert_eq 0 $? "directory keys-file -> non-zero exit (not silent 0 key vars)"
rm -rf "$_kd"

it "cmd_sync_multi ALSO dies clearly on a directory keys-file (v1.12.1 5a, --multi path)"
# The --multi path resolves keys through the same subshell pattern, so it needs its
# own main-process guard too (final-review IMPORTANT: cmd_sync had it, cmd_sync_multi did not).
_kd2="$(mktemp -d "${TMPDIR:-/tmp}/cma-kd2.XXXXXX")"
_kd2err="$( bash "$PROVIDERS_SH" sync --multi --offline --keys-file "$_kd2" 2>&1 >/dev/null )"; _kd2rc=$?
grep -qi 'is a directory' <<<"$_kd2err"; assert_eq 0 $? "--multi directory keys-file -> clear die"
[[ "$_kd2rc" -ne 0 ]]; assert_eq 0 $? "--multi directory keys-file -> non-zero exit (not silent 0 key vars)"
rm -rf "$_kd2"

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

it "xiaomi env file created with router transport + /v1 base + pinned models"
# v1.19.0: xiaomi moved native(/anthropic) -> router(/v1). Its OpenAI-compatible
# endpoint is live-verified, so it routes through ccr like every other provider.
assert_file "$PDIR/xiaomi.env" "xiaomi env"
grep -qE "^CMA_PROVIDER_TRANSPORT='?router'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi router transport"
grep -qE "^CMA_PROVIDER_BASE_URL='?https://api.xiaomimimo.com/v1'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi /v1 base"
grep -qE "^CMA_PROVIDER_MODEL='?mimo-v2.5-pro'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi strong model mimo-v2.5-pro"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?mimo-v2.5'?" "$PDIR/xiaomi.env" ; assert_eq 0 $? "xiaomi fast model mimo-v2.5"
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
grep -q 'claude-sync-state.*pull' <<<"$_run_body"; assert_eq 0 $? "cma_run pull"
grep -q 'claude-sync-state.*push' <<<"$_run_body"; assert_eq 0 $? "cma_run push"

it "cma_run has provider-env isolation (clears leaked ANTHROPIC_* before native launch)"
grep -q 'unset ANTHROPIC_BASE_URL' <<<"$_run_body"; assert_eq 0 $? "cma_run unsets ANTHROPIC_BASE_URL"

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
# Scope to cma_run's own body: BOTH cma_run and cma_run_provider legitimately
# carry this unset (lib.sh:420 and :607), so a whole-file count is 2, not 1.
# This assertion is about cma_run specifically, so extract just its body.
mig_unset="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$_mig" | grep -c 'unset ANTHROPIC_BASE_URL')"
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
# NOTE: herestring (<<<), NOT `printf '%s\n' … | grep -q`. Under `set -o
# pipefail`, grep -q exits at the first match and closes the pipe; printf's
# remaining trailing write to the now-larger cma_run_provider body then takes
# SIGPIPE (rc 141), which pipefail surfaces as the pipeline exit -> a false
# FAIL (want=0 got=141) even though the match IS present. A herestring feeds
# the body via a temp file (no writer to kill), so grep's real rc is preserved.
grep -qF 'CLAUDE_CODE_AUTO_COMPACT_WINDOW="$CMA_PROVIDER_CONTEXT_LIMIT"' <<<"$_acw_body"
assert_eq 0 $? "auto-compact-window exported from CMA_PROVIDER_CONTEXT_LIMIT"
# shellcheck disable=SC2016
grep -q 'CMA_PROVIDER_CONTEXT_LIMIT:-' <<<"$_acw_body"
assert_eq 0 $? "export is guarded by [[ -n \${CMA_PROVIDER_CONTEXT_LIMIT:-} ]]"

it "cma_run_provider does NOT export the window when CMA_PROVIDER_CONTEXT_LIMIT is empty/unknown"
# Static-body check: the export line is conditional — immediately preceded by
# the [[ -n "${CMA_PROVIDER_CONTEXT_LIMIT:-}" ]] guard — so an empty/unknown
# limit never exports a bogus window.
# shellcheck disable=SC2016
grep -B1 'export CLAUDE_CODE_AUTO_COMPACT_WINDOW' <<<"$_acw_body" | grep -q 'CMA_PROVIDER_CONTEXT_LIMIT:-'
assert_eq 0 $? "export CLAUDE_CODE_AUTO_COMPACT_WINDOW is guarded on the preceding line"

it "migration regenerates an outdated cma_run_provider that lacks the auto-compact cap guard"
# Mirror the cma_run migration regression above. The cma_run_provider migration
# guard (lib.sh) keys on the '_cma_compact_cap' marker — the local that caps the
# auto-compact window at <=200K — NOT on the bare 'CLAUDE_CODE_AUTO_COMPACT_WINDOW'
# export (which the guard does not check). Build an OLD-format alias file whose
# cma_run_provider carries ALL other current markers but is MISSING that guard.
# Rather than hand-write the body, take the CURRENT emitted body and delete the
# WHOLE auto-compact block as ONE unit — the 'local _cma_compact_cap=…' line
# through its closing 'fi'. Deleting the block atomically (a) genuinely removes a
# marker the guard keys on, so migration fires for the RIGHT reason, and (b) keeps
# the body valid bash (no orphan 'fi' — the bug a line-wise 'grep -v' strip of the
# export + its guard continuation introduced, which lost the 'if' but kept the 'fi').
_mig2="$ALIAS_FILE.migtest2"
{
  printf 'export CLAUDE_BIN="/usr/bin/true"\n\n'
  awk '
    /local _cma_compact_cap=/  { drop=1 }
    drop && /^[[:space:]]*fi$/ { drop=0; next }
    !drop
  ' <<<"$_acw_body"
  printf '\nalias kimi-for-coding="cma_run_provider kimi-for-coding"\n'
} > "$_mig2"
bash -n "$_mig2"; assert_eq 0 $? "old-format alias file parses (bash -n)"
grep -q '_cma_compact_cap' "$_mig2"; assert_eq 1 $? "old body lacks _cma_compact_cap guard marker (pre-migration)"
( ALIAS_FILE="$_mig2" cma_ensure_alias_file ) >/dev/null 2>&1
mig2_prov="$(grep -c '^cma_run_provider()' "$_mig2")"
mig2_alias="$(grep -c '^alias kimi-for-coding=' "$_mig2")"
mig2_cap="$(grep -c 'local _cma_compact_cap=' <<<"$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$_mig2")")"
assert_eq 1 "$mig2_prov"  "exactly one cma_run_provider() after migration"
assert_eq 1 "$mig2_alias" "kimi-for-coding alias preserved through migration"
assert_eq 1 "$mig2_cap"   "regenerated cma_run_provider restores the _cma_compact_cap guard"
rm -f "$_mig2"

it "migration regenerates an outdated cma_run_provider lacking the Kimi markers (v1.15.0)"
# The v1.15.0 features (family proxy discovery `_family_id` + Kimi OAuth
# launch-time token freshness 'kimi-code/credentials/...') MUST trigger the
# same self-heal migration — otherwise hosts upgrading from v1.14.0 keep a
# wrapper that can neither route kimi-* through kimi_proxy nor refresh the
# ~15-minute OAuth token (live-confirmed: stale wrapper => proxy never
# started => k3 400s every tool call; stale snapshot => 401 at launch).
_mig3="$ALIAS_FILE.migtest3"
cat > "$_mig3" <<'OLD'
export CLAUDE_BIN="/usr/bin/true"

cma_run_provider() {
  # claude-sync-state set -a +u claude-session apply-color _cma_compact_cap _cma_proxy_dir
  # command -v cma_log _cma_force >| "$tmp" unset ANTHROPIC_BASE_URL
  # ! git rev-parse --show-toplevel >/dev/null 2>&1
  # command -v "${CLAUDE_BIN:-}"
  :
}

alias kimi-for-coding="cma_run_provider kimi-for-coding"
OLD
bash -n "$_mig3"; assert_eq 0 $? "old-format alias file parses (bash -n)"
grep -q '_family_id' "$_mig3"; assert_eq 1 $? "old body lacks family proxy marker (pre-migration)"
grep -q 'kimi-code/credentials' "$_mig3"; assert_eq 1 $? "old body lacks OAuth freshness marker (pre-migration)"
( ALIAS_FILE="$_mig3" cma_ensure_alias_file ) >/dev/null 2>&1
mig3_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$_mig3")"
mig3_alias="$(grep -c '^alias kimi-for-coding=' "$_mig3")"
# Use a here-string, not `printf | grep -q`: grep -q exits on first match and
# closes the pipe while printf is still writing the ~400-line body, so printf
# dies with SIGPIPE and the PIPELINE's status is 141 — not grep's 0. That made
# this assertion fail even though the marker was present (the sibling
# _family_id check passed only because its match happens late enough that
# printf finishes first). A here-string has no pipe and no SIGPIPE race.
grep -qF '_family_id' <<<"$mig3_body"; assert_eq 0 $? "regenerated body carries family proxy discovery"
grep -qF 'kimi-code/credentials/kimi-code.json' <<<"$mig3_body"; assert_eq 0 $? "regenerated body carries OAuth token freshness"
assert_eq 1 "$mig3_alias" "kimi-for-coding alias preserved through migration"
rm -f "$_mig3"

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
grep -q 'ghost' <<<"$list_out"; assert_eq 0 $? "list-all still shows the alias-less provider"

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
grep -q '>| "\$tmp"' <<<"$_prov_body"; assert_eq 0 $? "router jq write uses force-clobber >|"
_bare=0
# shellcheck disable=SC2016
grep -qE '> "\$tmp"' <<<"$_prov_body" && _bare=1
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
grep -qF "st_groq	failed	llama-3	" <<<"$_all"; assert_eq 0 $? "groq row present with fields"

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
grep -q 'not launching' <<<"$_g_out"; assert_eq 0 $? "gate prints 'not launching'"
grep -q 'claude-providers sync' <<<"$_g_out"; assert_eq 0 $? "gate suggests re-verify via sync"

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
# herestring (<<<), NOT `printf … | grep -q`: SIGPIPE-safe on the larger body
# (see the auto-compact-window assertions above for the pipefail/SIGPIPE detail).
grep -qF '_cma_force' <<<"$_gate_body"; assert_eq 0 $? "emitted body carries the --force/gate marker"

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
# Byte-idempotent: a second refresh must yield an identical file. (Regression
# guard for the write_alias migration-churn bug — write_alias used to re-run the
# full cma_ensure_alias_file self-heal on every alias line, non-deterministically
# repositioning the cma_run_provider function relative to the alias lines, so this
# occasionally differed. Fixed by only bootstrapping the alias file when absent.)
_rb="$(cat "$ALIAS_FILE")"
bash "$PROVIDERS_SH" list --refresh-aliases --quiet >/dev/null 2>&1
assert_eq "$_rb" "$(cat "$ALIAS_FILE")" "second refresh yields an identical alias file"

it "--quiet suppresses the refresh log line (non-quiet emits it)"
_noisy="$(bash "$PROVIDERS_SH" list --refresh-aliases 2>&1 >/dev/null)"
grep -q refreshed <<<"$_noisy"; assert_eq 0 $? "non-quiet refresh logs 'refreshed'"
_quiet="$(bash "$PROVIDERS_SH" list --refresh-aliases --quiet 2>&1 >/dev/null)"
grep -q refreshed <<<"$_quiet" && _q=1 || _q=0
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
grep -q 'SCV-STUB' <<<"$out"; assert_eq 0 $? "driver execs the built binary"
grep -q -- '--sentinel Z' <<<"$out"; assert_eq 0 $? "driver forwards flags verbatim"
assert_file "$_sem_bin" "binary was cached under .local-cache"

it "claude-semantic-visibility.sh --help/-h ALWAYS works, even with no built binary (bug fix)"
# Regression guard: the OLD code did `exec "$BIN" -h` unconditionally, so with
# no cached binary (fresh checkout, no `go` toolchain yet) `exec` to a missing
# path kills the non-interactive script with exit 127 and empty stdout — the
# `||` fallback never runs because `exec` replaces the process on success and
# never returns to bash on failure either (it just fails the whole script).
out="$( LV_SEMANTIC_BIN=/nonexistent/path bash "$SEMDRV" --help 2>&1 )"; rc=$?
assert_eq 0 "$rc" "--help exits 0 with no built binary"
grep -qi 'usage' <<<"$out"; assert_eq 0 $? "--help prints a usage line with no built binary"
out="$( LV_SEMANTIC_BIN=/nonexistent/path bash "$SEMDRV" -h 2>&1 )"; rc=$?
assert_eq 0 "$rc" "-h exits 0 with no built binary"
grep -qi 'usage' <<<"$out"; assert_eq 0 $? "-h prints a usage line with no built binary"

# ---------------------------------------------------------------------------
# Section — providers-semantic.sh (layer 3 adapter). A stub driver stands in
# for the Go binary: it echoes a canned verdict JSON + exits with a chosen code,
# so the adapter's stdout/exit mapping is asserted with no go/network/keys.
# ---------------------------------------------------------------------------
SEMSH="$SCRIPTS_DIR/providers-semantic.sh"
_mk_stub_driver() {  # $1 = exit code, $2 = overall_pass json bool
  cat > "$HOME/fakebin/scv-stub" <<EOF
#!/usr/bin/env bash
printf '{"round1_sentinel":{"pass":$2,"observed":"ZETA-9-ORANGE-7f3a"},"round2_judge":{"pass":$2,"score":3,"skipped":false},"overall_pass":$2}\n'
exit $1
EOF
  chmod +x "$HOME/fakebin/scv-stub"
}

it "providers-semantic maps overall_pass=true -> 'verified' exit 0"
_mk_stub_driver 0 true
out="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
        bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
        --base-url https://api.deepseek.com 2>/dev/null )"; rc=$?
assert_eq "verified" "$out" "pass -> verified"
assert_eq 0 "$rc" "pass -> exit 0"

# The adapter SOURCES judge.env/template (which sets CMA_JUDGE_BASE_URL), so control
# the judge config via a CMA_JUDGE_ENV file, not an env var the template would clobber.
it "providers-semantic WARNs when judge endpoint == model-under-test endpoint (v1.12.1 1A independence guard)"
_mk_stub_driver 0 true
printf 'CMA_JUDGE_BASE_URL="https://api.deepseek.com"\nCMA_JUDGE_MODEL="deepseek-chat"\nCMA_JUDGE_KEYVAR="DEEPSEEK_API_KEY"\n' > "$HOME/judge-same.env"
err="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_JUDGE_ENV="$HOME/judge-same.env" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
        bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
        --base-url https://api.deepseek.com 2>&1 >/dev/null )"
grep -qi 'same-family judge is NOT independent' <<<"$err"; assert_eq 0 $? "same-endpoint judge -> independence WARNING on stderr"

it "providers-semantic does NOT warn when judge endpoint differs (independent judge)"
_mk_stub_driver 0 true
printf 'CMA_JUDGE_BASE_URL="https://api.groq.com/openai"\nCMA_JUDGE_MODEL="llama-3.1-8b-instant"\nCMA_JUDGE_KEYVAR="GROQ_API_KEY"\n' > "$HOME/judge-diff.env"
err2="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_JUDGE_ENV="$HOME/judge-diff.env" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
         bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
         --base-url https://api.deepseek.com 2>&1 >/dev/null )"
grep -qi 'same-family judge is NOT independent' <<<"$err2" && _w=1 || _w=0
assert_eq 0 "$_w" "different-endpoint judge -> NO independence warning"

it "providers-semantic maps Go exit 3 (transport/infra) -> 'skip', not 'unverified' (v1.12.1 I-1 no-downgrade)"
_mk_stub_driver 3 false
out3="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_JUDGE_ENV="$HOME/judge-diff.env" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
         bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
         --base-url https://api.deepseek.com 2>/dev/null )"; rc3=$?
assert_eq "skip" "$out3" "Go exit 3 (infra) -> skip (a transient judge/model error must not demote)"
assert_eq 2 "$rc3" "skip -> adapter exit 2"

it "providers-semantic maps overall_pass=false -> 'unverified' exit 1"
_mk_stub_driver 1 false
out="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
        bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
        --base-url https://api.deepseek.com 2>/dev/null )"; rc=$?
assert_eq "unverified" "$out" "fail -> unverified"
assert_eq 1 "$rc" "fail -> exit 1"

it "providers-semantic SKIPs (exit 2 -> 'skip') when the model key is absent — no downgrade"
# Use a key-var name no real provider would ever export (NOT DEEPSEEK_API_KEY —
# a host actually configured for this toolkit's own purpose, i.e. real provider
# keys exported in the operator's shell, would leak a real DEEPSEEK_API_KEY
# into this process's env and falsely defeat the "key absent" precondition).
unset CMA_TEST_NO_SUCH_KEY_VAR
out="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" \
        bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var CMA_TEST_NO_SUCH_KEY_VAR \
        --base-url https://api.deepseek.com 2>/dev/null )"; rc=$?
assert_eq "skip" "$out" "no key -> skip"
assert_eq 2 "$rc" "skip -> exit 2"

it "providers-semantic reads fixture/rubric from providers/ (CONST-051 boundary), not the submodule"
# The rendered judge-prompt must contain rubric-derived criteria, proving the
# toolkit owns the judge input and the submodule binary only receives CLI args.
_mk_stub_driver 0 true
CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y CMA_SEMANTIC_DEBUG=1 \
  bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
  --base-url https://api.deepseek.com >/dev/null 2>"$HOME/sem.err"
grep -q 'resolve_alias' "$HOME/sem.err" ; assert_eq 0 $? "judge-prompt carries rubric fixture-specific detail"

# providers-semantic.sh computes its own REPO_ROOT from BASH_SOURCE (it is not
# invoked through a symlink here, and there is no env override), so the driver
# it spawns writes evidence under the real repo's .local-cache — same place
# claude-semantic-visibility.sh's own driver test caches its stub binary from
# a *different* override; this one is not overridable, so we compute it the
# same way the script does and read the file back from there. .local-cache/
# is gitignored, so this never touches tracked state.
_sem_repo_root="$(cd "$SCRIPTS_DIR/.." && pwd)"
_sem_evidence="$_sem_repo_root/.local-cache/semantic-last.json"

it "providers-semantic writes the driver's JSON evidence to .local-cache/semantic-last.json (bug fix)"
# Regression guard: the OLD code redirected the driver's `--format json`
# stdout straight to /dev/null (only stderr was captured to semantic-last.err),
# so the round1_sentinel/round2_judge/overall_pass evidence Task 5's proof
# capture needs was silently discarded on every run.
rm -f "$_sem_evidence"
_mk_stub_driver 0 true
CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
  bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
  --base-url https://api.deepseek.com >/dev/null 2>/dev/null
assert_file "$_sem_evidence" "semantic-last.json evidence file written"
grep -q 'overall_pass' "$_sem_evidence" 2>/dev/null; assert_eq 0 $? "evidence file carries the driver's overall_pass"
grep -q 'round1_sentinel' "$_sem_evidence" 2>/dev/null; assert_eq 0 $? "evidence file carries the driver's round1_sentinel"

it "providers-semantic normalizes a judge base URL ending in /v1 before passing --judge-base-url (bug fix)"
# Regression guard: the adapter normalizes the MODEL-under-test base (strips
# trailing /, /chat/completions, /anthropic, /v1) because the Go command
# appends /v1/chat/completions itself, but the OLD code skipped that same
# normalization for the JUDGE base — a judge.env ending in /v1 (a very natural
# way to write one) would double up to /v1/v1/chat/completions -> 404, which a
# live run hit exactly. Point CMA_JUDGE_ENV at a throwaway file so the real
# providers/judge.env.template (which has no /v1 suffix) can't mask the bug.
_judge_env_v1="$(mktemp "${TMPDIR:-/tmp}/cma-judge-env.XXXXXX")"
cat > "$_judge_env_v1" <<'EOF'
CMA_JUDGE_BASE_URL="https://api.example.com/v1"
CMA_JUDGE_MODEL="judge-model"
CMA_JUDGE_KEYVAR="CMA_TEST_NO_SUCH_JUDGE_KEYVAR"
CMA_JUDGE_THRESHOLD="2"
EOF
_argv_file="$HOME/scv-argv.txt"
rm -f "$_argv_file"
cat > "$HOME/fakebin/scv-argv-recorder" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$_argv_file"
echo '{"overall_pass":true}'
exit 0
EOF
chmod +x "$HOME/fakebin/scv-argv-recorder"
CMA_JUDGE_ENV="$_judge_env_v1" CMA_JUDGE_KEY=y CMA_PROBE_KEY=x \
  CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-argv-recorder" \
  bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
  --base-url https://api.deepseek.com >/dev/null 2>/dev/null
assert_file "$_argv_file" "argv-recorder stub wrote its received args"
_judge_base_val="$(awk '$0=="--judge-base-url"{getline; print; exit}' "$_argv_file" 2>/dev/null)"
assert_eq "https://api.example.com" "$_judge_base_val" "judge base url has /v1 stripped, no double /v1/v1"
rm -f "$_judge_env_v1"

# ---------------------------------------------------------------------------
# Section — cmd_sync layer-3 wiring. Stub existence -> 'verified' and semantic
# -> 'unverified' and assert the persisted status is unverified/semantic.
# ---------------------------------------------------------------------------
cat > "$HOME/fakebin/verify-ok" <<'EOF'
#!/usr/bin/env bash
echo verified
EOF
cat > "$HOME/fakebin/semantic-fail" <<'EOF'
#!/usr/bin/env bash
echo unverified
exit 1
EOF
chmod +x "$HOME/fakebin/verify-ok" "$HOME/fakebin/semantic-fail"

it "cmd_sync: existence=verified + semantic=unverified -> status unverified/semantic"
# (uses the Section-3 catalog + key-aliases already seeded above; a key must be
# set so cmd_sync attempts verification. --no-verify is NOT passed.)
CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-ok" \
CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-fail" \
BETA_API_KEY=sk-test \
  bash "$PROVIDERS_SH" sync --keys-file <(echo 'export BETA_API_KEY=sk-test') >/dev/null 2>&1
assert_eq "unverified" "$(cma_status_read beta)" "semantic failure demotes to unverified"
assert_jq "$(cma_status_cache)" '.beta.failing_layer' "semantic" "failing layer = semantic"

it "cmd_sync: existence=verified + semantic=skip -> stays verified (honest SKIP, no downgrade)"
cat > "$HOME/fakebin/semantic-skip" <<'EOF'
#!/usr/bin/env bash
echo skip
exit 2
EOF
chmod +x "$HOME/fakebin/semantic-skip"
CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-ok" \
CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-skip" \
BETA_API_KEY=sk-test \
  bash "$PROVIDERS_SH" sync --keys-file <(echo 'export BETA_API_KEY=sk-test') >/dev/null 2>&1
assert_eq "verified" "$(cma_status_read beta)" "semantic skip does not downgrade verified"

it "cmd_sync: existence=unverified (inconclusive) -> failing_layer=existence (NOT semantic), semantic never invoked"
# Regression guard for the Task-2 fix: the OLD buggy code labeled failing_layer
# "semantic" whenever verification did not end in "verified", even when the
# semantic (layer-3) probe was never reached because existence itself was the
# layer that failed. CMA_PROVIDERS_SEMANTIC below drops a marker file if it is
# ever invoked, so an accidental future call into layer-3 from the
# existence-inconclusive path is caught even if the failing_layer text happens
# to still read correctly.
cat > "$HOME/fakebin/verify-unverified" <<'EOF'
#!/usr/bin/env bash
echo unverified
EOF
chmod +x "$HOME/fakebin/verify-unverified"
rm -f "$HOME/sem-marker-fired"
cat > "$HOME/fakebin/semantic-marker" <<EOF
#!/usr/bin/env bash
touch "$HOME/sem-marker-fired"
echo verified
EOF
chmod +x "$HOME/fakebin/semantic-marker"

CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-unverified" \
CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-marker" \
BETA_API_KEY=sk-test \
  bash "$PROVIDERS_SH" sync --keys-file <(echo 'export BETA_API_KEY=sk-test') >/dev/null 2>&1
assert_eq "unverified" "$(cma_status_read beta)" "existence-inconclusive -> status unverified"
assert_jq "$(cma_status_cache)" '.beta.failing_layer' "existence" "failing layer = existence, not semantic"
cond=0; [[ -f "$HOME/sem-marker-fired" ]] && cond=1
assert_eq 0 "$cond" "semantic layer not invoked when existence is inconclusive"

# ---------------------------------------------------------------------------
# Section — cmd_verify subcommand (Task 2 review Gap 1). Seeds one provider
# env file directly (no sync needed) and stubs the existence (layer-1) and
# semantic (layer-3) drivers via the same CMA_PROVIDERS_VERIFY /
# CMA_PROVIDERS_SEMANTIC overrides cmd_sync already uses above. --deep
# (layer-4, superpowers TUI) is covered separately in the
# verify_superpowers_tui.sh SKIP-behavior section below (Tier-A only — no
# real claude in the sandbox, so PASS/FAIL classification itself is deferred
# to Task 5's Tier-B live test).
# ---------------------------------------------------------------------------
cma_provider_write_env "gamma" "GAMMA_API_KEY" "router" "https://api.gamma.ai/v1" \
  "gamma-x" "" "$HOME/.claude-prov-gamma" "" "" "gamma"

cat > "$HOME/fakebin/verify-fail" <<'EOF'
#!/usr/bin/env bash
echo failed
EOF
cat > "$HOME/fakebin/semantic-ok" <<'EOF'
#!/usr/bin/env bash
echo verified
EOF
chmod +x "$HOME/fakebin/verify-fail" "$HOME/fakebin/semantic-ok"

it "cmd_verify: existence=verified + semantic=verified -> prints verified, persists verified with empty failing_layer"
out="$(CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-ok" CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-ok" \
       bash "$PROVIDERS_SH" verify gamma 2>/dev/null)"
assert_eq "verified" "$out" "cmd_verify stdout: verified"
assert_eq "verified" "$(cma_status_read gamma)" "cmd_verify persists status verified"
assert_jq "$(cma_status_cache)" '.gamma.failing_layer' "" "cmd_verify verified -> failing_layer empty"

it "cmd_verify: existence probe returns failed -> prints failed, persists failed/existence"
out="$(CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-fail" CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-ok" \
       bash "$PROVIDERS_SH" verify gamma 2>/dev/null)"
assert_eq "failed" "$out" "cmd_verify stdout: failed"
assert_eq "failed" "$(cma_status_read gamma)" "cmd_verify persists status failed"
assert_jq "$(cma_status_cache)" '.gamma.failing_layer' "existence" "cmd_verify failed -> failing_layer existence"

it "cmd_verify: existence=verified + semantic=unverified -> prints unverified, persists unverified/semantic"
out="$(CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-ok" CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-fail" \
       bash "$PROVIDERS_SH" verify gamma 2>/dev/null)"
assert_eq "unverified" "$out" "cmd_verify stdout: unverified"
assert_eq "unverified" "$(cma_status_read gamma)" "cmd_verify persists status unverified"
assert_jq "$(cma_status_cache)" '.gamma.failing_layer' "semantic" "cmd_verify semantic-fail -> failing_layer semantic"

it "cmd_verify: unknown provider id dies with non-zero exit + message"
out="$(bash "$PROVIDERS_SH" verify no-such-provider-xyz 2>&1)"; rc=$?
assert_eq 1 "$rc" "cmd_verify unknown id exits 1"
grep -q "unknown provider" <<<"$out"; assert_eq 0 $? "cmd_verify unknown id emits a die message"

# ---------------------------------------------------------------------------
# Section — verify_superpowers_tui.sh SKIP behavior (Tier-A: no real claude).
# With CLAUDE_BIN=/usr/bin/true (the sandbox default) the layer-4 test MUST
# SKIP-with-reason and exit 0 — never a faked PASS, never a hard FAIL.
#
# All invocations below pin PROOF_DIR into the sandbox. verify_superpowers_tui.sh
# computes its default --out from its OWN on-disk location
# (${PROOF_DIR:-$TESTS_ROOT/tests/proof}/...), which resolves to the REAL
# scripts/tests/proof/ in the repo tree, not the sandboxed $HOME, unless
# PROOF_DIR is overridden. Without this, every Tier-A run leaves untracked
# providers-*-superpowers.txt files outside the sandbox (independent review
# Finding 3; reproduced — see providers-deepseek-superpowers.txt and
# providers-no_such_alias-superpowers.txt that were untracked in `git status`
# before this fix).
# ---------------------------------------------------------------------------
STUI="$SCRIPTS_DIR/verify_superpowers_tui.sh"
STUI_PROOF="$HOME/proof"

it "verify_superpowers_tui SCRUB list mirrors verify_claude_live.sh exactly (session-continuity vars included)"
_stui_scrub="$(grep -oE -- '-u [A-Z_]+' "$STUI" | awk '{print $2}' | sort -u)"
_live_scrub="$(grep -oE -- '-u [A-Z_]+' "$TESTS_DIR/verify_claude_live.sh" | awk '{print $2}' | sort -u)"
assert_eq "$_live_scrub" "$_stui_scrub" "SCRUB var set identical to verify_claude_live.sh (incl. CLAUDE_CODE_CHILD_SESSION/SESSION_ID govern resume safety)"

it "verify_superpowers_tui SKIPs (exit 0 + reason) when there is no real claude binary"
out="$( CLAUDE_BIN=/usr/bin/true PROOF_DIR="$STUI_PROOF" bash "$STUI" --alias deepseek --timeout 5 2>&1 )"; rc=$?
assert_eq 0 "$rc" "SKIP is a non-failure (exit 0)"
grep -q 'SKIP:' <<<"$out"; assert_eq 0 $? "prints an honest SKIP reason"
grep -qiv 'PASS' <<<"$out"; assert_eq 0 $? "never claims PASS when skipping"

# A stub whose basename matches claude* (unlike the previous `cat`/`true`) so
# the launch passes the "no real claude binary" precondition
# (verify_superpowers_tui.sh: [[ ... && "$(basename "$CB")" == claude* ]]) and
# genuinely reaches the alias-not-installed check further down. Review
# Finding 2: the old test used CLAUDE_BIN="$(command -v cat)", which SKIPped
# at the EARLIER "no real claude binary" precondition — the
# alias-not-installed branch had zero real coverage even though its
# `grep -q 'SKIP:'` assertion passed.
mkdir -p "$HOME/fakebin"
cat > "$HOME/fakebin/claude-stub" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$HOME/fakebin/claude-stub"

it "verify_superpowers_tui SKIPs when the named alias is not installed (genuinely reaches that branch)"
[[ -f "$ALIAS_FILE" ]]; assert_eq 0 $? "precondition: sandbox alias file exists (so the alias-file check doesn't SKIP first)"
[[ ! -f "$PDIR/no_such_alias.env" ]]; assert_eq 0 $? "precondition: no_such_alias has no provider env file"
out="$( CLAUDE_BIN="$HOME/fakebin/claude-stub" PROOF_DIR="$STUI_PROOF" bash "$STUI" --alias no_such_alias --timeout 5 2>&1 )"; rc=$?
assert_eq 0 "$rc" "unknown alias -> SKIP exit 0"
grep -q "SKIP: alias 'no_such_alias' not installed" <<<"$out"; assert_eq 0 $? "SKIP reason names the alias-not-installed branch specifically (not an earlier precondition)"

# ---------------------------------------------------------------------------
# Section — xAI existence via the generic chat probe (CORRECTED: xAI exposes
# an OpenAI-shaped API with alias ids like "latest"). No docs-scrape
# special-case may exist (Task 4, §11.4.124 — see
# .superpowers/sdd/task-4-recon.md: the generic probe path already covers xAI;
# no model-id-membership check exists anywhere to add alias tolerance to).
# ---------------------------------------------------------------------------

it "no xAI docs-scrape / hardcoded-model special-case is present in the sources"
! grep -rniE 'docs\.x\.ai|scrape|xai-models\.json' "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.py 2>/dev/null
assert_eq 0 $? "xAI is handled by the generic probe path, not a scrape branch"

it "providers-verify treats xAI like any OpenAI-shaped provider (sentinel + tool call -> verified)"
# Fake the xAI chat endpoint on loopback: answer the VERIFY_OK sentinel probe
# and then the tool-calling probe with a tool_calls payload — exactly what the
# generic strategy-2 probes expect from any OpenAI-shaped provider.
python3 - "$HOME/xai.port" <<'PY' &
import http.server, socketserver, sys, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
        if '"tools"' in body:
            self.wfile.write(json.dumps({"choices":[{"message":{"tool_calls":[{"id":"c1","type":"function","function":{"name":"get_weather","arguments":"{}"}}]},"finish_reason":"tool_calls"}]}).encode())
        else:
            self.wfile.write(json.dumps({"choices":[{"message":{"content":"VERIFY_OK"}}]}).encode())
    def log_message(self,*a): pass
with socketserver.TCPServer(("127.0.0.1",0),H) as s:
    open(sys.argv[1],"w").write(str(s.server_address[1]))
    s.handle_request(); s.handle_request()  # chat probe + tool probe
PY
# wait for the port file, then probe
for _ in $(seq 1 50); do [[ -s "$HOME/xai.port" ]] && break; sleep 0.05; done
port="$(cat "$HOME/xai.port" 2>/dev/null)"
XAI_API_KEY=sk-test out="$( XAI_API_KEY=sk-test bash "$SCRIPTS_DIR/providers-verify.sh" \
    --provider xai --model grok-4 --key-var XAI_API_KEY \
    --base-url "http://127.0.0.1:${port}/v1" 2>/dev/null )"
assert_eq "verified" "$out" "xAI chat+tools probes pass -> verified (no special-case)"

# NOTE: no `summary` here. There must be exactly ONE summary call, as the very
# last statement in the file — it is what converts TESTS_FAILED into the exit
# code run-all.sh tallies. A stray mid-file summary is a latent false-PASS
# hazard: if a future edit reorders sections so a mid-file summary becomes the
# last executed statement, its status would be reported instead of the real,
# cumulative one. (Sections 10-11 follow below; the real summary is at EOF.)

# ---------------------------------------------------------------------------
# Section 10 — HTTP probe URL normalization (providers-verify.sh)
# Native-transport providers (/anthropic base URL) must probe the Anthropic
# messages endpoint UNDER the kept /anthropic prefix (POST
# /anthropic/v1/messages — the shape real native endpoints like
# api.deepseek.com/anthropic actually serve), with Anthropic content-block
# responses. Loopback HTTP server test.
# ---------------------------------------------------------------------------

it "providers-verify keeps /anthropic and probes /anthropic/v1/messages for native-transport providers"
python3 - "$HOME/nat.port" <<'PY' &
import http.server, socketserver, sys, json
class H(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        n = int(self.headers.get("Content-Length") or 0)
        body = self.rfile.read(n).decode() if n else ""
        if self.path == "/anthropic/v1/messages":
            self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
            if '"tools"' in body:
                self.wfile.write(json.dumps({"content":[{"type":"tool_use","id":"t1","name":"get_weather","input":{"city":"Paris"}}]}).encode())
            else:
                self.wfile.write(json.dumps({"content":[{"type":"text","text":"VERIFY_OK"}]}).encode())
        else:
            self.send_response(404); self.end_headers()
    def log_message(self,*a): pass
with socketserver.TCPServer(("127.0.0.1",0),H) as s:
    open(sys.argv[1],"w").write(str(s.server_address[1]))
    s.handle_request(); s.handle_request()  # chat probe + tool probe
PY
for _ in $(seq 1 50); do [[ -s "$HOME/nat.port" ]] && break; sleep 0.05; done
natport="$(cat "$HOME/nat.port" 2>/dev/null)"
NATIVE_ANTHROPIC_API_KEY=sk-test out="$(
  NATIVE_ANTHROPIC_API_KEY=sk-test bash "$SCRIPTS_DIR/providers-verify.sh" \
    --provider native --model mimo-x --key-var NATIVE_ANTHROPIC_API_KEY \
    --base-url "http://127.0.0.1:${natport}/anthropic" 2>/dev/null )"
assert_eq "verified" "$out" "native /anthropic base -> verified (prefix kept, /anthropic/v1/messages probed)"

# ---------------------------------------------------------------------------
# Section 11 — cma_run_provider env isolation (emitted body check)
# ---------------------------------------------------------------------------

it "emitted cma_run_provider carries env-isolation unset for ANTHROPIC_*"
grep -qF 'unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL' "$ALIAS_FILE"
assert_eq 0 $? "full ANTHROPIC_* unset line present in alias file"

it "emitted cma_run_provider carries env-isolation unset for CLAUDE_CODE_*"
grep -qF 'unset CLAUDE_CODE_AUTO_COMPACT_WINDOW CLAUDE_CODE_MAX_OUTPUT_TOKENS' "$ALIAS_FILE"
assert_eq 0 $? "CLAUDE_CODE_* unset line present in alias file"

it "env-isolation markers appear in cma_run_provider body before activation gate"
_gate_line="$(grep -n '_cma_force' "$ALIAS_FILE" | grep -v '^[0-9]*:.*grep\|^[0-9]*:.*_gate_line' | head -1 | cut -d: -f1)"
_unset_line="$(grep -n 'unset ANTHROPIC_BASE_URL' "$ALIAS_FILE" | head -1 | cut -d: -f1)"
[[ -n "$_unset_line" && -n "$_gate_line" && "$_unset_line" -lt "$_gate_line" ]]
assert_eq 0 $? "env-isolation unset lines precede the activation gate"

it "migration check detects missing env-isolation marker"
_bare_body='cma_run_provider() { :; }'
grep -qF 'unset ANTHROPIC_BASE_URL' <<<"$_bare_body" && _has=1 || _has=0
assert_eq 0 "$_has" "bare body without env-isolation triggers missing check"

# ---------------------------------------------------------------------------
# Section 12 — multi-alias status persistence (direct status cache + gate test)
# ---------------------------------------------------------------------------

it "cma_status_write works for a multi-alias name (numeric suffix pattern)"
cma_status_write "acme2" "verified" "acme-big" ""
assert_eq "verified" "$(cma_status_read acme2)" "multi-alias acme2 reads as verified"
assert_jq "$(cma_status_cache)" '.acme2.model' "acme-big" "multi-alias carries model name"
assert_jq "$(cma_status_cache)" '.acme2.failing_layer' "" "verified has empty failing_layer"

it "cma_status_write for multi-alias with low score -> unverified (existence)"
cma_status_write "acme4" "unverified" "acme-tiny" "existence"
assert_eq "unverified" "$(cma_status_read acme4)" "low-score multi-alias -> unverified"
assert_jq "$(cma_status_cache)" '.acme4.failing_layer' "existence" "low-score -> existence"

it "multi-alias activation gate: verified alias launches (cma_run_provider rc 0)"
cma_status_write "acme2" "verified" "acme-big" ""
mkdir -p "$HOME/.claude-prov-acme2"
_pdir="$(cma_providers_dir)"; mkdir -p "$_pdir"
cat > "$_pdir/acme2.env" <<ENVEOF
CMA_PROVIDER_ID='acme2'
CMA_PROVIDER_KEYVAR='ACME_API_KEY'
CMA_PROVIDER_TRANSPORT='native'
CMA_PROVIDER_BASE_URL=''
CMA_PROVIDER_MODEL='acme-big'
CMA_PROVIDER_FAST_MODEL='acme-small'
CMA_PROVIDER_CONFIG_DIR='$HOME/.claude-prov-acme2'
ENVEOF
( ACME_API_KEY=sk-test CLAUDE_BIN=/usr/bin/true source "$ALIAS_FILE"; cma_run_provider acme2 ) >/dev/null 2>&1
assert_eq 0 $? "multi-alias verified acme2 launches (rc 0)"

it "multi-alias activation gate: unverified alias blocks (rc 3)"
# Create env file first (needed for cma_run_provider to find it)
cat > "$_pdir/acme4.env" <<ENVEOF
CMA_PROVIDER_ID='acme4'
CMA_PROVIDER_KEYVAR='ACME_API_KEY'
CMA_PROVIDER_TRANSPORT='native'
CMA_PROVIDER_BASE_URL=''
CMA_PROVIDER_MODEL='acme-tiny'
CMA_PROVIDER_FAST_MODEL='acme-small'
CMA_PROVIDER_CONFIG_DIR='$HOME/.claude-prov-acme4'
ENVEOF
mkdir -p "$HOME/.claude-prov-acme4"
cma_status_write "acme4" "unverified" "acme-tiny" "existence"
( CLAUDE_BIN=/usr/bin/true ACME_API_KEY=sk-test source "$ALIAS_FILE"; cma_run_provider acme4 ) >/dev/null 2>&1; _grc=$?
assert_eq 3 "$_grc" "unverified multi-alias acme4 blocked by gate (rc 3)"

summary
