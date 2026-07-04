# Provider Model Verification Overhaul — Design Spec

**Date:** 2026-07-04
**Status:** Approved design (pending written-spec review)
**Author:** Claude (brainstormed with Milos Vasic)
**Extends:** `docs/superpowers/specs/2026-06-16-provider-aliases-design.md`

## 1. Problem & Goal

The 2026-06-16 design gave the toolkit dynamically-generated Claude Code aliases for
non-Anthropic LLM providers (DeepSeek, Groq, Mistral, OpenRouter, xAI, …). Each alias
points Claude Code at a provider's OpenAI-compatible endpoint via `ANTHROPIC_BASE_URL`
+ `ANTHROPIC_AUTH_TOKEN`. The current verification layer
(`scripts/providers-verify.sh` + `scripts/model_verify.py`) probes a provider's
`/models` endpoint and scores a `VERIFY_OK` probe response, but:

- It does not confirm the model can actually **see the operator's codebase** — a 200
  response with an empty or error body can pass. This is the load-bearing premise for
  the whole provider-alias feature: Claude Code's Read/tool results must reach the
  non-Anthropic backend, not just round-trip a chat prompt.
- It does not confirm the alias can **launch the full Claude Code TUI** and run the
  **superpowers plugin** end-to-end — the user-visible point of the feature.
- `claude-providers list` returns every configured alias regardless of verification
  state, so a broken alias is indistinguishable from a working one.
- A failed/unverified alias still launches Claude Code, surfacing the failure as a
  confusing in-session error instead of a clear pre-launch message.
- Every alias shares `settings.json`/`.claude.json` across accounts via the
  `SHARED_ITEMS` symlink model, which triggers an "overwrite config?" prompt on launch
  when the shared file drifts across accounts.
- `install.sh` does not keep the alias set in sync with the keys file on new sessions,
  so a freshly added key doesn't surface until the operator manually re-runs `sync`.

This spec defines the overhaul that resolves all of the above. It is the first
sub-project of a decomposed programme: the LLMsVerifier submodule gains a generic
**`semantic-code-visibility`** capability (project-not-aware, CONST-051 clean), and
the toolkit owns the claude-code-specific seams (fixture, prompt, judge rubric, the
superpowers-TUI test).

### Non-negotiable constraints (carried from prior designs + constitution)

- Existing `claude1..N` accounts keep working **unchanged**.
- Existing provider aliases keep working; the overhaul migrates their config layout
  in an idempotent, rollback-able step.
- Submodules stay **fully decoupled** (CONST-051): no consumer-project names, paths,
  version strings, release-naming, or namespace imports; N ≥ 2 unrelated consumers.
- API keys via environment only (`CMA_PROBE_KEY`), never argv; bearer tokens via
  process-substituted fds, never shell arguments.
- No force-push (§11.4.113); mirrors reconcile via MERGE commit.
- Release-tag prefix `HELIX_RELEASE_PREFIX` from `.env` else lowercased project root
  dir name; identical across main repo + all owned submodules (§11.4.151).
- Every change reviewed (§11.4.142); no fixes without root cause (§11.4.102); honest
  SKIP, never faked PASS (§11.4.3); no silent removals (§11.4.122).

## 2. Architecture & Boundaries (Design Section 1)

### 2.1 The four verification layers

A provider alias moves through four layers, in order. A layer that fails shortens the
pipeline — later layers do not run. The final status is the **first failing layer's
failure status**, or `verified` if all four pass:

| # | Layer | What it proves | Failure status |
|---|---|---|---|
| 1 | **Existence** | The provider endpoint answers, the key is valid, the configured model id exists in the provider's catalog. | `failed` |
| 2 | **Tool-call scoring** | The model responds coherently to a probe; anti-bluff checks reject empty/error/200-with-error-body responses. | `failed` |
| 3 | **Semantic code-visibility** | The model genuinely sees the operator's codebase through the alias path (round 1 sentinel + round 2 judge). | `unverified` |
| 4 | **Superpowers-TUI** | The alias launches the full Claude Code TUI and the superpowers plugin engages end-to-end. | `unverified` |

**Statuses (tightened):** `verified` (passed ALL four layers) / `unverified` (passed
existence + tool-call, failed semantic or superpowers) / `failed` (failed existence or
tool-call) / `pending` (verification in-flight or not yet run).

### 2.2 Component boundaries

