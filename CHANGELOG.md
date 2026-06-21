# Changelog

All notable changes to the Claude multi-account toolkit.

## v1.6.3 — 2026-06-21 — Poe provider (382 models, 3 aliases)

### Added
- **Poe provider** — universal AI platform with 382 models from all major providers.
  OpenAI-compatible API at `https://api.poe.com/v1`. Chat, code, image gen, video gen,
  TTS, STT, and more.
- **3 aliases**: `poe` (claude-sonnet-4.6 + gpt-5.4-mini), `poe2` (gpt-5.5 + deepseek-v4-pro-e),
  `poe3` (grok-4 + gemini-3.1-pro)
- **key-aliases**: `POE_API_KEY` + `ApiKey_Poe` → `poe`
- **Tool calling verified** on claude-sonnet-4.6, gpt-5.4-mini, deepseek-v4-pro-e, grok-4
- **382 models categorized**: 130 chat/reasoning, 16 code, 40 image gen, 17 video gen,
  12 TTS, 1 STT, 166 other
- **Documentation**: full Poe section in Provider_Aliases_User_Guide.md

### Verified
- API endpoint responds correctly
- Authentication works
- Tool calling confirmed
- All 3 aliases tested through ccr with "Do you see our codebase?" — all YES

## v1.6.2 — 2026-06-21 — Chutes provider documentation + model update

### Changed
- **Chutes provider models updated** — catalog was stale. Chutes now offers 13 TEE
  (Trusted Execution Environment) models. Updated strong=`zai-org/GLM-5.2-TEE`,
  fast=`Qwen/Qwen3.6-27B-TEE`.
- **Chutes documentation** added to Provider_Aliases_User_Guide.md with full model
  table, TEE explanation, pay-per-use note, and setup instructions.

### Verified
- Chutes API endpoint responds correctly
- All 13 TEE models accessible (require funded account for actual inference)
- OpenAI-compatible format confirmed at `https://llm.chutes.ai/v1`

## v1.6.1 — 2026-06-21 — cache_control fix + E2E tests

### Fixed
- **`cache_control` parameter error** — Claude Code sends `cache_control` (Anthropic-specific)
  in its API requests. ccr forwarded this to OpenAI-compatible endpoints which reject it with
  HTTP 422. Fixed by adding ccr's built-in `cleancache` transformer to every provider config,
  which strips `cache_control` before forwarding to the provider.

### Added
- **`alias_e2e_test.py`** — end-to-end alias verification script that tests each alias
  by sending requests through ccr and verifying responses work without errors.

### Verified working (all aliases tested with "Do you see our codebase?")
- `opencode` (north-mini-code-free): ✅ YES
- `opencode2` (big-pickle): ✅ YES
- `opencode3` (nemotron-3-ultra-free): ✅ YES
- `deepseek` (native transport): ✅ YES
- `deepseek2` (router transport): ✅ YES
- `xiaomi` (native transport): ✅ YES
- `zai-coding-plan` (router transport): ✅ YES

## v1.6.0 — 2026-06-21 — Multi-alias provider system

### Added
- **Multi-alias provider system** — every provider can now have multiple aliases
  (`provider`, `provider2`, `provider3`...) exposing ALL working models, not just
  the top 2. Verified via live HTTP probes with anti-bluff detection.
- **`model_verify.py`** — comprehensive model verification & scoring engine.
  Tests every model for a provider via HTTP probes, scores on 7 dimensions
  (existence 25pts, tool_call 20pts, reasoning 15pts, context_window 15pts,
  streaming 10pts, latency 10pts, free_tier 5pts). Anti-bluff detection prevents
  false positives (HTTP 200 with error body, empty responses, boilerplate errors).
  24h verification cache to avoid re-testing.
- **`providers_generate.py`** — multi-alias generation from verified models.
  Pairs models into alias groups of 2 (strong + fast), handles odd count (last
  model reused for both positions), single model (used for both positions).
  Generates env files, shell aliases, and overrides.json entries.
- **`claude-providers.sh --multi`** — new flag for `sync` that triggers the full
  verification + multi-alias generation pipeline. Additional flags: `--max-aliases`
  (default 5), `--min-score` (default 25), `--verify-concurrency` (default 5).
