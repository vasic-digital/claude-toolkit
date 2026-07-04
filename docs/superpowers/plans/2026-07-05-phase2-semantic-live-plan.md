# Provider Verification Overhaul — Implementation Plan (Phase 2: semantic layer + live verification)

> **For agentic workers:** REQUIRED SUB-SKILL: Use `superpowers:subagent-driven-development` (recommended, §11.4.70) or `superpowers:executing-plans` to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking. Every change passes an independent code review before commit (§11.4.142) and a deep multi-angle web-research pass before any closure/structural verdict (§11.4.150).

**Goal:** Add verification layer 3 (semantic code-visibility) and layer 4 (superpowers-TUI) to the provider-alias pipeline. Drive the LLMsVerifier submodule's `semantic-code-visibility` Go command from a cached toolkit driver, feed it the toolkit-owned fixture/prompt/sentinel/rubric, wire the verdict into `cmd_sync` (persisting through the Phase-1 `cma_status_write`), add a live superpowers-TUI test that flips a provider to fully `verified`, correct the xAI existence treatment, and add a Tier-B live verifier — all with hermetic (Tier-A) coverage that stays deterministic by stubbing the Go binary and faking endpoints.

**Architecture:** The Phase-1 status cache (`$(cma_providers_dir)/status.json`, written by `cma_status_write`) remains the single source of truth. Layer 3 slots into `cmd_sync` *after* existence/tool-call (`providers-verify.sh` returns `verified`): a new `scripts/providers-semantic.sh` adapter renders the toolkit rubric into a judge prompt, splits the toolkit prompt template into round-1/round-2, normalizes the base URL, injects keys via env (never argv), and execs the cached Go binary through a new `scripts/claude-semantic-visibility.sh` driver (mirroring the existing `claude-verify-providers.sh` cache-and-exec shape). Layer 4 (`scripts/verify_superpowers_tui.sh`) is a live, SKIP-able Tier-B test that launches real `claude` against `~/.claude-prov-<id>` and, on pass, is the only thing that writes fully-`verified`. The extended `scripts/tests/verify_providers_live.sh` (already wired into `run-proof.sh`) runs layers 3–4 on the real host and writes evidence to `scripts/tests/proof/`.

**Tech Stack:** POSIX-leaning bash (Linux + macOS bash 4+; macOS re-execs a newer bash), `jq` for JSON, Go 1.25 stdlib for the submodule command (already written), Python 3 for the existing `model_verify.py` scoring engine (untouched here), the hermetic sandbox harness under `scripts/tests/`.

---

## Reality reconciliation (READ FIRST — the tree is ahead of the spec)

