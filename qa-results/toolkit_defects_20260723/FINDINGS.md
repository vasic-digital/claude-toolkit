# Claude Toolkit defect batch — findings (ATM-850/851/852/853/860)

| Field | Value |
|---|---|
| Revision | 1 |
| Created | 2026-07-23 |
| Last modified | 2026-07-23T15:25:00Z |
| Status | complete — awaiting operator sign-off |
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

## Anti-bluff certification
Every fix carries: RED captured on the broken artifact (or its §1.1
mutation-equivalent), GREEN on the fixed one, a paired mutation observed to
FAIL the test, and live captured evidence where a live path exists without
disturbing shared infrastructure (running ccr untouched; no tmux pane
touched; no paid completion issued; track1 untouched). Suites after all
changes: providers 412/0, helixagent 46/0, pins 10/0, dispatch 8/0,
tmux-notice 12/0, ccr `go test ./...` exit 0. No key/token VALUE was
printed, logged, or committed (names only). **Nothing was pushed.**
