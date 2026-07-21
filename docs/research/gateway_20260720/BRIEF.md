# Go LLM Gateway — Resilience, Streaming Correctness & Zero-Downtime Config Research Brief

**Purpose.** Our Go reimplementation of `claude-code-router` is an Anthropic-compatible LLM
gateway (data plane `:3456`, management plane `:3458`) that Claude Code points
`ANTHROPIC_BASE_URL` at. It terminates TLS/ALPN + HTTP/3-over-QUIC, does brotli/gzip, SSE
streaming, Anthropic<->OpenAI translation, retry with a max-attempts budget, an upstream
timeout, config hot-reload (validates but keeps serving the startup config until restart — a
known limitation that forced a `restart` subcommand), pidfile service lifecycle, and a
subcommand that launches the agent with `ANTHROPIC_BASE_URL` pointed at itself.

This brief researches what **mature LLM gateways and proxies** do that ours does not yet, across
four areas: (1) retry/resilience safety, (2) streaming correctness, (3) config hot-reload /
zero-downtime, (4) remaining prior-art gaps. It ends with a **prioritised gap list**, concrete
**Go-idiomatic recommendations** for the top gaps, and explicit **warnings about approaches that
look right but fail** (naive retry of a partially-streamed completion).

**Scope note / honesty rule.** Every factual claim carries a source URL + access date. Where no
consensus exists, the brief says so. Where a recommendation is our synthesis rather than a cited
practice, it is labelled **[SYNTHESIS]**.

**Research date:** 2026-07-20. All access dates are 2026-07-20 unless noted.

**Status:** COMPLETE — all task items covered. See "Coverage tracker" (§6) for the item-by-item map.

---

## 0. Executive orientation — the three hard truths

1. **You cannot safely retry a completion once bytes have reached the client.** Every mature
   gateway treats "response headers sent / first SSE event flushed" as the point of no return.
   Retry budgets, backoff, and failover chains all live *before* first byte; after first byte the
   only correct moves are to propagate the error into the stream and stop.
2. **Client disconnect must cancel the upstream, or you pay for tokens nobody reads.** In Go this
   is `http.Request.Context()` cancellation wired through to the upstream call; getting it wrong
   means silent cost leakage and wasted provider quota.
3. **Config hot-swap is a solved problem in Go** — `atomic.Pointer[Config]` (RCU) for handler
   config, and either `net.Listener` reuse or `SO_REUSEPORT`/graceful-restart for listener/TLS
   changes. Our "validate-but-don't-apply" limitation is unnecessary for everything except a
   listener address / TLS-material change, and even those have well-trodden zero-downtime patterns.

### Prior verified findings (carried from earlier legs — do not re-derive)

- **Envoy AI Gateway** natively emits the four OpenTelemetry `gen_ai.*` metrics
  (`gen_ai.client.token.usage`, `gen_ai.client.operation.duration`, plus server-side token &
  request duration histograms) with disciplined **low-cardinality** attributes (model, operation,
  error type — never request IDs or user content). This is the reference model for our metrics.
- **LiteLLM** has the richest *operational* metrics surface — `litellm_deployment_state` (0 healthy
  / 1 partial-outage / 2 full-outage), a cooldown counter, and fallback counters labelled with
  `fallback_model` — but ships ~75 Prometheus series and has documented **cardinality traps** (per-
  key, per-model, per-user labels multiply). Take the ops signals, not the label sprawl.
- **W3C Trace Context** §3.4 says an intermediary **MUST** forward a received `traceparent`; §7.1
  warns that `tracestate` may carry vendor data that should not be leaked to external systems;
  restarting the trace at a trust boundary is spec-sanctioned. Applies to our translation hop.

---

## 1. Resilience — retry, backoff, circuit breaking, failover

### 1.1 Which HTTP statuses are safely retryable for LLM calls

The cross-industry consensus (HTTP proxies, cloud SDKs, LLM providers) is a small, stable set.
**Retryable transient statuses:** `408` (request timeout), `429` (too many requests / rate limit),
`500`, `502`, `503`, `504`. The Kubernetes Gateway API makes `500, 502, 503, 504` the **mandatory**
retryable set for a conformant gateway, and adds that implementations **SHOULD** also retry
**connection errors** (disconnect, reset, timeout, TCP failure).
Sources: https://gateway-api.sigs.k8s.io/geps/gep-1731/ ;
https://www.baeldung.com/cs/http-error-status-codes-retry ;
https://www.restapitutorial.com/advanced/responses/retries (accessed 2026-07-20).

**Do NOT retry by default:** `400` (bad request — a malformed body will fail identically forever),
`401`/`403` (auth/permission — a retry cannot fix a bad key), `404`, `422` (invalid params), and —
for LLM providers specifically — `402` (no credit). These are *terminal for the same input*; retrying
wastes a budget slot and delays the error the client needs to see. The Gateway API notes 400–499
codes are configurable-but "often inadvisable to retry."
Source: https://gateway-api.sigs.k8s.io/geps/gep-1731/ (accessed 2026-07-20).

**LLM-specific nuances the generic table misses:**
- **`429` splits by body**, per the credit-detection brief (Moonshot/Kimi returns 429 for BOTH
  transient rate-limit *and* terminal no-credit; only the body `error.type` disambiguates). A retry
  loop keyed on status `429` alone will hammer a no-credit key uselessly. Classify on
  `(status, body code)` before deciding retryable.
- **`529`** (Anthropic "overloaded") and provider-specific overload codes are retryable-transient —
  our Anthropic-shaped surface should treat `529` like `503`.
- **`400` with a context-length / token-limit message is terminal** — retrying an over-long prompt
  never succeeds; it must surface, not retry.

**Idempotency gate (the load-bearing rule).** Retrying is only unconditionally safe for *idempotent*
requests. A chat/completions POST is **not** HTTP-idempotent, but a **non-streaming** completion that
has produced **no client-visible side effect yet** (we have not sent response bytes, and the caller
performs no external action from the partial) is *effectively* replayable — the only cost is a second
generation. That "only cost is a second generation" caveat is exactly where duplicate-billing bites
(see §1.2). Where providers offer an **`Idempotency-Key`** header (OpenAI, Stripe-style), forwarding a
per-attempt-stable key lets the provider dedupe a double-submit; most LLM chat endpoints do **not**
yet honor one, so the gateway cannot rely on it.
Sources: https://www.buildmvpfast.com/blog/idempotent-ai-agent-retry-safe-patterns-production-workflow-2026 ;
https://dev.to/mukundakatta/rust-stop-retries-from-double-submitting-llm-calls-with-content-derived-idempotency-keys-3ook
(accessed 2026-07-20).