- **Endpoint normalization** — `/anthropic` endpoints auto-converted to `/v1` for
  OpenAI-compatible probing during verification.
- **Submodules updated** to helix_translate-2.3.1: LLMsVerifier (ModelVerifier,
  Seed, xiaomi provider), challenges (anti-bluff §11.4, chaos/stress tests),
  containers (deploy-stack).

### Changed
- Probe `max_tokens` increased from 32 to 128 — reasoning models need more tokens
  for chain-of-thought + response (was causing false anti-bluff rejections).
- `User-Agent` header added to HTTP probes (some APIs require it).

### Full test suite
- 8/8 test files passed (ALL GREEN), 0 failures.

### Usage
```bash
# Standard sync (2 models per provider, as before)
claude-providers sync

# Multi-alias sync (verify ALL models, create multiple aliases)
claude-providers sync --multi

# With options
claude-providers sync --multi --max-aliases 10 --min-score 20
```

## v1.5.1 — 2026-06-20 — Linux stat fix + nezha deployment

### Fixed
- **`stat -f %m` on Linux** — the mtime cache check in `claude-providers.sh` used
  `stat -f %m || stat -c %Y` as an `||` chain. On Linux, `stat -f` succeeds
  (returning filesystem info, not mtime), so both outputs merged into garbage
  (`"File: ...1781634386"`), causing `File: unbound variable` under `set -u`.
  Fixed with `case "$(uname -s)"` to pick the correct flag per platform.

### Deployment
- **nezha.local** (Linux x86_64) deployed and verified: 19 providers activated,
  100/100 provider tests pass, 5/5 live verifier pass, cross-alias sync confirmed.
  Evidence in `scripts/tests/proof/90-nezha-deployment.txt`.

### Full test suite
- macOS: 8/8 ALL GREEN
- Linux (nezha): 7/8 pass (export fails: pandoc not installed — pre-existing)

## v1.5.0 — 2026-06-20 — Cross-alias session visibility

### Added
- **Cross-alias session visibility** — sessions created under ANY alias (`claudeN`,
  `deepseek`, `opencode`, `xiaomi`, etc.) are now visible from every other alias
  via `/resume`. Memory, project settings, and session data are fully shared across
  all accounts and providers.
- **`claude-sync-state.sh` extended** — now discovers provider dirs
  (`~/.claude-prov-*`) alongside account dirs for its `.claude.json` merge. Provider
  sessions participate in the same lightweight jq merge that keeps account sessions
  in sync.
- **`cma_run_provider` sync-state hooks** — the provider wrapper now calls
  `claude-sync-state pull` before launch and `claude-sync-state push` after exit,
  matching the `cma_run` pattern. Previously provider sessions were intentionally
  excluded from sync; now they participate fully.
- **Sandbox test coverage**: 10 new assertions proving cross-alias merge (sessions
  from account→provider, provider→account, account→account all visible after sync).
  Providers test 90 → 100 assertions.
- **Live verification**: `lastSessionId` for a real project confirmed identical across
  all dirs (3 accounts + 1 provider). 61 projects merged in every `.claude.json`.
  Evidence in `scripts/tests/proof/80-cross-alias-sessions.txt`.

### Changed
- `scripts/claude-sync-state.sh` — provider dirs included in merge targets
- `scripts/lib.sh` — `cma_run_provider` wrapper updated with sync-state pull/push
- Alias file `aliases.sh` — updated `cma_run_provider` function (re-installed)

### Full test suite
- 8/8 test files passed (ALL GREEN), 0 failures. Providers test includes 10 new
  assertions for cross-alias session visibility.

### How it works
1. `claude-sync-state pull` merges every account's + provider's `.claude.json` into
   the launching dir before Claude Code starts (including `lastSessionId`,
   `allowedTools`, MCP config, etc.).
2. Claude Code launches with the merged state — `/resume` sees all sessions.
3. `claude-sync-state push` merges the post-session `.claude.json` back out after
   exit, so the next alias to launch picks up the new session.
