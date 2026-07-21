# Innovations Roadmap — Follow-up Work Items from the 2026-07-20 Deep Research

**Purpose.** This is the single durable landing point for the actionable output of this
session's deep-research legs, so no finding is lost and every one maps to a concrete future
work item against *this* toolkit. It is a synthesis of already-written research — every row
cites the source brief or transcript it came from; **no fresh web research was done here.**

**Sources synthesised**
- `docs/research/credit_detection_20260720/BRIEF.md` — per-provider balance endpoints, the
  `(provider, status, body-code)` error taxonomy, and the plan-gated "$0-but-not-free" trap.
  Status: DONE (18 providers, all with source URLs + 2026-07-20 access dates).
- `docs/research/antibluff_20260720/BRIEF.md` — mutation testing, vacuous-test detection,
  LLM-work verification, hermeticity, evidence-backed reporting (ranked R1–R9 mapped to failure
  modes F1–F7). Status: COMPLETE.
- `docs/research/gateway_20260720/BRIEF.md` — Go LLM-gateway resilience, streaming correctness &
  zero-downtime config for our Go `claude-code-router` reimpl: retry/first-byte safety, client-
  disconnect cancellation, SSE flush, streaming usage accounting, `atomic.Pointer[Config]` hot-swap,
  failover / circuit-breaking, and a ranked gap list **G1–G12**. Status: COMPLETE (every claim
  carries a source URL + 2026-07-20 access date; no-consensus items flagged). Folded in below as the
  `GW-*` rows; the observability items (OB-1/OB-2) it confirms are now concrete, no longer
  `[gateway-pending]`.
- Session transcripts (treated as verified inputs, not re-derived): capability-ranking signal
  research, observability-metrics comparison, benchmark-validity findings.

**How to read the priorities.** `P0` = do next (top-priority follow-up). `P1` = correctness/
safety, schedule soon. `P2` = correctness-adjacent or high-value enhancement. `P3` =
enhancement / speculative / blocked on external work. The **Class** column separates
**S/C (safety-or-correctness)** items — things whose absence lets a wrong or unsafe result
ship — from **E (enhancement)** — capability/quality gains that are not correctness gates.
Effort is **S** (hours), **M** (1–3 days), **L** (multi-day / cross-repo).

---

## 0. Already applied this release (v1.24.0) — done, not to-do

These landed in v1.24.0 (see `CHANGELOG.md`). They are the *baseline* this roadmap builds on;
listing them keeps done-vs-todo honest so nothing here re-proposes shipped work.

| Done | What shipped | Where |
|---|---|---|
| **Credit-aware model tier, conservative-unknown** | credit ⇒ strongest paid; no-credit/unknown ⇒ strongest free; unknown treated as no-credit (asymmetric: paid-on-unfunded = dead alias, free-on-funded = recoverable next sync) | `scripts/providers_resolve.py` (`tier_preference`, `model_cost_tier`, `select_models`); LLMsVerifier `llm-verifier/{providers,scoring,selection}` |
| **"Zero-cost" not blindly trusted as free** | missing/partial catalog pricing ⇒ tier `unknown`, never guessed free; OpenRouter `:free` suffix honoured | `scripts/providers_resolve.py` |
| **Plan-gated backstop via the launch gate** | credit inferred from the verification probe: 402/403 ⇒ no-credit, 429 ⇒ transient (never demotes), 401 ⇒ bad key; schema-versioned 24h cache so weaker-logic results never replay; launch wrapper refuses non-`verified` aliases | `scripts/model_verify.py --credit-probe`; `scripts/providers/credit-endpoints.json` (signal table, 2 providers so far); `scripts/lib.sh` launch gate |
| **Unforgeable superpowers challenge** | replaced the fuzzy vocabulary grep (both false-passed and false-failed) with a secret-knowledge challenge — one exact skill-table cell a model can only produce by loading the skill — plus a distinct `empty-result` verdict | layer-4 check via `scripts/verify_superpowers_tui.sh` / `run-proof.sh` |
| **Mutation-residue guard** | refuses to ship an always-pass `&& false` residue left by testing | `scripts/tests/test_mutation_residue.sh` |
| **Providers gate discriminates** | a `verified` provider's failure fails the suite; account-dead providers do not — with an anti-vacuous guard that the gate genuinely tells them apart | `scripts/tests/test_providers_gate.sh` |
| **Sandbox-hygiene guard + `sandbox_stub`** | no test writes a fixed `/tmp` path or a bare redirect into `.local/bin`; `sandbox_stub` removes an existing symlink before writing instead of writing through it; `assert_sandboxed` aborts if `$HOME` is not a `mktemp` sandbox | `scripts/tests/test_sandbox_hygiene.sh`, `scripts/tests/lib/sandbox.sh` |
| **Adjacent guards** | leaked-sandbox test fails even on exit 0 (`test_sandbox_leak.sh`); re-entrant suite lock (`test_suite_lock.sh`); launch-grammar conformance (`test_ccr_conformance.sh`); proof-dir `# FAIL:` sweep gate; `test_provider_credit.sh` (127 assertions) | `scripts/tests/` |

