# Investigation: the "overwrite configuration file(s)" prompt on provider aliases

**Date:** 2026-07-04
**Method:** systematic-debugging (§11.4.102) — root cause before any fix.
**Outcome:** Root-caused. **Already fixed** by prior work (`c6fe153` + `cma_trust_project`). **No new code change** — the spec's pre-supposed fix would have been redundant (§11.4.124 investigate-before-change).

## The report

User observation (verbatim, carried from the overhaul mandate): *"every time we open any of providers aliases we are asked to overwrite some configuration file(s). This most likely is causing issues and each providers alias MUST HAVE already its own file so we do not have to remove it."*

## Phase 1 — root cause

### The spec's assumed cause was WRONG

The design spec §6 assumed the prompt came from provider dirs symlinking a **shared** `settings.json` into `$SHARED_DIR`, so cross-account drift triggered an overwrite prompt. Investigation of the current code disproves this:

- `scripts/lib.sh` `CMA_SHARED_ITEMS` (the shared-by-symlink set) **deliberately excludes `settings.json`**. The comment at that definition states: *"settings.json is DELIBERATELY NOT in the shared set. Each config dir gets its OWN settings.json … See cma_own_settings_seed."* Each config dir (account **and** provider) gets a real, owned `settings.json` via `cma_own_settings_seed`.
- `.claude.json` is likewise **not** in `CMA_SHARED_ITEMS` — provider dirs never shared it. It is merged per-account by `cma_merge_claude_json` at unify time, not symlinked.

So no shared `settings.json`/`.claude.json` symlink exists for a provider dir to "overwrite." The assumed cause is not present.

### The actual cause: Claude Code's per-workspace TRUST dialog

The prompt the user sees is Claude Code's per-workspace **trust dialog** — *"Do you trust the files in this folder? … read, edit, and execute files here"*. Direct evidence in the codebase:

- `scripts/lib.sh` "Sticky-true TRUST preservation" block (added in `c6fe153`) states verbatim: *"the per-workspace trust dialog ('read, edit, and execute files here') reappear on every provider alias. Fix: OR the trust bit across all accounts — once a project path is trusted anywhere, it stays trusted in the merged portion."* It reduces every account's `projects[<path>].hasTrustDialogAccepted` with a logical OR so the merge never un-trusts a path.
- `scripts/claude-session.sh` `cma_trust_project()` (lines ~93-101) marks the launch project trusted in `<config_dir>/.claude.json` by setting `projects[<root>].hasTrustDialogAccepted = true`, *"so Claude Code does not warn 'this workspace has not been trusted'."* It is invoked from the `flags` path that `cma_run_provider` runs before launching (bare launch → `claude-session flags` → `cma_trust_project`).

The user's word "overwrite" maps to this dialog: accepting it writes the trust bit into the config; without the sticky-trust preservation, a subsequent cross-alias `.claude.json` merge would drop the bit, so the dialog re-appeared on the next provider-alias launch — matching "every time we open any of providers aliases."

## Phase 2 — pattern / already-applied fix

Three mechanisms, all already in place, jointly eliminate the recurrence:

1. **Per-alias OWN config files.** `settings.json` and `.claude.json` are owned real files per config dir (`cma_own_settings_seed` + the `CMA_SHARED_ITEMS` exclusion) — nothing gets overwritten across aliases. This is precisely the "each providers alias MUST HAVE already its own file" the user asked for; it is already true.
2. **Trust seeded before launch.** `cma_trust_project` writes `hasTrustDialogAccepted=true` for the launch CWD into the provider dir's own `.claude.json` on the `flags` path, before `claude` starts — so even a first launch in a project is pre-trusted.
3. **Sticky-trust merge (`c6fe153`).** The `.claude.json` cross-alias merge ORs the trust bit so it is never lost, so the dialog does not re-appear on the next alias.

## Phase 3 — verification (existing coverage, no new code)

The mechanism is already covered by hermetic tests — no redundant test added (§11.4.50, §11.4.124):

- `scripts/tests/test_session.sh:199-220` — *"trust: .claude.json gains hasTrustDialogAccepted=true after a flags call"* and *"repeated flags calls are idempotent (file stays valid JSON)"*. This exercises the exact `flags → cma_trust_project` path that `cma_run_provider` invokes.
- `scripts/tests/test_unify.sh` (touched by `c6fe153`) — covers the sticky-trust OR-merge across accounts.
- `scripts/tests/test_providers.sh` Section 1 — provider dirs are excluded from account detection, so their owned config is never swept into the shared merge.

**§11.4.108 layer-4 (user-visible) note:** the fully definitive proof — a live `claude` TUI launch under a provider alias with NO trust/overwrite prompt — is the **superpowers-TUI test in Phase 2** (it launches the real binary non-interactively; if the prompt still fired, the test would hang/timeout). Phase 1 establishes the root cause + the existing unit coverage; Phase 2 supplies the live layer-4 evidence.

## Determination

- **Root cause:** Claude Code per-workspace trust dialog (NOT a shared-settings-symlink overwrite).
- **Status:** already fixed by `c6fe153` (sticky-trust) + `cma_trust_project` (per-alias owned `.claude.json` + pre-launch trust seeding) + owned `settings.json`.
- **Action:** none in code. The spec's §6 "own settings.json split + migration" is **already the state of the tree**; implementing it blind would have been a redundant change (§11.4.124). The design spec §6 should be annotated to reflect this (deferred to the Phase-3 docs pass).

## Sources verified 2026-07-04

- `scripts/lib.sh` — `CMA_SHARED_ITEMS` exclusion comment; "Sticky-true TRUST preservation" block.
- `scripts/claude-session.sh` — `cma_trust_project()` definition.
- `scripts/tests/test_session.sh:199-220` — trust-seeding coverage.
- `git show c6fe153 --stat` — "per-alias own settings + sticky trust" commit scope.
