# Plan: Add Xiaomi MiMo as a fully-supported Claude Code provider

## Context (where this task fits)

This repo is a bash toolkit that runs multiple Claude Code accounts unified, plus a
**dynamic provider-alias generator** (`scripts/claude-providers.sh`) that turns the
API-key *variable names* in `~/api_keys.sh` into Claude Code aliases pointed at
non-Anthropic LLM providers. Nothing about providers is hardcoded — every provider is
derived from the **models.dev catalog** (`CMA_MODELS_DEV_URL`) plus two editable JSON
config files:

- `scripts/providers/key-aliases.json` — maps a key-var NAME → models.dev provider id
  (used when the key-var name does not literally match a provider's `env[]` entry).
- `scripts/providers/overrides.json` — per-provider manual pins for
  `alias / base_url / transport / strong_model / fast_model`.

The resolver (`scripts/providers_resolve.py`) classifies each key-var, finds its
provider in the catalog, auto-selects a strong (reasoning/newest) + fast (cheapest)
model, and the sync loop writes a non-secret `.env` file + a shell alias per provider.

**Existing precedent — Z.AI (v1.2.0):** `ZAI_API_KEY` did not match any provider's
`env[]`, so `key-aliases.json` mapped `ZAI_API_KEY → zai-coding-plan`, and
`overrides.json` pinned the strong/fast models. Tests in
`scripts/tests/test_providers.sh` (Sections 2 & 3) assert resolution + sync. Xiaomi
follows the **exact same pattern**, with one improvement: Xiaomi has a real
**Anthropic-native endpoint**, so it can be `transport: native` (like DeepSeek) instead
of `router` (like Z.AI) — no `ccr` dependency.

## Deep-research findings (ground truth, citation-backed)

Sources read: `mimo.mi.com/docs/en-US/quick-start/summary/{welcome,model,first-api-call}`,
`mimo.mi.com/docs/en-US/api/guidance/rate-limit`, `github.com/XiaomiMiMo` (+ MiMo-Code),
models.dev catalog, and **live probes with the user's key** (evidence captured below).

### Endpoints (confirmed live)
- OpenAI-compat: `https://api.xiaomimimo.com/v1`  (`GET /v1/models`, `POST /v1/chat/completions`)
- **Anthropic-native: `https://api.xiaomimimo.com/anthropic`**  (`POST /anthropic/v1/messages`)
- Token-plan regional hosts exist (`token-plan-ams/cn/sgp.xiaomimimo.com/v1`) but the
  user's key is a pay-as-you-go `sk-…` key → use the global `api.xiaomimimo.com` host.

### Auth (confirmed live — BOTH headers work)
- `Authorization: Bearer <key>` ✅ (this is what Claude Code native transport sets via
  `ANTHROPIC_AUTH_TOKEN`; the `cma_run_provider` wrapper sets exactly this)
- `api-key: <key>` ✅ (Xiaomi's own convention; docs show this)

Because `Authorization: Bearer` works on `/anthropic/v1/messages`, **native transport
is viable and preferred** — no `ccr` needed.

### Live evidence captured (HTTP 200 each)
1. `GET /v1/models` → `{"object":"list","data":[…10 models…]}`. Exact ids served:
   `mimo-v2-flash, mimo-v2-omni, mimo-v2-pro, mimo-v2-tts, mimo-v2.5, mimo-v2.5-asr,
   mimo-v2.5-pro, mimo-v2.5-tts, mimo-v2.5-tts-voiceclone, mimo-v2.5-tts-voicedesign`
2. `POST /v1/chat/completions` `mimo-v2.5-pro` w/ `tools[]` → `finish_reason:"tool_calls"`,
   valid `tool_calls` array, `reasoning_content` present → **tool calling works**.
3. `POST /v1/chat/completions` `mimo-v2-flash` → HTTP 200 (fast model works).
4. `POST …/v1/chat/completions` `mimo-v2.5` `stream:true` → SSE `chat.completion.chunk`
   deltas with `content` + `reasoning_content` → **streaming works**.
5. `POST /anthropic/v1/messages` `mimo-v2.5-pro` w/ `Authorization: Bearer` → native
   Anthropic response (`type:"message"`, `content:[{type:"text"},{type:"thinking"}]`,
   `usage`) → **native endpoint works with Bearer auth**.

### Model catalog (authoritative, from official model page + live /models)
Text-generation / coding-capable (all support tool calling + reasoning, all are
reasoning models):
| Model id | Context | Max out | Type | Notes |
|---|---|---|---|---|
| `mimo-v2.5-pro` | 1M | 128K | Pro, text | **flagship → strong model** |
| `mimo-v2.5` | 1M | 128K | Omni/multimodal | image/audio/video understanding |
| `mimo-v2-pro` | (legacy alias) | — | Pro | older v2 pro |
| `mimo-v2-omni` | 256K | 128K | Omni/multimodal | older v2 omni |
| `mimo-v2-flash` | 256K | 64K | Flash | **→ fast model** (cheapest tier) |

Non-text (excluded from Claude Code aliases — they cannot do chat/code):
`mimo-v2.5-asr` (speech-to-text), `mimo-v2.5-tts`, `mimo-v2.5-tts-voiceclone`,
`mimo-v2.5-tts-voicedesign`, `mimo-v2-tts` (text-to-speech).

> models.dev lists a `mimo-v2.5-pro-ultraspeed` id under the `xiaomi` provider that is
> **NOT served by the live API** (stale/preview entry). The resolver derives models from
> the catalog, so we **must pin strong/fast via overrides** to the live-served ids and
> not rely on catalog auto-selection for Xiaomi. This is exactly the Z.AI approach.

### Rate limits
- 100 RPM, 10M TPM for all text models (per-account, not per-key). No tiers. 429s under
  load → retry/backoff. (Not relevant to alias config, documented for completeness.)

## Decisions (already made from research — implementer does not re-derive)

- **Provider id:** `xiaomi` (matches the models.dev `xiaomi` provider that lists
  `XIAOMI_API_KEY` in its `env[]`). The user's key-var is `XIAOMI_MIMO_API_KEY`, which
  does NOT match → needs a `key-aliases.json` entry.
- **key-aliases.json entry:** `"XIAOMI_MIMO_API_KEY": "xiaomi"`.
- **Transport:** `native` (Anthropic endpoint w/ Bearer). NOT router.
- **base_url:** `https://api.xiaomimimo.com/anthropic` (the native Anthropic endpoint;
  Claude Code appends `/v1/messages`). Confirmed working with Bearer.
- **strong_model:** `mimo-v2.5-pro` (flagship 1M context reasoning, tool-call confirmed).
- **fast_model:** `mimo-v2-flash` (cheapest tier, 256K, tool-call confirmed).
- **overrides.json:** pin `transport`, `base_url`, `strong_model`, `fast_model` for
  `xiaomi` (so the stale catalog `ultraspeed` id is never selected, and the global
  OpenAI-compat `api` URL in the catalog is overridden to the native `/anthropic` URL).

## Global Constraints (binding — reviewer enforces these verbatim)

1. **No secrets in the repo.** Tests use dummy values only. The real key lives only in
   `~/api_keys.sh` and (mode-0600) ccr/router configs generated at launch. No test may
   read or assert on a real key value. (Existing invariant — see `verify_providers_live.sh`
   "NO secret values are present".)
2. **Config-only changes for the provider itself** — do NOT modify
   `providers_resolve.py`, `lib.sh`'s `cma_run_provider`, or `claude-providers.sh` logic.
   Xiaomi is added purely via `key-aliases.json` + `overrides.json`, exactly like Z.AI.
   (Rationale: the system is dynamic by design; hardcoding would regress the architecture.)
3. **Tests are hermetic** — they run in a `make_sandbox` `$HOME` with a fixture catalog
   and dummy keys; never touch real `~/.claude*`. New Xiaomi tests follow the Z.AI test
   pattern in `scripts/tests/test_providers.sh` Sections 2 & 3.
4. **Exact model-id strings** must match the live API: `mimo-v2.5-pro`, `mimo-v2-flash`,
   base_url `https://api.xiaomimimo.com/anthropic`, transport `native`.
5. **Idempotent + non-destructive.** Re-running `claude-providers sync` must not
   duplicate the alias or corrupt other providers. The existing `claudeN` aliases and
   other provider aliases must be untouched.
6. **No false results / no bluffing.** Every claim in CHANGELOG + release notes must be
   backed by captured evidence (live curl outputs in `scripts/tests/proof/`).
7. **Account-detection invariant preserved:** `~/.claude-prov-xiaomi` must remain
   excluded from `cma_detect_accounts` (the `prov-` prefix exclusion already covers it,
   but the test must assert it).
8. **BSD/macOS portability:** no GNU-only constructs in any new bash.

---

## Task 1 — Config: register Xiaomi in key-aliases.json + overrides.json

**Goal:** make the resolver turn `XIAOMI_MIMO_API_KEY` into a resolved `xiaomi` provider
record with the pinned native transport + models.

**Changes (exact):**

`scripts/providers/key-aliases.json` — add one key (keep existing entries; keep the file
sorted/consistent with current style — currently insertion-order, just append):
```json
{
  "ZAI_API_KEY": "zai-coding-plan",
  "CODESTRAL_API_KEY": "mistral",
  "HUGGINGFACE_API_KEY": "huggingface",
  "GITHUB_MODELS_API_KEY": "github-models",
  "TENCENT_CLOUD_API_KEY": "tencent-tokenhub",
  "XIAOMI_MIMO_API_KEY": "xiaomi"
}
```

`scripts/providers/overrides.json` — add a `xiaomi` section (keep existing `deepseek` +
`zai-coding-plan` sections untouched):
```json
{
  "deepseek": { …unchanged… },
  "zai-coding-plan": { …unchanged… },
  "xiaomi": {
    "transport": "native",
    "base_url": "https://api.xiaomimimo.com/anthropic",
    "strong_model": "mimo-v2.5-pro",
    "fast_model": "mimo-v2-flash"
  }
}
```

**Validation the implementer runs before reporting DONE:**
- `jq . scripts/providers/key-aliases.json` and `jq . scripts/providers/overrides.json`
  both parse and contain the new keys.
- Manual resolver check against the live cache:
  `python3 scripts/providers_resolve.py --models-dev <cache> --key-aliases scripts/providers/key-aliases.json --overrides scripts/providers/overrides.json --keys XIAOMI_MIMO_API_KEY --only xiaomi` →
  record has `status:"resolved"`, `provider_id:"xiaomi"`, `transport:"native"`,
  `base_url:"https://api.xiaomimimo.com/anthropic"`, `strong_model:"mimo-v2.5-pro"`,
  `fast_model:"mimo-v2-flash"`. Paste this JSON into the report.

**Commit:** `feat(providers): add Xiaomi MiMo provider alias (native transport)`

---

## Task 2 — Tests: resolver + sync coverage for Xiaomi (mirror Z.AI, hermetic)

**Goal:** permanent, hermetic test coverage proving Xiaomi resolves and syncs correctly.
Mirror exactly how `zai-coding-plan` is tested in `scripts/tests/test_providers.sh`
Sections 2 and 3, but for `xiaomi` with `native` transport.

**Changes to `scripts/tests/test_providers.sh`:**

Section 2 (resolver against fixture catalog) — add a `xiaomi` provider to the existing
fixture `$FIX/catalog.json` with `env:["XIAOMI_API_KEY"]`, a stale `ultraspeed` model
(to prove overrides beat catalog), and add `XIAOMI_MIMO_API_KEY` to the resolver `--keys`
list. Then add assertions (use the existing `rfield` helper):
- `XIAOMI_MIMO_API_KEY` → `provider_id == "xiaomi"`, `status == "resolved"`.
- transport `== "native"` (the override wins even though catalog npm is openai-compat).
- `base_url == "https://api.xiaomimimo.com/anthropic"` (override, not the catalog
  OpenAI-compat `api`).
- `strong_model == "mimo-v2.5-pro"`, `fast_model == "mimo-v2-flash"` (overrides beat the
  stale `ultraspeed` catalog entry).
- Negative: the stale catalog model id (`mimo-v2.5-pro-ultraspeed`) is NOT selected as
  strong or fast.

Section 3 (sync e2e against fixture cache) — add `xiaomi` to the fixture cache JSON and
add a `XIAOMI_MIMO_API_KEY="dummy-xiaomi"` line to the fake keys file. Add assertions:
- `scripts/providers/xiaomi.env` is created (use `assert_file`).
- It contains `CMA_PROVIDER_TRANSPORT='native'`,
  `CMA_PROVIDER_BASE_URL='https://api.xiaomimimo.com/anthropic'`,
  `CMA_PROVIDER_MODEL='mimo-v2.5-pro'`, `CMA_PROVIDER_FAST_MODEL='mimo-v2-flash'`.
- The alias file contains `alias xiaomi="cma_run_provider xiaomi"`.
- A `~/.claude-prov-xiaomi` config dir is created and its `plugins` is symlinked to
  `$SHARED_DIR/plugins` (use `assert_symlink_to`).
- `cma_detect_accounts` still excludes `prov-xiaomi` (grep returns 1).
- Re-running sync is idempotent (still exactly one `xiaomi` alias).
- No secret value (`dummy-xiaomi`) leaks into env files or the alias file.

Also extend the existing Section 4 zsh smoke test is NOT required (it covers the native
path generically via `acme`; Xiaomi is also native so the same code path is exercised).
But add one assertion to Section 4 if cheap: the zsh smoke test can additionally run
`cma_run_provider xiaomi` — only if it does not complicate the existing `acme` run. If it
adds risk, skip it and note why.

**Validation before DONE:**
- `bash scripts/tests/run-all.sh providers` → all pass; print the full summary line.
- Confirm the new assertion count went up by the number of Xiaomi assertions added.

**Commit:** `test(providers): hermetic resolver+sync coverage for Xiaomi MiMo`

---

## Task 3 — Install + full live verification (no bluff — capture evidence)

**Goal:** run the real toolkit against the real host, prove the Xiaomi alias works end to
end, and capture raw evidence. This is NOT a sandbox test; it uses the user's real key
(read from `~/api_keys.sh`, never written into the repo).

**Steps:**
1. `bash scripts/install.sh` (idempotent; refreshes symlinks). Confirm `claude-providers`
   is on PATH (`command -v claude-providers`).
2. `claude-providers sync` (online, WITH verification enabled — default). Confirm the log
   line: `provider 'xiaomi' -> alias 'xiaomi' [native] model=mimo-v2.5-pro (verified)`.
   Paste the full sync tail into the report.
3. `claude-providers show xiaomi` → paste output. Confirm transport native, base_url
   `/anthropic`, models correct.
4. `claude-providers list` → paste output; confirm `xiaomi` row present and other
   providers intact.
5. **Live "do you see my code?" proof** — confirm the alias actually launches Claude Code
   against Xiaomi. Because a full interactive launch is heavy, prove the transport
   config instead by sourcing the alias machinery and confirming the native env vars are
   set, then do a direct native-endpoint tool-call round trip with the user's key:
   - `set -a; . ~/api_keys.sh; set +a`
   - `curl … https://api.xiaomimimo.com/anthropic/v1/messages -H "Authorization: Bearer $XIAOMI_MIMO_API_KEY" … -d '{"model":"mimo-v2.5-pro", "max_tokens":64, "messages":[{"role":"user","content":"Reply with exactly: XIAOMI_ALIAS_OK"}]}'`
   - Assert HTTP 200 and the response `content[].text` contains `XIAOMI_ALIAS_OK`.
6. Write evidence to `scripts/tests/proof/60-xiaomi-live.txt`: the sync tail, the `show`
   output, the `/anthropic` curl response (redact nothing structural, but the report file
   must NOT contain the raw key — only the Authorization header presence, not value).
7. Run `bash scripts/tests/run-proof.sh` (sandbox suite + live opencode + live providers)
   and confirm `scripts/tests/proof/PROOF.md` reflects all-green. Paste the suite summary.

**Validation before DONE:**
- The Xiaomi alias exists and `show xiaomi` reports native + correct models.
- The `/anthropic` tool-call round trip returned HTTP 200 with the expected text.
- `verify_providers_live.sh` passes (no stray values, every provider has an alias, no
  provider dir detected as account).
- Full `run-all.sh` suite is ALL GREEN. Paste the final tally.
- Evidence file `60-xiaomi-live.txt` exists and contains no raw key value.

**Commit:** `docs(qa): Xiaomi MiMo live verification evidence (native, tool-call proven)`

---

## Task 4 — Docs + CHANGELOG + version bump → release to GitHub & GitLab

**Goal:** document Xiaomi, bump to v1.3.0, tag, and push to all configured remotes via
the existing upstream CLIs. (The user said "GitHub and GitLab"; the repo also has
gitflic/gitverse remotes — push to all four for consistency, but call out GitHub+GitLab
explicitly as required.)

**Changes:**
1. `CHANGELOG.md` — add a `## v1.3.0 — <today's date> — Xiaomi MiMo provider alias`
   section at the top (above v1.2.0), modeled on the v1.2.0 entry. Use **only**
   evidence-backed claims: native transport, `/anthropic` endpoint, `mimo-v2.5-pro`
   (strong) + `mimo-v2-flash` (fast), key-aliases + overrides pinning, test count delta,
   live-verified HTTP 200 + tool call. Do NOT claim things not captured in evidence.
2. If the repo's provider docs reference a provider table (check
   `docs/Provider_Aliases_User_Guide.md`), add Xiaomi to it (native transport row).
   If no such table, skip — note that in the report.
3. Regenerate rendered docs only if the doc pipeline is part of this release's scope:
   check whether `CHANGELOG.md` feeds `claude-export-docs.sh`. If CHANGELOG is a source
   for the doc pipeline, regenerate `CHANGELOG.{html,pdf,docx}` via
   `bash scripts/claude-export-docs.sh` (it reads the `.md`). If pandoc/weasyprint is
   missing, note it and skip rendering (don't fail the release).
4. Commit docs: `docs(release): v1.3.0 — Xiaomi MiMo provider alias`.
5. Tag: `git tag v1.3.0`.
6. Inspect `upstreams/*.sh` (one-line `UPSTREAMABLE_REPOSITORY=` exports) and the
   configured remotes (`git remote -v`). Push `main` + tag to **github** and **gitlab**
   (required), and also to **gitflic** + **gitverse** (consistency): e.g.
   `git push github main --tags`, etc., using whatever remote names exist
   (`git remote -v` first). If a push fails for auth reasons, capture the error and
   report it honestly (do NOT fake success).

**Validation before DONE:**
- `CHANGELOG.md` has the v1.3.0 entry with only evidence-backed claims.
- `git tag --list v1.3.0` shows the tag.
- `git log --oneline origin/main..main` is empty (pushed) for each remote that succeeded.
- Paste the `git remote -v` output and each push result into the report.

**No separate commit needed for the tag itself.**

---

## Out of scope (explicitly)

- Touching `providers_resolve.py` / `lib.sh` / `claude-providers.sh` core logic.
- Adding the non-text MiMo models (ASR/TTS) as aliases — they cannot do chat/code.
- The token-plan regional endpoints — the user's key is pay-as-you-go (`sk-`).
- Any change to the OpenCode sync (`claude-opencode-sync.sh`) — unrelated feature.
- Re-rendering the long-form `Claude_Multi_Account_Fine_Tuning.*` (Xiaomi is a provider,
  not a multi-account-doc topic) unless the doc explicitly lists providers.