---

## Top follow-ups at a glance (priority order)

1. **I-1 — free-usable gate must require a live probe on the *real* base URL** (P0, S/C).
2. **GW-1 — client-disconnect → upstream cancellation (stop paying for tokens nobody reads)** (P1, S/C).
3. **GW-2 — first-byte streaming-retry gate (never retry/splice once a byte reached the client)** (P1, S/C).
4. **GW-4 — retry classification on `(status, body-code)` + shared budget + Retry-After/jitter** (P1, S/C).
5. **CD-3 — provider-keyed `(status, body-code)` error classifier** (P1, S/C).
6. **CD-4 — route the credit probe through the plan-correct base URL first** (P1, S/C).
7. **AB-1 — hermetic sandbox: read-only source mount + size-capped scratch + no-net** (P1, S/C).
8. **AB-2 — formalise targeted mutation as a standing gate (verdict + body deletion ⇒ RED)** (P1, S/C).
9. **AB-3 — every absence/negative assertion carries a positive control** (P1, S/C).
10. **BV-1 — codify "live probe beats leaderboard/self-report" as ranking policy** (P1, S/C).
11. **CD-5 — keep BAD_KEY a distinct terminal outcome (never demote 401 to free)** (P1, S/C).
12. **GW-3 / GW-8 — config hot-swap via `atomic.Pointer[Config]` RCU (retire restart-to-apply); SSE flush discipline** (P2).
13. **CR-1 — capability ranking via agentic/coding index + honest "unranked" bucket** (P2, E).
14. **CD-2 / CD-6 — extend the balance-endpoint table; split cache TTL by verdict** (P2).
15. **AB-4…AB-8 — CTRF evidence gate, trace receipts, canary hardening, race fix, judge de-bias** (P2).
16. **GW-5 / GW-6 / GW-7 + OB-1 / OB-2 — failover chains, per-upstream circuit breaker + `deployment_state`, streaming usage accounting, native `gen_ai.*` metrics** (P2).
17. **CD-7 / AB-9 — second-credential balance read, evidence attestation** (P3, E).

---

## 1. Master work-item table (prioritised)