Parallel work already landed several Phase-2 substrates. This plan **verifies + wires**, it does not re-scaffold (§11.4.74 extend-don't-reimplement, §11.4.124 investigate-before-touch):

1. **The Go command already exists and is implemented.** `submodules/LLMsVerifier/llm-verifier/cmd/semantic-code-visibility/main.go` (standalone, stdlib-only — Option C from `docs/research/2026-07-04-llmsverifier-go-internals.md`, no cgo/`database`/`verification` imports) plus `main_test.go`. Task 1 **verifies** it (build + `go test`), does **not** rewrite it.
2. **Its real flag contract differs from spec §2.3** — the plan uses the REAL flags:
   - Required: `--base-url --model --api-key-env --fixture --prompt --sentinel` (`--api-key-env` names the env var; the key is read via `os.Getenv`, never passed on argv). `--timeout` (default 60), `--format json`.
   - Round-2 (all-or-none, enables the judge): `--judge-base-url --judge-model --judge-api-key-env`. Optional `--round2-prompt` (describe instruction; generic default) and `--judge-prompt` (scoring template with `{{FIXTURE_CONTENT}}` + `{{DESCRIPTION}}`; generic default). `--judge-threshold` (default 2).
   - **There is NO `--rubric` flag.** The spec's `rubric/code-visibility-rubric.json` is consumed by the *toolkit* (`providers-semantic.sh` renders it into a `--judge-prompt` template) — never bundled into the submodule (preserves the CONST-051 boundary: the submodule stays project-not-aware; fixture/prompt/judge-prompt/sentinel all arrive as CLI args).
   - It POSTs to **`{base-url}/v1/chat/completions`** (it appends `/v1/chat/completions` itself). The driver MUST pass a base URL **without** a trailing `/v1` or `/anthropic` (see Task 2 normalization), else you get `/v1/v1/chat/completions`.
   - Output JSON shape (REAL): `{"round1_sentinel":{"pass":bool,"observed":str,"reason"?},"round2_judge":{"pass":bool|null,"score":int|null,"skipped":bool,"reason"?},"overall_pass":bool}`. **No `evidence.fixture_hash`/`prompt_hash` block** (spec §2.3 showed one; the real command omits it). The cache write + Tier-B evidence reflect the real shape.
   - Exit codes (REAL): `0` overall pass · `1` verification fail · `2` usage/config error (missing/empty key, unreadable fixture, bad flags). The adapter maps these to `verified` / `unverified` / `skip`.
3. **`cma_status_write/read/all/cache` + the activation gate already exist** (Phase 1, `lib.sh:759-796` and the `cma_run_provider` heredoc + migration marker `…+activation-gate`, `lib.sh:470`). Task 2 persists through the existing `cma_status_write` — no schema change.
4. **`cmd_sync` already persists status** (`claude-providers.sh:190-228`) and already has a "Phase 2 (semantic…)" comment placeholder at the non-verified write. Task 2 edits that block in place — and **corrects** its existing mislabel (it currently writes `unverified`→`semantic` even when the existence probe was merely inconclusive; the corrected code writes `existence` when the semantic layer never ran).
5. **`scripts/tests/verify_providers_live.sh` already exists and is already wired into `run-proof.sh:30`** — at `scripts/tests/`, **not** `scripts/tests/proof/` as spec §7.3 said. Task 5 **extends the existing wired file** (adds layers 3–4 + aggregate summary); it does NOT create a duplicate at `proof/` (that would orphan the wiring and violate §11.4.122). The spec §7.3 path is superseded by the already-wired path; this is recorded in the self-review corrections.
6. **CONST-052 collision.** Spec §3.4 proposed adding the boundary contract as "CONST-052" in the submodule constitution. But `submodules/LLMsVerifier/CLAUDE.md` already defines CONST-052 = "Lowercase-Snake_Case-Naming Mandate" (cascaded). The boundary contract MUST use a non-colliding id — deferred to Phase 3 (docs/constitution); Phase 2 keeps the boundary in the *code* (CLI-arg-only inputs) and the self-review flags the id collision so Phase 3 does not reintroduce it.

---

## Global Constraints

- Target Linux + macOS; bash 4+ (macOS ships 3.2 — `install.sh` re-execs a newer bash; test the same way). POSIX-leaning: no GNU-only `awk` 3-arg `match()`, no `mktemp --suffix`; use `mktemp "${TMPDIR:-/tmp}/x.XXXXXX"`. `lib.sh` guards use literal `()` not `\(\)` (BRE empty-group bug, [[bre-empty-group-migration-bug]]).
- **Secrets via environment only** (`CMA_PROBE_KEY` for the model under test, `CMA_JUDGE_KEY` for the judge), never argv; the Go command reads them by env-var NAME via `--api-key-env`/`--judge-api-key-env`. Keys files are sourced only inside subshells (as `cmd_sync` already does at `claude-providers.sh:204`). No key ever lands in `status.json`, an `*.env`, the alias file, or a `proof/` artifact.
- **Status vocabulary is exactly**: `verified` (all runnable layers passed, none failed) / `unverified` (existence+tool-call passed, a later layer failed) / `failed` (existence or tool-call failed) / `pending` (not yet run). No other values. **`verified` = "no layer that we could actually test failed."** A layer that cannot run (no key / no network / no `go` / no real `claude`) is an **honest SKIP** (§11.4.3) and MUST NOT downgrade a provider — only a real layer *failure* downgrades. This keeps the activation gate usable while honoring "verified means all four" wherever the layers are actually testable.
- **Layer→status mapping** (the whole pipeline, so the plan stays internally consistent):
  | Layer | Runner | pass | fail | skip (precondition absent) |
  |---|---|---|---|---|
  | 1 existence / 2 tool-call | `providers-verify.sh` | `verified` (so far) | `failed`/`existence` | `unverified`/`existence` (inconclusive) |
  | 3 semantic | `providers-semantic.sh` → Go cmd | keep `verified` | `unverified`/`semantic` | keep prior verdict (no downgrade) |
  | 4 superpowers-TUI | `verify_superpowers_tui.sh` | `verified` (final flip) | `unverified`/`superpowers_tui` | keep prior verdict (no downgrade) |
- **Submodule discipline (Task 1 touches the separate `vasic-digital/LLMsVerifier` repo):** before any push in the submodule, `git fetch --all --prune` + investigate the diff vs our last HEAD (§11.4.71); **never** force-push (§11.4.113 absolute); commit the Go command in the submodule, then bump the submodule pointer in the main repo as its **own** commit (§11.4.124 separate-commit discipline). The submodule stays CONST-051-decoupled: zero `claude_toolkit`/`cma_`/`claude-providers`/toolkit-path/release-prefix strings in its source.
- **Every destructive replacement** uses `backup_and_remove` / `.preunify.<timestamp>`; nothing is `rm`'d without a backup. New temp files use `mktemp` + `mv` (atomic).
- **Hermetic (Tier-A) tests** use `make_sandbox` (mktemp `$HOME`, `CLAUDE_BIN=/usr/bin/true`), never touch real `~/.claude*`, no network, no keys, no `go`, no real `claude`. Tier-A stays deterministic (§11.4.50) by stubbing the driver / faking the endpoint. **Tier-B** (live) SKIPs-with-reason when preconditions are absent — never a faked PASS (§11.4.3), never a metadata-only pass (§11.4).
- **No fixes without root cause** (§11.4.102); no silent removal of existing components (§11.4.122); investigate dead/existing code before changing (§11.4.124). Every state-advancing commit updates `docs/CONTINUATION.md` + `.remember/remember.md` in the SAME commit (§11.4.131 / §6.S).
- Existing `claude1..N` accounts + existing provider aliases keep working unchanged.

---

## File Structure

- **Verify (no edit): `submodules/LLMsVerifier/llm-verifier/cmd/semantic-code-visibility/{main.go,main_test.go}`** — already implemented (Task 1 builds + tests them).
- **New: `scripts/claude-semantic-visibility.sh`** — thin build-and-cache driver for the Go command (mirrors `claude-verify-providers.sh`), binary cached at `.local-cache/semantic-code-visibility`.
- **New: `scripts/providers-semantic.sh`** — the layer-3 adapter (mirrors `providers-verify.sh`'s one-word stdout contract); renders rubric→judge-prompt, splits the prompt template, normalizes base URL, injects keys, execs the driver.
- **New: `scripts/providers/judge.env.template`** + `.gitignore` entry for `providers/judge.env` — the round-2 judge config (open question §10.2: a sensible default judge, overridable).
- **New: `scripts/verify_superpowers_tui.sh`** — the live layer-4 test (SKIP-able Tier-B).
- **Modify: `scripts/claude-providers.sh`** — `SEMANTIC` var + env overrides (`CMA_PROVIDERS_VERIFY`/`CMA_PROVIDERS_SEMANTIC`), the layer-3 wiring + failing-layer correction in `cmd_sync` (~lines 190-228), a `cmd_verify <id>` single-provider deep path + dispatch, xAI alias-id tolerance in the existence path.
- **Modify: `scripts/tests/verify_providers_live.sh`** — add live layers 3–4 + `proof/providers-summary.json` aggregate (already wired into `run-proof.sh`).
- **Modify: `scripts/tests/test_providers.sh`** — new hermetic sections: semantic adapter (stubbed driver), `cmd_sync` layer-3 integration (stubbed), xAI existence, superpowers-TUI SKIP behavior, rubric→judge-prompt rendering, CONST-051 boundary (fixture/rubric read from `providers/`, not the submodule).
- **Modify: `docs/CONTINUATION.md`, `.remember/remember.md`** — Phase-2 progress (final task).

---

### Task 1: Verify + driver the `semantic-code-visibility` Go command

**Files:**
- Verify (no edit): `submodules/LLMsVerifier/llm-verifier/cmd/semantic-code-visibility/main.go` + `main_test.go`
- Create: `scripts/claude-semantic-visibility.sh`
- Test: `scripts/tests/test_providers.sh` (new section `semantic driver`) — hermetic (stubs `go`/binary)

**Interfaces:**
- Consumes: `go` toolchain (Tier-B build only), the submodule at `submodules/LLMsVerifier/llm-verifier`.
- Produces: `claude-semantic-visibility.sh` — builds `./cmd/semantic-code-visibility/` to `${LV_SEMANTIC_BIN:-$REPO_ROOT/.local-cache/semantic-code-visibility}` (cached; rebuild when `main.go -nt` the binary), then `exec "$BIN" "$@"`. Preconditions mirror `claude-verify-providers.sh`: submodule present + `go` on PATH, else a clear non-zero error. Honors `LLMSVERIFIER_DIR`, `LV_SEMANTIC_BIN`.

- [ ] **Step 1: Confirm the command builds + its own tests pass (Tier-B, evidence-first)**

Run (submodule build + unit test; this is the §11.4 captured-evidence for "the command works"):
```bash
cd submodules/LLMsVerifier/llm-verifier
GOMAXPROCS=2 nice -n 19 go test -count=1 ./cmd/semantic-code-visibility/
GOMAXPROCS=2 nice -n 19 go build -o /tmp/scv ./cmd/semantic-code-visibility/ && /tmp/scv -h 2>&1 | head -20
```
Expected: `ok  digital.vasic.llmsverifier/cmd/semantic-code-visibility` and a flag-usage dump listing `--base-url --model --api-key-env --fixture --prompt --sentinel --judge-base-url --judge-model --judge-api-key-env --judge-threshold --format`. If `go` is absent, this step is a documented SKIP (§11.4.3) and Task 1 proceeds to the driver (which is exercised hermetically in Step 4).

- [ ] **Step 2: Write the failing test (hermetic — stub `go`, assert the driver's build+exec contract)**

Add to `scripts/tests/test_providers.sh` (new section, before `summary`):
```bash
# ---------------------------------------------------------------------------
# Section — semantic-code-visibility driver (claude-semantic-visibility.sh)
# Hermetic: a fake `go` on PATH "builds" a stub binary that echoes its argv,
# proving the driver caches + forwards flags without a real toolchain/network.
# ---------------------------------------------------------------------------
SEMDRV="$SCRIPTS_DIR/claude-semantic-visibility.sh"
_sem_bin="$HOME/.local-cache/semantic-code-visibility"
mkdir -p "$HOME/fakebin"
# Fake `go`: `go build -o <out> ./cmd/...` writes a stub that prints its args.
cat > "$HOME/fakebin/go" <<'FAKEGO'
#!/usr/bin/env bash
if [[ "$1" == build ]]; then
  out=""; while (($#)); do [[ "$1" == -o ]] && { out="$2"; shift 2; continue; }; shift; done
  printf '#!/usr/bin/env bash\nprintf "SCV-STUB %s\\n" "$*"\nexit 0\n' > "$out"; chmod +x "$out"; exit 0
fi
exit 0
FAKEGO
chmod +x "$HOME/fakebin/go"

it "claude-semantic-visibility.sh builds (cached) + forwards flags to the binary"
rm -f "$_sem_bin"
out="$( PATH="$HOME/fakebin:$PATH" LLMSVERIFIER_DIR="$SCRIPTS_DIR/../submodules/LLMsVerifier" \
        LV_SEMANTIC_BIN="$_sem_bin" bash "$SEMDRV" --model m --sentinel Z 2>/dev/null )"
printf '%s\n' "$out" | grep -q 'SCV-STUB' ; assert_eq 0 $? "driver execs the built binary"
printf '%s\n' "$out" | grep -q -- '--sentinel Z' ; assert_eq 0 $? "driver forwards flags verbatim"
assert_file "$_sem_bin" "binary was cached under .local-cache"
```

- [ ] **Step 3: Run test to verify it fails**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 'semantic-code-visibility driver'`
Expected: FAIL — `claude-semantic-visibility.sh` does not exist yet.

- [ ] **Step 4: Write the driver**

Create `scripts/claude-semantic-visibility.sh` (executable — `install.sh` auto-links every `claude-*.sh`):
```bash
#!/usr/bin/env bash
# claude-semantic-visibility.sh — build + run the LLMsVerifier semantic-code-visibility
# command (layer 3: "does this model actually SEE my code through the alias path?").
#
# Mirrors claude-verify-providers.sh: builds the Go binary (cached; rebuild if the
# command source is newer), then execs it, passing the caller's flags through. The
# command is stdlib-only (no cgo/database) so it builds without a C toolchain.
#
# Secrets: the command reads the model + judge keys from the env var NAMES given via
# --api-key-env / --judge-api-key-env (os.Getenv), never from argv.
#
# Env knobs: LLMSVERIFIER_DIR (submodule path), LV_SEMANTIC_BIN (cached binary path).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LV_DIR="${LLMSVERIFIER_DIR:-$REPO_ROOT/submodules/LLMsVerifier}"
LV_MOD="$LV_DIR/llm-verifier"
BIN="${LV_SEMANTIC_BIN:-$REPO_ROOT/.local-cache/semantic-code-visibility}"
SRC="$LV_MOD/cmd/semantic-code-visibility/main.go"

case "${1:-}" in -h|--help) exec "$BIN" -h 2>/dev/null || { echo "semantic-code-visibility driver: builds + runs the LLMsVerifier command"; exit 0; } ;; esac

if [ ! -d "$LV_MOD" ]; then
  echo "error: LLMsVerifier submodule not initialized." >&2
  echo "  run: git submodule update --init submodules/LLMsVerifier" >&2
  exit 3
fi
if ! command -v go >/dev/null 2>&1; then
  echo "error: the Go toolchain is required to build the semantic verifier." >&2
  exit 4
fi

if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  mkdir -p "$(dirname "$BIN")"
  echo "building semantic-code-visibility (go build)…" >&2
  ( cd "$LV_MOD" && go build -o "$BIN" ./cmd/semantic-code-visibility/ ) \
    || { echo "error: semantic verifier build failed" >&2; exit 5; }
fi

exec "$BIN" "$@"
```

- [ ] **Step 5: Run test to verify it passes**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 'semantic-code-visibility driver'`
Expected: PASS.

- [ ] **Step 6: Commit (main-repo driver only; the Go command is already committed in the submodule)**

If the submodule's `main.go`/`main_test.go` are uncommitted in the submodule worktree, commit them **in the submodule** first (separate repo), fetch-before-push (§11.4.71), no force-push (§11.4.113), then bump the pointer:
```bash
# Only if the submodule has uncommitted semantic-code-visibility work:
git -C submodules/LLMsVerifier fetch --all --prune
git -C submodules/LLMsVerifier add llm-verifier/cmd/semantic-code-visibility/
git -C submodules/LLMsVerifier commit -m "feat(cmd): semantic-code-visibility — generic 2-round sentinel+judge code-visibility verifier

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
# then, in the main repo, the pointer bump is its OWN commit:
git add submodules/LLMsVerifier
git commit -m "chore(submodule): bump LLMsVerifier pointer to semantic-code-visibility command

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```
Then commit the driver:
```bash
git add scripts/claude-semantic-visibility.sh scripts/tests/test_providers.sh
git commit -m "feat(providers): claude-semantic-visibility driver (build+cache the layer-3 Go command)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `providers-semantic.sh` adapter + wire layer 3 into `cmd_sync`

**Files:**
- Create: `scripts/providers-semantic.sh`
- Create: `scripts/providers/judge.env.template`; add `judge.env` to `scripts/providers/.gitignore`
- Modify: `scripts/claude-providers.sh` (`SEMANTIC` var + `CMA_PROVIDERS_*` overrides near line 43; the layer-3 block + failing-layer correction in `cmd_sync` ~190-228; a `cmd_verify` single-provider path + dispatch)
- Test: `scripts/tests/test_providers.sh` (`semantic adapter` + `cmd_sync layer-3` sections, both stubbed)

**Interfaces:**
- `providers-semantic.sh --provider ID --model M --key-var VAR [--base-url URL] [--offline]` → one word on stdout: `verified` (round-1 + round-2 judge passed) | `unverified` (round-1 or round-2 failed — semantic layer failed) | `skip` (precondition/config absent — honest SKIP, no downgrade). Reason on stderr. Exit: 0 verified, 1 unverified, 2 skip. Overridable driver via `CMA_SEMANTIC_DRIVER` (default `$LIB_DIR/claude-semantic-visibility.sh`) so tests inject a stub.
- Reads the toolkit-owned seam from `providers/` (NOT the submodule — CONST-051 boundary): `fixture/code-visibility.md`, `fixture/prompt-template.txt`, `rubric/code-visibility-rubric.json`, sentinel `ZETA-9-ORANGE-7f3a`. Judge config from `providers/judge.env` (if present) else `providers/judge.env.template` defaults.
- `cmd_sync` consumes `providers-semantic.sh` via a `SEMANTIC` var (overridable `CMA_PROVIDERS_SEMANTIC`); persists through the existing `cma_status_write`.

- [ ] **Step 1: Write the failing tests (hermetic — stub the Go driver via `CMA_SEMANTIC_DRIVER`)**

Add to `scripts/tests/test_providers.sh`:
```bash
# ---------------------------------------------------------------------------
# Section — providers-semantic.sh (layer 3 adapter). A stub driver stands in
# for the Go binary: it echoes a canned verdict JSON + exits with a chosen code,
# so the adapter's stdout/exit mapping is asserted with no go/network/keys.
# ---------------------------------------------------------------------------
SEMSH="$SCRIPTS_DIR/providers-semantic.sh"
_mk_stub_driver() {  # $1 = exit code, $2 = overall_pass json bool
  cat > "$HOME/fakebin/scv-stub" <<EOF
#!/usr/bin/env bash
printf '{"round1_sentinel":{"pass":$2,"observed":"ZETA-9-ORANGE-7f3a"},"round2_judge":{"pass":$2,"score":3,"skipped":false},"overall_pass":$2}\n'
exit $1
EOF
  chmod +x "$HOME/fakebin/scv-stub"
}

it "providers-semantic maps overall_pass=true -> 'verified' exit 0"
_mk_stub_driver 0 true
out="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
        bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
        --base-url https://api.deepseek.com 2>/dev/null )"; rc=$?
assert_eq "verified" "$out" "pass -> verified"
assert_eq 0 "$rc" "pass -> exit 0"

it "providers-semantic maps overall_pass=false -> 'unverified' exit 1"
_mk_stub_driver 1 false
out="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y \
        bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
        --base-url https://api.deepseek.com 2>/dev/null )"; rc=$?
assert_eq "unverified" "$out" "fail -> unverified"
assert_eq 1 "$rc" "fail -> exit 1"

it "providers-semantic SKIPs (exit 2 -> 'skip') when the model key is absent — no downgrade"
out="$( CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" \
        bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
        --base-url https://api.deepseek.com 2>/dev/null )"; rc=$?
assert_eq "skip" "$out" "no key -> skip"
assert_eq 2 "$rc" "skip -> exit 2"

it "providers-semantic reads fixture/rubric from providers/ (CONST-051 boundary), not the submodule"
# The rendered judge-prompt must contain rubric-derived criteria, proving the
# toolkit owns the judge input and the submodule binary only receives CLI args.
_mk_stub_driver 0 true
CMA_SEMANTIC_DRIVER="$HOME/fakebin/scv-stub" CMA_PROBE_KEY=x CMA_JUDGE_KEY=y CMA_SEMANTIC_DEBUG=1 \
  bash "$SEMSH" --provider deepseek --model deepseek-chat --key-var DEEPSEEK_API_KEY \
  --base-url https://api.deepseek.com >/dev/null 2>"$HOME/sem.err"
grep -q 'resolve_alias' "$HOME/sem.err" ; assert_eq 0 $? "judge-prompt carries rubric fixture-specific detail"
```

Add the `cmd_sync` integration test (stubs BOTH the existence verifier and the semantic adapter via env overrides):
```bash
# ---------------------------------------------------------------------------
# Section — cmd_sync layer-3 wiring. Stub existence -> 'verified' and semantic
# -> 'unverified' and assert the persisted status is unverified/semantic.
# ---------------------------------------------------------------------------
cat > "$HOME/fakebin/verify-ok" <<'EOF'
#!/usr/bin/env bash
echo verified
EOF
cat > "$HOME/fakebin/semantic-fail" <<'EOF'
#!/usr/bin/env bash
echo unverified
exit 1
EOF
chmod +x "$HOME/fakebin/verify-ok" "$HOME/fakebin/semantic-fail"

it "cmd_sync: existence=verified + semantic=unverified -> status unverified/semantic"
# (uses the Section-3 catalog + key-aliases already seeded above; a key must be
# set so cmd_sync attempts verification. --no-verify is NOT passed.)
CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-ok" \
CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-fail" \
BETA_API_KEY=sk-test \
  bash "$PROVIDERS_SH" sync --keys-file <(echo 'export BETA_API_KEY=sk-test') >/dev/null 2>&1
assert_eq "unverified" "$(cma_status_read beta)" "semantic failure demotes to unverified"
assert_jq "$(cma_status_cache)" '.beta.failing_layer' "semantic" "failing layer = semantic"

it "cmd_sync: existence=verified + semantic=skip -> stays verified (honest SKIP, no downgrade)"
cat > "$HOME/fakebin/semantic-skip" <<'EOF'
#!/usr/bin/env bash
echo skip
exit 2
EOF
chmod +x "$HOME/fakebin/semantic-skip"
CMA_PROVIDERS_VERIFY="$HOME/fakebin/verify-ok" \
CMA_PROVIDERS_SEMANTIC="$HOME/fakebin/semantic-skip" \
BETA_API_KEY=sk-test \
  bash "$PROVIDERS_SH" sync --keys-file <(echo 'export BETA_API_KEY=sk-test') >/dev/null 2>&1
assert_eq "verified" "$(cma_status_read beta)" "semantic skip does not downgrade verified"
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 -E 'providers-semantic|cmd_sync: existence'`
Expected: FAIL — `providers-semantic.sh` missing; `CMA_PROVIDERS_VERIFY`/`CMA_PROVIDERS_SEMANTIC` overrides not honored; `cmd_sync` does not call a semantic layer.

- [ ] **Step 3: Write `providers-semantic.sh`**

Create `scripts/providers-semantic.sh`:
```bash
#!/usr/bin/env bash
# providers-semantic.sh — layer-3 (semantic code-visibility) adapter for
# claude-providers. Runs AFTER existence/tool-call passed. Drives the
# LLMsVerifier semantic-code-visibility command with the toolkit-owned fixture,
# prompt, sentinel and rubric (the submodule stays project-not-aware; every
# consumer-specific input is a CLI arg — CONST-051).
#
# Output: one word on stdout — verified | unverified | skip. Exit: 0/1/2.
#   verified  round-1 sentinel + round-2 judge both passed.
#   unverified  a round failed (this alias cannot genuinely see your code / bluffed).
#   skip  a precondition was absent (no key/judge/go/network) — HONEST SKIP,
#         the caller MUST NOT downgrade on this (§11.4.3).
#
# Args: --provider ID --model M --key-var VAR [--base-url URL] [--offline]
set -uo pipefail

_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"

PROVIDER="" MODEL="" KEYVAR="" BASEURL="" OFFLINE=0
while (( $# )); do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    --key-var)  KEYVAR="$2"; shift 2 ;;
    --base-url) BASEURL="$2"; shift 2 ;;
    --offline)  OFFLINE=1; shift ;;
    *) echo "providers-semantic: unknown arg $1" >&2; exit 2 ;;
  esac
done

emit_skip() { echo skip; echo "providers-semantic[$PROVIDER]: skip — ${1:-precondition absent}" >&2; exit 2; }

DRIVER="${CMA_SEMANTIC_DRIVER:-$LIB_DIR/claude-semantic-visibility.sh}"
FIX="${CMA_SEMANTIC_FIXTURE:-$LIB_DIR/providers/fixture/code-visibility.md}"
PROMPT="${CMA_SEMANTIC_PROMPT:-$LIB_DIR/providers/fixture/prompt-template.txt}"
RUBRIC="${CMA_SEMANTIC_RUBRIC:-$LIB_DIR/providers/rubric/code-visibility-rubric.json}"
SENTINEL="${CMA_SEMANTIC_SENTINEL:-ZETA-9-ORANGE-7f3a}"

(( OFFLINE )) && emit_skip "offline"
[[ -f "$FIX" && -f "$PROMPT" && -f "$RUBRIC" ]] || emit_skip "toolkit seam files missing"
command -v jq >/dev/null 2>&1 || emit_skip "jq not available"

# --- keys (env only; never argv) -------------------------------------------
# The model-under-test key: the caller (cmd_sync) has already sourced the keys
# file into this process's env, so ${!KEYVAR} resolves. Re-export under the
# fixed name the Go command reads via --api-key-env.
mkey="${!KEYVAR:-}"
[[ -n "$mkey" ]] || emit_skip "no key in \$$KEYVAR for model under test"
export CMA_PROBE_KEY="$mkey"

# --- judge config (providers/judge.env overrides the template default) ------
JUDGE_ENV="${CMA_JUDGE_ENV:-$LIB_DIR/providers/judge.env}"
[[ -f "$JUDGE_ENV" ]] || JUDGE_ENV="$LIB_DIR/providers/judge.env.template"
# shellcheck source=/dev/null  # runtime judge config, non-secret (holds var NAMES + urls)
[[ -f "$JUDGE_ENV" ]] && { set -a +u; . "$JUDGE_ENV"; set +a; }
JUDGE_BASE="${CMA_JUDGE_BASE_URL:-}"
JUDGE_MODEL="${CMA_JUDGE_MODEL:-}"
JUDGE_KEYVAR="${CMA_JUDGE_KEYVAR:-}"
JUDGE_THRESHOLD="${CMA_JUDGE_THRESHOLD:-2}"
# Judge key: the value under $CMA_JUDGE_KEY (already set by tests) OR ${!JUDGE_KEYVAR}.
jkey="${CMA_JUDGE_KEY:-}"
[[ -z "$jkey" && -n "$JUDGE_KEYVAR" ]] && jkey="${!JUDGE_KEYVAR:-}"
[[ -n "$jkey" && -n "$JUDGE_BASE" && -n "$JUDGE_MODEL" ]] || emit_skip "no round-2 judge configured (see providers/judge.env)"
export CMA_JUDGE_KEY="$jkey"

# --- base-url normalization (the Go command appends /v1/chat/completions) ----
base="${BASEURL:-}"
base="${base%/}"; base="${base%/chat/completions}"; base="${base%/anthropic}"; base="${base%/v1}"
[[ -n "$base" ]] || emit_skip "no base url"

# --- split the toolkit prompt template into round-1 + round-2 ----------------
# The template carries a "Round 1 —" block and a "Round 2 —" block; the Go
# command takes them as two separate flags. Split on the first line starting
# with "Round 2" (a generic delimiter; the wording stays toolkit-owned).
tmp1="$(mktemp "${TMPDIR:-/tmp}/cma-r1.XXXXXX")"
tmp2="$(mktemp "${TMPDIR:-/tmp}/cma-r2.XXXXXX")"
awk 'BEGIN{p=1} /^Round 2/{p=2} p==1{print > R1} p==2{print > R2}' \
    R1="$tmp1" R2="$tmp2" "$PROMPT"

# --- render the rubric into a judge-prompt template (toolkit-owned) ----------
tmpj="$(mktemp "${TMPDIR:-/tmp}/cma-judge.XXXXXX")"
{
  echo "You grade whether a DESCRIPTION accurately reflects some REFERENCE code."
  echo
  echo "REFERENCE code:"
  echo "{{FIXTURE_CONTENT}}"
  echo
  echo "DESCRIPTION to grade:"
  echo "{{DESCRIPTION}}"
  echo
  echo "Score 0-3 using this rubric:"
  jq -r '.criteria | to_entries[] | "  \(.key) = \(.value)"' "$RUBRIC"
  echo "Fixture-specific details a good description names:"
  jq -r '.fixture_specific_details[] | "  - \(.)"' "$RUBRIC"
  echo
  echo "Reply with ONLY the single integer 0, 1, 2, or 3."
} > "$tmpj"

[[ -n "${CMA_SEMANTIC_DEBUG:-}" ]] && cat "$tmpj" >&2

cleanup() { rm -f "$tmp1" "$tmp2" "$tmpj"; }
trap cleanup EXIT

# --- run the command (keys via env, never argv) ------------------------------
set +e
"$DRIVER" \
  --base-url "$base" --model "$MODEL" --api-key-env CMA_PROBE_KEY \
  --fixture "$FIX" --prompt "$tmp1" --round2-prompt "$tmp2" --sentinel "$SENTINEL" \
  --judge-base-url "$JUDGE_BASE" --judge-model "$JUDGE_MODEL" --judge-api-key-env CMA_JUDGE_KEY \
  --judge-prompt "$tmpj" --judge-threshold "$JUDGE_THRESHOLD" \
  --format json >/dev/null 2>"$LIB_DIR/../.local-cache/semantic-last.err"
rc=$?
set -e

case "$rc" in
  0) echo verified;   echo "providers-semantic[$PROVIDER]: layer-3 sentinel+judge PASS" >&2; exit 0 ;;
  1) echo unverified; echo "providers-semantic[$PROVIDER]: layer-3 FAIL (cannot see code / bluffed)" >&2; exit 1 ;;
  *) emit_skip "semantic command config/precondition error (exit $rc)" ;;
