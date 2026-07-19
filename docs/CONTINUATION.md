# CONTINUATION — claude_toolkit

**Last updated:** 2026-07-19
**Last HEAD:** `main @ v1.19.0` (✅ **v1.19.0 RELEASED** — all providers on ccr + IPv4 fix. Tag `v1.19.0` on all 4 mirrors; gh + glab release objects live. Submodules clean.)
**Working tree:** clean
**Active branch:** `main`
**Next action:** Phase 2/3 provider verification work per the programme state below. 11 providers still failing (account-side: suspended accounts, expired keys).

## v1.19.0 — DELIVERED (commit fec3c4f)

All 12 active providers now route through ccr uniformly. Deepseek and xiaomi ported from native (Anthropic) transport to router (OpenAI-compatible) transport via overrides.json. IPv4 fix in providers-verify.sh (curl -4) resolves HTTP 000 on hosts with broken IPv6 routing. Full suite 27/27 green. Gh + glab releases live.

## v1.18.2 — DELIVERED (commit b51228e)

Follow-up to v1.18.1: the deployed alias file body was never regenerated because the migration guard at `cma_ensure_alias_file` lacked a marker for the new `ccr --help` check. Added `! grep -qF 'ccr --help'` to the guard so the provider body is rewritten on next install/sync. Full suite 27/27 green; helixagent verified.

## v1.18.1 — DELIVERED (commit 0e30dfb)

ccr identity guard fix: `ccr version` no longer works — positional args are profile names in the current CLI. Guard now uses `ccr --help` + `"ccr start"|"ccr serve"` patterns. 128k test hardened against harness env contamination. Full suite 27/27 green; proof all green; 8 live-verified providers. Gh + glab releases live. Constitution plugin synced (17 new commits).

## v1.12.3 — DELIVERED
`claude-session.sh` now sanitizes auto-derived session names to kebab-case: lowercase, trim leading/trailing whitespace, collapse whitespace/underscores to `-`, strip remaining characters that are not `[a-z0-9-]`, collapse consecutive `-`, and trim leading/trailing `-`. Tests added to `test_session.sh` for whitespace trimming, multi-space collapse, and special-character stripping. Full suite 20/20 green; install.sh re-run on real HOME; doc artifacts regenerated. Submodules clean.

## v1.12.2 — DELIVERED
`claude-unify.sh` now auto-registers `claude<N>` aliases for every pre-existing account dir, so existing users no longer have to run `claude-add-account` to get working `claude1..claude4` aliases. `lib.sh` account detection hardened to ignore `~/.claude-code-router` and `~/.claude-*.lock` dirs that share the `.claude-` prefix. Tests added to `test_unify.sh` (auto-registration on existing accounts) and `test_install.sh` (no bogus aliases for router/lock dirs). Full suite 20/20 green; install.sh re-run on real HOME verified all four native aliases resolve correctly. Doc artifacts regenerated. Submodules clean.

## v1.12.1 — DELIVERED (commits 4240e76..7382007)
judge.env.template default → groq/llama (different family; self-grade bias arXiv:2508.06709, verified live); providers-semantic.sh independence WARN (same-endpoint judge) + explicit exit-3→skip; overrides.json xai base_url https://api.x.ai/v1 (endpoint confirmed live); claude-providers.sh directory-keys-file clear die on BOTH cmd_sync + cmd_sync_multi; submodule I-1 (semantic cmd exit 3 for transport/infra vs exit 1 genuine-fail, 11/11 go tests) + CONST-069 (17b4bfb6). Suite 20/20 deterministic; final review READY.