### 1.2 Why retrying a partially-streamed completion is dangerous (the point of no return)

**The single most important rule in this brief.** Every mature proxy draws a hard line at *first
byte to the client*. NGINX's upstream module states it, and the Kubernetes Gateway API GEP quotes it
verbatim:

> "Passing a request to the next server can only happen if nothing has been sent to a client yet.
> That is, if an error or timeout occurs in the middle of the transferring of a response, fixing this
> is impossible."
> — NGINX, quoted in Gateway API GEP-1731 (accessed 2026-07-20).

Once you have flushed **response headers** (for SSE: `Content-Type: text/event-stream` + the first
`data:` event), retry is off the table, because:

1. **You cannot un-send bytes.** The client has already received a partial assistant message / partial
   tool-call JSON. A retried attempt produces a *different* completion (LLMs are non-deterministic even
   at temperature 0 across attempts). Splicing attempt-2's tail onto attempt-1's head yields a corrupt,
   self-contradictory message — often invalid tool-call JSON that breaks the agent.
2. **You double-bill and double-compute.** The provider generated (and charged for) attempt-1's tokens;
   a silent retry generates and charges again. A widely reported failure mode: a long generation
   completes, the response network hiccups, retry fires, the job "finishes again — and your invoice
   doubles." Streaming makes this worse because the first token can arrive, then the stream stalls: a
   timeout does **not** prove the provider did nothing.
   Source: https://tianpan.co/blog/2026-04-20-idempotency-llm-pipelines ;
   https://networkspy.app/blog/llm-api-errors-retries-rate-limits-debugging (accessed 2026-07-20).
3. **Side effects already happened.** If the partial stream contained a tool-call the agent began
   executing, a retry re-issues it — the "hedge duplicates side effects" hazard. Pure text completions
   are side-effect-free; tool-calling agents are not.
   Source: https://www.truefoundry.com/blog/llm-failover-load-balancing-provider-outages (accessed 2026-07-20).

**LiteLLM confirms the boundary empirically:** its retry mechanism fires for a streaming request that
hits `429` **before** any data is sent, but not once bytes flow — and the reported bug was precisely
that pre-first-byte streaming retries were *inconsistent*, not that post-first-byte retries were
missing (those are correctly absent).
Source: https://github.com/BerriAI/litellm/issues/8648 (accessed 2026-07-20).

**Design consequence for our gateway (two-phase streaming retry):**
- **Phase A — before first byte:** buffer the upstream connect + until the first upstream event is
  received/validated. Failures here (connect error, `429`/`5xx` before any `data:`, upstream timeout
  before first token) ARE retryable, subject to the budget/backoff below and to idempotency
  classification. The client has seen nothing, so switching to attempt-2 or a failover provider is
  invisible and safe.
- **Phase B — after first byte:** retry is forbidden. The only correct actions are (a) propagate an
  error *into* the open SSE stream (emit an Anthropic-shaped `error` event and a terminal
  `message_stop`, or close the connection), and (b) record the partial usage. Never reconnect and
  concatenate. **[SYNTHESIS]** — this is the direct application of the NGINX/Gateway-API rule to our
  Anthropic SSE surface.

**Approach that LOOKS right but fails:** "on mid-stream upstream drop, transparently reconnect to the
provider and keep appending events so the client never notices." This corrupts the message (attempt-2
is a different generation), double-bills, and can replay tool calls. It is the canonical trap. The
industry answer is: *do not*. Fail the stream honestly.

### 1.3 Backoff + jitter

Fixed-delay retries synchronize failed clients into a "thundering herd" that re-stampedes the
recovering upstream. The fix is **exponential backoff with jitter** — randomizing each client's delay
decorrelates the herd. AWS's canonical study compares strategies; **Full Jitter** does the least total
work and yields the lowest server load:

```
sleep = random_between(0, min(cap, base * 2**attempt))
```

`base` = initial delay (e.g. 200–500 ms), `cap` = ceiling (e.g. 20–30 s), `attempt` = 0-indexed retry
number. **Decorrelated Jitter** (`sleep = min(cap, random_between(base, prev_sleep*3))`) is a close
second and self-tunes. Equal Jitter (half fixed, half random) is strictly worse than Full for load.
Sources: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/ ;
https://builder.aws.com/content/3EumjoZascWd1oZiEgL8ORlv3qE/timeouts-retries-and-backoff-with-jitter
(accessed 2026-07-20).

**Honour `Retry-After` over your own backoff.** On `429`/`503`, if the provider sends `Retry-After`,
wait exactly that and do **not** add backoff on top (that only delays recovery). The header has two
forms — **delta-seconds** (`Retry-After: 120`) and **HTTP-date** (`Retry-After: Wed, 21 Oct 2026
07:28:00 GMT`); parse both, compute the date form relative to *now*, and **clamp to non-negative** (a
past date means "retry now", not a negative sleep). Fall back to jittered backoff only when the header
is absent.
Sources: https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Retry-After ;
https://www.thisdevtool.com/blog/handle-429-too-many-requests-retry-after-backoff ;
https://zuplo.com/learning-center/http-429-too-many-requests-guide (accessed 2026-07-20).

### 1.4 Retry budgets — capping amplification (the retry-storm trap)

Naive per-request retries multiply load exactly when the upstream is already struggling: at N retries,
a partial brownout becomes an (N+1)× self-inflicted DDoS. AWS's guidance is a **retry token bucket /
retry budget** — cap retries to a small **fraction of total requests** (AWS SDKs use a token-bucket
where each request costs tokens and retries cost more; a common ceiling is ~**10–20%** additional
load, or "retries ≤ X% of successful requests"). When the bucket is empty, fail fast instead of
retrying.
Sources: https://builder.aws.com/content/3EumjoZascWd1oZiEgL8ORlv3qE/timeouts-retries-and-backoff-with-jitter ;
https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/ (accessed 2026-07-20).

**Retry at ONE layer only.** If Claude Code retries, and our gateway retries, and the provider SDK
retries, three multiplicative layers turn one client request into up to `a*b*c` upstream calls. Pick
the gateway as the single retry authority for the upstream hop and keep the budget there; document that
the agent's own retries and ours compose. Our existing **max-attempts budget** is the right primitive —
it just needs to be a *shared budget* (token bucket) rather than per-request, and needs the
Phase-A/Phase-B gate from §1.2 so it never counts a post-first-byte failure as retryable.

### 1.5 Circuit breaking

