# Release-Readiness Constitution Compliance Audit

- **Repo:** `/run/media/milosvasic/DATA4TB/Projects/claude_toolkit` — branch `main`
- **Date:** 2026-07-04 — **READ-ONLY** audit
- **Produced by:** parallel constitution-audit subagent (§11.4.150 parallel deep-research); all evidence is real captured command output.

## Gate 1 — CONST-051 (submodule decoupling)

Command (from repo root):
```bash
grep -rIl --include='*.go' --include='*.sh' --include='*.py' \
  -e 'claude_toolkit' -e 'claude-providers' -e 'cma_run_provider' -e 'CMA_PROVIDER' \
  submodules/LLMsVerifier/llm-verifier/ 2>/dev/null | head -50
```
Actual output: *(no file paths printed; exit 0)* — zero matching files. The `--include` filters cover all go/sh/py source; none are source or doc hits.

**Verdict: PASS** — no consumer-project names in the LLMsVerifier submodule source. The submodule is strictly decoupled.

## Gate 2 — §11.4.113 / §11.4.156 (no force-push, no active CI/CD)

```bash
git ls-files | grep -E '^\.github/workflows/.*\.ya?ml$|^\.gitlab-ci\.yml$' || echo NONE
```
Output: `NONE`
```bash
grep -rn -- '--force' scripts/ 2>/dev/null | grep -i push || echo NONE
```
Output: `NONE`

**Verdict: PASS** — no tracked CI/CD workflows, no force-push in scripts.

## Gate 3 — §11.4.157 (GEMINI.md lockstep)

```bash
ls -la {CLAUDE,AGENTS,QWEN,GEMINI}.md 2>&1
```
Output: only `CLAUDE.md` (9749 B) exists; `AGENTS.md`, `QWEN.md`, `GEMINI.md` are absent.

| File | Exists | Bytes |
|---|---|---|
| CLAUDE.md | yes | 9749 |
| AGENTS.md | no | — |
| QWEN.md | no | — |
| GEMINI.md | no | — |

**Verdict: NEEDS-FIX** — only CLAUDE.md exists; three lockstep siblings missing. Report-only (not created here). Address before release (Phase 3).

## Gate 4 — §11.4.151 (release-tag prefix)

```bash
grep -H HELIX_RELEASE_PREFIX .env .env.example 2>&1 || echo 'no .env prefix'
```
Output: no `.env` / `.env.example` at root → fallback = lowercased root dir name.

Resolved prefix: **`claude_toolkit`**.

**Verdict: PASS.**

## Gate 5 — §11.4.53 (.gitignore hygiene)

```bash
git ls-files | grep -E 'node_modules/|\.env$|api_keys|\.credentials' || echo CLEAN
```
Output: `config/containers/nezha.env`

Secret-content check:
```bash
grep -iE 'key|token|secret|password|passwd' config/containers/nezha.env
# CONTAINERS_REMOTE_DEFAULT_SSH_KEY=~/.ssh/id_ed25519
# CONTAINERS_REMOTE_HOST_1_KEY=~/.ssh/id_ed25519
```
Only SSH key **file paths** (no key material), no node_modules / api_keys / .credentials. Consistent with the SSH-key-only security constraint.

**Verdict: PASS (with note)** — a tracked `*.env` config file trips the `\.env$` pattern but holds no secret values or build artifacts. Optional hygiene: rename to `.env.example`.

## Gate 6 — Test-suite baseline

```bash
bash scripts/tests/run-all.sh 2>&1 | tail -4
# ============================================
# Test files: 20   passed: 20   failed: 0
# ALL GREEN
```

**Verdict: PASS** — 20/20 green.

## Verdict summary

| Gate | Ref | Verdict |
|---|---|---|
| 1 Submodule decoupling | CONST-051 | PASS |
| 2 No force-push / CI/CD | §11.4.113 / §11.4.156 | PASS |
| 3 GEMINI.md lockstep | §11.4.157 | NEEDS-FIX |
| 4 Release-tag prefix | §11.4.151 | PASS (`claude_toolkit`) |
| 5 .gitignore hygiene | §11.4.53 | PASS (with note) |
| 6 Test baseline | — | PASS (20/20) |

**Tally:** 5 PASS, 1 NEEDS-FIX, 0 FAIL.

## Release blockers

None (no hard FAIL). Outstanding **NEEDS-FIX before release**: create `AGENTS.md`, `QWEN.md`, `GEMINI.md` at root in lockstep with `CLAUDE.md` (§11.4.157). Optional hygiene: `config/containers/nezha.env` trips `\.env$` scanners but holds only SSH key paths.