## Phase 2 — DELIVERED (commits ea4417f..1bedc95, 11 commits)
- Task 1 driver `claude-semantic-visibility.sh` (ea4417f, tests 25ab80f). Task 2 adapter `providers-semantic.sh` + cmd_sync/cmd_verify (ed70c14). Submodule reconciled+pushed 7a3ae9a6 (pointer f084d9c). Task 3 layer-4 `verify_superpowers_tui.sh` (d1972b5, review-fixes f4b5ebb). Task 4 xAI generic /v1/models tests — NO-OP (f596c75). Task 5 Tier-B live verifier + live negative-case honesty PASS (1bedc95).
- Bugs found by REAL execution + fixed: -h pre-build, JSON-evidence-to-/dev/null, judge-url doubling (bd502ef, 38ff959); `--refresh-aliases` non-idempotence — write_alias re-ran migrations per alias (5693297, root-caused from captured diff, 42 flake-loops clean).
- Live proof: mistral→verified (round1✅+judge2/3), chutes/deepseek→unverified honestly; layer-4 classifier honesty proven live (neutral prompt did NOT false-match). Full suite 20/20 deterministic; submodule Go test ok.

## 0. Out-of-the-box resumption

A fresh session resumes with ZERO additional context by reading:
1. `.remember/remember.md` (moment-valid handoff — read FIRST)
2. this file (`docs/CONTINUATION.md`)
3. `docs/superpowers/specs/2026-06-16-provider-aliases-design.md` (approved design foundation)

Then `git fetch --all --prune` and re-enter `superpowers:brainstorming` at the clarifying-questions step (NOT exploration — already done).

## 1. Programme state

### Phase: Provider verification overhaul (in progress)

Overarching user request: extend provider/model validation & verification so that:
- LLMsVerifier eliminates all unverified models; provider API integration follows official online docs.
- Failed/unverified aliases MUST NOT bring up Claude Code — they return a clear message.
- `claude-providers list` → only verified; add `list-all` (current behavior) and `list-faulty`.
- A 4th semantic layer: "Do you see my codebase?" test (real confirmation, not HTTP 200).
- Final verification: fire up the provider alias with full Claude Code TUI and start using the superpowers plugin — verify this works.
- `install.sh` runs `claude-providers sync` on every new session via rc files.
- Each providers alias gets its own config file (investigate + fix the overwrite prompt).
- Full test coverage + live testing after `bash install.sh`.
- Constitution up-to-date + followed.
- Docs, guides, manuals, FAQs, diagrams extended + new ones created.
- New release with proper version + change logs via `gh` + `glab`.

### Decomposition decision (user-approved 2026-07-04)

Decompose into sub-projects; extend LLMsVerifier generically (project-not-aware, CONST-051). Each sub-project gets its own spec→plan→implement cycle. Verification sub-project brainstormed first.

### Brainstorming progress

- ✅ Phase 1: Explore project context — done. Read `claude-providers.sh`, `providers-verify.sh`, `claude-verify-providers.sh`, `model_verify.py`, `install.sh`, `test_providers.sh`, `submodules/LLMsVerifier/CLAUDE.md`, the 2026-06-16 design spec.
- ✅ Phase 2: Both clarifying questions answered — (1) decompose + extend LLMsVerifier generically; (2) semantic test = two-round sentinel + judge (Option C).
- ✅ Phase 3: Approach A selected — generic `semantic-code-visibility` in LLMsVerifier + toolkit-owned fixture/prompt/rubric/superpowers-TUI test.
- ✅ Phase 4: All 8 design sections presented + approved per-section (architecture+boundaries, LLMsVerifier capability, toolkit seams, list/list-all/list-faulty+gate, install.sh session sync, per-alias config files, testing strategy, docs/release).
- ✅ Phase 5: Spec written to `docs/superpowers/specs/2026-07-04-provider-verification-design.md`.
- ✅ Phase 6: Spec self-review — fixed §2.1 status contradiction; no placeholders; scope tight; open questions deferred to plan.
- ✅ Phase 7: User approved ("continue everything now!").
- ✅ Phase 8: `superpowers:writing-plans` — Phase-1 (toolkit-side) implementation plan written to `docs/superpowers/plans/2026-07-04-provider-verification-plan.md`.

### Implementation phases (from the plan's decomposition)