| ID | Pri | Class | Finding (source) | Concrete change to THIS toolkit | Effort | Depends |
|---|---|---|---|---|---|---|
| **I-1** | **P0** | **S/C** | Observed `{cost.input:0, cost.output:0}` is treated as *free-usable*, but for plan-gated providers (GitHub Models, Z.AI coding-plan, Chutes) `{0,0}` is a plan/subscription entry that fails at launch — catalog-free is *necessary, not sufficient* (credit BRIEF §3, §4.3) | Change the free-usable predicate so `cost==0` alone never marks a model launchable-free: require **`cost==0` AND the live verification probe passes with this key on the alias's *real* base URL**. Implement in `providers_resolve.py` free-tier selection / `model_verify.py --credit-probe`; a `cost:0` model whose probe returns 401/402/403/1113 is plan-gated ⇒ NOT offered as the free pick (fall to next candidate or honest `unranked`) | M | CD-4 (needs plan-correct base URL) |
| **CD-3** | P1 | S/C | HTTP status alone is ambiguous across providers; the disambiguator is `provider + status + body-code` (credit BRIEF §2, §0) | Encode the §2 taxonomy as a provider-keyed classifier in `model_verify.py --credit-probe` returning one of `{BAD_KEY, NO_CREDIT, RATE/QUOTA, OK}`. Must handle the named collisions: Moonshot/Kimi **429** splits on body (`exceeded_current_quota_error`=no-credit vs `rate_limit_reached_error`=transient); Z.AI app-code **1113**; Groq **400 `blocked_api_access`**; Upstage **403 "Insufficient credit"** (not 402); Cerebras `*_quota_exceeded`. Data lives in `providers/credit-endpoints.json`-adjacent table | M | — |
| **CD-4** | P1 | S/C | A funded Z.AI coding-plan / Chutes / GitHub-Models key returns no-credit/1113 on the *wrong* base URL despite being usable — must route to the plan endpoint before reading the error (credit BRIEF §3, §4.3) | Before classifying a no-credit signal, route the probe to the plan-correct base URL: Z.AI ⇒ `/api/anthropic` or `/api/coding/paas/v4`; Chutes ⇒ read `/users/me/quotas` (quota-remaining ⇒ launchable); GitHub Models ⇒ always "free tier", only 401/429 matter. Wire into the base-URL resolution already in `providers_resolve.py` / `lib.sh` | M | CD-3 |
| **AB-1** | P1 | S/C | Strongest fixes remove capability, not assert about it: a read-only source mount would have made the symlink-escape write *fail loudly* instead of truncating a tracked script; a size-capped scratch turns a 35 GB leak into ENOSPC red (antibluff R1, §4.2–4.4) | Run the suite inside bubblewrap: `--ro-bind` the repo, `--tmpfs` scratch with a byte cap, `--unshare-net`/`--unshare-pid`. Keep the existing `sandbox_stub`/`test_sandbox_hygiene.sh` as defense-in-depth, not sole guard; keep a macOS-portable path (container `--read-only --tmpfs --network none`) for CI parity. Wrap the `run-all.sh` entrypoint | M–L | — |
| **AB-2** | P1 | S/C | Mutation is the only technique that answers "would my tests notice if the code were wrong?" — kills F1 (pass-helper) and F3 (feature deleted, still green) (antibluff R2, §1.2–1.4) | Formalise the existing residue check into a standing targeted-mutation gate: mutate (a) each pass/assert helper's verdict → constant `pass`, (b) each verified feature body → statement/return deletion; the suite MUST go red. Go: **Gremlins** or **go-mutesting** (covered-only, PR-diff scope); bash: **universalmutator** or the bespoke sed harness. Do **not** chase a global mutation-score number. Extend `test_mutation_residue.sh` | M | — |
| **AB-3** | P1 | S/C | F4 (assert "credential not leaked" passes because the leak path never ran) has **no off-the-shelf detector**; the only reliable defense is a positive control (antibluff R6, §2.3) | Add a convention + bespoke lint: every absence/negative assertion must be paired with a fault-injection case that plants the very thing being asserted-absent and confirms the test goes red. Reduces F4 to a mutation-kill. New `scripts/tests/test_positive_controls.sh` (lint) + convention doc | M | AB-2 (shares injection machinery) |
| **BV-1** | P1 | S/C | No benchmark predicts real agentic coding; SWE-bench overstates ~3× after leakage filtering; leaderboards + self-report unreliable (METR 40-point perception error); live probes win (transcript: BENCHMARK VALIDITY) | Codify as ranking-policy guardrail (CLAUDE.md provider section + `providers_resolve.py` comment): a provider alias is **never** ranked or gated by a benchmark leaderboard or model self-report; the live verification probe on the real base URL is the authoritative signal. Reinforces I-1 and CR-1 | S | — |
| **CD-5** | P1 | S/C | BAD_KEY (401) is terminal — demoting a 401 key to a free model just produces a second failure; must not collapse into UNKNOWN/NO_CREDIT (credit BRIEF §4.2) | Confirm/enforce that the credit classifier keeps `BAD_KEY` a distinct outcome that does **not** activate the alias and does **not** trigger free-model demotion (distinct from `NO_CREDIT` ⇒ free). Likely partially present — audit `model_verify.py`/`providers_resolve.py` and add a `test_provider_credit.sh` case | S | CD-3 |
| **CR-1** | P2 | E | models.dev `api.json` carries **no quality signal**; models.dev `models.json` + OpenRouter `/api/v1/models` carry `artificial_analysis` agentic_index / coding_index (best free signal, ~33% entry coverage); Arena Elo is the worst proxy for code editing (r=0.11); family lineage is dangerous as a score; price is only a weak tie-break (Spearman ~0.61) (transcript: CAPABILITY RANKING) | Rework `providers_resolve.py:select_models` to rank by agentic_index (percentile-tier), price as tie-break only, keep top-3 fallbacks, and put every unscored model in an honest **`unranked`** bucket (never guessed). Ingest agentic/coding index from models.dev `models.json` + OpenRouter `/api/v1/models`. Layers *under* the credit-tier constraint (affordable tier first, then rank) | L | I-1, BV-1 |
| **CR-2** | P2 | S/C | Price must never be the primary rank; unscored must stay honestly unranked, never guessed (transcript: CAPABILITY RANKING) | Policy encoded inside CR-1: assert (test) that a higher-priced model does not outrank a higher-agentic-index one, and that `unranked` is surfaced not silently dropped | S | CR-1 |
| **CD-2** | P2 | E | Only 2 of the documented-🟢 balance endpoints are wired (`deepseek`, `openrouter`); the brief documents more (credit BRIEF §1, §4.3) | Extend `providers/credit-endpoints.json` (data-only, no Python) with the remaining 🟢: SiliconFlow `/v1/user/info` (`chargeBalance>0`⇒paid), Moonshot `/v1/users/me/balance` (`cash_balance>0`⇒paid), Novita "Get User Balance" **[VERIFY-AT-INTEGRATION path]**. Note xAI/Tencent need a second credential class (CD-7) | M | — |
| **CD-6** | P2 | S/C | A rate-limit blip should not pin an alias to free for a whole day (credit BRIEF §4.4) | Split cache TTL by verdict: CREDIT/NO_CREDIT/BAD_KEY ⇒ 24h; UNKNOWN/transient ⇒ ≤1h or no-cache so the next sync re-probes and upgrades. Extend the schema-versioned credit cache | S | CD-3 |
| **AB-4** | P2 | S/C | A self-printed "40 passed" tally lied (F1); nothing read the evidence files (F2). A gate should re-derive PASS from machine-readable evidence (antibluff R5, §5.1) | Emit results as **CTRF JSON** (one schema for bash + Go); a separate gate parses it, independently counts failures, and asserts on the *content* of `proof/*` (sentinel/receipt/canary present). Extends the existing `# FAIL:` sweep gate | M | — |
| **AB-5** | P2 | S/C | Agentic hallucination is entity-level; prove the action from the receipt/trace, not the model's claim (antibluff R4, §3.2) | The verifier's tool-calling probe should assert a real tool call appears in the transcript (not "the model said it would call a tool"); where a boundary exists, add HMAC-signed tool receipts cross-referenced against claims. Harden `providers-verify.sh` / `providers-semantic.sh` | M | — |
| **AB-6** | P2 | S/C | Canary must be high-entropy, rotated per run, and present ONLY in the resource whose loading is proven — else reproduction is a vacuous (F4-shaped) pass (antibluff R3, §3.1) | Audit the superpowers secret-knowledge challenge for: per-run rotation, secret never echoed into logs the model can read, secret absent from prompt/context outside the artifact. Retire any `VERIFY_OK`-style guessable sentinel as a sole signal | S | — |
| **AB-7** | P2 | S/C | A test raced a spawned process's death (F5); no research tool fixes this — determinism discipline (antibluff R7) | Replace process-liveness asserts with an explicit readiness signal (file/port/log line) + timeout, capture exit status, assert on captured status/output. Audit `test_sessions.sh`, wrapper-exec tests | S | — |
| **AB-8** | P2 | E | LLM-as-judge is a biased oracle (position bias up to 75%, verbosity, self-preference 10–25%) — root of F7's false-fail (antibluff R8, §3.4) | For judge legs: swap/average option order, mask model identity, use a **different-family** judge than the model under test, score against a rubric/reference with an explicit "accept paraphrase" rule; reserve exact-match for canary bytes. Touches `providers-semantic.sh` judge path | M | — |
| **AB-10** | P2 | S/C | Go 1.24 `os.Root` gives `openat`-based traversal-resistant file I/O; symlinks out of the root cannot be followed (antibluff §4.3) | In the bundled router's install/link code, swap `os.OpenFile`→`root.OpenFile` for any path derived from repo/home so a link cannot escape. Defense-in-depth under AB-1 | S | — |
| **CD-7** | P3 | E | xAI prepaid balance and Tencent `DescribeAccountBalance` are readable but need a *second credential class* (management key + team_id / CAM TC3 signing) most operators won't have (credit BRIEF §1 xAI/Tencent, §4.3) | Optional: if the operator stored `XAI_MANAGEMENT_KEY`+`XAI_TEAM_ID` (or Tencent CAM), read the mgmt balance; otherwise fall to the conservative UNKNOWN⇒free branch. Data + small Python | M | CD-2 |
| **CD-8** | P3 | S/C | Novita exact balance path, Fireworks account sub-resource, and Chutes field names are docs-fetch-derived and marked VERIFY-AT-INTEGRATION — must be live-confirmed once before trusting (credit BRIEF §5) | One-time live confirmation of each VERIFY-AT-INTEGRATION endpoint during implementation; record the confirmed path in `credit-endpoints.json` `doc`. Never trust an invented/unconfirmed path | S | CD-2 |
| **GW-1** | P1 | S/C | Client hang-up does not cancel upstream generation, so a disconnected stream keeps the provider generating and **billing** — a filed, reproduced bug in **LiteLLM #30244** and **vLLM #9428/#24584** (self-hosted backends hold a generation slot per orphaned stream); closing the provider TCP connection is the only stream-cancel signal (gateway BRIEF §2.2, §4.1 / G1) | Wire the inbound `r.Context()` into the upstream request (`upstreamReq.WithContext(r.Context())`) so a client disconnect cancels `http.Client.Do`/body-read and drops the provider connection. Never detach onto `context.Background()`; filter the spurious `context canceled`→502 (golang/go#20071/#20617); emit `gateway_client_disconnects_total`. Test: disconnect mid-stream, assert the upstream ctx was cancelled | S | — |
| **GW-2** | P1 | S/C | Retrying a completion after **any** byte reached the client corrupts the message (attempt-2 is a different generation ⇒ invalid tool-call JSON), double-bills, and can replay tool-call side effects; NGINX/Gateway-API forbid it and LiteLLM only retries pre-first-byte (#8648). Faking a clean `message_stop` on truncation makes the agent act on corrupt data (gateway BRIEF §1.2, §2.4, §5.2 / G2) | Implement the two-phase gate around first client-visible byte. **Phase A** (pre-first-byte): connect/`429`/`5xx`/timeout/connection-errors are retryable, subject to GW-4's budget. **Phase B** (post-first-byte): retry/reconnect/failover forbidden — on upstream drop/error synthesize an Anthropic `event: error` (e.g. `overloaded_error`), close open `content_block`s, record partial usage, stop. Never splice a second generation; never emit a fake clean stop on truncation | S–M | GW-4 |
| **GW-3** | P2 | E | The router validates a new config but keeps serving the startup config until `restart` — unnecessary for the ~90% non-listener-bound case (routing/providers/base-URLs/keys/timeouts/retry/circuit-breaker/**TLS**); only a bind-address/ALPN or QUIC-socket change needs a heavier path (gateway BRIEF §3.1–3.4, §5.1 / G3+G8) | Serve hot config through `atomic.Pointer[Config]` RCU: `Load()` a lock-free snapshot per request, `Store()` a freshly-built **validated, immutable** `*Config` on reload (invalid ⇒ old pointer keeps serving, as today). Trigger on `SIGHUP` and/or `:3458` `POST /reload`; watch the parent dir + debounce. Fold TLS into the hot class via `tls.Config.GetCertificate` + `atomic.Pointer[tls.Certificate]` (live rotation, no socket churn). Do NOT hold a `sync.RWMutex` read-lock across a streaming request. Scope `restart` strictly to a bind-address/QUIC rebind, documented | S–M | — |
| **GW-4** | P1 | S/C | Retrying on HTTP status alone hammers a no-credit key (Moonshot/Kimi `429` splits no-credit vs rate-limit on body) and turns a brownout into an (N+1)× self-DDoS; the safe set is `408/429/5xx`+connection-errors, pre-first-byte only, honoring `Retry-After` (gateway BRIEF §1.1, §1.3, §1.4, §5.2 / G4) | Classify retryability on provider-keyed `(status, body-code)` — reuse **CD-3's taxonomy** so `429`-no-credit is terminal and `429`-rate-limit retries. Add exponential backoff with **Full Jitter** (`random(0, min(cap, base*2^n))`), honor `Retry-After` (delta-seconds AND HTTP-date, clamp ≥0) over own backoff, cap retries with a **shared token-bucket budget** (retry at ONE layer only). **No consensus** on the exact budget fraction — default ≤10%, make configurable (§5.4) | M | CD-3 |
| **GW-5** | P2 | E | A circuit-open/terminal provider doesn't route to a next; Portkey/Bifrost make ordered cross-provider failover the headline feature — but it is only safe in **Phase A** (pre-first-byte) (gateway BRIEF §1.6, §4, §5 / G5) | Add an ordered fallback list per alias; failover only on transient/terminal-upstream classes (`5xx`/connect/circuit-open/capacity-`429`), never `400/401/402/422`; each hop consumes GW-4's shared budget; translate the model id per target; after first byte, failover forbidden. **No consensus** on whether a coding agent should auto-failover at all (a silent model swap changes capabilities/tokenizer mid-session) — make it **opt-in per alias** (§5.4) | M | GW-2, GW-4 |
| **GW-6** | P2 | E | No per-upstream circuit breaker ⇒ the router keeps sending doomed requests (and burning the retry budget) at a sustained-outage provider; the idiomatic Go answer is `sony/gobreaker`, one breaker per base URL (gateway BRIEF §1.5, §4 / G6) | Add a `sony/gobreaker` breaker per upstream; `IsSuccessful` counts `5xx`/connect but **not** `400`/`429` (a rate-limit is not a health failure); Open ⇒ fail-fast for `Timeout`, Half-Open probes to re-close. One breaker per provider so one dead upstream doesn't trip others. Surface the state via OB-2 | M | — |
| **GW-7** | P2 | E | Token usage rides inside the stream and truncation loses it: Anthropic `message_delta.usage.output_tokens` is **CUMULATIVE** (take the LAST, don't sum — summing double-counts); OpenAI streaming omits usage unless `stream_options.include_usage`, and that final usage chunk **never arrives on a cancelled stream** (gateway BRIEF §2.3 / G7) | Maintain a per-request usage struct: input from `message_start`/first upstream usage signal, output from cumulative deltas (last wins); always set `include_usage` on upstream OpenAI calls; on stream end — clean `message_stop` OR mid-stream abort — emit exactly one usage row (`partial:true` when the terminal chunk was missing). Feeds the cost-tier logic and GW-1's disconnect metric | M | — |
| **GW-8** | P2 | S/C | SSE only works if each event is flushed immediately; Go `ReverseProxy` `FlushInterval=-1` content-type sniffing is brittle (fails on `text/event-stream; charset=utf-8`; golang/go#31125/#47359) and downstream layers re-buffer without `X-Accel-Buffering: no` (gateway BRIEF §2.1 / G10) | In the hand-rolled translate loop assert `http.Flusher` and `Flush()` after **every** emitted Anthropic event (don't accumulate — forward `input_json_delta` partial JSON incrementally); set `FlushInterval=-1` behaviour explicitly rather than depend on sniffing; emit `X-Accel-Buffering: no` + `Cache-Control: no-cache` on the SSE response | S | — |
| **GW-9** | P3 | E | QUIC/HTTP-3 zero-downtime listener swap is genuinely hard: plain `SO_REUSEPORT` for UDP routes by a 4-tuple hash with no flow awareness and scatters established connections; the real fix (Cloudflare `udpgrm`) needs an eBPF REUSEPORT program — "neither practical for small deployments." QUIC has mandatory TCP/HTTP-2 fallback (gateway BRIEF §3.5, §5.4 / G11) | **No consensus / accept-the-limit:** keep `restart` strictly for a QUIC-socket rebind and document *why*; apply handler/TLS config live via GW-3 so QUIC is never disrupted for the common case; for a bind/binary change do the Caddy-style / `tableflip` TCP handover and accept a brief QUIC reset (TCP fallback covers it). Do NOT build eBPF flow-pinning | L | GW-3 |
| **GW-10** | P3 | E | Response caching (exact/semantic), gateway rate-limiting, guardrails, budgets are headline features of LiteLLM/Portkey/Cloudflare/Bifrost but low-value for a personal dev router; **semantic caching for code is a correctness hazard** — a "similar" prompt returning a cached different-context answer (praise for it assumes Q&A, not agentic coding) (gateway BRIEF §4, §5.4 / G9, G12) | Opt-in at most. Sliding-window gateway rate-limiting per key/model is the most defensible (protects a shared key from agent burstiness; G9, Medium). Exact-match cache has a poor hit rate for coding; **semantic cache off-by-default** (no consensus). Guardrails/budgets out of scope; a per-provider spend cap could reuse the credit-tier logic | M | — |
| **OB-1** | P2 | E | Envoy AI Gateway is the reference: it emits the four native OTel `gen_ai.*` histograms (`gen_ai.client.token.usage`, `gen_ai.client.operation.duration`, + server-side token/request-duration) with disciplined **low-cardinality** attributes (model, operation, error-type — never request IDs or user content); LiteLLM is richer but ships ~75 series with documented cardinality traps (per-key/model/user labels multiply) (gateway BRIEF §0 prior-verified, §2.1, §5.3 / G10) | Emit native `gen_ai.*` histograms + one structured per-request line (model, provider, tokens, cost, latency, outcome, error-class) from the router/`telemetry` dir; keep cardinality bounded (no raw `client_ip`/`user_agent`/full keys); opt-in header allowlist. Reuses GW-7's usage struct; pairs with GW-8's flush path | M | GW-7 |
| **OB-2** | P2 | E | LiteLLM's `deployment_state` (0 healthy / 1 partial / 2 full outage) + cooldown counter is a circuit breaker surfaced as a metric — the richest routing-ops signal; a deployment in cooldown is an open breaker (gateway BRIEF §1.5, §4) | Surface GW-6's per-upstream breaker state as a low-cardinality `deployment_state`-style gauge + cooldown counter (and a `fallback_model`-labelled counter once GW-5 lands); keep the label set small. This is the metric face of GW-6, no longer speculative | M | GW-6 |
| **AB-9** | P3 | E | GitHub Artifact Attestations / SLSA make evidence tamper-evident — but prove integrity/provenance, **not correctness** (a signed vacuous pass is a signed lie) (antibluff R9, §5.2–5.3) | *Speculative / CI-only:* if suite results ever cross a trust boundary to another system/person, sign `proof/*` with Artifact Attestations / `slsa-verifier`. Low priority for a purely local run; only meaningful *combined* with AB-2 + AB-4 | M | AB-2, AB-4 |

---

## 2. Detail on the top-priority item (I-1)

**The exact refinement rule (verbatim intent from credit BRIEF §3):**

```
is_free_usable(model, key) :=
      (models.dev cost.input == 0 AND cost.output == 0)      # catalog-free candidate
  AND (verification probe passes with THIS key on THIS alias's real base URL)   # confirms reachable
```

- Catalog `cost==0` supplies only the *candidate*; the live probe on the real base URL confirms
  the key can actually reach it. **Never treat catalog `cost:0` as launchable without the probe —
  that is exactly the plan-gated trap** (credit BRIEF §3).
- `cost:0` + probe **OK** ⇒ true-free (offer it). `cost:0` + probe **401/402/403/1113** ⇒
  plan-gated (needs a plan the key doesn't carry) ⇒ **do not offer as the free pick**; fall to
  the next verifying free candidate, else surface the alias as `unranked`/unfundable rather than
  shipping a model that dies at launch.
- This is asymmetric-cost-consistent with the shipped design: a false "free" pick on a plan-gated
  `{0,0}` model is a *dead alias at launch*; the probe is the cheap disambiguator that prevents it.
- Depends on **CD-4** (route the probe through the plan-correct base URL first) so a funded
  coding-plan key isn't misread as plan-gated.

**Why this is P0 and not already fully done:** v1.24.0 stopped *missing/partial* pricing from
being guessed free (⇒ `unknown`), but an **explicit `{0,0}`** is still observed to be classified
free-usable without the base-URL-correct live-probe gate — which is the residual plan-gated hole
this closes.

---

## 3. Themes and honest limits

**Credit detection (credit BRIEF).** The durable truth is that *reliable machine-readable balance
APIs are rare* — most providers are console-only, so the portable signal is the inference-probe
error taxonomy (CD-3), not a balance endpoint. The 🟢 balance endpoints (CD-2) are a precision
bonus where they exist. The genuinely hard, must-own-original-design piece is the
provider-keyed disambiguation (CD-3/CD-4/I-1); the brief is explicit that "no external solution
found" for the majority (Cerebras, Upstage, NVIDIA, Groq, Mistral, Together, HF).

**Anti-bluff (antibluff BRIEF).** The ranking theme is *prefer capability removal and unforgeable
evidence over assertions that can be vacuous.* Mechanism-level fixes (AB-1 read-only mount, AB-10
`os.Root`) beat any assertion because they remove the capability. Where the honest answer is "no
established practice — original design needed": F4 vacuous-absence detection (AB-3), F5 process-race
(AB-7), bash mutation testing (AB-2), and the shell-redirect-into-source symlink lint (already the
project's `test_sandbox_hygiene.sh`, to be backed by AB-1's read-only mount). Attestation (AB-9)
proves integrity, **not correctness** — a signed vacuous pass is still a lie; it only counts when
combined with AB-2 + AB-4.

**Capability ranking (transcript).** `[unverified until a live coverage check confirms the ~33%
index coverage on this host's catalog]` — the ranking overhaul (CR-1) is a
quality enhancement layered *under* the credit-tier constraint, never over it: affordable tier
first (I-1 / shipped credit policy), then rank within it by agentic_index with price as tie-break
only, unscored honestly `unranked`.

**Gateway resilience & streaming correctness (gateway BRIEF).** The BRIEF's three hard truths drive
the `GW-*` block. (1) You cannot safely retry a completion once a byte has reached the client — the
first-byte gate (GW-2) is the one rule everyone must encode, and the canonical trap is "transparently
reconnect mid-stream and keep appending" (corrupts the message, double-bills, replays tool calls).
(2) Client disconnect must cancel the upstream or you pay for tokens nobody reads (GW-1) — a filed,
reproduced bug in LiteLLM #30244 and vLLM #9428, so our `r.Context()` wiring is a differentiator, not
a nicety. (3) Config hot-swap is a solved Go problem via `atomic.Pointer[Config]` RCU (GW-3), so the
restart-to-apply limitation is unnecessary for everything except a listener/QUIC rebind. **Where the
BRIEF is explicit that no consensus exists:** the retry-budget fraction (GW-4 — pick ≤10%,
configurable), auto-failover for a coding agent (GW-5 — opt-in per alias; a silent model swap changes
behaviour mid-session), semantic caching for code (GW-10 — off by default, a correctness hazard), and
QUIC graceful restart (GW-9 — accept a brief reset; even Cloudflare has no cheap portable answer). The
observability rows OB-1/OB-2 are now concrete, not `[gateway-pending]`: the BRIEF confirms the Envoy
`gen_ai.*` low-cardinality metric model and the LiteLLM `deployment_state` circuit-breaker-as-metric
signal. Layered *under* these correctness gates, the ccr parity check (§4.2 — preserve `Router{}`
scenarios and the general `transformer` mechanism, not per-family hardcoding) remains a standing
regression concern to confirm against the Go reimpl.

---

*Roadmap compiled 2026-07-20 from the briefs and transcripts named above; the gateway BRIEF was
folded in on 2026-07-20 (the `GW-*` rows + concrete OB-1/OB-2, replacing the earlier
`[gateway-pending]` placeholders). Extend this file (do not replace it) as further research lands and
as items are completed — move a finished row into §0 with its shipping commit.*