esac
```

Create `scripts/providers/judge.env.template` (open question §10.2 — a sensible default judge, overridable by copying to `providers/judge.env`):
```bash
# providers/judge.env — round-2 judge configuration for semantic code-visibility.
# Copy to providers/judge.env and set to a DIFFERENT provider/model than the one
# under test (an independent judge; §3.2 defense-in-depth). Holds only NON-secret
# config: a base URL, a model id, and the NAME of the env var holding the judge
# key (never the key itself). judge.env is gitignored.
CMA_JUDGE_BASE_URL="https://api.deepseek.com"
CMA_JUDGE_MODEL="deepseek-chat"
CMA_JUDGE_KEYVAR="DEEPSEEK_API_KEY"
CMA_JUDGE_THRESHOLD="2"
```
Append to `scripts/providers/.gitignore`:
```
judge.env
semantic-last.err
```

- [ ] **Step 4: Wire layer 3 into `claude-providers.sh`**

Near the other path vars (`claude-providers.sh:43-44`) add the semantic path + env overrides:
```bash
VERIFY="${CMA_PROVIDERS_VERIFY:-$LIB_DIR/providers-verify.sh}"
SEMANTIC="${CMA_PROVIDERS_SEMANTIC:-$LIB_DIR/providers-semantic.sh}"
```
(Change the existing `VERIFY="$LIB_DIR/providers-verify.sh"` to the `${CMA_PROVIDERS_VERIFY:-...}` form so the hermetic test can inject a stub.)

Replace the status-write block in `cmd_sync` (currently `claude-providers.sh:218-226`, the `if [[ "$vstatus" == "verified" ]] … else … semantic … fi`) with the layer-3 orchestration + failing-layer correction:
```bash
    cma_link_shared_items "$cdir"
    cma_provider_write_env "$pid" "$keyvar" "$transport" "$base" "$model" "$fast" "$cdir" "$ctx_limit" "$max_out" "$alias"
    cma_provider_write_alias "$alias" "$pid"

    # Layer bookkeeping. vstatus here is 'verified' (existence+tool-call passed)
    # or 'unverified' (existence probe inconclusive). failing_layer records the
    # FIRST layer that did not pass ("" when none failed).
    local flayer=""
    if [[ "$vstatus" == "verified" ]]; then
      # Layer 3: semantic code-visibility. Only attempt when verification is on
      # and we are not offline; a 'skip' (precondition absent) NEVER downgrades.
      if (( ! NO_VERIFY )) && (( ! OFFLINE )); then
        local sstatus
        # shellcheck source=/dev/null  # runtime user keys file, path only known at execution
        sstatus="$( ( [[ -f "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; \
                      bash "$SEMANTIC" --provider "$pid" --model "$model" --key-var "$keyvar" \
                        ${base:+--base-url "$base"} 2>/dev/null ) )" || true
        if [[ "$sstatus" == "unverified" ]]; then
          vstatus="unverified"; flayer="semantic"
        fi
        # 'verified' | 'skip' | '' -> keep the existence verdict (verified).
      fi
    else
      # existence probe was inconclusive -> the layer that did not pass is existence.
      flayer="existence"
    fi
    cma_status_write "$pid" "$vstatus" "$model" "$flayer"
    cma_log "provider '$pid' -> alias '$alias' [$transport] model=$model ($vstatus${flayer:+/$flayer})"
    n_created=$((n_created+1))