- ✅ **Phase 1 (toolkit-side)** — COMPLETE (8/8). Commits: `249400b` T1 status cache, `49932bc` T2 cmd_sync persists status, `e6c881b` T3 list/list-all/list-faulty, `09d4618` T4 activation gate, `0d958e3` T5 --refresh-aliases/--quiet, `0323ea2` T6 install.sh session hook, T7 config-overwrite investigation (this commit — no code change, already fixed), T8 suite-green + CONTINUATION. Full suite 20/20 green throughout.
- 🔨 **Phase 2 (semantic + live)** — Go command DONE + LIVE-PROVEN; toolkit wiring is the remaining implementation. Plan: `docs/superpowers/plans/2026-07-05-phase2-semantic-live-plan.md` (verified). Ready to EXECUTE the 6 tasks — fully de-risked:
  - **LIVE PROOF (real evidence, independently re-run):** `docs/qa/2026-07-04-semantic-visibility-live/report.md` — a real Groq model (llama-3.3-70b) received the toolkit fixture through the built `semantic-code-visibility` binary and returned the sentinel `ZETA-9-ORANGE-7f3a` verbatim (`overall_pass:true`, exit 0). Reproduced by the orchestrator. The headline capability WORKS end-to-end. (DeepSeek = honest 402-billing SKIP.) Groq base = `https://api.groq.com/openai` (binary appends `/v1/chat/completions`).
  - **Infra map** (`docs/research/2026-07-04-live-verify-infra-map.md`): Phase-2 Task 5 EXTENDS the EXISTING `scripts/tests/verify_providers_live.sh` (existence-only today; append layers 3–4 before its `summary`, keep the SKIP guard; wired into `run-proof.sh:28-31`). Reuse `scripts/tests/verify_claude_live.sh`'s `--use-superpowers` PTY machinery (+ `lib/pty_drive.py`) for layer 4. Do NOT create a `proof/` duplicate. New files to ADD: `scripts/claude-semantic-visibility.sh` (driver, mirror `claude-verify-providers.sh:57-63` build-cache pattern), `scripts/providers-semantic.sh` (layer-3 adapter), `scripts/verify_superpowers_tui.sh` (layer-4).
  - Real Go flags: `--base-url --model --api-key-env --fixture --prompt --sentinel --timeout --format` + optional `--round2-prompt --judge-base-url --judge-model --judge-api-key-env --judge-prompt --judge-threshold`. NO `--rubric` (rubric → rendered into `--judge-prompt`). Output: `round1_sentinel/round2_judge/overall_pass` (no evidence hashes). Binary cached (do not commit; `.local-cache/` now gitignored).
  - Toolkit seam scaffolded: `scripts/providers/fixture/{code-visibility.md,prompt-template.txt}` + `rubric/code-visibility-rubric.json` (sentinel `ZETA-9-ORANGE-7f3a`).
- ⏸ **Phase 3 (docs + release)** — separate plan: manual/FAQ/diagrams/templates + CONST-052 + v1.12.0 release across main repo + LLMsVerifier submodule via gh+glab, `<prefix>/v1.12.0` (§11.4.151), no force-push (§11.4.113).

### Corrections discovered during Phase 1 (MUST apply in Phase 2/3 — do not re-derive)

Source: `docs/research/2026-07-04-provider-api-endpoints.md` (§11.4.99 latest-source, verified 2026-07-04):
- **xAI premise CONTRADICTED.** Spec §4.6 said "xAI has no /models endpoint" — WRONG. xAI **does** expose `GET https://api.x.ai/v1/models` (OpenAI-shaped `{"object":"list","data":[...]}`, has `context_length`) + native `/v1/language-models`. Its docs pages point to a console table and `/v1/models` returns alias ids ("latest"), so it reads "special" per docs page — but the endpoint exists. Phase 2: treat xAI like the others (real /models), drop the "no endpoint / scrape docs" special-case; the nuance is alias-id handling, not endpoint absence.
- **OpenRouter is the real deviation** (not xAI): `GET https://openrouter.ai/api/v1/models` is PUBLIC (no auth), returns bare `{"data":[...]}` with NO `"object":"list"`. DeepSeek/Groq/Mistral are exact OpenAI `{"object":"list",...}`. models.dev shape confirmed (keyed by provider id; `limit.{context,output}`, `cost`, `reasoning`, `tool_call`, `release_date`; no documented TTL).
- **File-forwarding premise is STRONGER than "unconfirmed."** Anthropic's gateway-protocol docs document that the FULL Anthropic-Messages request body is POSTed to `ANTHROPIC_BASE_URL/v1/messages` (and warns gateways not to redact bodies); Read output rides in `tool_result` blocks by construction. So frame it as "documented full-body forwarding from which file-content forwarding follows" — NOT "unconfirmed." The two-round test still empirically confirms per-provider.

