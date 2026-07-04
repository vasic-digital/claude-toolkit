# Live-verification / proof infrastructure map (for Phase-2 Task 5)

> READ-ONLY survey. Purpose: let Phase-2 Task 5 **extend** the existing live/proof
> infrastructure rather than duplicate it (§11.4.74 extend-don't-reimplement).
> All citations are `path:line` against the tree as of 2026-07-04.

---

## 1. Inventory — every live/proof verification script

All live verifiers live in `scripts/tests/` and are deliberately **not** named
`test_*.sh` so `run-all.sh` never auto-picks them up (they need network/keys/a
real binary). The hermetic sandbox suite is the `test_*.sh` set; the live layer is:

| Script | Size | Scope | Emits evidence to |
|---|---|---|---|
| `scripts/tests/verify_opencode_live.sh` | 7018 B | OpenCode real binary + real config | `scripts/tests/proof/` (`00-summary.txt`, `10-…`, `21-…`, `30/31-…`) |
| `scripts/tests/verify_providers_live.sh` | 3488 B | Provider-alias **structural** proof (existence-level) | `scripts/tests/proof/50-providers-live.txt`, `51-detected-accounts.txt` |
| `scripts/tests/verify_aliases_live.sh` | 10678 B | Provider-alias **functional API** (6 API-shape checks) | `scripts/tests/proof/alias-verify-evidence.txt` |
| `scripts/tests/verify_claude_live.sh` | 7303 B | Provider aliases through **real Claude Code** (CLI + TUI/PTY), incl. `--use-superpowers` | `scripts/tests/proof/claude-live-verify.txt`, `claude-live-superpowers-cli.txt` |
| `scripts/tests/run-proof.sh` | 3483 B | Orchestrator (sandbox suite + 3 live verifiers → `PROOF.md`) | `scripts/tests/proof/PROOF.md` + `40/41/42/43-*.log` |

Root-of-`scripts/` drivers (not in `tests/`, invoked by the pipeline, not by run-proof):
- `scripts/claude-verify-providers.sh` (2755 B) — LLMsVerifier submodule build+run driver (the cache pattern a new semantic driver mirrors).
- `scripts/providers-verify.sh` (3349 B) + `scripts/model_verify.py` (23290 B) — the layer-1/2 existence + scoring engine consumed by `cmd_sync`.

Grep confirming the live verifiers reference `proof`/`SKIP`:
`verify_providers_live.sh`, `run-proof.sh`, `verify_opencode_live.sh`, `verify_aliases_live.sh`, `verify_claude_live.sh` all matched.

---

## 2. Per-verifier behaviour, preconditions, evidence, and SKIP logic

### 2.1 `verify_opencode_live.sh` (OpenCode live)

- **Precondition + SKIP** (§11.4.3 honest SKIP): if `opencode` is not on PATH it prints a reason and exits 0 —
  `verify_opencode_live.sh:29-32`:
  ```bash
  if ! command -v opencode >/dev/null 2>&1; then
    echo "SKIP: opencode not installed on this host — live verification skipped."
    exit 0
  fi
  ```
- **Knobs**: `PROOF_DIR` (default `$TESTS_DIR/proof`), `MIN_SKILLS=200`, `MIN_MCP_ENABLED=3`, `OPENCODE_CONFIG` — `verify_opencode_live.sh:24-27`.
- **What it checks**: binary version (`:67-69`), `opencode debug config` resolves + valid JSON + has mcp/skill keys (`:72-84`), skills resolve `>= MIN_SKILLS` (`:87-99`), enabled MCP servers connect `>= MIN_MCP_ENABLED` and 0 failed (`:102-114`), instructions wired (`:116-120`).
- **Evidence**: `00-summary.txt` header (`:57-64`), `10-debug-config.json` (redacted, `:73-78`), `21-skill-names.txt` (`:95-96`), `30/31-mcp-list*.txt` (redacted, ANSI-stripped, `:103-107`).
- **Secret hygiene**: `cma_redact_secrets` sed filter redacts API keys / URL passwords / JWTs BEFORE writing to the committed proof dir — `verify_opencode_live.sh:49-55`.
- **Tally**: ends with `summary` from `lib/assert.sh` (`:129`).

### 2.2 `verify_providers_live.sh` (provider-alias **structural** — THE provider live-verifier today)

This is the existing provider live-verifier. It is **structural/existence-level only** — no semantic (does-the-model-see-code) and no superpowers-TUI layer.

- **Precondition + SKIP**: if no provider dir or no `*.env` files, prints reason and exits 0 —
  `verify_providers_live.sh:21-24`:
  ```bash
  if [[ ! -d "$PDIR" ]] || ! compgen -G "$PDIR/*.env" >/dev/null 2>&1; then
    echo "SKIP: no provider aliases installed on this host — live provider verification skipped."
    exit 0
  fi
  ```
- **Paths**: `PDIR=$HOME/.local/share/claude-multi-account/providers`, `ALIASES=$ALIAS_FILE|…/aliases.sh`, `PROOF_DIR` default `$TESTS_DIR/proof` — `verify_providers_live.sh:16-19`.
- **What it checks (all structural)**:
  1. every `*.env` has required non-secret fields `CMA_PROVIDER_{ID,KEYVAR,TRANSPORT,MODEL,CONFIG_DIR}` — `:30-38`.
  2. NO secret values present — every non-comment/blank line must be a `CMA_PROVIDER_*=` assignment (stronger than a length heuristic) — `:40-49`.
  3. each provider id resolves to a `cma_run_provider <id>` line in the alias file — `:51-59`.
  4. the `cma_run_provider()` wrapper is defined — `:61-62`.
  5. provider config dirs are excluded from `cma_detect_accounts` — `:64-68`.
- **Evidence**: `$PROOF_DIR/50-providers-live.txt` (`EV`, `:27`), plus a footer recording providers-installed count, `ccr` presence, and **`LLMsVerifier binary: built|not-built`** — `:70-75`. Also `51-detected-accounts.txt` (`:67`).
- **Tally**: `summary` (`:78`). Uses `set +e` (`:26`) so failing-by-design assertions don't abort.
- **Sample evidence on disk** (`proof/50-providers-live.txt`): `providers installed: 28`, `ccr installed: yes`, `LLMsVerifier binary: not-built`.

### 2.3 `verify_aliases_live.sh` (provider-alias **functional API** — 6 checks)

- **Scope**: per-alias API-shape verification — (1) basic chat, (2) tools missing `parameters` (proxy fix), (3) tools with `$ref/$defs` (Grok-4 fix), (4) `cache_control` (cleancache fix), (5) streaming, (6) tool calling — `verify_aliases_live.sh:2-12`. Auto-starts the Poe proxy where needed (`:56-60`, header `:12`).
- **SKIP posture**: `set +e` (`:19`); sources the keys file only if present (`:36-39`) and the alias file only if present (`:40-41`); a missing single `--alias` target exits 1 (`:46-48`). It iterates real installed `*.env` (`:49-51`).
- **Evidence**: `$PROOF_DIR/alias-verify-evidence.txt` (`EV`, `:33`).
- **Timeout**: default 30s (`:30`).

### 2.4 `verify_claude_live.sh` (provider aliases through **real Claude Code**, CLI + TUI, incl. superpowers)

This already exercises a superpowers prompt end-to-end, but note it is **NOT wired into `run-proof.sh`** (see §3). It is run manually.

- **Scope**: launches EVERY provider alias through real Claude Code in both modes — CLI (`cma_run_provider <id> -p … --output-format json`, authoritative) and TUI (Ink app under a PTY via `lib/pty_drive.py`) — `verify_claude_live.sh:2-9`.
- **Superpowers hook**: `--use-superpowers` sets the prompt to `/using-superpowers` — `verify_claude_live.sh:37`. Evidence of a real run: `proof/claude-live-superpowers-cli.txt` (per-alias PASS/FUNDS/BADKEY verdicts, `# DONE fails=0`).
- **Outcome classification** (so account problems aren't counted as toolkit bugs): `PASS/FUNDS/BADKEY/NOKEY/FAIL/TIMEOUT` — `:10-19`; exit code = number of genuine FAILs (`:19`, `:154`). This is effectively an honest-SKIP-by-bucketing model: FUNDS/BADKEY/NOKEY never fail the run.
- **Scrubbed env** mimicking a fresh shell — `SCRUB=(env -u …)` `:50-53`; TUI runs from a throwaway temp cwd so it can't resume a real session (`:119-125`).
- **Reclassifier**: `reclassify_fail` probes the provider API directly on FAIL/TIMEOUT to recover the true cause (401/402/403/429 → BADKEY/FUNDS) — `:63-108`, invoked at `:144-147`.
- **Preconditions**: requires the alias file; hard-exits 2 if absent (`:48`). Shared classifier `lib/classify_live.py` (`:57`).

---

## 3. `run-proof.sh` wiring — which verifiers, where evidence lands

`scripts/tests/run-proof.sh` is the single "prove everything" orchestrator. It runs the hermetic suite **and** three live verifiers, then writes `PROOF.md`.

Invocation order (each tee'd to a log):
1. Sandbox suite — `bash run-all.sh` → `40-sandbox-suite.log` — `run-proof.sh:18-20`.
2. `verify_opencode_live.sh` → `41-live-verify.log` — `run-proof.sh:23-25`.
3. `verify_providers_live.sh` → `42-live-providers.log` — `run-proof.sh:28-31`.
4. `verify_aliases_live.sh` → `43-live-aliases.log` — `run-proof.sh:34-37`.

**Note:** `verify_claude_live.sh` is **NOT** invoked by `run-proof.sh` (grep confirmed only `verify_providers_live.sh:30` and `verify_aliases_live.sh:36` are wired). The superpowers/CLI-TUI verifier is run out-of-band.

- **Report**: distils each tally and writes `$PROOF_DIR/PROOF.md` — `run-proof.sh:47-79`. The provider block is `run-proof.sh:65-69` (`## Live provider-alias verification … evidence: [50-providers-live.txt]`).
- **SKIP = pass contract**: the file header states the live verification "SKIPs (counts as pass) when opencode is absent" — `run-proof.sh:6-7`. Final gate requires all four rc==0 — `run-proof.sh:85-90`:
  ```bash
  if (( sand_rc == 0 && live_rc == 0 && prov_rc == 0 && alias_rc == 0 )); then
    echo "ALL GREEN — evidence is in $PROOF_DIR"; exit 0
  fi
  ```
  So any live verifier that SKIPs-with-exit-0 folds cleanly into the green gate — this is the contract a Task-5 extension must preserve.
- **Evidence dir**: everything under `scripts/tests/proof/` (default `PROOF_DIR=$TESTS_DIR/proof`, `run-proof.sh:11`). `PROOF.md` at `scripts/tests/proof/PROOF.md`.

---

## 4. Is there already a provider live-verifier? What does it cover?

**Yes** — `scripts/tests/verify_providers_live.sh` is the existing provider live-verifier (distinct from the OpenCode one). Coverage today:

- **Existence / structural**: YES — env-file well-formedness, no-secret-leak structural check, alias resolution, wrapper presence, account-detection exclusion (`verify_providers_live.sh:30-68`).
- **Semantic (does the model actually SEE the code)**: NO. There is no code-visibility check here. The footer merely records whether the `LLMsVerifier` binary is built (`:74`) — it does not run it.
- **Superpowers-TUI (layer 4)**: NO. Not present in this file. (A superpowers CLI/TUI run exists only in the separate, un-wired `verify_claude_live.sh --use-superpowers`.)

The provider status pipeline itself already reserves these two layers as future work: `claude-providers.sh:218-226` writes `verified` only from the existence/tool-call layer and comments that a "later layer (semantic / superpowers-TUI, Phase 2)" has not yet confirmed, persisting `semantic` as the failing layer when non-verified.

---

## 5. `claude-verify-providers.sh` — the build+cache pattern to mirror

`scripts/claude-verify-providers.sh` is the reference driver for the LLMsVerifier submodule. A new semantic-visibility driver should mirror its shape.

- **Path resolution**: `SCRIPT_DIR`/`REPO_ROOT`, then `LV_DIR=${LLMSVERIFIER_DIR:-$REPO_ROOT/submodules/LLMsVerifier}`, `LV_MOD=$LV_DIR/llm-verifier`, `CONFIG=${LV_CONFIG:-…}`, cached binary `BIN=${LV_BIN:-$REPO_ROOT/.local-cache/code-verification}` — `claude-verify-providers.sh:18-23`.
- **Preconditions**: submodule present else actionable exit 3; `go` on PATH else exit 4 — `:42-50`.
- **Keys via env only** (never argv): optionally sources `LV_KEYS` file, values used as env — `:52-55`.
- **Build cache + rebuild-if-newer** (the pattern to copy) — `claude-verify-providers.sh:57-63`:
  ```bash
  if [ ! -x "$BIN" ] || [ "$LV_MOD/cmd/code-verification/main.go" -nt "$BIN" ]; then
    mkdir -p "$(dirname "$BIN")"
    echo "building code-verification (go build)…" >&2
    ( cd "$LV_MOD" && go build -o "$BIN" ./cmd/code-verification/ ) \
      || { echo "error: verifier build failed" >&2; exit 5; }
  fi
  ```
- **Exec pass-through**: `exec "$BIN" --config "$CONFIG" "$@"` — `:66`.
- **Hermetic test** of this driver: `scripts/tests/test_verify_providers.sh` (help exits 0, `.gitmodules` declares the submodule, uninitialised submodule → exit 3, secrets never echoed) — `test_verify_providers.sh:14-37`.

The Phase-2 plan's new `scripts/claude-semantic-visibility.sh` is a near-verbatim copy of this shape targeting `./cmd/semantic-code-visibility/`, cached at `.local-cache/semantic-code-visibility` (plan Task 1, `docs/superpowers/plans/2026-07-05-phase2-semantic-live-plan.md:125-168`).

---

## Recommendation for Phase-2 Task 5

**EXTEND, do not create.** Add the new live layers to the existing, already-wired file:

- **File to extend:** `/run/media/milosvasic/DATA4TB/Projects/claude_toolkit/scripts/tests/verify_providers_live.sh`
  - It is already invoked by `run-proof.sh:28-31` and its `prov_rc` already folds into the all-green gate (`run-proof.sh:85`). Adding a duplicate under `scripts/tests/proof/` (as the older spec §7.3 suggested) would **orphan** that wiring and violate §11.4.122 (no silent removal / no shadow duplicate). The Phase-2 plan itself records this correction: "Task 5 **extends the existing wired file** … it does NOT create a duplicate at `proof/`" (`docs/superpowers/plans/2026-07-05-phase2-semantic-live-plan.md:27` and `:886`).
  - Append the layer-3 (semantic) + layer-4 (superpowers-TUI) loop **before** the final `summary` (currently `verify_providers_live.sh:78`), after the structural checks. Keep the top-level SKIP guard (`:21-24`) so a host with no aliases still exits 0.
  - Keep every new layer SKIP-safe / exit-0-on-precondition-absent so `run-proof.sh`'s "SKIP = pass" contract holds — the plan's Task 5 body is at `…phase2-semantic-live-plan.md:771-843` (writes `proof/providers-<id>-semantic.txt`, `proof/providers-<id>-superpowers.txt`, and aggregate `proof/providers-summary.json`).

- **Files to CREATE (not extensions of live infra) — per plan, out of Task-5 scope but consumed by it:**
  - `scripts/claude-semantic-visibility.sh` — NEW driver, mirrors `claude-verify-providers.sh` (§5 pattern). Plan Task 1.
  - `scripts/providers-semantic.sh` — NEW layer-3 adapter. Plan Task 2.
  - `scripts/verify_superpowers_tui.sh` — NEW live layer-4 test (SKIP-able Tier-B). Plan Task 3. (Its superpowers-engagement idea already has a working reference implementation in `verify_claude_live.sh:37` / `run_tui` `:119-125` + `lib/pty_drive.py` — reuse that PTY/scrub machinery rather than re-inventing it.)

- **Do NOT touch**: `run-proof.sh` (wiring already correct — plan Task 5 Step 3 is verify-only, `…plan.md:828-831`); `verify_opencode_live.sh`; `verify_aliases_live.sh`.

Net: Task 5 is a **pure append** to `scripts/tests/verify_providers_live.sh`, reusing `PROOF_DIR`, the SKIP guard, the `it/_pass/summary` harness, and the `cma_redact`/scrub conventions already established by the sibling live verifiers.
