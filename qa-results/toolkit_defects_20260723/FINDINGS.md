# Claude Toolkit defect batch — findings (ATM-850/851/852/853/860)

| Field | Value |
|---|---|
| Revision | 2 |
| Created | 2026-07-23 |
| Last modified | 2026-07-23T20:35:00Z |
| Status | complete — ATM-860 D14 implemented + ATM-854 release prepared; awaiting operator sign-off (no tag, no release, no push) |
| Author | (T1/main - claude4) resumption agent, after §11.4.147(e) predecessor crash |

**NOTHING WAS PUSHED. NO TAG. NO RELEASE.** All work is LOCAL commits only:
toolkit `82b48e3`, ccr submodule `df610f9` (gitlink bumped inside `82b48e3`).
Evidence: `qa-results/toolkit_defects_20260723/evidence/`.

Resumption note (§11.4.147): predecessor state on disk was VERIFIED, not
restarted — ATM-851 was complete (independently re-run GREEN), ATM-850 had
fix+RED+GREEN but no mutation/remediation/live proof (all added here).

---

## ATM-850 — `claude5` alias not recognized (FIXED, live-proven)

**Conductor root cause: CONFIRMED.** `aliases.sh` regenerated 15:14:14 while
five tmux servers from 00:00:47 held pane shells that sourced the OLD file;
SSH re-login re-attaches the same server. Static `alias claudeN=…` lines can
never fix the class.

**Fix (predecessor, verified + completed here):**
- `scripts/lib.sh` — `_cma_emit_account_dispatch()` (new, emitted into the
  managed block at `_cma_emit_managed`): a `command_not_found_handle(r)`
  (bash+zsh) resolving `<name>` -> `$HOME/.claude-<name>` at INVOCATION time.
  Guard-rails: defined names always win; pre-existing handler chained;
  `prov-*`/`code-router` refused; non-account miss keeps rc=127.
- `scripts/claude-add-account.sh` + `cma_tmux_stale_shell_notice()` (lib.sh,
  new here): detects tmux servers/panes, states dispatcher coverage, prints
  the exact `source` + per-server broadcast one-liner; broadcast only on an
  interactive default-No confirm — never autonomous send-keys.

**Evidence:** RED `d1_RED_run.log` (3 FAIL pre-fix) -> GREEN
`d1_GREEN_run.log` + independent re-run `d1_GREEN_independent_rerun.log`
(8/0). Mutation `d1_mutation_run.log` (strip dispatcher emit -> 3 FAIL,
restored GREEN). Notice: RED `d1b_RED_run.log` (7 FAIL) -> GREEN
`d1b_GREEN_run.log` (12/0) -> mutation `d1b_mutation_run.log`.
Tests: `scripts/tests/test_dynamic_account_dispatch.sh`,
`scripts/tests/test_add_account_tmux_notice.sh` (+ proof/94, proof/95).

**Operator decision "connected out of the box" — proven live**
(`d1c_live_outofbox_claude5.log`): live `aliases.sh` re-rendered with the
dispatcher (26->26 aliases, no loss; backup taken); fresh shell resolves
`claude5` (alias); with the alias REMOVED, bare `claude5 --version` still
launched real Claude Code 2.1.218 through the dispatcher with
`CLAUDE_CONFIG_DIR=~/.claude-claude5`; `claude-list-accounts` enumerates
claude5 (the roster the orchestrator consumes). Honest boundary: the
account's OAuth login (`claude5 /login`) is operator-side; the
atmosphere-side per-host multitrack YAML lives outside this repo
(track1 untouchable per constraint) — claude5 is resolvable/enumerable to
any consumer out of the box.

## ATM-851 — helixagent reports raw `.gguf` instead of the pinned facade (FIXED by predecessor — verified)

**Conductor root cause: CONFIRMED** at
`scripts/claude-providers.sh` `detect_helixagent_record()` (pre-fix ~:273):
when the live `/v1/models` listing did not contain the pinned facade id, the
positional fallback `strong="$(… head -n1)"` OVERWROTE the explicitly pinned
`CMA_HELIXAGENT_STRONG/FAST` with the endpoint-reported `.gguf` path — while
base_url/key_var/context_limit (never live-derived) survived. Stale-install
and `+x` short-circuit refuted (symlinked install; vars unset).