### Config-overwrite prompt — ROOT-CAUSED (Task 7)

`docs/investigations/2026-07-04-config-overwrite-prompt.md`: the prompt is Claude Code's per-workspace **trust dialog**, NOT a shared-settings-symlink overwrite. Already fixed by `c6fe153` (sticky-trust merge) + `cma_trust_project` (per-alias owned `.claude.json` + pre-launch trust seeding) + owned `settings.json` (`CMA_SHARED_ITEMS` excludes it). Tested: `test_session.sh:199-220`, `test_unify.sh`. No code change (§11.4.124). Phase-3: annotate spec §6 to reflect "already the state of the tree."

### Phase-3 release blocker (from `docs/qa/2026-07-04-constitution-audit/report.md`)

§11.4.157 GEMINI.md lockstep — **RESOLVED** (commit `1c53562`): `AGENTS.md`, `QWEN.md`, `GEMINI.md` created at root as byte-identical lockstep mirrors of `CLAUDE.md` (verified BODY IDENTICAL x3). All audited gates now PASS (CONST-051 decoupling PASS — zero consumer names in LLMsVerifier source; no force-push/CI; prefix=`claude_toolkit`). NOTE: keep all four in lockstep on any future CLAUDE.md edit.

### Recent commits (Phase-1 close + Phase-2/3 prep)

`1c53562` GEMINI/AGENTS/QWEN lockstep + spec xAI correction · `9867b0f` T7/T8 close-out · `2ecb84b` parallel subagent artifacts · `0323ea2`..`249400b` Phase-1 T1-T6. Spec §4.6 annotated with the xAI correction (struck the wrong "no endpoint" claim).

### Phase-2 Go command — INTEGRATED (local commits only, NOT pushed)

`cmd/semantic-code-visibility/main.go` + `main_test.go` committed INSIDE the submodule at `a48c03a5` (message: "feat(cmd): add semantic-code-visibility"). Main-repo submodule pointer bumped `86cebbf → a48c03a` (this commit). Standalone stdlib-only (no cgo/DB), CONST-051-clean (verified: zero consumer names), anti-bluff (transport/non-200/empty → fail-with-reason; judge failure hard-fails round 2). Independently verified this session: `go build` exit 0, `go test` → ok 0.006s, gofmt clean. Removed the stray `go build` binary from the submodule root (§11.4.53).

**PUSH DISCIPLINE (when releasing — §11.4.71/§11.4.113):** the submodule commit `a48c03a5` is LOCAL-ONLY. Before any main-repo push that carries the bumped pointer, the submodule MUST be pushed first (fetch-before-push, no force-push), else the pointer dangles on the remote. Minor future refinement noted in review: `parseScore` takes the first integer (a chatty judge could misparse — judge prompt mandates a bare integer, round-1 unaffected).

### Phase-2 plan — WRITTEN + VERIFIED + COMMITTED

`docs/superpowers/plans/2026-07-05-phase2-semantic-live-plan.md` (897 lines). 6 tasks: (1) verify + driver the Go command (`scripts/claude-semantic-visibility.sh`, mirrors claude-verify-providers.sh; submodule fetch-before-push + separate pointer bump); (2) `providers-semantic.sh` layer-3 wiring into cmd_sync (renders rubric into `--judge-prompt`, persists via `cma_status_write`); (3) `verify_superpowers_tui.sh` layer-4 (Tier-B SKIP-able); (4) xAI CORRECTED (generic /v1/models, no docs-scrape special-case); (5) extend the EXISTING `scripts/tests/verify_providers_live.sh` (Tier-B); (6) full suite + submodule go test + CONTINUATION sync. Each task: exact paths, complete code, failing→passing test, commands+expected output, commit step. Verified before commit: xAI correction present, CONST-052-collision flagged, real `--judge-prompt` flag, no placeholders, header OK.