```
┌─ claude_toolkit (consumer) ─────────────────────────────────────┐
│                                                                  │
│  providers/<id>.env  ──►  providers_resolve.py  ──►  providers-   │
│        │                                              verify.sh  │
│        │                                                  │      │
│        │                                                  ▼      │
│        │                                  submodules/LLMsVerifier  │
│        │                                  (code-verification +    │
│        │                                   semantic-code-         │
│        │                                   visibility binaries)  │
│        │                                                  │      │
│        ▼                                                  ▼      │
│  claude-providers.sh ◄──  VERIFIED_CACHE (extended) ◄── model_  │
│        │                                                  verify.py │
│        │  list / list-all / list-faulty / sync / verify        │
│        │                                                        │
│        ▼                                                        │
│  cma_run_provider <id>  ──►  activation gate  ──►  Claude Code  │
│   (per-alias owned config: settings.json, .claude.json)         │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘
```

The toolkit owns:
- `providers/<id>.env` — per-alias provider config (base URL, model id, env-var key name).
- `providers/fixture/` — the sentinel fixture file (sample code + unguessable token).
- `providers/rubric/` — the round-2 judge rubric (0–3 scale, threshold 2).
- `scripts/providers-verify.sh` — the adapter that drives LLMsVerifier binaries.
- `scripts/model_verify.py` — the Python scoring engine (extended for layers 3–4).
- `scripts/claude-providers.sh` — the CLI (`list`/`list-all`/`list-faulty`/`sync`/`verify`).
- `scripts/verify_superpowers_tui.sh` — the layer-4 live TUI test driver.
- The extended `VERIFIED_CACHE` schema.
- The `cma_run_provider` activation gate.

The submodule owns (project-not-aware):
- `cmd/code-verification/` — existence + tool-call verification (existing).
- `cmd/semantic-code-visibility/` (new) — generic two-round sentinel+judge capability.
- Its own `CLAUDE.md` constitution (CONST-036→040, CONST-051, proposed CONST-052).

### 2.3 CONST-051 boundary contract

The submodule's `semantic-code-visibility` command accepts **every consumer-specific
input as a CLI arg**:

```
semantic-code-visibility \
  --base-url <provider-endpoint> \
  --model <model-id> \
  --api-key-env <ENV-NAME> \           # reads the key from env, never argv
  --fixture <path-to-fixture-file> \
  --prompt <prompt-template-path> \    # template references {{SENTINEL}} + {{FIXTURE_CONTENT}}
  --sentinel <unguessable-token> \
  --judge-base-url <judge-endpoint> \  # round-2 judge model endpoint
  --judge-model <judge-model-id> \
  --judge-api-key-env <ENV-NAME> \
  --rubric <rubric-path> \
  --judge-threshold 2 \                # 0–3 scale, default 2
  --format json
```

It emits a JSON verdict:

```json
{
  "round1_sentinel": {"pass": true, "observed": "ZETA-9-ORANGE-7f3a"},
  "round2_judge": {"score": 3, "threshold": 2, "pass": true, "reasoning": "..."},
  "overall_pass": true,
  "evidence": {"fixture_hash": "sha256:...", "prompt_hash": "sha256:..."}
}
```

The submodule **MUST NOT**:
- Bundle a default fixture, prompt, sentinel, or rubric that references any consumer
  project (codified as CONST-052).
- Read any consumer's `providers/` directory or `VERIFIED_CACHE`.
- Reference `claude_toolkit`, `cma_`, `claude-providers`, or the release-tag prefix in
  its source.
- Assume the consumer is a Claude Code toolkit (it serves N ≥ 2 unrelated consumers).

## 3. LLMsVerifier `semantic-code-visibility` Capability (Design Section 2)

### 3.1 The two-round test

**Round 1 — sentinel-token exact match (unfalsifiable-positive):**
The consumer supplies a fixture file containing an unguessable 16+ character sentinel
token (e.g. `ZETA-9-ORANGE-7f3a`) embedded in real code. The prompt template instructs
the model under test to read the fixture and name the sentinel. The test passes round 1
iff the model's response contains the exact sentinel string.

Rationale: a model that cannot read the fixture cannot guess a 16+ char random token.
A round-1 pass is strong evidence the model received the fixture's contents through
the alias path (the file-forwarding premise). A round-1 fail = "this alias cannot see
your codebase through this path" — an actionable finding, not a test bug.

