# Changelog

All notable changes to the Claude multi-account toolkit.

## v1.1.0 — 2026-06-16 — Distributed infrastructure + provider verification

Headline: stand up the full LLMsVerifier System on a remote host for heavy
testing against **real production LLM services**, plus end-to-end provider
aliases proven on two hosts and two transports.

### Added
- **`containers` + `challenges` submodules** (`submodules/`) — the
  distributed-boot orchestrator and its sibling. `helix-deps.yaml` confirms
  `containers` has zero own-org submodule deps.
- **Remote host registration** — `config/containers/nezha.env` registers
  `nezha.local` as a remote boot/test host (SSH key, podman runtime).
- **LLMsVerifier deployment overlays** (`config/containers/llmsverifier/`):
  - `docker-compose.app.yml` — the `llm-verifier` API (cgo image, config mount,
    `/api/health` healthcheck, loopback, fail-fast secrets).
  - `docker-compose.infra.yml` — observability tier: prometheus + grafana
    (auto-provisioned datasource + dashboard) + node-exporter. **No DBs**
    (the app uses SQLite; postgres/redis were unused and removed).
  - `Dockerfile.nezha` / `Dockerfile.mv` — cgo nested-module builds for the
    server + the `model-verification` tool.
  - `patches/0001..0005` — upstream LLMsVerifier fixes (see PR #2 below).
- **Deployment guide** `config/containers/llmsverifier/README.md` and the
  **Provider Aliases User Guide** `docs/Provider_Aliases_User_Guide.md`
  (HTML/PDF/DOCX exports included).
- **QA evidence** `docs/qa/20260616-infra/` — verification proofs, endpoint
  coverage, security posture, observability, per-provider sweeps, dual-host
  end-to-end alias proofs.

### Changed
- **Provider session accent color: orange → purple** across spec, guide, and
  the long-form doc. (Claude Code 2.1.178 cannot persist a default `/color`, so
  this is the documented default + a manual `/color purple` — a platform limit.)
- `claude-add-account` consolidated onto the shared `cma_link_shared_items`
  helper (single `CMA_SHARED_ITEMS` source).
- `claude-export-docs` now also emits **DOCX** (HTML/PDF/DOCX).

### Fixed (LLMsVerifier — shipped as PR #2, applied to deployed builds)
- **Auth header missing** — verification requests sent no `Authorization`
  header → HTTP 401 for every provider. Now `Bearer <key>`.
- **cohere 405** — switched to the OpenAI-compat endpoint
  (`api.cohere.ai/compatibility/v1`). Verifies at score 1.00.
- **gemini / huggingface** — corrected to OpenAI-compat / router endpoints
  (huggingface verifies; gemini code-ready pending a valid key).
- **model-id strictness** — verifies a requested id directly when not in the
  discovered list (no premature `model_not_found`).
- **no `/metrics`** — added `GET /api/metrics` + `/metrics` (stdlib Prometheus).
- **provider-session sync-state noise** — `cma_run_provider` no longer runs
  cross-account sync-state on isolated provider dirs.

### Verified live (real "Do you see my code?" against production APIs)
- **9 providers verified:** DeepSeek, Groq, Mistral, Cerebras, Novita, NVIDIA,
  Cohere, Codestral, HuggingFace.
- **Both transports, both hosts:** native (DeepSeek) + router (Novita via ccr)
  on macOS and on nezha.
- Account-side failures (402/401/429/403) and non-OpenAI providers documented
  honestly; excluded under "valid users only" but kept fully supported.

### Safety
- Provider dirs (`~/.claude-prov-*`) excluded from account detection — existing
  `claudeN` accounts and `claude-add-account` untouched.
- Secrets only in the keys file + on-host mode-600 `.env`; never in the repo.
  All published ports bound to loopback.

## v1.0.0 — 2026-06-16 — Dynamic provider-alias generator

First tagged release. `claude-providers` creates per-provider Claude Code
aliases (DeepSeek, Groq, GLM, …) from your keys file pointed at each provider's
strongest model — fully dynamic via models.dev + the LLMsVerifier submodule,
hybrid native/claude-code-router transport, full lifecycle + tests + docs.
See `docs/Provider_Aliases_User_Guide.md`.