Retries handle *transient* blips; a **circuit breaker** handles a *sustained* outage so you stop
sending doomed requests (and stop spending the retry budget) against a dead upstream. The standard
three-state machine (`sony/gobreaker` is the idiomatic Go library):
- **Closed** — requests flow; failures are counted. When failures cross `ReadyToTrip`, open.
- **Open** — requests are rejected **immediately** (fail-fast, no upstream call) for a `Timeout`.
- **Half-Open** — after `Timeout`, allow `MaxRequests` probe calls; success ⇒ close, failure ⇒ re-open.

`gobreaker.Settings` exposes `MaxRequests`, `Interval`, `Timeout`, `ReadyToTrip(Counts)`,
`OnStateChange`, `IsSuccessful` (to decide which errors count — e.g. count `5xx`/connect errors but
**not** `400`/`429`, since a rate-limit is not an upstream health failure). One breaker **per upstream
provider** (per base URL), so one dead provider doesn't trip others.
Sources: https://github.com/sony/gobreaker ; https://pkg.go.dev/github.com/sony/gobreaker/v2 ;
https://oneuptime.com/blog/post/2026-01-07-go-circuit-breaker/view (accessed 2026-07-20).

**LiteLLM's operational analog** (from the prior metrics leg): `litellm_deployment_state` (0 healthy /
1 partial / 2 full outage) plus a cooldown counter is essentially a circuit breaker surfaced as a
metric — a deployment in "cooldown" is an open breaker. Worth emitting the same signal.

### 1.6 Failover chains

When one provider is circuit-open or returns a terminal-for-this-provider error, a **failover chain**
routes the *same logical request* to the next provider/model in an ordered list. This is only safe in
**Phase A** (nothing sent to client) — the same first-byte rule governs failover as governs retry.
LiteLLM models this as `fallbacks` with per-model fallback lists and emits a fallback counter labelled
`fallback_model`; TrueFoundry and Portkey document ordered provider fallback + load-balancing as a
core gateway feature.
Sources: https://www.truefoundry.com/blog/llm-failover-load-balancing-provider-outages ;
https://github.com/BerriAI/litellm/issues/8648 (accessed 2026-07-20).

Chain design notes: (a) failover only on **transient/terminal-upstream** classes (`5xx`, connect,
circuit-open, provider-wide `429` with capacity semantics), never on `400`/`401`/`402`/`422` which will
fail identically downstream; (b) each hop consumes the shared retry budget; (c) translate the model id
per target provider (our Anthropic<->OpenAI translation already does this); (d) after first byte,
failover is forbidden — surface the error.

## 2. Streaming correctness

### 2.1 SSE buffering & flush discipline

SSE only works if each event reaches the client *immediately*; any buffering layer that waits for a
full body defeats the "typewriter" UX and can stall the agent. Three things must all be right:

1. **Flush after every event.** In Go, the `http.ResponseWriter` must be asserted to `http.Flusher`
   and `flusher.Flush()` called after each `data:` write. Without it, the runtime buffers until the
   write buffer fills.
2. **If proxying via `httputil.ReverseProxy`, `FlushInterval` governs flush cadence.** Go's
   `ReverseProxy` **auto-sets `FlushInterval = -1` (flush immediately)** when the upstream response
   `Content-Type` is `text/event-stream` **or** `Content-Length == -1` (unknown). Historically this
   detection was brittle — it failed when the content-type carried extra parameters
   (`text/event-stream; charset=utf-8`) and there were bugs where headers weren't flushed
   (golang/go#31125, #47359). If we hand-roll the proxy loop (likely, given translation), set
   `FlushInterval = -1` behaviour explicitly and don't depend on content-type sniffing.
   Sources: https://go.dev/src/net/http/httputil/reverseproxy.go ;
   https://github.com/golang/go/issues/47359 ; https://github.com/golang/go/issues/31125 (accessed 2026-07-20).
3. **Tell downstream proxies not to buffer.** Emit `X-Accel-Buffering: no` and `Cache-Control:
   no-cache` on the SSE response so nginx/CDN layers don't re-buffer. (nginx also needs
   `proxy_buffering off`, `proxy_http_version 1.1`.) Since Claude Code connects to us directly this
   is mostly defensive, but it is free and correct.
   Sources: https://oneuptime.com/blog/post/2026-01-25-server-sent-events-streaming-go/view ;
   https://github.com/epam/ai-dial-core/issues/1349 (accessed 2026-07-20).

**Translation caveat unique to us:** because we translate OpenAI-shaped upstream chunks into
Anthropic SSE events, we are not a byte-for-byte pipe — we parse each upstream `data:` line, re-emit
one or more Anthropic events, and must flush per emitted event. The translator must not accumulate
(e.g. waiting to parse a full tool-call before emitting) beyond what correctness requires — Anthropic
itself streams tool-call input as `input_json_delta` *partial JSON strings*, so we can and should
forward incrementally.
Source: https://platform.claude.com/docs/en/api/messages-streaming (accessed 2026-07-20).

### 2.2 Client disconnect propagation + upstream cancellation (the billing leak)

**The core hazard: if the client hangs up and you keep reading the upstream, the provider keeps
generating and keeps billing.** For streaming HTTP there is no separate "cancel" API call — **closing
the TCP connection to the provider is the cancel signal**, and whether generation actually stops
depends on the provider honouring client-disconnect. The community consensus is blunt: "if you simply
abort your connection without proper cancellation support, the provider keeps generating upstream and
you can be billed for the full completion." OpenAI *does* stop on cancel ("you only pay for the tokens
generated before you aborted"); other providers vary, and OpenRouter maintains a per-provider list of
which stop billing on cancel.
Sources: https://community.openai.com/t/if-we-stop-streaming-output-stream-before-it-finishes-do-we-still-get-billed-for-the-tokens-that-werent-ouputted/859904 ;
https://openrouter.zendesk.com/hc/en-us/articles/51691588409883 (403 to bots; summary via search index, accessed 2026-07-20).

