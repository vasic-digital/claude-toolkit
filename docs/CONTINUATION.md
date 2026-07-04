# CONTINUATION — claude_toolkit

**Last updated:** 2026-07-04
**Last HEAD:** `c6fe153` — `fix(toolkit): per-alias own settings + sticky trust; decouple aliases from atmosphere`
**Working tree:** clean
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
- ✅ Phase 2 first clarifying question answered: "Decompose into sub-projects; extend LLMsVerifier generically."
- ⏳ Phase 2 second clarifying question: FAILED validation (AskUserQuestion options missing `label` field). Re-issue with labels: (A) Sentinel-token exact match [Recommended], (B) Judge-graded rubric, (C) Two-round sentinel + judge.
- ⏸ Phase 3: Propose 2-3 approaches with trade-offs.
- ⏸ Phase 4: Present design sections, per-section approval.
- ⏸ Phase 5: Write spec to `docs/superpowers/specs/YYYY-MM-DD-provider-verification-design.md`.
- ⏸ Phase 6: Spec self-review (placeholders/contradictions/ambiguity/scope).
- ⏸ Phase 7: User reviews written spec.
- ⏸ Phase 8: Transition to `superpowers:writing-plans` (terminal state — NO other implementation skill before this).
- ⏸ Then: implement verification overhaul + tests + docs + release.

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
