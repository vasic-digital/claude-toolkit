# LLMsVerifier Go internals — de-risking `cmd/semantic-code-visibility`

Research date: 2026-07-04
Module: `digital.vasic.llmsverifier` (`go 1.25.3`), at
`submodules/LLMsVerifier/llm-verifier/`
Goal: identify what a **future** `cmd/semantic-code-visibility/main.go` can
reuse vs. must write, to make a real chat-completion call to an arbitrary
OpenAI-compatible endpoint (base URL + model + API-key-env from flags), send a
two-round prompt (round 1 "read this fixture, reply with the sentinel token";
round 2 "describe what you see"), and check the response for an **exact**
sentinel string.

READ-ONLY research. No Go source was built, tested, or modified. Every
function/type named below is backed by a `file:line` I read directly. Where an
API does **not** exist, that is stated explicitly.

---

## 1. The `client` package — HTTP client for chat POSTs

File: `submodules/LLMsVerifier/llm-verifier/client/http_client.go`

- `type HTTPClient struct{...}` — wraps a `*http.Client` plus a brotli cache and
  a pluggable `endpointResolver func(provider, modelID string) string`.
  `client/http_client.go:18-29`.
- Constructor: `func NewHTTPClient(timeout time.Duration) *HTTPClient`
  `client/http_client.go:43-52`. (This is exactly what `code-verification`
  calls — see §4.)
- Chat-style methods that DO make a real `POST .../chat/completions` with
  `Authorization: Bearer <key>`:
  - `func (c *HTTPClient) TestResponsiveness(ctx, provider, apiKey, modelID, prompt string) (time.Duration, time.Duration, error, string, bool, int, error)`
    `client/http_client.go:107-162` — POSTs a `{model,messages,max_tokens}` body.
  - `func (c *HTTPClient) TestStreaming(ctx, provider, apiKey, modelID, prompt string) (bool, error)`
    `client/http_client.go:165-213`.
  - `func (c *HTTPClient) TestBrotliSupport(ctx, provider, apiKey, modelID string) (bool, error)`
    `client/http_client.go:358-459`.
  - `func (c *HTTPClient) TestModelExists(ctx, provider, apiKey, modelID string) (bool, error)`
    `client/http_client.go:67-104` (GET to the models list).

**Critical limitation for the new command:** every chat method here resolves its
URL from a **hardcoded provider→URL table**, NOT from an arbitrary base URL.
`getModelEndpoint(provider, modelID)` is a fixed map of provider name → known
chat URL (`client/http_client.go:278-334`), and `getProviderEndpoint` similarly
(`client/http_client.go:216-273`). `TestResponsiveness` calls
`getModelEndpoint(provider, modelID)` directly (`client/http_client.go:108`);
`TestBrotliSupport` uses the `endpointResolver` seam which defaults to the same
table (`client/http_client.go:50`, `62-64`, `390-394`). Unknown providers return
`""` (`:270-272`, `:332-333`). There is **no** public method on
`client.HTTPClient` that POSTs a chat completion to a caller-supplied base URL
with a caller-supplied multi-message array. So this package gives you the
*timeout-bearing http.Client wrapper* used by `code-verification`, but it is
not, by itself, an "arbitrary endpoint + two-round messages" chat caller.

`DetectErrorType(statusCode int, body []byte) string` (`:339-355`) is a small
reusable status→category helper if the new command wants to classify failures.

---

## 2. The `providers` package — reusable "call this provider's chat endpoint"

### 2.1 A concrete, reusable non-streaming `ChatCompletion` exists

Yes. Every OpenAI-compatible adapter exposes an identical, reusable
`ChatCompletion` against an **arbitrary** endpoint. Canonical simplest example
(`providers/kilo.go`):

- Constructor: `func NewKiloAdapter(client *http.Client, endpoint, apiKey string) *KiloAdapter`
  `providers/kilo.go:17-30` — takes an arbitrary `endpoint` + bearer `apiKey`,
  sets `Authorization: Bearer <key>` header.
- `func (p *KiloAdapter) ChatCompletion(ctx, request OpenAIChatRequest) (*OpenAIChatResponse, error)`
  `providers/kilo.go:100-133` — marshals the request, `POST {endpoint}/chat/completions`,
  decodes `OpenAIChatResponse`.

