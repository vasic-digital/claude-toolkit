# 43 — origin/main → feature/helixllm-full-extension merge (zero-risk, no-loss)

| Field | Value |
|---|---|
| Revision | 1 |
| Created | 2026-07-19 |
| Last modified | 2026-07-19T00:20:00Z |
| Status | MERGE: DONE-LOCAL-REVIEW-PENDING |
| Author | (T4/feature/board-cleanup - claude1) merge agent, Fable per §11.4.211 |
| Repo | /home/milos/Factory/projects/tools_and_research/claude_toolkit |
| Merge commit | `a944c09def13ce31d94db050dade6fd03fa5fcc2` (parents `877f86b` + `8e96f2e`) — LOCAL ONLY, NOT pushed |

## 1. Pre-flight state (§9.2 safety net confirmed BEFORE any action)

- Tree clean: `git status --short` showed ONLY `?? qa-results/`; `git diff --stat HEAD` EMPTY.
- HEAD = `877f86b2bc385253aaed0281632ab33d0c79af57`, branch `feature/helixllm-full-extension`.
- Backup present: `/home/milos/Factory/projects/tools_and_research/.claude_toolkit_git_backups/toolkit.git.mirror.premerge.20260718T183712Z` (restore net; unused).
- `origin/main` = `8e96f2e` (3 commits: `04fe17d` Kimi v1.15.0, `741bb64` output-cap + router-hardening v1.16.0, `8e96f2e` Auto-commit). merge-base = `ca36be9`. Both facts re-verified live before merging.
- `~/.claude/settings.json` sha256 BEFORE: `a676b78a579bdbb5dd49e954dabe89a3a8112838d95c78a9e7e172246545483b` (338 bytes).

## 2. Conflicted files