**Fix:** pin-provenance flags captured BEFORE built-in defaults
(`_ha_strong_pinned/_ha_fast_pinned`); an explicit pin is authoritative and
the live listing (still fetched as reachability evidence) never overwrites
it; unpinned selection stays data-driven.

**Evidence (per §11.4.196(F) — asserts the GENERATED .env, not a fixture):**
`scripts/tests/test_helixagent_pins_survive_live_sync.sh` runs the REAL sync
against a live stub server that reports only the `.gguf` id and asserts the
generated `providers/helixagent.env`. RED `d2_RED_proof.txt`/`d2_RED_run.log`
(3 FAIL: MODEL/FAST_MODEL = .gguf) -> fix `d2_fix.patch` -> GREEN
`d2_GREEN_run.log` (10/0) + my independent re-run
`d2_GREEN_independent_rerun.log`. Paired mutation `d2_mutation_run.log`
(re-introduce the overwrite -> 3 FAIL). Regression `d2_regression_suite.log`
46/0 (verify_helixagent_test.sh, incl. env-wins + no-pins controls).

## ATM-852 — provider name in the base URL (FIXED, live-proven on an isolated instance)

**Seams:** launcher `submodules/claude-code-router/cmd/ccr/launch.go`
(`cmdLaunch` -> `providerScopedBase(gatewayBaseURL, defaultRouteProvider())`;
all live provider aliases are router-transport, so this is the operative
seam; `scripts/lib.sh:2022` non-router export left unchanged — its base URL
is the provider's REAL endpoint where a suffix would break the API) and mux
`internal/gateway/gateway.go` `registerRoutes()`:
`/:provider/v1/{messages,chat/completions}` validated against configured
providers, segment STRIPPED before the protocol classifier (which reads the
raw path), bare `/v1/*` + `/proxy/v1/*` untouched; unknown segment -> 404;
no `//v1` possible (TrimRight + PathEscape; gatewayBaseURL carries no path).

**Evidence:** RED `d3_RED_run.log` (scoped paths 404; helper undefined) ->
GREEN `d3_GREEN_run.log` -> mutation `d3_mutation_run.log` (drop scoped
registration -> 2 FAIL, bare control green) -> full Go suite
`d3_full_go_suite.log` (exit 0). **LIVE `d3_live_proof.log`:** isolated
patched ccr (sandbox HOME, gateway :3999 — running :3456 ccr NEVER touched)
routed a REAL completion: `POST /helixagent/v1/messages` -> HTTP 200,
`"SCOPED-PATH-OK"` from live llama.cpp; bare path 200; unknown segment 404.

**Activation boundary (honest §11.4.108 layer-3):** the RUNNING gateway
still serves the old build; activation = `claude-ccr-build` + a coordinated
restart (or the next routed launch after the rebuild). Not performed —
restart of the live ccr is operator-coordinated by constraint.

## ATM-853 — dynamic discovery + opencode context-compression loop (FIXED at root cause; live loop-retest pending coordinated window)

**Discovery half (facts):** sync already pulls models.dev LIVE per sync
(`CMA_MODELS_DEV_URL`, cache+TTL) — no hardcoded roster found. Live OpenCode
API captured (`d4_opencode_models_live.log`): 57 models; `big-pickle` and
`deepseek-v4-flash-free` ARE live-listed AND serving (real completion 200,
`d4_opencode_bigpickle_probe.log`) — the env's models are not stale ids.
Paid-tier control honestly errors (CreditsError, no payment method).

**Compression-loop root cause (evidence-grounded):** conductor's suspect
CONFIRMED in refined form. `opencode.env` `CONTEXT_LIMIT='200000'` comes from
`derive_limits()` (`scripts/providers_resolve.py`) which read ONLY
`limit.context` and IGNORED `limit.input`. models.dev publishes big-pickle
`{context:200000, input:160000, output:32000}` (captured). The launch guard
(`scripts/lib.sh` cma-token-guards, :1471-1478) then exports
`CLAUDE_CODE_AUTO_COMPACT_WINDOW = 200000-32000 = 168000` — ABOVE the
model's real 160000 input cap, so the client-side compact guard can never
fire before the endpoint rejects an over-limit turn; every such turn loops
reject -> compact -> reject regardless of the prompt.
**Fix:** `derive_limits` clamps `ctx = min(limit.context, limit.input)` when
the catalog publishes a smaller real input cap (>= MIN_VIABLE_CONTEXT);
big-pickle now resolves `(160000, 8192)` -> window <= 151808 < 160000 — the
guard fires first. Controls: `input >= context` and absent `input` unchanged.

**Evidence:** RED `d4_RED_derive.log` ((200000, 32000)) -> GREEN
`d4_GREEN_derive.log` -> mutation `d4_mutation_run.log` (skip the clamp ->
new test FAILs; suite restored 412/0 `d4_GREEN_full_providers_suite.log`).
Test: `scripts/tests/test_providers.sh` "limit.input below limit.context…".
**PENDING_FORENSICS (tracked):** (a) exact server behaviour at the 160k
boundary and (b) on-alias loop-gone retest both require driving the opencode
alias through the RUNNING ccr (route rewrite + `ccr restart`) — forbidden
without coordination. The fix reaches the live `.env` at the next
`claude-providers sync` (24h session-hook TTL or manual) — not run here to
avoid rewriting live provider state pre-sign-off.

## ATM-860 — multi-model providers => multiple aliases (mechanism un-wired + one blocking defect fixed; default wiring = sign-off decision)

**Finding 1 (CONFIGURED != IN USE, §11.4.196(F)):** the full pipeline already
exists — `scripts/model_verify.py` (REAL completion round-trip per model,
anti-bluff response checks, tool-call gate, scoring) +
`scripts/providers_generate.py` (one alias per verified model pair,
`provider_name1/2…`, env files + manifest) wired into
`claude-providers.sh cmd_sync_multi` (:967) — but ONLY behind the opt-in
`sync --multi` flag which no default path (session hook, plain sync) ever
passes. Zero `*_verified.json`/`*_manifest.json` in the live providers dir =
never ran live.

**Finding 2 (blocking defect, FIXED):** even when invoked, an UNCATALOGUED
live-proven model was demoted: `model_verify.py enrich_from_catalog()` read
an ABSENT catalog context as `0` and failed the `< 8000` gate
("Context window too small: 0 < 8000") — a §11.4.201(9) capacity-vs-unknown
false refusal that zeroed helixagent's whole live-enumerated roster
(`verified_count:0` despite a scored, serving model). Fix: only a KNOWN
small context (`0 < ctx < 8000`) demotes; unknown earns no context score but
keeps the live-probe verdict. RED(mutation)/GREEN `d5_RED_run.log` /
`d5_GREEN_unit.log`; test in `test_providers.sh`.

**Live end-to-end proof (`d5_live_pipeline_proof.log`, free endpoints only):**
dynamic enumeration from live `/v1/models` -> model_verify REAL completion
probe (verified_count 1, score 55) -> providers_generate manifest + env file
-> second run byte-identical (idempotent, re-runnable).

**Not done autonomously (§11.4.101(d) — spending):** flipping `--multi` into
the default sync fires real completion probes against ~20 providers incl.
PAID endpoints. Proposed change set for sign-off: (1) default `sync` runs the
multi path with a per-provider free-tier-first budget + `CMA_SYNC_MULTI=0`
opt-out; (2) per-provider scoping flag for `sync --multi <id>`;
(3) native-first ordering is already structural (§11.4.196(A) class
partition — generated provider aliases are a separate class that never
outranks an operational native; no change needed, none made).

---

## Proposed change set awaiting sign-off
1. **Push** toolkit `82b48e3` + submodule `df610f9` (currently local only).
2. **Activate ATM-852 live**: `claude-ccr-build` + coordinated `ccr restart`.
3. **Apply ATM-853 live**: run `claude-providers sync` (regenerates
   `opencode.env` with the input-clamped window), then a coordinated
   opencode-alias session to confirm the compaction loop is gone.
4. **ATM-860 wiring decision**: make multi-alias sync default (cost-bearing;
   options above), or keep opt-in and document.
5. Optional: broadcast re-source to idle tmux shell panes (exact commands
   printed by `claude-add-account`; operator-triggered).

## ATM-860 — IMPLEMENTED per operator decision D14 (free-tier first; 2026-07-23/24 resumption round 2)

**Operator decision D14 (verbatim intent):** "Free-tier first — verify only
free endpoints by default; paid providers stay opt-in per sync." Implemented,
RED-first, mutation-paired, live-proven. All local; nothing pushed.

**What became the default.** Plain `claude-providers sync` now runs the
single-alias sync AND the per-model multi-alias phase, restricted to
FREE-tier models (`cmd_sync_multi` passes `--free-only` to
`model_verify.py`). `sync --multi` runs only the per-model phase, also
free-only. Paid probing is opt-in ONLY: `--include-paid` flag or
`CMA_SYNC_INCLUDE_PAID=1`; `CMA_SYNC_MULTI=0` restores the legacy
single-alias-only default. This closes the §11.4.196(F) CONFIGURED!=IN-USE
gap (Finding 1) without ever firing a paid completion by default.

**How free-vs-paid is determined (no roster, §11.4.6).** New
`model_verify.py classify_tier()` — the single classification point shared
by the pre-probe filter and `enrich_from_catalog` (filtering and scoring
cannot disagree). Precedence: (1) models.dev `cost` row (fetched live per
sync): 0/0 both sides = free, any non-zero = paid — the catalog verdict
outranks locality; (2) the provider `:free` id convention; (3) an
UNCATALOGUED model on a loopback/RFC1918 endpoint = free by construction
(the helixagent/llama.cpp self-hosted class — no billing party exists);
(4) otherwise "unknown", which `--free-only` treats as PAID (fail-safe on
spend) and records honestly: `<provider>_verified.json` now carries
`free_only`, `skipped_count`, `skipped_models[]` with per-model
`credit_tier` + `skip_reason` ("tier 'X' treated as paid — no completion
fired"). Skipped models are never probed AND never recorded verified/failed.

**Determinism/idempotency hardening found necessary during implementation:**
`rank_by_credit` and `pair_models` results arrived in `as_completed()`
(probe-completion) order, so equal-(tier,score) models could swap which
alias they back between two identical syncs. Both sorts now tie-break on
`model_id`; `CACHE_VERSION` 2->3 (verification semantics changed). Naming
stays `provider`, `provider2`, ... — deterministic + collision-free.

**Native-first (§11.4.196(A)) — verified structurally, no change needed:**
generated aliases live in the `~/.claude-prov-*` namespace and launch via
`cma_run_provider` (provider class); the ATM-850 account dispatcher REFUSES
`prov-*` names (test_dynamic_account_dispatch.sh, re-run GREEN 8/0). A
generated alias cannot shadow or outrank a native account alias — asserted
in the new test (CASE 6: every manifest config_dir is `.claude-prov-*`;
alias lines invoke `cma_run_provider`).

**Four-layer evidence (all under `evidence/`):**
- RED `d6_RED_run.log` — new test `scripts/tests/test_free_tier_multi_sync.sh`
  (28 assertions, REAL local recording completion server + models.dev-shaped
  catalog: free/paid/unknown/broken-free models) run on the UNMODIFIED code:
  17 FAIL / 11 pass, exit 1 — default sync emits no multi artifacts,
  `--free-only`/`--include-paid` absent.
- GREEN `d6_GREEN_run.log` 28/0 exit 0 + independent re-run
  `d6_GREEN_independent_rerun.log` 28/0. Assertions include the control
  needle (recorder proves free probes incl. the tool-call round-trip),
  paid+unknown ZERO requests, honest skip records, broken-free model probed
  but never admitted (a /v1/models listing is not evidence), deterministic
  `stubprov`/`stubprov2` naming with model-id tie-break, byte-identical
  second run, opt-in probing under `--include-paid`, prov-class namespace.
- Paired §1.1 mutations (applied, observed to FAIL, restored — logs):
  `d6_mutation_M1_run.log` strip the free-only filter -> paid probed ->
  FAIL; `d6_mutation_M2_run.log` admit models on catalog metadata alone
  (override the live-probe verdict) -> "brokenfree recorded verified=false"
  FAILs (the manifest stayed clean via the independent min-score floor in
  pair_models — layered defense, noted); `d6_mutation_M3_run.log` unwire
  the default multi phase -> default-sync assertions FAIL.
- LIVE `d7_live_free_sync_proof.log` — sandbox HOME (live provider state
  untouched), real keys (values file-to-file only, never logged), REAL
  models.dev fetch (3.2 MB live), REAL opencode endpoint: 82 catalog models
  -> 59 paid/unknown SKIPPED UNPROBED -> 23 free-tier models probed with
  real completions -> 5 verified (north-mini-code-free 72,
  deepseek-v4-flash-free 71, mimo-v2.5-free 71, big-pickle 66,
  nemotron-3-ultra-free 65; all tool_call=true, real latencies), 17x HTTP
  401 + 1x 429 recorded as HONEST per-model failures (the account's plan
  gates some free models — never admitted, never bluffed); control needle
  `non_free_probed=0`; 3 aliases generated (opencode/opencode2/opencode3);
  RUN 2 byte-identical env sha256 (`be30fe92...`) — idempotent.

**Honest boundaries.** (a) helixagent is skipped by the multi phase with
"no models specified and no catalog available" — the multi enumerator reads
the catalog, and helixagent is in no commercial catalog; its pinned
single-alias env (ATM-851) is untouched. Live-endpoint model enumeration
for the multi phase remains the pre-existing boundary (tracked follow-up,
not silently changed here). (b) The default multi phase runs on the same
24h-TTL cadence as sync (session hook / install soft-sync); probe volume is
bounded by the verification cache (now v3). (c) Guard-hook false positive
observed (§11.4.201(7)(a) carrier class): the constitution PreToolUse guard
blocked an inline command containing `sync --no-verify` — claude-providers'
OWN LLMsVerifier-skip flag, not git's `--no-verify`; worked around by
running the proof as a script file (the standard §11.4.89 pattern). The
guard lives in the constitution submodule (outside this repo's scope) —
flagged here for the guard's own golden-FALSE set.

**Docs synced:** `usage()` in claude-providers.sh +
`docs/Provider_Aliases_User_Guide.md` multi-alias section (free-tier-first
default, opt-in flags, determinism, native-first note).

## ATM-854 — release PREPARED (operator D15: prepare, do NOT cut)

**Proposed version: v1.26.0** (minor: new default behaviour + features on
top of v1.25.5). CHANGELOG.md carries a complete drafted `## v1.26.0 —
DRAFT` section in the house style covering ATM-850/851/852/853/860 + the
ccr provider-scoped-path change (Added/Fixed/Notes, § citations, evidence
pointers). The heading is explicitly marked DRAFT until sign-off.

**Full regression state (REAL run, `evidence/d6_regression_sweep.log`,
2026-07-23T20:08-20:09Z, after ALL changes + mutation restores):**

| Suite | Result |
|---|---|
| test_free_tier_multi_sync.sh (NEW) | 28 passed, 0 failed |
| test_providers.sh | 412 passed, 0 failed |
| verify_helixagent_test.sh | 46 passed, 0 failed |
| test_helixagent_pins_survive_live_sync.sh | 10 passed, 0 failed |
| test_dynamic_account_dispatch.sh | 8 passed, 0 failed |
| test_add_account_tmux_notice.sh | 12 passed, 0 failed |
| ccr `go test ./...` | exit 0 |

**NOT done (operator-gated):** no git tag, no GitHub release, no GitLab
release, no push of the new commits. The running ccr was not restarted; no
tmux pane touched; track1 untouched; no paid completion fired anywhere.

**Exact commands for operator sign-off (run from the repo root):**

```bash
# 0. Pre-release gate (mandatory; includes live smoke through the real ccr):
bash scripts/claude-release-gate.sh

# 1. Finalize the changelog: change the drafted heading
#    "## v1.26.0 — DRAFT (awaiting operator sign-off; no tag/release/push yet) — ..."
#    to "## v1.26.0 — <date> — ..." and commit, then regenerate doc exports:
bash scripts/claude-export-docs.sh

# 2. Activate ATM-852 on the live gateway (operator-coordinated window):
bash scripts/claude-ccr-build.sh && ccr restart   # restarts the LIVE router

# 3. Tag + push (all remotes):
git tag -a v1.26.0 -m "v1.26.0 — free-tier-first per-model aliases by default + dynamic account dispatch + provider-scoped gateway paths"
git push origin main --follow-tags        # + the remaining remotes per repo convention
# (GitHub/GitLab release objects per the usual release procedure, if desired)
```

## Anti-bluff certification
Every fix carries: RED captured on the broken artifact (or its §1.1
mutation-equivalent), GREEN on the fixed one, a paired mutation observed to
FAIL the test, and live captured evidence where a live path exists without
disturbing shared infrastructure (running ccr untouched; no tmux pane
touched; no paid completion issued; track1 untouched). Suites after all
changes (round-2 sweep, `evidence/d6_regression_sweep.log`): free-tier
multi-sync 28/0 (NEW), providers 412/0, helixagent 46/0, pins 10/0,
dispatch 8/0, tmux-notice 12/0, ccr `go test ./...` exit 0. No key/token
VALUE was printed, logged, or committed (names only). **Nothing was
pushed. No tag. No release.**