**Go-idiomatic implementation:** the inbound `*http.Request` carries a `Context()` that is **cancelled
when the client disconnects**. Wire that context into the upstream request
(`upstreamReq = upstreamReq.WithContext(r.Context())`, or a derived context), so that when Claude Code
disconnects, the upstream `http.Client.Do` / body read is cancelled and the TCP connection to the
provider closes — propagating the cancel. This is the single most important cost-safety wire in the
gateway. Two known Go footguns:
- `httputil.ReverseProxy` surfaces client-disconnect as a `context canceled` log line and can emit a
  spurious `502` — filter that from real errors (golang/go#20071, #20617).
- Do **not** detach the upstream call onto `context.Background()` "so the response completes" — that is
  exactly the anti-pattern that keeps billing after the client left. If you need the full completion
  for logging/caching even after disconnect, that is a *deliberate* product decision with a real cost,
  not a default.
Sources: https://github.com/golang/go/issues/20071 ; https://github.com/golang/go/issues/20617
(accessed 2026-07-20).

**[SYNTHESIS] Recommended default:** propagate client cancellation to the upstream unconditionally;
expose an opt-in `keep_upstream_on_disconnect` only if a caching/logging feature ever needs the tail,
and account for its cost explicitly. Emit a metric (`gateway_client_disconnects_total`) so leaks are
visible.

### 2.3 Usage / token accounting from a stream

Token counts drive our cost-tier logic and any metrics, and they arrive **inside** the stream — you
must parse them out, and you must handle truncation.

**Anthropic SSE** (our output shape): `message_start` carries `usage.input_tokens` (and
`cache_creation_input_tokens`, `cache_read_input_tokens`) plus an initial `output_tokens` of ~1;
**`message_delta` carries `usage.output_tokens` and these counts are CUMULATIVE** (the docs flag this
explicitly with a warning). The final `message_delta` before `message_stop` has the authoritative
output-token total; `server_tool_use.web_search_requests` also rides there. So: read input tokens from
`message_start`, and take output tokens from the **last** `message_delta` (not a sum of deltas — they
are already cumulative; summing double-counts).
Source: https://platform.claude.com/docs/en/api/messages-streaming (accessed 2026-07-20).

**OpenAI-compatible upstream** (what we translate FROM): usage is **absent by default** in streaming;
you must send `stream_options: {"include_usage": true}` on the upstream request. Then every chunk has
`usage: null` **except a final extra chunk** whose `choices` is `[]` and whose `usage` holds the totals.
**Critical failure mode: if the stream is interrupted/cancelled, that final usage chunk never arrives**,
so you get no token totals at all. The gateway must (a) always set `include_usage` on upstream OpenAI
calls, and (b) **fall back to counting from the deltas** (or a tokenizer estimate) when the final chunk
is missing, so a truncated stream still yields an approximate usage record.
Sources: https://community.openai.com/t/usage-stats-now-available-when-using-streaming-with-the-chat-completions-api-or-completions-api/738156 ;
https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events
(accessed 2026-07-20).

**[SYNTHESIS] Accounting rule for our translator:** maintain a running usage struct per request;
populate `input_tokens` from the upstream's first usage signal (or `message_start`), accumulate/patch
output tokens as deltas arrive, and on stream end — **whether clean `message_stop` or a mid-stream
abort** — emit exactly one usage record (marking it `partial: true` when the terminal usage chunk was
missing). This guarantees an accounting row even for disconnected/failed streams, which is what §2.2's
disconnect metric needs to be trustworthy.

### 2.4 Mid-stream error handling

Errors that occur *after* `200 OK` + first event cannot change the HTTP status (it is already sent).
Both APIs solve this by carrying the error **inside** the stream:
- **Anthropic** emits `event: error` with `data: {"type":"error","error":{"type":"overloaded_error",
  "message":"Overloaded"}}` — the streaming analogue of an HTTP `529`. Our gateway must be able to
  **synthesize** this event: when an OpenAI-shaped upstream drops or returns an error object
  mid-stream, translate it into an Anthropic `error` event so Claude Code sees a well-formed failure
  rather than a truncated-but-"successful" message.
  Source: https://platform.claude.com/docs/en/api/messages-streaming (accessed 2026-07-20).
- After emitting the error event, **stop** — do not attempt the transparent reconnect-and-splice of
  §1.2. If any content blocks were opened, closing them cleanly (`content_block_stop`) before the
  error event produces the least-broken client state; at minimum, do not leave a half-open block and
  then silently hang.

**Official "resume" is client-side and NOT a proxy splice.** Anthropic documents an *error recovery*
pattern — capture the partial response, then build a **new** request that includes the partial (as an
assistant-message prefill for Claude ≤4.5, or as a user "continue from where you left off" message for
≥4.6) and stream the remainder. Crucially the docs note **"tool use and extended thinking blocks
cannot be partially recovered; you can resume from the most recent text block."** This confirms the
brief's central warning: safe recovery is a *fresh, context-carrying request* (ideally the agent's
decision), never a gateway transparently concatenating a second generation onto the first.
Source: https://platform.claude.com/docs/en/api/messages-streaming#error-recovery (accessed 2026-07-20).

**Approach that LOOKS right but fails:** translating an OpenAI mid-stream `[DONE]`-without-`finish_reason`
or a dropped socket into a clean `message_stop` (pretending success). This hands Claude Code a
truncated message with `stop_reason: end_turn`, so the agent believes the (possibly mid-sentence or
mid-tool-call) output is complete and acts on corrupt data. Always surface truncation as an `error`
event / non-`end_turn` stop, never as a fabricated clean stop.

## 3. Config hot-reload / zero-downtime

Our current limitation — "hot-reload validates the new config but keeps serving the startup config
until a `restart`" — is **unnecessary for the common case** and only partly justified for one narrow
case (the QUIC listener). The fix is to split config by what it binds to.

### 3.1 Split the config into two classes

- **Handler/routing config** (the 90% case): provider list, base URLs, API keys, model mappings,
  strong/fast tiers, timeouts, retry budget/backoff params, translation rules, circuit-breaker
  thresholds. **None of these are bound to the listening socket** — they are read on every request by
  the handler. These can be swapped live with zero downtime.
- **Listener-bound config** (the 10% case): bind address/port, ALPN set, and TLS key material. These
  are attached to an open `net.Listener` / `tls.Config` / QUIC socket and need more than a pointer
  swap.

### 3.2 Handler config: atomic.Pointer RCU (drops the restart limitation)

The idiomatic Go pattern is **RCU via `atomic.Pointer[Config]`**: readers `Load()` the current config
pointer with no lock and never stall; a reload builds a brand-new `*Config`, validates it, and
`Store()`s it in one atomic write. In-flight requests keep using the pointer they already loaded;
new requests see the new config. No mutex on the read path, no request draining, no restart.

```go
var cfg atomic.Pointer[Config]              // package-level

func handler(w http.ResponseWriter, r *http.Request) {
    c := cfg.Load()                          // never blocks, always a consistent snapshot
    // ... use c.Providers, c.Timeout, c.RetryBudget ...
}

func reload(path string) error {
    nc, err := loadAndValidate(path)         // parse + validate FIRST
    if err != nil { return err }             // invalid ⇒ keep serving old, report error
    cfg.Store(nc)                            // atomic swap; zero downtime
    return nil
}
```

Rules that make this safe (all standard practice):
- **Immutable snapshots.** Never mutate a `*Config` after `Store()` — build a fresh one each reload so
  a request that `Load()`ed the old pointer sees a stable object. (This is the "RCU" guarantee.)