`git merge --no-ff origin/main` → exactly ONE conflicted file: **`scripts/lib.sh`** (7 conflict regions). `scripts/claude-providers.sh` and `scripts/tests/test_providers.sh` auto-merged; both were then SEMANTICALLY verified (my helixagent pins/gate/reason hunks + main's kimi detector / `resolve_records` precedence / `cmd_sync` migration call / migtest3 block all present, `bash -n` clean).

## 3. Per-region resolution (scripts/lib.sh, §11.4.41 step 3 union)

| # | Region | Resolution |
|---|---|---|
| 1 | cma_run migration `mv` + log | main's `command mv -f` + my richer log message (union) |
| 2 | provider marker-doc comment | union of both sides' marker bullets (`_family_id`, kimi-freshness, `_cma_session_flags`, `_cma_out_guard` + my clamped-export marker) |
| 3 | provider migration marker-check list | full union — **20 markers** — in my zsh-safe herestring style (main's 4 new markers added: `_family_id`, `kimi-code/credentials/kimi-code.json`, `_cma_out_guard`, `_cma_session_flags`; my 4 kept: `ANTHROPIC_DEFAULT_OPUS_MODEL`, `CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"`, `_cma_ccr_self`, `ccr default-claude-code -- "$@"`) |
| 4 | provider migration `mv` + log | `command mv -f` + combined log naming every merged capability |
| 5 | auto-compact NOTE comment | merged (both transports + clamped ≤128000 both stated) |
| 6 | **output-token cap block (the critical one)** | unified block — see §4 |
| 7 | native branch | my tier-map exports KEPT (main had none) + main's session-block relocation ADOPTED (my side never modified that block — zero loss) + merged pointer comments |

Auto-merged inside the heredoc and verified present: main's `_cma_session_flags` both-transports block, ccr identity check, kimi OAuth freshness, `_family_id` proxy fallback, `cma_union_rosters`, `cma_migrate_daemon_dirs_once`, `daemon jobs` shared items; my `ANTHROPIC_DEFAULT_*` + token-guard unset isolation (cma_run lines 426/435, provider lines 639/640), `_cma_ccr_self` guard, upsert gate, `ccr default-claude-code -- "$@"` launch.

## 4. The 128k reconciliation (what was kept/dropped and WHY)

**Finding: the two mechanisms were NOT equivalent — each carried a live-proven behavior the other lacked.** Keeping either alone would ship a defect; keeping both verbatim would be two conflicting cap code paths. One unified block was built (main's `_cma_out_guard` comment + my `CLAUDE_CODE_MAX_OUTPUT_TOKENS="$_cma_out"` export literal both preserved as migration markers):

| Case | MY branch (b168504) | MAIN (741bb64) | MERGED (kept) | Why |
|---|---|---|---|---|
| real budget > 128000 (deepseek 384000 / xiaomi 131072, output < context) | clamp → 128000 | export RAW (defect: resurrects the live-proven ">128000 output token maximum" fatal) | **clamp → 128000** (MINE) | my live-proven fix; the CLI hard-caps custom models at 128000 |
| output >= context (nvidia5 catalog mislabel) | export 128000 (defect: 400 window-overshoot for small contexts) | NO export | **NO export** (MAIN) | main's live-proven nvidia5 fix |
| real budget ≤ 128000 | verbatim | verbatim | **verbatim** | identical |
| missing / non-numeric / zero | export 128000 default | NO export | **NO export** (MAIN) | effect-equivalent for unknown models (CLI default = 128000) AND additionally safe for small-context catalog-gap models where an unconditional 128000 could resurrect the nvidia5 overshoot — main's behavior strictly subsumes mine here, nothing user-visible lost |
| >18-digit huge value (user-settable via `CMA_HELIXAGENT_MAX_OUTPUT`, jq --argjson verbatim) | collapse → 128000, no arithmetic | unguarded `(( ))` arithmetic (overflow/parse hazard) | **no-arithmetic collapse kept** (MINE): ctx known → mislabel shape → no export; no ctx → 128000 | my overflow-safety analysis extended to main's context comparison (ctx sanitized before any test) |

Single guarded export remains (`if [ -n "$_cma_out" ]; then export …; fi`); the old raw native-branch re-export is GONE. POSIX-shape `[ ]` tests for bash/zsh parity.

**Functional proof on the EXTRACTED merged block (not a re-type): 18/18 decision-table cases PASS under bash, 6/6 under zsh** (deepseek/xiaomi clamp, nvidia5 skips, sarvam/helixagent verbatim, missing/empty/non-numeric/zero no-export, 23-digit + 2^63 collapse, leading-zero 007, boundaries 128000/128001).

## 5. Reconciliations landed with the merge (§11.4.120 — assert the NEW mechanism, never fake-pass)

1. **SIGPIPE false-FAILs (test_coverage ×11, test_kimi ×3, test_session_flags ×1, test_output_tokens ×3):** the merged wrapper body (union of both feature sets, 395 lines) widened the `printf body | grep -q` pipefail race — `grep -q` exits on first match, printf's remaining write takes SIGPIPE → rc 141 → false FAIL while the match IS present (captured: `want=0 got=141`; content-presence proven independently by the 29-marker harness). Converted to herestrings — the identical fix this branch had already landed in test_providers.sh for the identical bug. No assertion weakened.
2. **test_output_tokens.sh:** fake `ccr` stubs now observe BOTH launch grammars (`code|default-claude-code`) since the merge carries the v3.0.6 grammar fix; clamped expectations 131072 → 128000 (3 sites) per §4.
3. **test_128k_output_clamp.sh:** probe extraction updated to follow the merged conditional export through its closing `fi` (the old exit-on-export-line would emit an unterminated `if`); probe prints `${VAR-UNSET}` so no-export is observable; ctx-aware `clamp_eval`; expectations moved to the merged decision table; NEW mislabel (nvidia5) case group added. All original live-proven clamp cases still covered.
4. **lib.sh `cma_migrate_daemon_dirs_once` (latent MAIN bug, captured live):** on a fresh HOME the unguarded `: > "$SHARED_DIR/.daemon-migration-done"` redirection fails (`line 1166: … No such file or directory`) and, under `set -e`, ABORTS the whole `cmd_sync` (exit 1, zero providers registered). Exposed by my sandboxed `verify_helixagent_test.sh` (which main never had). Fix: `mkdir -p "$SHARED_DIR" || true` + `|| true` on the marker write — the marker is a skip-optimization; the migration loop is idempotent (symlinks skipped), so a failed marker write must never kill a sync.

## 6. Validation counts

| Check | Result |
|---|---|
| `bash -n scripts/lib.sh` + `zsh -n scripts/lib.sh` | clean |
| `bash -n` all 16 touched `.sh` files | 16/16 clean |
| Migration-marker consistency (every checked marker present in emitted heredoc bodies) | **29/29 PASS** (9 cma_run + 20 cma_run_provider) + absent-needle control PASS + non-empty-body control PASS (97/395 lines) |
| Merged clamp decision table (extracted block) | **18/18 bash, 6/6 zsh** |
| Hermetic sandbox suite `run-all.sh` | **27/27 files ALL GREEN** (first run 22/27; 5 failures root-caused per §11.4.102 and reconciled per §5 — zero fake-passes) |
| `verify_helixagent_test.sh` | **46/46 PASS** (was 32/46 before the §5.4 fix; failure evidence: `scripts/tests/proof/82-helixagent-detect.txt` history) |
| Live/ccr-launching tests | **NOT run** (per mandate) |

## 7. NO-LOSS proofs (verbatim)

**(a) Both sides' commits reachable from the merge:**
```
REACHABLE c6c9831  REACHABLE b168504  REACHABLE 7cda632  REACHABLE 63f4231  REACHABLE 877f86b   (my 5)
REACHABLE 04fe17d  REACHABLE 741bb64  REACHABLE 8e96f2e                                          (main's 3)
a944c09 parents: 877f86b 8e96f2e
```
**(b) Zero conflict markers in tracked files** (fixed-string scan, proof logs excluded as captured evidence):
```
files-with '<<<<<<< ': 0    files-with '>>>>>>> ': 0    files-with bare =======: 0
```
**(c) Union-completeness — no file from EITHER parent missing** (neither side deleted anything vs base: mine-deleted 0, main-deleted 0):
```
files-in-a-parent-but-missing-from-merge: 0
```
Sanity: `git diff --stat HEAD@{1} HEAD` → 89 files, +3346/−802; `git diff --stat origin/main HEAD` → 12 files, +710/−105.

**(d) Load-bearing features grep-proven (grep -F counts in the merged tree):**
```
detect_helixagent_record: 4 (claude-providers.sh)   ccr default-claude-code -- "$@": 2 (lib.sh)
_cma_ccr_self: 4 (lib.sh)   _cma_out_guard: 4 (lib.sh)   ANTHROPIC_DEFAULT_FABLE_MODEL: 3 (lib.sh)
scripts/providers/helixagent.json: present          control needle (absent literal): 0 ✓
```
(An initial BRE `grep -c` mis-read `ccr default-claude-code -- "$@"` as 0 — instrument error, refuted by `grep -F` = 2 and the 29-marker harness; recorded per §11.4.201.)

**Submodule pointer (`submodules/challenges`):** only main moved it (base/mine `8b18650` → main `41d1a13`); the merge commits main's `41d1a13`. The local submodule WORKTREE still shows `8b18650` (stale checkout, not commit content) — deliberately NOT staged (staging it would have regressed the pointer). Conductor: `git submodule update --init submodules/challenges` aligns it.

## 8. Operator-environment integrity

`~/.claude/settings.json` sha256 BEFORE == AFTER:
```
a676b78a579bdbb5dd49e954dabe89a3a8112838d95c78a9e7e172246545483b  (338 bytes)  — both snapshots identical
```
No `ccr`/`claude` launched at any point; only hermetic sandboxed tests ran (sandbox `$HOME`s under `/tmp`).

## 9. Verdict

**MERGE: DONE-LOCAL-REVIEW-PENDING** — merge commit `a944c09def13ce31d94db050dade6fd03fa5fcc2` on `feature/helixllm-full-extension`, LOCAL ONLY (not pushed, per mandate). No code lost, both sides preserved, 7 conflict regions resolved by union, 27/27 + 46/46 hermetic suites green, backup untouched and still available.