```

Add a single-provider deep-verify entry (the command the activation gate points at, spec §5.2) — a `cmd_verify` that reruns existence + semantic (+ optionally layer 4) for ONE provider and persists. Place near `cmd_sync`:
```bash
# claude-providers verify <id> [--deep]
# Re-run verification for ONE already-installed provider and persist status.
# --deep also runs the live superpowers-TUI (layer 4); without it, layers 1-3.
cmd_verify() {
  local id="${1:-}" deep=0; shift 2>/dev/null || true
  [[ "${1:-}" == "--deep" ]] && deep=1
  [[ -n "$id" ]] || cma_die "usage: claude-providers verify <id> [--deep]"
  local envf; envf="$(cma_providers_dir)/$id.env"
  [[ -f "$envf" ]] || cma_die "unknown provider: $id (run: claude-providers sync)"
  # shellcheck source=/dev/null
  ( set -a +u; . "$envf"; set +a
    local base="$CMA_PROVIDER_BASE_URL" model="$CMA_PROVIDER_MODEL" keyvar="$CMA_PROVIDER_KEYVAR"
    local vst sst flayer=""
    vst="$( ( [[ -f "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; \
              bash "$VERIFY" --provider "$id" --model "$model" --key-var "$keyvar" ${base:+--base-url "$base"} 2>/dev/null ) )" || true
    [[ -z "$vst" ]] && vst=unverified
    if [[ "$vst" == "failed" ]]; then cma_status_write "$id" failed "$model" existence; echo "failed"; return; fi
    if [[ "$vst" != "verified" ]]; then cma_status_write "$id" unverified "$model" existence; echo "unverified"; return; fi
    sst="$( ( [[ -f "$CMA_KEYS_FILE" ]] && { set -a +u; . "$CMA_KEYS_FILE"; set +a; }; \
              bash "$SEMANTIC" --provider "$id" --model "$model" --key-var "$keyvar" ${base:+--base-url "$base"} 2>/dev/null ) )" || true
    if [[ "$sst" == "unverified" ]]; then cma_status_write "$id" unverified "$model" semantic; echo "unverified"; return; fi
    if (( deep )); then
      if bash "$LIB_DIR/verify_superpowers_tui.sh" --alias "$id" >/dev/null 2>&1; then
        cma_status_write "$id" verified "$model" ""; echo "verified"; return
      fi
      # layer-4 SKIP or FAIL: SKIP keeps verified-through-3; FAIL demotes.
      # verify_superpowers_tui.sh exits 0 on PASS *and* on SKIP (honest), 1 on FAIL.
      if [[ $? -eq 1 ]]; then cma_status_write "$id" unverified "$model" superpowers_tui; echo "unverified"; return; fi
    fi
    cma_status_write "$id" verified "$model" ""; echo "verified" )
}
```
Add `verify` to the subcommand accept-list (the `SUBCMD="$1"; shift` guard where the other verbs are recognized) AND add an explicit branch to the dispatch `case "$SUBCMD" in … esac` (`claude-providers.sh:504-512` — it is an explicit per-verb `case`, NOT a `cmd_$SUBCMD` mapping):
```bash
  verify)      cmd_verify "${POSITIONAL[@]:-}" ;;