- **Validate before swap.** Exactly what we already do; the only change is that a *valid* config is now
  `Store()`d live instead of deferred to restart. An invalid one is rejected and the old pointer stays.
- **Trigger.** `SIGHUP` or a management-plane (`:3458`) endpoint; if watching a file, watch the parent
  **directory** (Kubernetes ConfigMap updates are atomic symlink swaps) and debounce multi-event
  writes.
Sources: https://pkg.go.dev/sync/atomic ;
https://oneuptime.com/blog/post/2026-01-25-hot-reload-configuration-go-without-restarts/view ;
https://dev.to/chiman_jain/dynamic-configuration-reloading-in-go-apps-on-kubernetes-5bmp (accessed 2026-07-20).

This single change lets `claude-providers sync` add/remove a provider, retune a timeout, or flip a
model tier and have it take effect **live**, eliminating the `restart` subcommand for everything except
a bind-address or (partly) a QUIC change.

### 3.3 TLS material: rotate via callback, no listener replacement

Changing certificates does **not** require replacing the listener. `tls.Config.GetCertificate`
(and `GetConfigForClient`) are per-handshake callbacks — point them at an `atomic.Pointer[tls.Certificate]`
and a reload just `Store()`s the new cert; the next handshake picks it up. This is how live cert
rotation is done in Go without dropping connections. So TLS reloads belong in the *hot* class too.
**[SYNTHESIS]** built on the RCU pattern above + the standard `GetCertificate` hook.

### 3.4 Listener/bind-address changes: in-process graceful swap vs process handover

If the bind address or ALPN actually changes, the socket must be replaced. Two proven models:

- **In-process, single process (Caddy's model):** *start the new config/listener before stopping the
  old.* "The new config is started before the old config is stopped, so for a brief time both configs
  are running" — zero downtime, and "if the new config fails, the old config is rolled back into place
  without downtime." No new process, no FD passing. This is the cleanest fit for a small gateway and
  extends §3.2 to listeners: open the new `net.Listener`, start serving, then gracefully drain and
  close the old one.
  Source: https://caddyserver.com/docs/api ; https://caddyserver.com/docs/getting-started (accessed 2026-07-20).
- **Process handover (binary upgrades), Cloudflare `tableflip`:** for replacing the *binary*, tableflip
  uses NGINX-style FD passing — clears `FD_CLOEXEC` on the listening socket, passes the FD to a freshly
  `exec`'d child via env, the child calls `Upgrader.Ready()`, then the parent drains and exits.
  **Explicit warning from Cloudflare: plain `SO_REUSEPORT` is NOT sufficient** — binding with
  `SO_REUSEPORT` creates a *separate* socket structure, so "new-but-not-yet-accepted connections on the
  socket used by the old process will be orphaned and terminated by the kernel." Use FD passing (single
  accept queue), not `SO_REUSEPORT`, for TCP zero-downtime handover. tableflip assumes a single host
  with no load-balancer in front and does not handle config-only changes (that's §3.2's job).
  Sources: https://blog.cloudflare.com/graceful-upgrades-in-go/ ;
  https://github.com/cloudflare/tableflip (accessed 2026-07-20).

### 3.5 The genuinely hard case — QUIC / HTTP/3 graceful restart (partial justification for `restart`)

Our HTTP/3-over-QUIC listener is the one place where "just restart" is defensible. **QUIC keeps
stateful flows over UDP, so a socket handover is much harder than TCP:**
- Plain `SO_REUSEPORT` for UDP routes by a **4-tuple hash**, with **no flow awareness** — during a
  restart the kernel scatters packets of *established* QUIC connections randomly across old and new
  processes, dropping connections; the hash table is keyed only by local IP:port and can overfill.
- The real fix (Cloudflare `udpgrm`) needs an **eBPF `REUSEPORT` program** that inspects QUIC Initial
  packets and routes by **connection ID / socket generation** to keep established flows pinned to the
  old instance while new flows go to the new one. That is heavyweight kernel infrastructure — "neither
  practical for small deployments."
Sources: https://blog.cloudflare.com/quic-restarts-slow-problems-udpgrm-to-the-rescue/ ;
https://github.com/cloudflare/udpgrm (accessed 2026-07-20).

**[SYNTHESIS] Practical stance for us:** QUIC is a *performance* transport with mandatory TCP/HTTP-2
fallback (clients that fail QUIC fall back to TLS/TCP). So the pragmatic zero-downtime posture is:
apply handler/TLS config live via §3.2–3.3 (no QUIC disruption at all); for the rare bind-address or
binary change, do the Caddy-style/tableflip TCP handover and **accept that in-flight QUIC connections
may reset and re-establish (falling back to TCP momentarily)** rather than building eBPF flow-pinning.
Reserve the `restart` subcommand strictly for a QUIC-socket rebind, and document *why* — it is the one
case where the industry itself has no cheap answer. Do **not** keep deferring handler-config changes to
restart; that is the limitation to remove.

## 4. Remaining prior-art gaps (LiteLLM / Portkey / Cloudflare / Bifrost / vLLM / upstream ccr)

Beyond the metrics/tracing findings carried from earlier legs, the mature gateways share a feature set
our gateway does not yet have. Each is noted with who ships it and whether it is in-scope for a
Claude-Code-facing router.