The same `func (X) ChatCompletion(ctx, OpenAIChatRequest) (*OpenAIChatResponse, error)`
signature is implemented by ~25 adapters (verified list): `hyperbolic.go:100`,
`modal.go:100`, `kimi.go:100`, `novita.go:100`, `nlpcloud.go:100`,
`publicai.go:100`, `nia.go:100`, `sambanova.go:100`, `sarvam.go:100`,
`vulavula.go:100`, `zhipu.go:100`, `upstage.go:100`, `groq.go:139`,
`mistral.go:108`, `siliconflow.go:108`, `xai.go:108`, `togetherai.go:108`,
`xiaomi.go:108`, `cerebras.go:108`, `cohere.go:159`, `cloudflare.go:108`,
`qwen.go:245`, `replicate.go:185`, `kimicode.go:160`, plus `anthropic.go:364`
(anthropic maps OpenAI shape → messages API). The generic
`providers.OpenAIAdapter` (`providers/openai.go:20` `NewOpenAIAdapter`) has only
`StreamChatCompletion` (SSE) + `GetModelInfo`, **not** a non-streaming
`ChatCompletion`; use `KiloAdapter`/`ModalAdapter`/etc. for a plain
non-streaming call.

Request/response shapes:
- `type OpenAIChatRequest struct { Model string; Messages []Message; MaxTokens int; Temperature float64; TopP float64; Stream bool }`
  `providers/openai.go:124-131`. `Messages []Message` is an array → supports the
  two-round conversation directly.
- `type Message struct { Role string; Content string }` `providers/openai.go:156-159`.
- `type OpenAIChatResponse struct {... Choices []struct{ Message struct{ Role, Content string } } ...}`
  `providers/groq.go:15-32`. Reply text = `resp.Choices[0].Message.Content`.

### 2.2 Is there a `ProviderAdapter` interface?

The CLAUDE.md docstring advertises `ProviderAdapter interface { DiscoverModels;
TestModel; SupportsFeature }`, but the only actual Go declaration of that name is
in a **different** package: `enhanced/adapters/providers.go:30-31`
(`// ProviderAdapter interface for provider-specific optimizations`) — a
performance-optimization interface, unrelated to chat calls. There is **no**
`ProviderAdapter` interface unifying the `providers/*.go` adapters; they are
concrete structs embedding `BaseAdapter` (`providers/base.go:8-13`) with a
by-convention `ChatCompletion` method (no shared interface). So "reuse a
`ProviderAdapter`" means "instantiate one concrete adapter", not "program to an
interface".

### 2.3 Generic HTTP primitive in the same package

`providers.HTTPClient` (`providers/http_client.go:13-19`) is a genuinely generic
base-URL client: `NewHTTPClient(config *HTTPClientConfig)` (`:33-71`, config
carries `BaseURL`/`APIKey`/`Headers`/`Timeout`), then
`func (c *HTTPClient) Post(ctx, path string, body interface{}) (*Response, error)`
(`:180-186`) which POSTs `baseURL+path` and sets `Authorization: Bearer <apiKey>`
when the key is non-empty (`:112-114`). This is a clean reusable primitive, but
it lives in the heavyweight `providers` package (see §6 dependency note).

### 2.4 Provider service adapter (used by code-verification, NOT a chat caller)

`providers.NewProviderServiceAdapter(service *ModelProviderService) verification.ProviderServiceInterface`
`providers/provider_service_adapter.go:11-13` — adapts the provider *registry*
to the verification layer (`GetAllProviders`, `GetModels`). It exposes providers'
`BaseURL`/`APIKey` (`:20-27`) but does not itself call chat endpoints. It is
provider-catalogue plumbing, not reusable for a single-endpoint semantic check.

---

## 3. The `verification` package — what `code-verification` uses; reusability

### 3.1 Types `code-verification` consumes

- Result type in the report: `verification.VerificationResult` — fields
  `ProviderID, ModelID, VerificationID, Status, CodeVisibility, ToolSupport,
  VerificationScore, VerifiedAt, ErrorMessage`
  `verification/code_verification_integration.go:34-44`. (This is the
  *integration* result; distinct from `database.VerificationResult` at
  `database/database.go:875`, and from the small `providers.VerificationResult`
  at `providers/service.go:20-26`.)
- Service constructor: `verification.NewCodeVerificationService(httpClient *client.HTTPClient, logger *logging.Logger) *CodeVerificationService`
  `verification/code_verification.go:95-100`.
- Integration constructor: `verification.NewCodeVerificationIntegration(verificationService *CodeVerificationService, db *database.Database, logger *logging.Logger, providerService ProviderServiceInterface) *CodeVerificationIntegration`
  `verification/code_verification_integration.go:24-31`.