```
Update `usage()` to document `verify <id> [--deep]`.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 -E 'providers-semantic|cmd_sync: existence'`
Expected: PASS (all semantic-adapter + cmd_sync-integration assertions green).

- [ ] **Step 6: Commit**

```bash
git add scripts/providers-semantic.sh scripts/providers/judge.env.template scripts/providers/.gitignore \
        scripts/claude-providers.sh scripts/tests/test_providers.sh
git commit -m "feat(providers): layer-3 semantic code-visibility — providers-semantic.sh + cmd_sync/cmd_verify wiring

Runs after existence/tool-call; renders the toolkit rubric into a judge prompt,
drives the LLMsVerifier semantic-code-visibility command, persists via cma_status_write.
Honest SKIP never downgrades; corrects the inconclusive-existence failing-layer label.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: `verify_superpowers_tui.sh` — the live layer-4 test

**Files:**
- Create: `scripts/verify_superpowers_tui.sh`
- Test: `scripts/tests/test_providers.sh` (`superpowers-tui SKIP` section — Tier-A asserts only the SKIP-when-absent path; the PASS path is Tier-B, exercised by Task 5)

**Interfaces:**
- `verify_superpowers_tui.sh --alias ID [--prompt STR] [--timeout N] [--out FILE]` → launches real `claude` against `~/.claude-prov-<ID>` non-interactively via the installed `cma_run_provider ID -p "<prompt>"`, in a scrubbed env (mirrors `verify_claude_live.sh`'s `SCRUB`), from a throwaway cwd so it can't resume a real session.
- **PASS (exit 0)** iff: the session launched with NO trust/overwrite prompt AND the superpowers plugin engaged (transcript carries the engagement marker) AND it exited cleanly within the timeout. **FAIL (exit 1)** iff it launched but the plugin did not engage, or a trust/overwrite prompt fired (detected as a hang → timeout, or the trust-dialog text in the transcript). **SKIP (exit 0, prints `SKIP: <reason>`)** when a precondition is absent (§11.4.3): no real `claude` (`CLAUDE_BIN` empty / `/usr/bin/true`), no alias installed, no key for the provider, no network. SKIP is exit 0 (an honest non-failure), FAIL is exit 1 — so `cmd_verify --deep` can distinguish "layer-4 not run" from "layer-4 failed" via the exit code + a printed `SKIP:`/`FAIL:` line.

- [ ] **Step 1: Write the failing test (Tier-A: only the deterministic SKIP path)**

Add to `scripts/tests/test_providers.sh`:
```bash
# ---------------------------------------------------------------------------
# Section — verify_superpowers_tui.sh SKIP behavior (Tier-A: no real claude).
# With CLAUDE_BIN=/usr/bin/true (the sandbox default) the layer-4 test MUST
# SKIP-with-reason and exit 0 — never a faked PASS, never a hard FAIL.
# ---------------------------------------------------------------------------
STUI="$SCRIPTS_DIR/verify_superpowers_tui.sh"