4. The `sessions/` directory was already shared via symlink — this release ensures
   `.claude.json` project settings are also merged.

### Performance
- Adds ~1-2 seconds overhead per provider launch (jq merge of `.claude.json` across
  all dirs). Same overhead that `claudeN` aliases already have.

## v1.4.0 — 2026-06-20 — OpenCode Zen provider alias

### Added
- **`opencode` provider alias** — [OpenCode Zen](https://opencode.ai/zen) curated AI
  gateway with **21 free models** (all $0 cost, all support tool calling + reasoning)
  and 49 paid models. The alias uses **router transport** (ccr) targeting the
  OpenAI-compatible endpoint `https://opencode.ai/zen/v1/chat/completions`.
- **Model overrides**: strong = `big-pickle` (free stealth model, 200K context,
  reasoning + tool_call), fast = `deepseek-v4-flash-free` (free, 200K context,
  reasoning + tool_call). Pinning is deliberate — auto-selection would pick
  `nemotron-3-ultra-free` (1M ctx) as strong and `trinity-large-preview-free` (131K,
  no reasoning) as fast, both suboptimal for coding workloads.
- **key-aliases.json mappings**: `ZEN_API_KEY` → `opencode` and
  `ApiKey_Opencode_Zen` → `opencode` (both key vars present in the user's keys file).
- **overrides.json pin**: `strong_model=big-pickle`, `fast_model=deepseek-v4-flash-free`
  (no transport/base_url override needed — catalog values are correct).
- **Sandbox test coverage**: resolver tests (key-alias mapping for both key vars, router
  transport from `@ai-sdk/openai-compatible` npm, zen/v1 base_url from catalog, model
  override beats auto-selection, stale-model-never-selected guards) + sync e2e tests
  (env file, alias, config-dir + plugins symlink, account-detection exclusion,
  idempotency, no-secret-leak). Providers test 69 → 90 assertions.
- **Live endpoint verification**: `GET /v1/models` HTTP 200; `POST /v1/chat/completions`
  round trip HTTP 200 with correct text for `big-pickle` (stealth, cost=$0,
  reasoning_content present) and `deepseek-v4-flash-free` (cost=$0); additional free
  models (`mimo-v2.5-free`, `nemotron-3-ultra-free`, `north-mini-code-free`) all HTTP 200
  with cost=$0. Evidence in `scripts/tests/proof/70-zen-live.txt` (secret-free).
- **Docs**: dedicated `opencode` section in `docs/Provider_Aliases_User_Guide.md`
  (full free models table, setup, usage, live-verified notes, stealth model explanation).

### Changed
- `scripts/providers/key-aliases.json` and `scripts/providers/overrides.json` extended
  with the `opencode` entries (config-only; no code changes — same dynamic pattern as
  Xiaomi v1.3.0 / Z.AI v1.2.0 / DeepSeek).

### Full test suite
- 8/8 test files passed (ALL GREEN), 0 failures. Providers test includes 21 new
  assertions for `opencode`.

### Honest notes
- The alias uses router transport (ccr) because Zen's free models use OpenAI-compatible
  format (`/v1/chat/completions`), not Anthropic native format. This adds a ccr
  dependency that native-transport aliases (deepseek, xiaomi) don't have.
- Big Pickle is a stealth model — the actual model served may vary (observed as
  deepseek-v4-flash). This is by design per OpenCode's documentation.
- The same pre-existing `~/api_keys.sh` set -u issue affects the in-process verifier
  for all providers; authoritative proof is the direct HTTP round trip.
- The 2 pre-existing, environmental opencode-skill-discovery failures in `run-proof.sh`
  remain unchanged (unrelated to this work).

## v1.3.0 — 2026-06-19 — Xiaomi MiMo provider alias

### Added
- **`xiaomi` provider alias** — Xiaomi MiMo via the **Anthropic-native endpoint**
  `https://api.xiaomimimo.com/anthropic` (`POST /anthropic/v1/messages`). Unlike most
  providers in this toolkit, MiMo exposes a genuine native Anthropic endpoint that
  accepts `Authorization: Bearer`, so the alias uses **native transport** with no
  `claude-code-router` (`ccr`) dependency — the same direct-launch model as `deepseek`.
- **Model overrides**: strong = `mimo-v2.5-pro` (flagship, 1M context, reasoning,
  tool-call), fast = `mimo-v2-flash` (256K, cheapest tier). Pinning is deliberate —
  models.dev lists a `mimo-v2.5-pro-ultraspeed` id the **live API does not serve**, so
  the override guarantees only live-served ids are used.
- **key-aliases.json mapping**: `XIAOMI_MIMO_API_KEY` → `xiaomi` (the user's key-var
  name does not match the models.dev provider's documented `XIAOMI_API_KEY` env).
- **overrides.json pin**: native transport, `/anthropic` base_url, `mimo-v2.5-pro` /
  `mimo-v2-flash`.
- **Sandbox test coverage**: resolver tests (key-alias mapping, override forces native
  transport, `/anthropic` base_url beats catalog `/v1`, model pinning beats the stale
  `ultraspeed` entry, stale-id-never-selected guard) + sync e2e tests (env file,
  alias, config-dir + plugins symlink, account-detection exclusion, idempotency,
  no-secret-leak). Providers test 60 → 69 assertions.
- **Live endpoint verification**: `GET /v1/models` HTTP 200 (10 models); native
  `/anthropic/v1/messages` round trip HTTP 200 with correct text for both
  `mimo-v2.5-pro` and `mimo-v2-flash`; tool calling proven (`finish_reason: tool_calls`
  + `reasoning_content`); streaming confirmed. Evidence in
  `scripts/tests/proof/60-xiaomi-live.txt` (secret-free).
- **Docs**: dedicated `xiaomi` section in `docs/Provider_Aliases_User_Guide.md`
  (model table, setup, usage, live-verified notes).

### Changed
- `scripts/providers/key-aliases.json` and `scripts/providers/overrides.json` extended
  with the `xiaomi` entries (config-only; no code changes — same dynamic pattern as
  Z.AI v1.2.0 / DeepSeek).

### Full test suite
- 8/8 test files passed (ALL GREEN), 0 failures. Providers test includes 9 new
  assertions for `xiaomi`. Live provider verifier 5/5 PASS.

### Honest notes
- The only failures in the repo's `run-proof.sh` are 2 **pre-existing, environmental**
  opencode-skill-discovery checks, unrelated to Xiaomi (zero opencode files changed by
  this release; they fail identically when run standalone).
- The in-process LLMsVerifier step reports `(unverified)` for every provider because
  `~/api_keys.sh` has a pre-existing unrelated `unbound variable` on a different
  provider's key under `set -u`; authoritative proof is the direct native-endpoint
  round trip (HTTP 200), recorded in the evidence file.

## v1.2.0 — 2026-06-19 — Z.AI Coding Plan provider alias

### Added
- **`zai-coding-plan` provider alias** — OpenAI-compatible router transport via `https://api.z.ai/api/coding/paas/v4` (Coding Max-Yearly Plan endpoint).
- **Model overrides**: strong = `glm-5.2` (flagship 1M context reasoning model, free on plan), fast = `glm-4.7` (204k context, tool_call, 0 cost).
- **key-aliases.json mapping**: `ZAI_API_KEY` → `zai-coding-plan` (targets the coding plan API endpoint instead of the general `z.ai` paas endpoint).
- **overrides.json pin**: overrides auto-selected strong/fast models for the coding plan.
- **Sandbox test coverage**: resolver tests (env-key matching, coding endpoint, router transport, glm-5.2/glm-4.7 model selection) + sync e2e tests (env file, alias, model overrides).
- **Live endpoint verification**: HTTP 200 at `/models` (8 models discovered), curl test of `glm-4.7` chat completion confirmed operational.
- **ccr integration**: provider auto-registered in `~/.claude-code-router/config.json` as the active default route.

### Changed
- `overrides.json` extended with `zai-coding-plan` section for model pinning.

### Full test suite
- 8/8 test files passed (ALL GREEN), 0 failures. Provider tests include 5 new assertions for `zai-coding-plan`.

## v1.1.0 — 2026-06-16 — Distributed infrastructure + provider verification

Headline: stand up the full LLMsVerifier System on a remote host for heavy
testing against **real production LLM services**, plus end-to-end provider
aliases proven on two hosts and two transports.

### Added
- **`containers` + `challenges` submodules** (`submodules/`) — the
  distributed-boot orchestrator and its sibling. `helix-deps.yaml` confirms
  `containers` has zero own-org submodule deps.
- **Remote host registration** — `config/containers/nezha.env` registers
  `nezha.local` as a remote boot/test host (SSH key, podman runtime).
- **LLMsVerifier deployment overlays** (`config/containers/llmsverifier/`):
  - `docker-compose.app.yml` — the `llm-verifier` API (cgo image, config mount,
    `/api/health` healthcheck, loopback, fail-fast secrets).
  - `docker-compose.infra.yml` — observability tier: prometheus + grafana
    (auto-provisioned datasource + dashboard) + node-exporter. **No DBs**
    (the app uses SQLite; postgres/redis were unused and removed).
  - `Dockerfile.nezha` / `Dockerfile.mv` — cgo nested-module builds for the
    server + the `model-verification` tool.
  - `patches/0001..0005` — upstream LLMsVerifier fixes (see PR #2 below).
- **Deployment guide** `config/containers/llmsverifier/README.md` and the
  **Provider Aliases User Guide** `docs/Provider_Aliases_User_Guide.md`
  (HTML/PDF/DOCX exports included).
- **QA evidence** `docs/qa/20260616-infra/` — verification proofs, endpoint
  coverage, security posture, observability, per-provider sweeps, dual-host
  end-to-end alias proofs.

### Changed
- **Provider session accent color: orange → purple** across spec, guide, and
  the long-form doc. (Claude Code 2.1.178 cannot persist a default `/color`, so
  this is the documented default + a manual `/color purple` — a platform limit.)
- `claude-add-account` consolidated onto the shared `cma_link_shared_items`
  helper (single `CMA_SHARED_ITEMS` source).
- `claude-export-docs` now also emits **DOCX** (HTML/PDF/DOCX).

### Fixed (LLMsVerifier — shipped as PR #2, applied to deployed builds)
- **Auth header missing** — verification requests sent no `Authorization`
  header → HTTP 401 for every provider. Now `Bearer <key>`.
- **cohere 405** — switched to the OpenAI-compat endpoint
  (`api.cohere.ai/compatibility/v1`). Verifies at score 1.00.
- **gemini / huggingface** — corrected to OpenAI-compat / router endpoints
  (huggingface verifies; gemini code-ready pending a valid key).
- **model-id strictness** — verifies a requested id directly when not in the
  discovered list (no premature `model_not_found`).
- **no `/metrics`** — added `GET /api/metrics` + `/metrics` (stdlib Prometheus).
- **provider-session sync-state noise** — `cma_run_provider` no longer runs
  cross-account sync-state on isolated provider dirs.

### Verified live (real "Do you see my code?" against production APIs)
- **9 providers verified:** DeepSeek, Groq, Mistral, Cerebras, Novita, NVIDIA,
  Cohere, Codestral, HuggingFace.
- **Both transports, both hosts:** native (DeepSeek) + router (Novita via ccr)
  on macOS and on nezha.
- Account-side failures (402/401/429/403) and non-OpenAI providers documented
  honestly; excluded under "valid users only" but kept fully supported.

### Safety
- Provider dirs (`~/.claude-prov-*`) excluded from account detection — existing
  `claudeN` accounts and `claude-add-account` untouched.
- Secrets only in the keys file + on-host mode-600 `.env`; never in the repo.
  All published ports bound to loopback.

## v1.0.0 — 2026-06-16 — Dynamic provider-alias generator

First tagged release. `claude-providers` creates per-provider Claude Code
aliases (DeepSeek, Groq, GLM, …) from your keys file pointed at each provider's
strongest model — fully dynamic via models.dev + the LLMsVerifier submodule,
hybrid native/claude-code-router transport, full lifecycle + tests + docs.
See `docs/Provider_Aliases_User_Guide.md`.