### NEW findings from the Phase-2 plan authoring (apply in Phase 2/3)

- **CONST-052 ID COLLISION (Phase-3 fix):** spec §3.4 proposes a NEW "CONST-052" for the semantic-code-visibility boundary contract, but the cascaded constitution ALREADY defines CONST-052 (lowercase-snake_case naming mandate). Renumber draft (grep-backed): `docs/research/2026-07-04-const052-collision-renumber-draft.md` — recommended next-free = **CONST-069 ⇐ §11.4.166** (highest existing: CONST-068, §11.4.165). DRAFT-ONLY; land via the §11.4.49 constitution-submodule workflow in Phase 3 (fetch/pull first → author → validate → commit+push all upstreams → bump pointer → fix spec refs). Spec §3.4 already annotated "DO NOT reuse CONST-052".
- **Tree is AHEAD of the spec** (the plan reconciled these): Go command already implemented (flags `--judge-prompt`, NOT `--rubric`; appends `/v1/chat/completions`; exit 0/1/2; output has NO `evidence` hashes — update spec §2.3/§4.5 accordingly); a live verifier `scripts/tests/verify_providers.sh`/`verify_providers_live.sh` already exists + is wired into run-proof.sh (spec §7.3's `proof/verify_providers_live.sh` path was wrong); `cma_status_*` + gate already landed (Phase 1).
- **Minor doc gap:** the Phase-2 plan does not mention the OpenRouter deviation (public, no `object:list`) — add it to the existence-layer handling + Phase-3 docs (it's in `docs/research/2026-07-04-provider-api-endpoints.md`).

### KEY DISCOVERY (recorded so it's not re-derived)

Spec §6 (per-alias config / overwrite prompt) premise is ALREADY PARTLY FIXED: `lib.sh:711-723` — `settings.json` is deliberately NOT in `CMA_SHARED_ITEMS`; each dir gets its OWN via `cma_own_settings_seed`; `.claude.json` was never shared for provider dirs. Commit `c6fe153` ("per-alias own settings + sticky trust") addressed it. So Task 7 is INVESTIGATION-FIRST (§11.4.102) — the overwrite prompt (if any) is likely Claude Code's trust dialog, NOT a shared-settings symlink. Do NOT implement the pre-supposed fix blind.

## 2. Known issues / deferred

- `submodules/LLMsVerifier/CONSTITUTION.md` (282.2 KB) exceeds 256 KB Read limit — use offset/limit or grep when needed.
- The `AskUserQuestion` call for semantic-test design must be re-issued with `label` fields on every option.

## 3. Recent commits (for context)

```
c6fe153 fix(toolkit): per-alias own settings + sticky trust; decouple aliases from atmosphere
397035a feat(cma_run): generic opt-in CWD hook for multi-track alias→worktree entry
cd12c54 v1.11.2: token-limit guard + re-enable provider proxies + Poe tool cap
e9e0891 Auto-commit
3cdcd51 v1.11.1: live per-alias Claude Code verification (CLI+TUI) + provider fixes
```

## 4. Binding constraints (unchanging)

See `.remember/remember.md` §"Binding constraints" for the verbatim list. Highlights: SSH-key-only; no force-push; no silent removals; every change reviewed; release-tag prefix from `HELIX_RELEASE_PREFIX` or lowercased project root; CI/CD disabled; GEMINI.md lockstep; submodules decoupled (CONST-051); no fixes without root cause (§11.4.102); endless autonomous loop default (§11.4.126).

## 5. Update protocol

Every commit that advances state MUST update this file in the SAME commit (§6.S / §11.4.131). The §0 "Last updated" + "Last HEAD" lines MUST track HEAD. Stale CONTINUATION = CRITICAL DEFECT.