**Round 2 — judge-graded describe-what-you-see (catches the bluff):**
The prompt template asks the model an open-ended question about the fixture's content
(e.g. "describe the function signatures in this file"). An independent **judge model**
(the consumer's choice — a different provider/model than the one under test) scores
the response against a rubric (0–3 scale, threshold 2):

- 0 — response is empty, an error message, or a refusal.
- 1 — response is generic boilerplate with no fixture-specific detail.
- 2 — response names at least one fixture-specific detail correctly.
- 3 — response accurately describes multiple fixture-specific details.

Round 2 passes iff the judge's score ≥ threshold (default 2).

**Why two rounds:** Round 1 is unfalsifiable-positive (can't be bluffed), but a model
that parrots the sentinel without actually reading the file could pass. Round 2 catches
that by requiring fixture-specific description. Together they cover both "got 200 but
empty body" and "got the file path but can't read it" failure modes.

### 3.2 Anti-bluff (defense in depth)

Round 1 rejects: empty responses, error messages, HTTP-non-200 bodies, rate-limit
misidentification. The sentinel's unguessability means a pass is genuine. Round 2's
judge is an independent model (different provider or different model id) so a provider
that cheats round 1 would need to also cheat a competitor's judge — high cost, low
yield.

### 3.3 The load-bearing premise (framing strengthened post-research)

> **UPDATE (2026-07-04, post-implementation research —
> `docs/research/2026-07-04-provider-api-endpoints.md`).** The premise is stronger than
> "unconfirmed": Anthropic's official gateway-protocol docs **document that the FULL
> Anthropic-Messages request body is POSTed to `ANTHROPIC_BASE_URL/v1/messages`** (and
> warn gateways not to redact request bodies). Read-tool output rides in `tool_result`
> content blocks by construction, so file-content forwarding **follows from documented
> full-body forwarding** — it is not merely a third-party claim. Frame it that way in the
> docs, NOT as "undocumented." The two-round test still **empirically confirms** it
> per-provider (a provider/proxy could still drop or truncate the body).

Whether Claude Code forwards Read-tool file contents to non-Anthropic backends via
`ANTHROPIC_BASE_URL` — the two-round test EMPIRICALLY VERIFIES this per alias rather than
assuming it. A round-1 fail on a known-good fixture is reported as "this alias cannot
see your codebase through this path" — actionable, not a test defect. The spec and the
manual MUST cite the Anthropic gateway-protocol docs + the claude-code-router README with
retrieval dates (§11.4.99).

### 3.4 CONST-052 (proposed new constitution entry)

> "The `semantic-code-visibility` capability MUST accept fixture, prompt, sentinel,
> judge-config, and rubric as CLI args. It MUST NOT bundle consumer-project-specific
> fixtures, prompts, sentinels, or rubrics as defaults. A consumer project supplies its
> own."

This codifies the Approach-A boundary so a future contributor cannot silently re-couple
the submodule by "adding a default fixture for convenience."

## 4. claude_toolkit Seams (Design Section 3)

### 4.1 The toolkit-owned fixture

`providers/fixture/code-visibility.md` (new, gitignored content — never commit real
sample code with secrets):

```markdown
# Fixture for semantic code-visibility verification

Sentinel: ZETA-9-ORANGE-7f3a

## Sample code (excerpt)

def resolve_alias(provider_id: str, model_id: str) -> Alias:
    """Resolve a provider+model pair into a launchable alias."""
    catalog = fetch_catalog(provider_id)
    if model_id not in catalog:
        raise UnknownModel(model_id)
    return Alias(provider=provider_id, model=model_id, strong=is_strong(model_id))

class TokenBucket:
    def __init__(self, rate: float, capacity: int):
        self.rate = rate
        self.capacity = capacity
        self.tokens = capacity
```

The sentinel `ZETA-9-ORANGE-7f3a` is generated once at fixture-authoring time, stored
in the fixture, and passed to the submodule via `--sentinel`. The fixture's content
(round-2's "describe what you see" target) is the `def resolve_alias` function and the
`TokenBucket` class.

### 4.2 The prompt template

`providers/fixture/prompt-template.txt` (new):

```
Round 1: Read the following file and respond with exactly the sentinel token found in it, nothing else.
{{FIXTURE_CONTENT}}

Round 2: Describe the function signatures and class definitions in the file above. Be specific.
```

The submodule interpolates `{{FIXTURE_CONTENT}}` (the fixture file's contents) and
`{{SENTINEL}}` (the token) into the prompts it sends to the model under test. The
template is toolkit-owned so the wording can evolve without submodule changes.

### 4.3 The judge rubric

`providers/rubric/code-visibility-rubric.json` (new):

```json
{
  "scale": [0, 1, 2, 3],
  "threshold": 2,
  "criteria": {
    "0": "response is empty, an error message, or a refusal",
    "1": "response is generic boilerplate with no fixture-specific detail",
    "2": "response names at least one fixture-specific detail correctly",
    "3": "response accurately describes multiple fixture-specific details"
  },
  "fixture_specific_details": [
    "function resolve_alias",
    "class TokenBucket",
    "parameters provider_id and model_id",
    "TokenBucket __init__ takes rate and capacity"
  ]
}
```

### 4.4 The superpowers-TUI test (layer 4)

`scripts/verify_superpowers_tui.sh` (new) launches the real `claude` binary against
`~/.claude-prov-<id>` non-interactively with a scripted prompt that triggers a
superpowers plugin command (e.g. `/superpowers:using-superpowers`). It captures the
session transcript and PASSES iff:

1. The session launched without an "overwrite config?" prompt.
2. The superpowers plugin actually engaged (transcript contains the expected
   superpowers output marker).
3. The session exited cleanly within a timeout.

This is the §11.4.108 layer-4 (user-visible) verification — both for the alias's TUI
launch and for the per-alias config-file fix (Section 6): if the overwrite prompt were
still firing, the test would hang on the non-interactive timeout and fail.

### 4.5 The extended `VERIFIED_CACHE` schema

`VERIFIED_CACHE` (at `$(cma_providers_dir)/verification_cache.json`) gains per-layer
detail:

```json
{
  "<provider-id>": {
    "status": "verified",
    "model_id": "deepseek-chat",
    "checked_at": "2026-07-04T12:00:00Z",
    "layers": {
      "existence": {"pass": true, "evidence": "..."},
      "tool_call": {"pass": true, "score": 87, "evidence": "..."},
      "semantic": {
        "pass": true,
        "round1_sentinel": {"pass": true, "observed": "ZETA-9-ORANGE-7f3a"},
        "round2_judge": {"score": 3, "threshold": 2, "pass": true}
      },
      "superpowers_tui": {"pass": true, "transcript_path": "..."}
    }
  }
}
```

### 4.6 xAI special-case

> **CORRECTION (2026-07-04, post-implementation research — supersedes the paragraph
> below).** Fresh §11.4.99 research (`docs/research/2026-07-04-provider-api-endpoints.md`)
> found that **xAI DOES expose `GET https://api.x.ai/v1/models`** (OpenAI-shaped
> `{"object":"list","data":[...]}`, carries `context_length`), plus a native
> `GET /v1/language-models`. So xAI is **not** a "no-endpoint / scrape-the-docs"
> outlier — the existence layer treats it like the other OpenAI-shaped providers.
> The only real nuance is that xAI's docs pages steer users to a console table and
> `/v1/models` can return alias ids (e.g. `"latest"`), so model-id resolution should
> tolerate alias ids. The genuine deviation among the providers is **OpenRouter**
> (`GET https://openrouter.ai/api/v1/models` is public/no-auth and returns a bare
> `{"data":[...]}` with **no** `"object":"list"`). Phase 2 implements per this
> correction, not the superseded paragraph.

~~xAI has no documented `/models` endpoint (verified during research, 2026-07-04). The
existence layer special-cases xAI: it scrapes `https://docs.x.ai/docs/models` (or reads
a cached copy under `providers/cache/xai-models.json` refreshed daily) and confirms the
configured model id appears in the known list.~~ (Superseded — see the correction above.)

## 5. `list` / `list-all` / `list-faulty` + Activation Gate (Design Section 4)

### 5.1 The three list subcommands

`claude-providers.sh` `cmd_list` is split:

- **`list`** (default) — only `verified` aliases. This is what `install.sh`'s session
  hook uses; this is what an operator sees when they ask "what works right now?"
- **`list-all`** — every configured alias (current `list` behavior). For operators
  auditing the full set.
- **`list-faulty`** — only `failed` + `unverified` aliases. For operators diagnosing
  what to fix.

Each subcommand accepts `--json` for machine consumption (the session hook uses
`--quiet --refresh-aliases`). Output columns: alias name, provider, model, status,
last-checked timestamp, failing layer (if any).

### 5.2 The activation gate

`cma_run_provider <id>` (the shell function installed in `$ALIAS_FILE`) checks the
cached verification status at launch time:

- `verified` → launch Claude Code normally.
- `unverified` or `failed` → refuse to launch, print an actionable message:
  ```
  Alias <id> is <status>: <failing layer> did not pass.
  Run: claude-providers verify <id>
  Override: <id> --force   (operator only — unverified/failed aliases may not work)
  ```
- `pending` → refuse with "verification in progress, retry shortly" (or launch with a
  warning after a short timeout — implementation plan decides).
- `--force` override → launch with a warning banner. Documented as operator-only.

The gate reads `VERIFIED_CACHE` (no network on launch). A stale cache (> TTL) triggers
a background re-sync (Section 5.3) but does NOT block launch — the cached status is
authoritative for launch decisions; the background re-sync refreshes it for the next
launch.

### 5.3 Session-sync hook (install.sh + rc files)

`install.sh` is extended to install a session-refresh hook in `$ALIAS_FILE` (sourced
from `~/.bashrc` + `~/.zshrc` on Linux, `~/.zshrc` only on macOS — reusing
`cma_ensure_alias_file`):

- **Install-time**: `install.sh` runs `claude-providers sync` once after bootstrap
  (non-fatal if it fails — the host may lack keys/network at install time).
- **Session-time**: a `cma_providers_session_refresh` function fires on every
  interactive shell startup. It calls `claude-providers list --quiet
  --refresh-aliases` — **no network**, just re-writes alias shell functions from the
  cached `VERIFIED_CACHE`. Fast, idempotent.
- **TTL-triggered background re-sync**: if `VERIFIED_CACHE` is older than
  `CMA_PROVIDERS_SYNC_TTL` (default 24h), the hook triggers a detached
  `claude-providers sync &` (background, does not block the shell). The next launch
  sees the refreshed cache.

The `--refresh-aliases` flag (new on `list`) re-writes the alias shell functions in
`$ALIAS_FILE` from the cache — no network, no probe, just the shell-function
regeneration step of `sync`. The hook is bracketed by marker comments
(`# cma-providers-session-refresh BEGIN/END`) and replaced atomically so re-sourcing
does not double-install.

`.profilerc` is not used — `cma_ensure_alias_file` manages `~/.bashrc` + `~/.zshrc` on
Linux and `~/.zshrc` on macOS, which is the existing, tested path.

## 6. Per-Alias Config Files — The Overwrite-Prompt Fix (Design Section 6)

> **RESOLVED (2026-07-04, systematic-debugging — full record:
> `docs/investigations/2026-07-04-config-overwrite-prompt.md`).** The premise of this
> section (a **shared** `settings.json` symlink triggering an overwrite prompt) was
> WRONG: `settings.json` is already excluded from `CMA_SHARED_ITEMS` and each config dir
> gets its OWN via `cma_own_settings_seed`; `.claude.json` was never shared for provider
> dirs. The actual prompt is Claude Code's per-workspace **trust dialog**, ALREADY fixed
> by `c6fe153` (sticky-trust merge) + `cma_trust_project` (per-alias owned `.claude.json`
> + pre-launch trust seeding), covered by `test_session.sh:199-220` + `test_unify.sh`.
> **No code change was needed** (§11.4.124 investigate-before-change). The "owned config
> layout" this section proposes is already the state of the tree. The design below is
> retained as the rationale; treat it as descriptive of the existing implementation, not
> pending work. The live layer-4 (no-prompt) proof is the Phase-2 superpowers-TUI test.

### 6.1 Root cause (CONFIRMED — see the RESOLVED note above)

The overwrite prompt fires because provider dirs (`~/.claude-prov-<id>`) symlink
`settings.json` and `.claude.json` into the shared tree (`$SHARED_DIR`), the same model
used by `claude1..N`. When another account's session updates the shared file, the next
provider-alias launch sees a "foreign" config and offers to overwrite. The fix: each
provider alias gets **its own owned config files**, so nothing drifts under it.

### 6.2 The per-alias config layout

```
~/.claude-prov-<id>/
  ├── settings.json          ← OWNED (real file, not symlink) — per-alias, stable
  ├── .claude.json           ← OWNED (real file, not symlink) — per-alias, stable
  ├── CLAUDE.md              ← symlink → $SHARED_DIR/CLAUDE.md (user-scope memory IS shared)
  ├── plugins/               ← symlink → $SHARED_DIR/plugins (plugins ARE shared)
  ├── projects/              ← symlink → $SHARED_DIR/projects (history/projects shared)
  ├── todos/                 ← symlink → $SHARED_DIR/todos
  ├── plans/                 ← symlink → $SHARED_DIR/plans
  ├── history.jsonl          ← symlink → $SHARED_DIR/history.jsonl
  └── .credentials.json      ← absent (token injected from env via cma_run_provider)
```

Shared-by-symlink for cross-account state (plugins, projects, todos, plans, history,
CLAUDE.md); owned-not-shared for per-alias config (`settings.json`, `.claude.json`).

### 6.3 The per-alias `settings.json`

Written once at `sync` time, regenerated only when the always-on plugin set or model
selection changes — never on every launch, so no overwrite prompt:

```json
{
  "color": "purple",
  "enabledPlugins": {
    "superpowers@anthropics": true,
    "systematic-debugging@anthropics": true,
    "frontend-design@anthropics": true,
    "code-review@anthropics": true
  }
}
```

### 6.4 The per-alias `.claude.json`

Minimal, stable:

```json
{
  "projects": {},
  "mcpServers": {},
  "version": "<claude-code-version>"
}
```

The `projects/` *directory* is symlinked (shared history), but the `.claude.json`
*file* is owned — so the runtime `cma_merge_claude_json` that churns the shared
`~/.claude/.claude.json` across accounts does not fire for provider dirs (they are
already excluded from `cma_detect_accounts` per the 2026-06-16 design's `*-prov-*`
skip; this just makes the file owned too, for consistency).

### 6.5 Migration from the old layout

Existing `~/.claude-prov-<id>` dirs have `settings.json` + `.claude.json` as symlinks
into `$SHARED_DIR`. `sync` migrates them idempotently:

1. Detect symlink-at-`settings.json` (the old layout).
2. Read the symlink target's content (for any operator overrides).
3. Write a real `settings.json` at the provider dir with the per-alias content
   (Section 6.3), merging any per-provider overrides from `providers/overrides.json`.
4. Remove the symlink via `backup_and_remove` (renames to `.preunify.<timestamp>`).
5. Same for `.claude.json`.

A second `sync` sees real files (not symlinks) and skips. Rollback via
`claude-rollback` works — the migration uses `backup_and_remove`, so the old symlinks
are recoverable.

### 6.6 Verification the prompt is gone

The superpowers-TUI test (Section 4.4) doubles as the prompt-gone verification: it
launches Claude Code against the provider dir non-interactively. If the overwrite
prompt were still firing, the test would hang waiting for input (or fail on a
non-interactive timeout). Test passing = no prompt = fix confirmed. This is §11.4.108
layer-4 for this fix.

## 7. Testing Strategy (Design Section 7)

### 7.1 Three test tiers

| Tier | Where | Network | Keys | What it proves |
|---|---|---|---|---|
| **A. Hermetic unit/sandbox** | `scripts/tests/test_providers.sh` + new files | no | no | Logic correctness: list split, cache reads, gate decisions, migration, rc-hook idempotency |
| **B. Live host verification** | `scripts/tests/proof/verify_providers_live.sh` (new) | yes | yes (env) | Real providers pass all 4 layers on this host — §11.4.108 layer-3/4 evidence |
| **C. Constitution/conformance** | `scripts/tests/proof/verify_constitution.sh` (new) | no | no | CONST-051 decoupling holds, §11.4.151 tag prefix consistent, no force-push, GEMINI.md lockstep |

### 7.2 Tier A — hermetic sandbox tests (new cases)

All hermetic tests use `make_sandbox` (mktemp `$HOME`, rebind env vars,
`CLAUDE_BIN=/usr/bin/true`). No real `~/.claude*`, no network, no API keys.

1. **`test_list_split`** — `cmd_list` returns only `verified`; `list-all` returns all;
   `list-faulty` returns only `failed`/`unverified`. Three fake provider dirs at each
   status, assert the three outputs partition correctly.
2. **`test_activation_gate`** — `cma_run_provider <id>` for `unverified`/`failed`/
   `pending` refuses with the actionable message; `verified` proceeds; `--force`
   overrides. Stub `CLAUDE_BIN` records argv, never launches Claude Code.
3. **`test_per_alias_config_files`** — old symlink layout migrates to owned real files
   with expected JSON content; symlink backups exist as `.preunify.<ts>`; second
   `sync` is a no-op. Asserts no overwrite prompt can fire.
4. **`test_session_sync_hook`** — fresh interactive subshell sources `$ALIAS_FILE`;
   `cma_providers_session_refresh` fires exactly once, calls `claude-providers list
   --quiet --refresh-aliases` (stubbed, no network), respects `CMA_PROVIDERS_SYNC_TTL`
   (old TTL file → refresh; fresh → skip). Marker-comment pair replaced atomically;
   re-sourcing does not double-install.
5. **`test_xai_specialcase`** — fake xAI provider (no `/models` endpoint stubbed)
   falls through to the docs-scrape/cached-list path and reports `verified`/`unverified`
   rather than crashing.
6. **`test_verification_cache_format`** — extended `VERIFIED_CACHE` schema round-trips
   through `jq`: status, per-layer booleans, sentinel/judge scores, `checked_at`,
   `model_id`, `provider_id`. Read/write/idempotent-rewrite.
7. **`test_semantic_fixture_independence`** — the toolkit's fixture and rubric are read
   from `providers/` (toolkit-owned), NOT from inside `submodules/LLMsVerifier/`.
   Asserts CONST-051 boundary (the submodule binary accepts fixture/prompt/sentinel as
   CLI args; does NOT bundle toolkit fixtures).
8. **`test_providers_help`** — `list --help`, `list-all --help`, `list-faulty --help`
   produce correct usage text and exit 0.

### 7.3 Tier B — live host verification

Read-only against the real host config; writes evidence to `scripts/tests/proof/`.
**SKIPs with a reason (never fakes PASS, §11.4.3)** when preconditions are absent:
no key → "skip: no key for <provider>"; no network → "skip: no network"; no `go` →
"skip: no go"; `CLAUDE_BIN` not real `claude` → "skip: not real claude binary".

Per configured provider alias with preconditions present:
1. **Existence** — `claude-verify-providers` (LLMsVerifier `code-verification`) or the
   `/models` curl probe; capture stdout+exit to `proof/providers-<id>-existence.txt`.
2. **Semantic** — two-round sentinel+judge via LLMsVerifier `semantic-code-visibility`;
   capture round-1 + round-2 to `proof/providers-<id>-semantic.json`.
3. **Superpowers-TUI** — launch real `claude` against `~/.claude-prov-<id>`
   non-interactively with a scripted superpowers prompt; capture transcript to
   `proof/providers-<id>-superpowers.txt`; PASS iff plugin engaged AND no overwrite
   prompt. §11.4.108 layer-4.
4. **Aggregate** — `proof/providers-summary.json` with per-alias final status + per-layer
   evidence paths. §11.4.83 end-user evidence.

`run-proof.sh` is extended to invoke this verifier. The existing `PROOF.md` generator
pulls from `providers-summary.json`.

### 7.4 Tier C — constitution/conformance

Static checks, no network:
- **CONST-051**: grep `submodules/LLMsVerifier/` for `claude_toolkit`, `cma_`,
  `claude-providers`, toolkit paths, release-tag prefix — zero hits. The
  `semantic-code-visibility` command's fixture/prompt/sentinel/rubric come from CLI
  args, not bundled defaults referencing the toolkit.
- **§11.4.151**: release-tag prefix in main repo `.env` matches the submodule's; both
  equal `HELIX_RELEASE_PREFIX` or lowercased project-root dir name.
- **§11.4.113**: no force-push in any release script.
- **§11.4.157**: `GEMINI.md` exists and matches `CLAUDE.md`/`AGENTS.md`/`QWEN.md` size
  within tolerance (lockstep).
- **§11.4.156**: CI/CD disabled (`.github/workflows/` empty/absent, `.gitlab-ci.yml`
  absent).

### 7.5 Determinism (§11.4.50)

- Tier A: fully deterministic (no network, no real keys, no real `claude`, stubbed
  `CLAUDE_BIN`).
- Tier B: non-deterministic by nature (live network + live model) — SKIP-by-default in
  CI, run on the host after `install.sh`. Summary JSON records `checked_at` so stale
  evidence is detectable.
- Tier C: deterministic (static grep checks).

### 7.6 Test-running commands

```bash
# Hermetic only (CI-grade)
bash scripts/tests/run-all.sh providers

# Full proof suite (Tier A + B + C), SKIPs live layers if preconditions absent
bash scripts/tests/run-proof.sh

# Constitution/conformance only
bash scripts/tests/proof/verify_constitution.sh
```

## 8. Docs, Release, and Versioning (Design Section 8)

### 8.1 Documentation updates

**A. `Claude_Multi_Account_Fine_Tuning.md`** — new/updated sections: the 4-layer
pipeline + tightened statuses + xAI special-case + models.dev enrichment + the
unconfirmed file-forwarding premise; the `claude-providers` CLI reference (`list`/
`list-all`/`list-faulty`/`sync`/`verify`/`--refresh-aliases`/`--force`); the per-alias
config layout + overwrite-prompt fix; the session-sync hook; troubleshooting.

**B. This spec** — `docs/superpowers/specs/2026-07-04-provider-verification-design.md`.

**C. The implementation plan** — `docs/superpowers/plans/2026-07-04-provider-verification-plan.md`
(written by `superpowers:writing-plans`).

**D. Graphs/diagrams/schemes (new)** — pipeline diagram (4 layers + status
transitions); status state-machine (`pending → verified | unverified | failed`);
per-alias config layout diagram (owned vs symlinked); session-sync timing diagram
(install-time → session-time → TTL background).

**E. Templates/definitions (new)** — `docs/templates/provider-alias.template.json`
(canonical per-alias `settings.json`); `provider-verification-cache.template.json`
(extended `VERIFIED_CACHE` shape); `provider-fixture.template.md` (sentinel-fixture
pattern for operators authoring alternative fixtures).

### 8.2 FAQs (new)

`docs/faq/` (or a manual appendix) covering: why `list` shows fewer aliases now; why
an alias won't start; `unverified` vs `failed`; why the overwrite prompt is gone; whether
the semantic test assumes file-forwarding (no — it empirically verifies it); how to
add a new provider; why xAI is special-cased.

### 8.3 Latest-source citations (§11.4.99, §11.4.150)

Every provider-specific claim in the docs carries a cited source URL + retrieval date:
models.dev `api.json`; each provider's `/models` API docs; xAI's docs page; the
Anthropic Messages API docs + claude-code-router README for the unconfirmed premise
(labeled "empirically verified, not assumed"). Web searches re-run during
implementation so citations reflect ship-time docs.

### 8.4 Constitution update

`submodules/LLMsVerifier/CLAUDE.md` gets:
- **CONST-052 (new)**: the `semantic-code-visibility` boundary contract (Section 3.4).
- **§11.4.X (new)**: submodule capabilities that empirically verify a consumer's
  load-bearing premise MUST document that premise as unconfirmed-in-upstream-docs and
  frame the capability as empirical verification, not assumption.

The main-repo `CLAUDE.md` gets a cross-reference to the new verification pipeline + the
per-alias config layout.

### 8.5 Release

**Version:** v1.12.0 (proposed — minor bump for new user-visible behavior: `list`
semantics change + new subcommands + activation gate + config layout change + session
sync hook). Bumped in main repo + `submodules/LLMsVerifier/` in lockstep (§11.4.151).

**Release-tag prefix:** `HELIX_RELEASE_PREFIX` from `.env` else lowercased project-root
dir name — identical across main repo + submodule. Tag: `<prefix>/v1.12.0` on both.

**Change logs:**
- Main repo: the 11-point overhaul, grouped by user-facing behavior / CLI / config /
  docs / tests / constitution.
- LLMsVerifier submodule: the new `semantic-code-visibility` command + CONST-052,
  scoped to the submodule's own changes (no toolkit references — CONST-051).

**Release flow (gh + glab, §11.4.113 no force-push):**
1. Commit all work to `main`; bump submodule pointer; commit the bump.
2. Update `docs/CONTINUATION.md` + `.remember/remember.md` in the SAME commit as every
   state advance (§6.S / §11.4.131).
3. Tag both repos `<prefix>/v1.12.0` from `main`.
4. `git push origin <prefix>/v1.12.0` (no `--force`) on both.
5. Mirrors reconcile via MERGE commit (GitHub, GitLab, GitFlic, GitVerse) — no
   force-push (gitflic/gitlab block it).
6. `gh release create <prefix>/v1.12.0 --notes-file <main-changelog>` on GitHub.
7. `glab release create <prefix>/v1.12.0 --notes-file <main-changelog>` on GitLab.
8. Repeat gh/glab release for the LLMsVerifier submodule with its own changelog.
9. Verify all four mirrors agree on tag + HEAD (standing practice per
   [[release-tag-divergence]]).

**Pre-release gate:** `bash scripts/tests/run-proof.sh` MUST pass (Tier A green, Tier B
green-or-SKIP-with-reason, Tier C green) before tagging. §11.4.108 layer-4 evidence for
the release itself.

## 9. Out of scope

- New mirrors beyond the existing four (GitHub, GitLab, GitFlic, GitVerse).
- Changing the release-tag prefix (inherits `HELIX_RELEASE_PREFIX`).
- Replacing the existing `model_verify.py` scoring engine (extended, not replaced).
- Adding new providers — the operator's `providers/<id>.env` is the source of truth;
  this overhaul makes existing providers verifiable, not new ones.
- The `claude1..N` account-dir config layout (unchanged — only provider dirs get the
  owned-config split).

## 10. Open questions for the implementation plan

- The exact `pending`-status launch behavior (refuse-with-retry hint vs. launch-with-
  warning after a short timeout) — the implementation plan decides based on UX.
- The judge-model default (which provider/model the toolkit ships as the default
  judge for round 2) — the implementation plan picks a sensible default and makes it
  overridable via `providers/judge.env`.
- Whether the TTL background re-sync is a `nohup`/`disown` shell background job or a
  single-shot systemd user unit — the implementation plan picks the portable default
  (`nohup`/`disown`, §11.4.89) since systemd is not universally available.