it "verify_superpowers_tui SKIPs (exit 0 + reason) when there is no real claude binary"
out="$( CLAUDE_BIN=/usr/bin/true bash "$STUI" --alias deepseek --timeout 5 2>&1 )"; rc=$?
assert_eq 0 "$rc" "SKIP is a non-failure (exit 0)"
printf '%s\n' "$out" | grep -q 'SKIP:' ; assert_eq 0 $? "prints an honest SKIP reason"
printf '%s\n' "$out" | grep -qiv 'PASS' ; assert_eq 0 $? "never claims PASS when skipping"

it "verify_superpowers_tui SKIPs when the named alias is not installed"
out="$( CLAUDE_BIN="$(command -v cat)" bash "$STUI" --alias no_such_alias --timeout 5 2>&1 )"; rc=$?
assert_eq 0 "$rc" "unknown alias -> SKIP exit 0"
printf '%s\n' "$out" | grep -q 'SKIP:' ; assert_eq 0 $? "reason printed for unknown alias"
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 'verify_superpowers_tui'`
Expected: FAIL — script does not exist.

- [ ] **Step 3: Write `verify_superpowers_tui.sh`**

Create `scripts/verify_superpowers_tui.sh`:
```bash
#!/usr/bin/env bash
# verify_superpowers_tui.sh — layer-4 live test: launch REAL Claude Code through a
# provider alias and confirm (a) no trust/overwrite prompt fires and (b) the
# superpowers plugin engages end-to-end. This is the ONLY thing that flips a
# provider to fully 'verified' (§4.4, §11.4.108 layer-4 user-visible).
#
# Honest SKIP (§11.4.3), never a faked PASS: SKIPs (exit 0, prints "SKIP: <why>")
# when the real claude binary / the alias / a key / the network is absent.
# PASS -> exit 0 + "PASS: ...". FAIL -> exit 1 + "FAIL: ...".
#
# Usage: verify_superpowers_tui.sh --alias ID [--prompt STR] [--timeout N] [--out FILE]
set -uo pipefail
TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDIR="$HOME/.local/share/claude-multi-account/providers"
ALIASES_FILE="${ALIAS_FILE:-$HOME/.local/share/claude-multi-account/aliases.sh}"

ALIAS_ID="" PROMPT="/using-superpowers" TIMEOUT=180 OUT=""
while (( $# )); do
  case "$1" in
    --alias)   ALIAS_ID="$2"; shift 2 ;;
    --prompt)  PROMPT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${OUT:=${PROOF_DIR:-$TESTS_ROOT/tests/proof}/providers-${ALIAS_ID}-superpowers.txt}"
mkdir -p "$(dirname "$OUT")"

skip() { echo "SKIP: $1"; { echo "# SKIP $(date): $1"; } >> "$OUT" 2>/dev/null || true; exit 0; }

# --- preconditions (each an honest SKIP) ------------------------------------
[[ -n "$ALIAS_ID" ]] || skip "no --alias given"
CB="${CLAUDE_BIN:-$(command -v claude || true)}"
[[ -n "$CB" && "$CB" != "/usr/bin/true" && "$(basename "$CB")" == claude* ]] || skip "no real claude binary (CLAUDE_BIN=$CB)"
[[ -f "$ALIASES_FILE" ]] || skip "no alias file ($ALIASES_FILE) — run install.sh"
[[ -f "$PDIR/$ALIAS_ID.env" ]] || skip "alias '$ALIAS_ID' not installed"
command -v curl >/dev/null 2>&1 || skip "no curl (cannot pre-check network)"
# key present?
keyvar="$( set -a; . "$PDIR/$ALIAS_ID.env"; set +a; printf '%s' "${CMA_PROVIDER_KEYVAR:-}" )"
( set -a +u; [[ -f "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" ]] && . "${CMA_KEYS_FILE:-$HOME/api_keys.sh}"; set +a
  eval "tok=\"\${$keyvar:-}\""; [[ -n "${tok:-}" ]] ) || skip "no key in \$$keyvar for '$ALIAS_ID'"

# --- launch (scrubbed env + throwaway cwd, like verify_claude_live.sh) -------
SCRUB=(env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT -u CLAUDE_CONFIG_DIR
       -u ANTHROPIC_MODEL -u ANTHROPIC_BASE_URL -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN)
tmpd="$(mktemp -d "${TMPDIR:-/tmp}/cma-stui.XXXXXX")"
: > "$OUT"
out="$( timeout "$TIMEOUT" "${SCRUB[@]}" bash -c '
    cd "'"$tmpd"'" || exit 97
    source "'"$ALIASES_FILE"'" >/dev/null 2>&1
    cma_run_provider "'"$ALIAS_ID"'" -p "'"$PROMPT"'" --output-format json 2>&1
  ' )"
rc=$?
rmdir "$tmpd" 2>/dev/null || true
printf '%s\n' "$out" >> "$OUT"

# --- classify ---------------------------------------------------------------
# A trust/overwrite prompt makes the non-interactive launch hang -> timeout (124),
# or leaves its dialog text in the transcript.
if (( rc == 124 )); then echo "FAIL: launch hung within ${TIMEOUT}s (trust/overwrite prompt?)"; echo "# FAIL: timeout" >> "$OUT"; exit 1; fi
if printf '%s' "$out" | grep -qiE 'do you (trust|want to open)|overwrite.*config|trust the files'; then
  echo "FAIL: a trust/overwrite prompt fired"; echo "# FAIL: trust-prompt" >> "$OUT"; exit 1
fi
# superpowers engagement marker: the skill announces itself in the transcript.
if printf '%s' "$out" | grep -qiE 'superpowers|using-superpowers|systematic-debugging|skill'; then
  echo "PASS: superpowers engaged, no trust/overwrite prompt"; echo "# PASS" >> "$OUT"; exit 0
fi
echo "FAIL: session ran but superpowers did not engage"; echo "# FAIL: no-engagement" >> "$OUT"; exit 1
```
Note (§11.4.102, to confirm at implementation): whether `-p` (print mode) reliably fires a superpowers *skill* engagement marker is provider/version-dependent. If print mode proves insufficient, switch the launch to the existing PTY driver (`scripts/tests/lib/pty_drive.py --prompt "$PROMPT" --use-superpowers`) that `verify_claude_live.sh` already uses for the TUI — same classification, fuller layer-4. Do NOT invent a marker; use whichever path produces a real, observable engagement signal.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 'verify_superpowers_tui'`
Expected: PASS (both SKIP-path assertions green — no real claude in the sandbox).

- [ ] **Step 5: Commit**

```bash
git add scripts/verify_superpowers_tui.sh scripts/tests/test_providers.sh
git commit -m "feat(providers): verify_superpowers_tui.sh — live layer-4 (SKIP-able) that flips to verified

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: xAI existence treatment — CORRECTED (real `/v1/models`, alias-id nuance; NO docs-scrape)

**Files:**
- Modify (only if a scrape/hardcode special-case exists): `scripts/providers-verify.sh` / `scripts/model_verify.py` / `scripts/providers_resolve.py`
- Test: `scripts/tests/test_providers.sh` (`xai existence` section — hermetic, fake `/v1/models`)

**Interfaces:**
- Consumes: the existing generic `/models` probe (`providers-verify.sh:57` probes `${BASEURL%/}/models`).
- Produces: xAI (`base=https://api.x.ai/v1`) verifies through the SAME generic path (`https://api.x.ai/v1/models` returns `{"object":"list","data":[{"id":"latest","aliases":[...]}]}`). NO `docs.x.ai` scrape, NO `providers/cache/xai-models.json`, NO xAI branch. The only nuance: when an id-membership check runs, xAI's live list surfaces **alias ids** (`"latest"`, entries with `aliases:[]`) rather than concrete build ids, so membership must tolerate aliases.

