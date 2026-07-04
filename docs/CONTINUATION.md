# CONTINUATION — claude_toolkit

**Last updated:** 2026-07-04
**Last HEAD:** (pending — Phase 1 toolkit-side COMPLETE, 8/8 tasks)
**Working tree:** modified (investigation doc + this file)
**Active branch:** `main`

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
- ⏸ **Phase 2 (semantic + live)** — separate plan (next). LLMsVerifier `semantic-code-visibility` Go command + `model_verify.py` semantic-layer wiring + live superpowers-TUI test + xAI + Tier-B live verifier. **DE-RISKED by parallel research** (`docs/research/2026-07-04-llmsverifier-go-internals.md`): build it as a **standalone stdlib-only** `cmd/semantic-code-visibility/main.go` (flag/os/net/http/encoding/json) — NOT reusing the chat clients (they transitively import the sqlite3 cgo `database` pkg). Keeps the submodule command CONST-051-decoupled + cgo-free. Toolkit-owned seam already scaffolded: `scripts/providers/fixture/{code-visibility.md,prompt-template.txt}` + `rubric/code-visibility-rubric.json` (sentinel `ZETA-9-ORANGE-7f3a`).
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

### In-flight (background subagents, may still be running on resume)

- Go command `cmd/semantic-code-visibility/main.go` (standalone stdlib) being implemented+built+tested in the submodule working tree (NOT yet committed — needs review + submodule commit + pointer bump per §11.4.71, no force-push).
- Phase-2 plan `docs/superpowers/plans/2026-07-05-phase2-semantic-live-plan.md` being authored.
Check `git status` in the submodule + `docs/superpowers/plans/` on resume; verify their evidence before committing.

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