| Feature | Who ships it | Relevance to us |
|---|---|---|
| **Gateway-level retry policy (configurable count/delay/backoff)** | Cloudflare (≤5 attempts, 100 ms–5 s delay, constant/linear/exponential), Portkey, Bifrost | **High** — this is §1 made configurable. We have a max-attempts budget; expose count/backoff/Retry-After honoring as config. |
| **Cross-provider failover chains** | Portkey ("if Anthropic down → OpenAI → Azure"), Bifrost ("99.999% via multi-provider failover"), Cloudflare model fallback | **High** — §1.6. We have per-alias providers but no ordered fallback list. |
| **Load balancing across keys/providers (weighted: latency-/cost-weighted)** | Portkey, Bifrost ("adaptive load balancer") | **Medium** — useful when one provider id maps to several keys; pairs with circuit breaking. |
| **Response caching (exact-match + semantic)** | Cloudflare (up to 90% latency cut), Portkey, Bifrost | **Low–Medium** — coding agents rarely repeat identical prompts; exact-match cache has limited hit rate, semantic caching risks stale/wrong reuse for code. Consider opt-in only. |
| **Gateway rate limiting (per key/model/user, fixed/sliding)** | Cloudflare, Portkey | **Medium** — protects a shared key from the agent's burstiness; complements upstream `Retry-After`. |
| **Guardrails (ingress/egress input/output checks)** | Portkey (50+), Bifrost, Cloudflare | **Low** — out of scope for a personal dev router; note for completeness. |
| **Budgets / spend limits / virtual keys** | Portkey, Cloudflare | **Low–Medium** — overlaps the toolkit's credit-tier logic; a spend cap per provider could reuse it. |
| **Health checks + cooldown / deployment_state** | LiteLLM (`deployment_state` 0/1/2 + cooldown counter) | **High** — this is the circuit breaker (§1.5) surfaced as state+metric; adopt the signal. |
| **Request/response logging + per-provider cost analytics** | Cloudflare, Portkey, LiteLLM | **Medium** — pairs with the stream usage accounting (§2.3); one structured log line per request with model, tokens, cost, latency, outcome. |
| **In-gateway MCP tool support** | Bifrost (native MCP) | **Low** — Claude Code manages its own MCP; not our concern. |
| **Scenario routing (default/background/think/longContext/webSearch) + transformers** | upstream ccr | **High** — this is ccr's core value; a faithful Go reimpl must preserve `Router{}` scenarios and the `transformer` request/response-shaping hooks (openrouter/deepseek/gemini/maxtoken/tooluse). Confirm parity. |
| **Sub-100 µs gateway overhead at high RPS** | Bifrost (Go, ~11 µs/req at 5k RPS, ~68% less memory than LiteLLM) | **Reference bar** — a Go gateway *should* be this cheap; if ours adds ms-level overhead per request, profile the translation/allocation path. |

### 4.1 Prior-art confirmation of the disconnect-leak (reinforces §2.2)

The client-disconnect billing/resource leak is not theoretical — it is a **filed, reproduced bug in
both LiteLLM and vLLM**:
- LiteLLM #30244: *"Proxy keeps upstream LLM connection open after a streaming client disconnects;
  backend keeps generating or stays blocked."*
- vLLM #9428 / #24584 / #10087: aborting a request does **not** reliably abort generation; a
  `BaseHTTPMiddleware` can make `request.is_disconnected()` return `False`; **self-hosted backends hold
  a generation slot per orphaned stream.**
Sources: https://github.com/BerriAI/litellm/issues/30244 ; https://github.com/vllm-project/vllm/issues/9428 ;
https://github.com/vllm-project/vllm/issues/24584 (accessed 2026-07-20). **Takeaway:** even leading
projects get this wrong; our §2.2 context-propagation wiring is a differentiator, not a nicety, and
must be tested (a test that disconnects mid-stream and asserts the upstream context was cancelled).

### 4.2 Upstream ccr parity notes

Our Go reimplementation replaced the JS `@musistudio/claude-code-router`. The features a faithful
reimpl must not silently drop (from the ccr integration notes + upstream README):
- **`Router{}` scenarios:** `default`, `background`, `think`, `longContext` +
  `longContextThreshold` (default 60000), `webSearch`, `image`. These map a request *class* to a
  `provider,model` pair — richer than a single strong/fast split.
- **`transformer` hooks:** per-provider request/response shaping (`openrouter`, `deepseek`, `gemini`,
  `maxtoken`, `tooluse`). Our Kimi proxy tool-schema normalization is the same idea; confirm the Go
  gateway has a general transformer mechanism, not just per-family hardcoding.
- **`API_TIMEOUT_MS`, `PROXY_URL` (authenticated outbound proxy), `NON_INTERACTIVE_MODE`, `APIKEY`
  (local auth via Bearer / `x-api-key`).** The recent commits show the Go router already added
  authenticated outbound proxy and operator switches — verify each maps to a ccr config key so
  existing `config.json` users migrate cleanly.
Source: docs/research/ccr-integration-notes.md (repo-internal); upstream
https://github.com/musistudio/claude-code-router (accessed 2026-07-20).

## 5. Prioritised gap list & Go recommendations

Ranked by impact (correctness/cost first, then resilience, then features). "Effort" is a rough
Go-implementation estimate.

| # | Gap | Impact | Effort | Why it ranks here |
|---|---|---|---|---|
| **G1** | **Client-disconnect → upstream cancellation** not guaranteed | **Critical** (silent $ leak + provider slot leak) | Low | Wire `r.Context()` into the upstream call. Leading gateways have this as a *filed bug* (§4.1). Pure downside if missing. |
| **G2** | **Streaming-retry safety** (Phase-A/Phase-B first-byte gate) | **Critical** (corrupt messages, double-bill) | Low–Med | Without the gate, any mid-stream retry corrupts output. The one warning everyone must encode. |
| **G3** | **Config hot-swap for handler config** (drop restart-to-apply) | **High** (operability) | Low | `atomic.Pointer[Config]` RCU. Removes the known limitation for the 90% case. |
| **G4** | **Retry classification by `(status, body)` + budget + Retry-After** | **High** (resilience, avoids retry storms & no-credit hammering) | Med | Ties to the credit-detection brief's 429-split; add token-bucket budget + jittered backoff. |
| **G5** | **Cross-provider failover chains** (Phase-A only) | **High** (availability) | Med | Ordered fallback list per alias; the headline feature of Portkey/Bifrost. |
| **G6** | **Circuit breaker per upstream** + `deployment_state`-style signal | **Medium-High** | Med | `sony/gobreaker`; stops spending budget on a dead provider; surfaces as metric. |
| **G7** | **Stream usage accounting incl. truncated streams** | **Medium** (cost visibility) | Med | Always emit one usage row, `partial:true` when terminal usage chunk missing; set `include_usage` upstream. |
| **G8** | **TLS cert live rotation** via `GetCertificate` + atomic pointer | **Medium** | Low | Folds TLS into the hot class; no listener replacement. |
| **G9** | **Gateway rate limiting** (per key/model) | **Medium** | Med | Protects a shared key from agent burstiness; sliding-window. |
| **G10** | **Structured per-request log/metrics line** (model, tokens, cost, latency, outcome) | **Medium** | Low | Pairs with G7; low-cardinality per the Envoy finding. |
| **G11** | **QUIC/HTTP3 zero-downtime listener swap** | **Low** (has TCP fallback) | High | Genuinely hard (§3.5); accept restart-for-QUIC-rebind rather than build eBPF. |
| **G12** | Response caching (exact/semantic), guardrails, budgets | **Low** for a dev router | Med–High | Opt-in at most; semantic cache risky for code. |

### 5.1 Top recommendation A — Config hot-swap (kills the restart-to-apply limitation)

**Do this (G3 + G8).** Split config into hot (handler/routing/providers/timeouts/retry/TLS) vs
listener-bound (bind addr/ALPN). Serve the hot class through `atomic.Pointer[Config]`:

```go
type Server struct{ cfg atomic.Pointer[Config] }

func (s *Server) Reload(path string) error {
    nc, err := LoadValidate(path)     // your existing validation, unchanged
    if err != nil { return err }      // invalid ⇒ old config keeps serving (as today)
    s.cfg.Store(nc)                   // VALID ⇒ now applied LIVE, not deferred to restart
    return nil
}
func (s *Server) handle(w http.ResponseWriter, r *http.Request) {
    c := s.cfg.Load()                 // lock-free snapshot; in-flight reqs keep their snapshot
    ...
}
```
- Trigger on `SIGHUP` and/or a `:3458` management endpoint (`POST /reload`).
- Build a **fresh** `*Config` each reload; never mutate a stored one (RCU immutability).
- TLS: `tls.Config{GetCertificate: func(*ClientHelloInfo)(*tls.Certificate,error){ return s.cert.Load(), nil }}`
  with `s.cert atomic.Pointer[tls.Certificate]`; reload `Store()`s a new cert — live rotation, no
  socket churn.
- **Keep `restart` only for a bind-address or QUIC-socket change** and document that scope. This
  converts the current limitation from "hot-reload never applies" to "hot-reload applies everything
  except a socket rebind."
Sources: https://pkg.go.dev/sync/atomic ; https://caddyserver.com/docs/api (accessed 2026-07-20).

**Looks-right-but-fails:** taking a `sync.RWMutex` around the whole config and holding the read lock
for the duration of a (possibly minutes-long) streaming request. That blocks every reload behind the
slowest stream and can deadlock writer-starvation. RCU/atomic-pointer is the correct tool precisely
because reads never block and never hold anything.

### 5.2 Top recommendation B — Streaming-retry safety (the first-byte gate)

**Do this (G2 + G1).** Model every upstream attempt as two phases around the first client-visible byte:

```
attempt(req):
  ctx = r.Context()                       // G1: client disconnect cancels this
  resp = do_upstream(req.WithContext(ctx))
  # ---- PHASE A: nothing sent to client yet ----
  if err or retryable_status(resp):       # classify on (status, body-code), per §1.1 & credit brief
      if budget.allow() and phaseA:       # token-bucket budget, jittered backoff, honor Retry-After
          return RETRY | FAILOVER          # safe: client saw nothing
      else: return error_to_client(resp)  # normal HTTP error status
  write_headers(w); flusher.Flush()       # <-- POINT OF NO RETURN
  # ---- PHASE B: bytes are on the wire ----
  for event in translate(resp.stream):
      if write_or_flush_fails: break       # client gone: cancel ctx (G1), record partial usage, stop
      if upstream_error_event(event):      # G2: NEVER retry/reconnect here
          emit_anthropic_error_event(w)    # translate to `event: error` (overloaded_error/etc.)
          record_partial_usage(); return   # do NOT splice a second generation
  emit clean message_stop; record_usage()
```
- **Retryable classification** must be provider-keyed on `(status, body-code)` — reuse the
  credit-detection brief's table so a 429-no-credit isn't retried and a 429-rate-limit is (with
  `Retry-After`). Never count a Phase-B failure against the retry budget as "retryable".
- **Budget** is a shared token bucket (≈10–20% of requests), not per-request, so three retry layers
  (agent, gateway, SDK) don't multiply. Fail fast when empty.
Sources: https://gateway-api.sigs.k8s.io/geps/gep-1731/ ;
https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/ (accessed 2026-07-20).

**Looks-right-but-fails (the canonical trap):** "transparently reconnect on mid-stream drop and keep
appending events so the client never notices." Restated from §1.2 because it is *the* mistake — it
splices two different generations (corrupt/invalid tool JSON), double-bills, and can replay tool-call
side effects. NGINX/Gateway-API forbid it; LiteLLM only retries pre-first-byte; Anthropic's own
"resume" is a *new context-carrying request the client builds*, not a proxy splice. **Fail the stream
honestly instead.**

### 5.3 Quick wins (low effort, real value)

- **G1** (context propagation) — a few lines; test by disconnecting mid-stream and asserting upstream
  ctx cancelled. Highest value-per-line in the brief.
- **G8** (TLS `GetCertificate`) — folds into G3.
- **G10** (one structured log/metric line per request) — reuse G7's usage struct; keep labels
  low-cardinality (model, provider, outcome, error-class) per the Envoy finding; never label with
  request IDs / user content / full keys (the LiteLLM cardinality trap).

### 5.4 Where there is NO consensus (stated honestly)

- **Exact retry-budget fraction.** AWS advocates a token-bucket cap but the exact ratio (~5%? 10%?
  20%?) is workload-specific; there is no universal number. Pick a conservative default (e.g. retries
  ≤10% of requests) and make it configurable.
- **Whether to failover automatically at all for a coding agent.** Silent provider-switching changes
  model behaviour mid-session (different model = different capabilities/tokenizer); some argue a dev
  router should fail loudly rather than silently degrade. No consensus — make failover opt-in per alias.
- **Semantic caching for code.** Genuinely contested: big cost/latency wins for FAQ-style traffic, but
  for code generation a "similar" prompt returning a cached different-context answer is a correctness
  hazard. Most sources that praise semantic caching assume Q&A workloads, not agentic coding. Treat as
  off-by-default.
- **QUIC graceful restart.** Even Cloudflare concludes there is no cheap portable answer (udpgrm needs
  eBPF; "should really be a feature of systemd"). For a self-hosted gateway, accepting a brief QUIC
  reset (TCP fallback covers it) is a legitimate choice, not a defect.

## 6. Coverage tracker