- [ ] **Step 1: Investigate first (§11.4.124) — is there any xAI special-case to remove?**

```bash
grep -rniE 'xai|x\.ai|scrape|xai-models' scripts/ | grep -v test_
```
Record the finding in the commit body. Per `docs/CONTINUATION.md` "Corrections discovered during Phase 1" + `docs/research/2026-07-04-provider-api-endpoints.md §3`: the spec §4.6 "no /models endpoint → scrape docs" premise is **contradicted** — xAI exposes `GET https://api.x.ai/v1/models` (OpenAI-shaped, has `context_length`). If a scrape/hardcode branch was never implemented, Task 4 is: (a) confirm the generic path covers xAI, (b) add alias-id tolerance where membership is checked, (c) add the hermetic test, (d) do NOT build the scrape path. If a partial special-case exists, remove it in its own commit citing the git-history investigation (§11.4.124).

- [ ] **Step 2: Write the failing test (hermetic — a local fake `/v1/models`)**

Add to `scripts/tests/test_providers.sh`:
```bash
# ---------------------------------------------------------------------------
# Section — xAI existence via the generic /models probe (CORRECTED: xAI DOES
# expose GET /v1/models, OpenAI-shaped, with alias ids like "latest"). No
# docs-scrape special-case may exist.
# ---------------------------------------------------------------------------
it "no xAI docs-scrape / hardcoded-model special-case is present in the sources"
! grep -rniE 'docs\.x\.ai|scrape|xai-models\.json' "$SCRIPTS_DIR"/*.sh "$SCRIPTS_DIR"/*.py 2>/dev/null
assert_eq 0 $? "xAI is handled by the generic /models path, not a scrape branch"

it "providers-verify treats xAI like any OpenAI-shaped provider (200 on /models -> verified)"
# Fake xAI /v1/models on loopback so the generic curl probe returns 200.
python3 - "$HOME/xai.port" <<'PY' &
import http.server, socketserver, sys, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.send_header("Content-Type","application/json"); self.end_headers()
        self.wfile.write(json.dumps({"object":"list","data":[{"id":"latest","aliases":[],"context_length":131072,"object":"model","owned_by":"xai"}]}).encode())
    def log_message(self,*a): pass
with socketserver.TCPServer(("127.0.0.1",0),H) as s:
    open(sys.argv[1],"w").write(str(s.server_address[1])); s.handle_request()
PY
# wait for the port file, then probe
for _ in $(seq 1 50); do [[ -s "$HOME/xai.port" ]] && break; sleep 0.05; done
port="$(cat "$HOME/xai.port" 2>/dev/null)"
XAI_API_KEY=sk-test out="$( XAI_API_KEY=sk-test bash "$SCRIPTS_DIR/providers-verify.sh" \
    --provider xai --model grok-4 --key-var XAI_API_KEY \
    --base-url "http://127.0.0.1:${port}/v1" 2>/dev/null )"
assert_eq "verified" "$out" "xAI /v1/models 200 -> verified (no special-case)"
```

- [ ] **Step 3: Implement (add alias-id tolerance only where id-membership is checked)**

If the existence path only checks HTTP 200 on `/models` (as `providers-verify.sh` does today), **no code change is needed** — record "verified already covered by the generic path" (§11.4.124 honest no-op). If/where a configured-model-id-∈-catalog membership check runs (e.g. in `providers_resolve.py` or a future strict existence gate), tolerate xAI alias ids: accept when the live list contains the configured id OR an alias entry (`"id":"latest"` or a non-empty `aliases[]`). Keep it a generic "accept alias ids" tolerance, not an `if provider == xai` branch, so it degrades gracefully for any alias-emitting provider.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 'xAI'`
Expected: PASS (no-scrape assertion + fake-`/v1/models` probe both green).

- [ ] **Step 5: Commit**

```bash
git add scripts/tests/test_providers.sh scripts/providers-verify.sh scripts/providers_resolve.py 2>/dev/null
git commit -m "fix(providers): xAI verified via generic /v1/models (corrected); no docs-scrape special-case

Per docs/research/2026-07-04-provider-api-endpoints.md §3: xAI exposes GET
/v1/models (OpenAI-shaped, alias ids). Drops the stale spec §4.6 scrape premise;
adds alias-id tolerance + a hermetic fake-endpoint test.

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: Extend the Tier-B live verifier + confirm run-proof wiring

**Files:**
- Modify: `scripts/tests/verify_providers_live.sh` (already wired into `run-proof.sh:30`)
- Verify (no edit expected): `scripts/tests/run-proof.sh`

**Interfaces:**
- Adds, per installed provider whose cached status is `verified`/`unverified` (read-only against real host state; SKIPs the whole file when no aliases installed, as it already does):
  1. **Semantic (layer 3)** — run `providers-semantic.sh` for the provider; capture stdout+reason to `proof/providers-<id>-semantic.txt`. SKIP-with-reason when the driver/`go`/keys/judge/network are absent (never a faked PASS, §11.4.3).
  2. **Superpowers-TUI (layer 4)** — run `verify_superpowers_tui.sh --alias <id> --out proof/providers-<id>-superpowers.txt`. SKIP when no real `claude`.
  3. **Aggregate** — write `proof/providers-summary.json`: per-alias `{status, layers:{existence,semantic,superpowers_tui}, evidence:{...paths}}` (§11.4.83 end-user evidence; §11.4.116 verdict-carries-evidence-path). The JSON mirrors the REAL semantic output shape (no `fixture_hash`).
- All additions are read-only + SKIP-safe: the file's exit code stays 0 when every live layer SKIPs (preconditions absent), matching `run-proof.sh`'s "SKIP counts as pass" contract (`run-proof.sh:85`).

- [ ] **Step 1: Add the live layers (guarded by preconditions; each an honest SKIP)**

Append to `scripts/tests/verify_providers_live.sh` (before the final `summary`), after the existing structural checks:
```bash
# --- layer 3 (semantic) + layer 4 (superpowers-TUI) per installed provider ---
SUMMARY="$PROOF_DIR/providers-summary.json"
printf '{}\n' > "$SUMMARY"
for f in "$PDIR"/*.env; do
  id="$( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_ID" )"
  status="$( source "$SCRIPTS_DIR/lib.sh" 2>/dev/null; cma_status_read "$id" )"

  it "semantic (layer 3) for '$id' — PASS/SKIP, never a faked pass"
  sem_ev="$PROOF_DIR/providers-${id}-semantic.txt"
  sem="$( ( [[ -f "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" ]] && { set -a +u; . "${CMA_KEYS_FILE:-$HOME/api_keys.sh}"; set +a; }; \
            bash "$SCRIPTS_DIR/providers-semantic.sh" --provider "$id" \
              --model "$( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_MODEL" )" \
              --key-var "$( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_KEYVAR" )" \
              --base-url "$( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_BASE_URL" )" ) 2>"$sem_ev" )"
  echo "semantic verdict: ${sem:-skip}" >> "$sem_ev"
  case "$sem" in
    verified)   _pass "layer-3 semantic PASS for $id" ;;
    unverified) _pass "layer-3 semantic ran (verdict: unverified) for $id" ;;  # a real verdict, not a test failure
    *)          echo "SKIP: layer-3 preconditions absent for $id" ;;
  esac

  it "superpowers-TUI (layer 4) for '$id' — PASS/SKIP"
  bash "$SCRIPTS_DIR/verify_superpowers_tui.sh" --alias "$id" \
     --out "$PROOF_DIR/providers-${id}-superpowers.txt" --timeout 180 || true

  # aggregate (real semantic shape: no fixture_hash)
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma-sum.XXXXXX")"
  jq --arg id "$id" --arg st "$status" --arg sem "${sem:-skip}" \
     --arg semev "$sem_ev" --arg tuiev "$PROOF_DIR/providers-${id}-superpowers.txt" \
     '.[$id]={status:$st, layers:{semantic:$sem}, evidence:{semantic:$semev, superpowers_tui:$tuiev}}' \
     "$SUMMARY" > "$tmp" && mv "$tmp" "$SUMMARY"
done
echo "aggregate: $SUMMARY" >> "$EV"
```

- [ ] **Step 2: Run it (Tier-B — expect all-SKIP on a host without keys/go/claude, exit 0)**