- Driver method: `func (cvi *CodeVerificationIntegration) VerifyAllModelsWithCodeSupport(ctx) ([]VerificationResult, error)`
  `verification/code_verification_integration.go:47-98`.

### 3.2 The closest existing behaviour — and why it does NOT fit

`func (cvs *CodeVerificationService) VerifyModelCodeVisibility(ctx, modelID, providerID string, providerClient ProviderClientInterface) (*CodeVerificationResult, error)`
`verification/code_verification.go:103-209` is the "Do you see my code?" check.
Its real HTTP call is the **unexported** `makeVerificationRequest`
(`verification/code_verification.go:272-332`), which POSTs
`{providerClient.GetBaseURL()}/chat/completions` with `Authorization: Bearer
<GetAPIKey()>` and reads `choices[0].message.content` — structurally the exact
call the new command needs, but it is private to the package and therefore not
directly callable.

It is **not reusable for the semantic-code-visibility requirement** because:
1. Prompts are hardcoded — `createCodeVerificationPrompt` builds a fixed
   "Do you see my code? …" string (`code_verification.go:266-269`) over a fixed
   set of built-in `getTestCodeSamples()` (`:528-594`). No caller-supplied
   fixture/prompt.
2. It does keyword/heuristic analysis (`analyzeCodeResponse`,
   `code_verification.go:334-378`: matches "yes"/"i can see"/… vs "no"/"cannot
   see"/…), **not** an exact-sentinel-string match. The task requires exact
   sentinel matching.
3. It is single-turn per sample — no two-round conversation (round-1 sentinel /
   round-2 describe). `makeVerificationRequest` sends one `messages:[{user,
   prompt}]` payload (`:274-281`).
4. `providerClient ProviderClientInterface` is easy to satisfy —
   `verification.SimpleProviderClient{BaseURL, APIKey, HTTPClient}`
   (`verification/provider_client.go:14-19`) implements
   `GetBaseURL/GetAPIKey/GetHTTPClient` (`:21-30`) — but there is no public entry
   that lets you inject a custom prompt/fixture/sentinel through it.

Also note `verification.Verifier.Verify` (`verification/verification.go:29-63`)
is deliberately stubbed to return `ErrVerificationNotWired`
(`verification/verification.go:62`, `:69`) — an anti-bluff guard, not a usable
path.

**Conclusion for item 3:** the verification package's public API is built around
*fixed* code-visibility sampling + heuristic scoring + DB persistence. None of
its exported functions accept a custom fixture/prompt/sentinel or perform a
two-round exact-sentinel check. A semantic-code-visibility command is better as
its **own command** with its own small chat call (reusing a chat *client*, not
this service). Reusing `CodeVerificationService` would mean forking its prompt
logic anyway.

---

## 4. Flag-parsing + JSON output pattern in `cmd/code-verification/main.go`

File: `submodules/LLMsVerifier/llm-verifier/cmd/code-verification/main.go`

- Uses the stdlib `flag` package (`main.go:6` import, `:67-79` declarations).
  Flags: `--config` (string, path), `--output` (string, dir, default
  `verification_results`), `--providers` (comma-list), `--models` (comma-list),
  `--concurrency` (int, default 5), `--timeout` (int seconds, default 60),
  `--format` (string, default **`"json"`**; also `csv`, `markdown`), `--db`
  (string), `--help` (bool). `flag.Parse()` at `:79`; `--help` short-circuits to
  a printed usage (`:81-84`, `printHelp` `:157-188`).
- Config precedence: flags override a JSON `--config` file
  (`loadConfig` `:190-218`: `os.ReadFile` + `json.Unmarshal` into
  `VerificationConfig`, then CLI overrides).
- Wiring order in `main` (`:117-129`): `client.NewHTTPClient(timeout)` →
  `providers.NewModelProviderService("config.yaml", logger)` →
  `RegisterAllProviders()` → `verification.NewCodeVerificationService(...)` →
  `providers.NewProviderServiceAdapter(...)` →
  `verification.NewCodeVerificationIntegration(...)`.
- JSON output: `saveJSONResults` marshals the report with
  `json.MarshalIndent(report, "", "  ")` and writes a timestamped file
  (`main.go:425-438`); format dispatch in `saveResults` (`:410-423`). A
  human-readable summary is printed via `printSummary` using an i18n `tr(...)`
  helper (`:509-517`).

**Convention for the new command:** stdlib `flag`; keep `--format` defaulting to
`json`; emit machine output via `json.MarshalIndent`. The new command's flags
per the task: `--fixture`, `--prompt` (or round-1/round-2 prompts), `--sentinel`,
`--endpoint` (base URL), `--model`, `--api-key-env` (name of the env var holding
the key), plus `--format json`. Read the key with `os.Getenv(<api-key-env>)`.

---

## 5. How the binary is built/run

Driver: `scripts/claude-verify-providers.sh` (repo root).

- Locates the module: `LV_MOD="$LV_DIR/llm-verifier"` where
  `LV_DIR=${LLMSVERIFIER_DIR:-$REPO_ROOT/submodules/LLMsVerifier}`.
- Build (cached, rebuild if source newer):
  `( cd "$LV_MOD" && go build -o "$BIN" ./cmd/code-verification/ )`, with
  `BIN=${LV_BIN:-$REPO_ROOT/.local-cache/code-verification}`, rebuilt when
  `"$LV_MOD/cmd/code-verification/main.go" -nt "$BIN"`.
- Run: `exec "$BIN" --config "$CONFIG" "$@"`, `CONFIG` defaulting to
  `$LV_DIR/code_verification_config.json`.
- Preconditions: submodule present, `go` on PATH; optionally `source`s an API
  keys file from `LV_KEYS`.

So the established pattern is `go build -o <bin> ./cmd/<name>/` run from
`$LV_MOD`. A new command would build with
`go build -o <bin> ./cmd/semantic-code-visibility/`. A parallel driver
(`claude-semantic-visibility.sh` or a flag on the existing one) would mirror the
cache-and-exec shape. `cmd/` currently holds `code-verification/` and
`crush-config-converter/`.

**Build-cost caveat (cgo):** the module's `database` package imports
`github.com/mattn/go-sqlite3` with a blank cgo import
(`database/database.go:11`; `go.mod:21`). `code-verification` imports `database`
directly (`cmd/code-verification/main.go:15`), so building it already requires
`CGO_ENABLED=1` + a C toolchain. See §6 for how this constrains the reuse choice.

---

## 6. Recommendation

There are exactly three public, arbitrary-base-URL, message-array chat callers
in the module:

| Option | Entry point | Import path | Transitive weight |
|---|---|---|---|
| A | `llmverifier.LLMClient.ChatCompletion` | `digital.vasic.llmsverifier/llmverifier` | pulls in `database` → cgo sqlite (see below) |
| B | `providers.KiloAdapter.ChatCompletion` (or any sibling adapter) / `providers.HTTPClient.Post` | `digital.vasic.llmsverifier/providers` | pulls in `verification` → `database` → cgo sqlite |
| C | standalone stdlib `net/http` in the new command | (none — stdlib only) | pure Go, no cgo, no DB |

The cleanest *code* match is **`llmverifier.LLMClient`**:
- `func NewLLMClient(endpoint, apiKey string, headers map[string]string) *LLMClient`
  `llmverifier/llm_client.go:23-25` (and `NewLLMClientWithTimeout` `:28-37`) —
  arbitrary base URL + bearer key.
- `func (c *LLMClient) ChatCompletion(ctx, req ChatCompletionRequest) (*ChatCompletionResponse, error)`
  `llmverifier/llm_client.go:122-159` — POST `{endpoint}/chat/completions`, sets
  `Authorization: Bearer <key>` (`setAuthHeaders` `:227-229`), decodes choices.
- `type ChatCompletionRequest struct { Model string; Messages []Message; Temperature *float64; MaxTokens *int; ... }`
  `llmverifier/llm_client.go:80-89`; `Message{Role,Content}` `:92-95`;
  reply text = `resp.Choices[0].Message.Content`
  (`ChatCompletionResponse` `:104-112`, `ChatCompletionChoice` `:98-102`). The
  `Messages` slice supports the two-round flow (append the round-1 assistant
  reply + round-2 user message, call again).

**However**, both reuse options (A and B) transitively import the cgo
`database` package, verified by direct reads:
- A: `llmverifier/issue_detector.go:9` and `llmverifier/config_export.go:15`
  import `digital.vasic.llmsverifier/database`; Go compiles the whole
  `llmverifier` package, so importing it drags in `database` → cgo sqlite even
  though the new command only calls `NewLLMClient`/`ChatCompletion`.
- B: `providers/provider_service_adapter.go:3` imports
  `digital.vasic.llmsverifier/verification`; `verification/verification.go:7`
  imports `database` → cgo sqlite. So `providers` is likewise cgo-tainted, and
  it is a ~60-file package.

**Primary recommendation — Option C (standalone ~120–150 line command), with
Option A named as the sanctioned fallback:**

Write `cmd/semantic-code-visibility/main.go` as a self-contained command using
only stdlib (`flag`, `os`, `net/http`, `encoding/json`, `context`, `time`). It
does its own `POST {endpoint}/chat/completions` with `Authorization: Bearer
<os.Getenv(apiKeyEnv)>`, a two-element `messages` array for round 1, appends the
assistant reply + the round-2 user message for the second call, and checks
`strings.Contains(choices[0].message.content, sentinel)` for the exact sentinel.
Rationale:
1. No existing **public** function performs a two-round, custom-fixture,
   exact-sentinel check (§3.2) — that orchestration is new code regardless.
2. Every reusable chat *client* (A/B) transitively links the cgo `database`
   package, which a decoupled semantic-visibility binary has no reason to carry;
   a stdlib command stays pure-Go, builds without a C toolchain, and honours the
   module's own decoupling ethos (CONST-051). The chat POST it "reimplements" is
   ~20 lines and is materially cheaper than importing the DB/sqlite surface.
3. It matches the `cmd/code-verification` conventions (stdlib `flag`, `--format
   json`, `json.MarshalIndent`) and the `go build ./cmd/<name>/` driver pattern.

If the project's extend-don't-reimplement rule (§11.4.74) is treated as
overriding and the cgo/database transitive cost is accepted (the module already
pays it for `code-verification`), then reuse **Option A**:
`import "digital.vasic.llmsverifier/llmverifier"`, build the client with
`llmverifier.NewLLMClient(baseURL, os.Getenv(apiKeyEnv), nil)`, and call
`.ChatCompletion(ctx, llmverifier.ChatCompletionRequest{Model: model, Messages:
[]llmverifier.Message{...}})` twice (appending round-1 reply + round-2 prompt),
checking the sentinel on `resp.Choices[0].Message.Content`. In this case the
*new* code is only: flags, env-key read, fixture load, two-round message
assembly, and the exact-sentinel check.

Exact import path(s) a new command would use:
- Option C (recommended): standard library only — no `digital.vasic.llmsverifier/*`
  import needed for the HTTP call. (It may still import
  `digital.vasic.llmsverifier/logging` if it wants the project logger, but that
  is optional.)
- Option A (reuse fallback): `digital.vasic.llmsverifier/llmverifier`.

Do NOT import `.../verification` or `.../database` — they add the cgo/DB surface
with no benefit to a stateless semantic check.

---

## Sources verified (files read this session)

- `submodules/LLMsVerifier/llm-verifier/cmd/code-verification/main.go`
- `submodules/LLMsVerifier/llm-verifier/client/http_client.go`
- `submodules/LLMsVerifier/llm-verifier/providers/base.go`
- `submodules/LLMsVerifier/llm-verifier/providers/http_client.go`
- `submodules/LLMsVerifier/llm-verifier/providers/openai.go`
- `submodules/LLMsVerifier/llm-verifier/providers/kilo.go`
- `submodules/LLMsVerifier/llm-verifier/providers/provider_service_adapter.go`
- `submodules/LLMsVerifier/llm-verifier/providers/groq.go` (OpenAIChatResponse def, via grep)
- `submodules/LLMsVerifier/llm-verifier/providers/service.go`
- `submodules/LLMsVerifier/llm-verifier/verification/verification.go`
- `submodules/LLMsVerifier/llm-verifier/verification/provider_client.go`
- `submodules/LLMsVerifier/llm-verifier/verification/provider_service_interface.go`
- `submodules/LLMsVerifier/llm-verifier/verification/verification_real.go`
- `submodules/LLMsVerifier/llm-verifier/verification/code_verification.go`
- `submodules/LLMsVerifier/llm-verifier/verification/code_verification_integration.go`
- `submodules/LLMsVerifier/llm-verifier/llmverifier/llm_client.go`
- `submodules/LLMsVerifier/llm-verifier/database/database.go` (imports/head only)
- `submodules/LLMsVerifier/llm-verifier/go.mod` (module id, go version, sqlite dep)
- `scripts/claude-verify-providers.sh` (repo root driver)
- Grep-confirmed (names + line numbers): `ChatCompletion` method set across
  `providers/*.go`; `ProviderAdapter interface` only in
  `enhanced/adapters/providers.go:30-31`; `type VerificationResult struct` in
  `database/database.go:875`; `llmverifier` package imports `database` in
  `issue_detector.go:9` + `config_export.go:15`.
</content>
</invoke>