| # | Task item | Status | Section |
|---|---|---|---|
| 1a | Which HTTP statuses are safely retryable | DONE | §1.1 |
| 1b | Why retrying a non-idempotent streaming completion is dangerous | DONE | §1.2 |
| 1c | Backoff + jitter | DONE | §1.3 |
| 1d | Circuit breaking | DONE | §1.5 |
| 1e | Honouring Retry-After | DONE | §1.3 |
| 1f | Failover chains | DONE | §1.6 |
| 1g | Mid-stream failure after bytes sent (pitfalls) | DONE | §1.2, §2.4, §5.2 |
| 1h | Retry budgets / storm amplification | DONE | §1.4 |
| 2a | SSE buffering/flush discipline | DONE | §2.1 |
| 2b | Client-disconnect propagation + upstream cancellation (billing after hangup?) | DONE | §2.2 |
| 2c | Usage/token accounting from a stream | DONE | §2.3 |
| 2d | Mid-stream error handling | DONE | §2.4 |
| 3a | Atomic config swap (atomic.Value/RCU) | DONE | §3.2 |
| 3b | Graceful listener replacement | DONE | §3.4 |
| 3c | SO_REUSEPORT handover | DONE | §3.4 (why it drops conns) |
| 3d | How Envoy/Caddy/Traefik/Cloudflare do live updates | DONE | §3.4 (Caddy), §3.5 (Cloudflare QUIC) |
| 3e | Go-idiomatic rec to drop restart-to-apply | DONE | §3.2, §5.1 |
| 4 | Remaining prior-art gaps (LiteLLM/Portkey/Cloudflare/Bifrost/vLLM/ccr) | DONE | §4 |
| D1 | Prioritised gap list (ranked by impact) | DONE | §5 (table) |
| D2 | Concrete Go recs (esp. config hot-swap + streaming-retry) | DONE | §5.1, §5.2 |
| D3 | Warnings about approaches that look right but fail | DONE | §1.2, §2.4, §5.1, §5.2 |
| D4 | Where no consensus exists | DONE | §5.4 |

### Traefik note (asked in 3d, brief)
Traefik supports dynamic configuration via *providers* (file/Docker/Kubernetes) that push updates into
a live watcher; the file provider `watch: true` hot-reloads routers/services/middlewares without
restart, and TLS certs reload dynamically — same conceptual model as §3.2 (validated dynamic config
swapped into the running process). Envoy does the equivalent via xDS (LDS/CDS/RDS/EDS) delta pushes
with a hot-restart binary for the rare data-plane binary change. Both confirm the industry norm:
*dynamic/handler config is hot; only a listener/binary change needs the heavier path.*
Sources: https://doc.traefik.io/traefik/providers/file/ (Traefik file provider `watch`);
https://www.envoyproxy.io/docs/envoy/latest/intro/arch_overview/operations/hot_restart (accessed 2026-07-20,
general knowledge — verify exact URLs at integration).

---

## Source index (primary citations, all accessed 2026-07-20)

**Retry / resilience**
- Gateway API retries GEP: https://gateway-api.sigs.k8s.io/geps/gep-1731/
- Baeldung retryable status codes: https://www.baeldung.com/cs/http-error-status-codes-retry
- REST API Tutorial retries: https://www.restapitutorial.com/advanced/responses/retries
- AWS exponential backoff & jitter: https://aws.amazon.com/blogs/architecture/exponential-backoff-and-jitter/
- AWS Builders' Library timeouts/retries/backoff: https://builder.aws.com/content/3EumjoZascWd1oZiEgL8ORlv3qE/timeouts-retries-and-backoff-with-jitter
- Retry-After (MDN): https://developer.mozilla.org/en-US/docs/Web/HTTP/Reference/Headers/Retry-After
- 429 handling: https://www.thisdevtool.com/blog/handle-429-too-many-requests-retry-after-backoff ; https://zuplo.com/learning-center/http-429-too-many-requests-guide
- Circuit breaker: https://github.com/sony/gobreaker ; https://pkg.go.dev/github.com/sony/gobreaker/v2 ; https://oneuptime.com/blog/post/2026-01-07-go-circuit-breaker/view
- Idempotency / duplicate-charge: https://tianpan.co/blog/2026-04-20-idempotency-llm-pipelines ; https://networkspy.app/blog/llm-api-errors-retries-rate-limits-debugging ; https://www.buildmvpfast.com/blog/idempotent-ai-agent-retry-safe-patterns-production-workflow-2026 ; https://dev.to/mukundakatta/rust-stop-retries-from-double-submitting-llm-calls-with-content-derived-idempotency-keys-3ook
- LLM failover: https://www.truefoundry.com/blog/llm-failover-load-balancing-provider-outages
- LiteLLM streaming retry: https://github.com/BerriAI/litellm/issues/8648

**Streaming**
- Anthropic streaming (event flow, usage cumulative, error event, resume): https://platform.claude.com/docs/en/api/messages-streaming
- OpenAI stream usage: https://community.openai.com/t/usage-stats-now-available-when-using-streaming-with-the-chat-completions-api-or-completions-api/738156 ; https://developers.openai.com/api/reference/resources/chat/subresources/completions/streaming-events
- OpenAI cancel/billing: https://community.openai.com/t/if-we-stop-streaming-output-stream-before-it-finishes-do-we-still-get-billed-for-the-tokens-that-werent-ouputted/859904
- OpenRouter cancel-and-billing (403 to bots): https://openrouter.zendesk.com/hc/en-us/articles/51691588409883
- Go SSE flush / X-Accel-Buffering: https://oneuptime.com/blog/post/2026-01-25-server-sent-events-streaming-go/view ; https://github.com/epam/ai-dial-core/issues/1349
- Go ReverseProxy FlushInterval / cancellation: https://go.dev/src/net/http/httputil/reverseproxy.go ; https://github.com/golang/go/issues/47359 ; https://github.com/golang/go/issues/31125 ; https://github.com/golang/go/issues/20071 ; https://github.com/golang/go/issues/20617
- Disconnect leak (prior art bugs): https://github.com/BerriAI/litellm/issues/30244 ; https://github.com/vllm-project/vllm/issues/9428 ; https://github.com/vllm-project/vllm/issues/24584 ; https://github.com/vllm-project/vllm/issues/10087

**Config hot-reload / zero-downtime**
- Go atomic: https://pkg.go.dev/sync/atomic ; https://oneuptime.com/blog/post/2026-01-25-hot-reload-configuration-go-without-restarts/view ; https://dev.to/chiman_jain/dynamic-configuration-reloading-in-go-apps-on-kubernetes-5bmp
- Caddy graceful reload: https://caddyserver.com/docs/api ; https://caddyserver.com/docs/getting-started
- Cloudflare tableflip: https://blog.cloudflare.com/graceful-upgrades-in-go/ ; https://github.com/cloudflare/tableflip
- Cloudflare QUIC/udpgrm: https://blog.cloudflare.com/quic-restarts-slow-problems-udpgrm-to-the-rescue/ ; https://github.com/cloudflare/udpgrm

**Prior-art gateways**
- Portkey: https://github.com/portkey-ai/gateway ; https://portkey.ai/docs/product/ai-gateway
- Bifrost (Go): https://github.com/maximhq/bifrost ; https://docs.getbifrost.ai/overview
- Cloudflare AI Gateway: https://developers.cloudflare.com/ai-gateway/features/ ; https://developers.cloudflare.com/ai-gateway/features/rate-limiting/
- Upstream ccr: https://github.com/musistudio/claude-code-router (+ repo-internal docs/research/ccr-integration-notes.md)

*End of brief.*