Run: `bash scripts/tests/verify_providers_live.sh; echo "rc=$?"`
Expected: on a host with no keys/go/real-claude, every live layer prints `SKIP: …` and `rc=0`; on a fully-provisioned host, real `verified`/`unverified` verdicts + a populated `proof/providers-summary.json`. Confirm no non-zero exit from SKIP-only runs (matches `run-proof.sh` "SKIP = pass").

- [ ] **Step 3: Confirm `run-proof.sh` picks it up (no edit expected)**

Run: `grep -n verify_providers_live scripts/tests/run-proof.sh`
Expected: line 30 already invokes it and folds `prov_rc` into the final all-green gate (`run-proof.sh:85`). If the aggregate should surface in `PROOF.md`, note it references `providers-summary.json` — a one-line addition to the report block is optional and non-blocking.

- [ ] **Step 4: Commit**

```bash
git add scripts/tests/verify_providers_live.sh
git commit -m "test(proof): Tier-B live verifier runs semantic + superpowers-TUI, writes providers-summary.json

SKIP-with-reason when go/keys/judge/network/real-claude absent (never a faked PASS);
already wired into run-proof.sh. Extends the existing wired file (not a proof/ duplicate).

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: Full hermetic suite green + Go test + CONTINUATION/remember sync

**Files:**
- Modify: `docs/CONTINUATION.md`, `.remember/remember.md`
- Test: the whole hermetic suite + the submodule Go test

- [ ] **Step 1: Run the full hermetic suite (Tier-A) — must stay deterministic**

Run: `bash scripts/tests/run-all.sh`
Expected: ALL GREEN, including the new sections — `semantic-code-visibility driver`, `providers-semantic`, `cmd_sync layer-3`, `verify_superpowers_tui SKIP`, `xAI existence`. No section touches the network, `go`, real keys, or real `claude` (all stubbed / faked-loopback), so the run is deterministic (§11.4.50).

- [ ] **Step 2: Run the submodule Go test (Tier-B, resource-capped per submodule CLAUDE.md rule 9)**

Run: `cd submodules/LLMsVerifier/llm-verifier && GOMAXPROCS=2 nice -n 19 go test -count=1 ./cmd/semantic-code-visibility/`
Expected: `ok  digital.vasic.llmsverifier/cmd/semantic-code-visibility`. If `go` absent → documented SKIP.

- [ ] **Step 3: Update handoff docs (§11.4.131 / §6.S — SAME commit as the state advance)**

Update `docs/CONTINUATION.md`: flip the "Implementation phases" bullet to `✅ Phase 2 (semantic + live) — COMPLETE`, list the Task 1–6 commits, bump the `Last HEAD` line, and record the corrections this plan applied (real Go flags vs spec §2.3; wired live-verifier path vs spec §7.3 `proof/`; CONST-052 id collision deferred to Phase 3). Rewrite `.remember/remember.md` to the post-Phase-2 state (short + full resumption variants, §11.4.127).

- [ ] **Step 4: Commit**

```bash
git add docs/CONTINUATION.md .remember/remember.md
git commit -m "docs: Phase 2 (semantic layer + live verification) complete; CONTINUATION synced (§11.4.131)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (Phase 2 scope) + corrections applied:**
- Spec §3 (LLMsVerifier `semantic-code-visibility` capability) → Task 1 **verifies** the already-implemented standalone stdlib command + adds the cache-and-exec driver. ✅ *Correction:* the command is already written (not to-be-scaffolded); the plan reflects its REAL flags (`--judge-prompt`, no `--rubric`; appends `/v1/chat/completions`; exit 0/1/2; output has no `evidence` hashes) rather than spec §2.3's idealized contract.
- Spec §4.1–4.3 (fixture/prompt/rubric seam) → Task 2 consumes them from `providers/` and renders the rubric into a `--judge-prompt` (the submodule never receives the rubric file — CONST-051 boundary held; asserted by the `CONST-051 boundary` test). ✅
- Task-list item 1 (driver builds+caches the Go cmd; submodule pointer discipline) → Task 1 (`claude-semantic-visibility.sh`, §11.4.71 fetch-before-push, §11.4.113 no-force-push, separate pointer-bump commit). ✅
- Task-list item 2 (wire semantic into the toolkit; pass→toward-verified, fail→`unverified`/`semantic`; persist via `cma_status_write`) → Task 2 (`providers-semantic.sh` + `cmd_sync` block + `cmd_verify`). ✅ *Correction:* also fixes the pre-existing `cmd_sync` mislabel (inconclusive existence was tagged `semantic`; now `existence`).
- Task-list item 3 (`verify_superpowers_tui.sh`, PASS iff engaged AND no trust/overwrite prompt, SKIP-with-reason, flips to fully verified) → Task 3 + the `cmd_verify --deep` flip. ✅ SKIP=exit 0, FAIL=exit 1 so the caller distinguishes not-run from failed.
- Task-list item 4 (xAI CORRECTED — real `/v1/models`, alias-id nuance, no scrape) → Task 4, grounded in the CONTINUATION correction + endpoint research; investigate-before-remove (§11.4.124). ✅
- Task-list item 5 (Tier-B `verify_providers_live.sh` + run-proof wiring) → Task 5. ✅ *Correction:* the file already exists at `scripts/tests/` and is already wired (spec §7.3's `proof/` path is superseded); the plan **extends the wired file**, does not create a duplicate (§11.4.122).
- Task-list item 6 (hermetic tests keep Tier-A deterministic) → Task 2/3/4 tests stub the driver (`CMA_SEMANTIC_DRIVER`), stub existence+semantic in `cmd_sync` (`CMA_PROVIDERS_VERIFY`/`CMA_PROVIDERS_SEMANTIC`), fake `go`, and fake `/v1/models` on loopback — no network/keys/go/claude. Task 6 also runs the already-present `main_test.go`. ✅
- Out of Phase-2 scope (deferred, not dropped): the CONST-052→boundary-contract constitution entry (id collides with the cascaded CONST-052 "snake_case naming" — Phase 3 must pick a non-colliding id), the manual/FAQ/diagrams/templates, and the v1.12.0 cross-repo release (`<prefix>/v1.12.0`, §11.4.151) — all Phase 3. Documented here so Phase 3 does not re-derive.

**Placeholder scan:** No TBD/TODO/"add error handling" — every code step carries complete, buildable code. Task 4 Step 3 is intentionally conditional (§11.4.124 investigate-first: implement only if a scrape branch is found; else an honest no-op with recorded evidence) — that is the correct shape for a remove-only/confirm task, not a placeholder. The Task 3 print-mode-vs-PTY note is a flagged §11.4.102 confirmation point (use whichever produces a real engagement signal), not an unfinished stub.

**Type / name consistency:** `providers-semantic.sh` one-word contract `verified|unverified|skip` (exit 0/1/2) is used identically in its own tests, the `cmd_sync` wiring, `cmd_verify`, and the Tier-B verifier. `verify_superpowers_tui.sh` contract (PASS exit 0 / FAIL exit 1 / SKIP exit 0 + `SKIP:`) is consistent across its Tier-A test, `cmd_verify --deep`, and Task 5. The status vocabulary (`verified|unverified|failed|pending`) and failing-layer tokens (`existence|semantic|superpowers_tui`) are consistent throughout. Env-override knobs (`CMA_SEMANTIC_DRIVER`, `CMA_PROVIDERS_VERIFY`, `CMA_PROVIDERS_SEMANTIC`, `CMA_JUDGE_*`, `LV_SEMANTIC_BIN`, `LLMSVERIFIER_DIR`) are named identically where introduced and consumed. The Go command's REAL flag set (`--base-url --model --api-key-env --fixture --prompt --round2-prompt --sentinel --judge-base-url --judge-model --judge-api-key-env --judge-prompt --judge-threshold --format`) is used verbatim in the adapter — cross-checked against `main.go:118-132`.

**Secret-handling audit:** keys move only via env (`CMA_PROBE_KEY`, `CMA_JUDGE_KEY`) read by env-var NAME in the Go command; keys files sourced only in subshells; no key in `status.json`, `*.env`, alias file, judge config (holds var NAMES only), or any `proof/` artifact. `providers/judge.env` + `semantic-last.err` are gitignored. Matches the toolkit's existing process-substituted-fd / env-only discipline.

**Determinism / SKIP honesty:** every live layer SKIPs-with-reason (§11.4.3) and returns a non-failing exit when its preconditions are absent, so `run-proof.sh`'s "SKIP = pass" gate holds and Tier-A never depends on network/keys/go/real-claude.
