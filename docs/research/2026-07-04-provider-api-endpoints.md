# Provider Model-Listing APIs & Token Limits — Latest-Source Research

**Retrieved / verified:** 2026-07-04 (all claims below carry a source URL; the
"Sources verified" footer lists every URL fetched).
**Method:** Live `WebFetch` + `WebSearch` against official docs and live
endpoints. Where a source was unreachable or silent, it is stated as such — no
gap is filled from memory.
**Constitution:** §11.4.99 (verify against the LATEST official online docs, cite
URL + retrieval date; document contradictions and silences).

**Purpose for the consuming project:** wiring non-Anthropic LLM providers as
Claude Code aliases needs to (a) enumerate a provider's available models and
(b) read each model's context/output token limits, to verify a configured model
actually exists.

---

## 1. models.dev — `https://models.dev/api.json` catalog

**Reachable: YES.** The live JSON was fetched successfully.

### Shape — CONFIRMED

- **Top level is an object keyed by provider id.** Observed provider keys
  include `requesty`, `qiniu-ai`, `alibaba-cn`, `xai`, etc. (root object, not an
  array).
  Source: `https://models.dev/api.json` (retrieved 2026-07-04).
- **Each provider entry carries metadata + a `models` object keyed by model id.**
  Provider metadata fields observed: `id`, `env` (array of API-key env-var
  names), `npm`, `api` (base URL), `name`, `doc`, and `models`.
  Verbatim provider entry (retrieved 2026-07-04):
  ```json
  "requesty":{"id":"requesty","env":["REQUESTY_API_KEY"],
  "npm":"@ai-sdk/openai-compatible",
  "api":"https://router.requesty.ai/v1","name":"Requesty",
  "doc":"https://requesty.ai/solution/llm-routing/models","models":{...}}
  ```
- **Each model object carries the fields the consuming project needs.**
  Verbatim complete model object (retrieved 2026-07-04):
  ```json
  "xai/grok-4":{"id":"xai/grok-4","name":"Grok 4",
  "description":"Grok model for agentic tool use, reasoning, coding,
  and live assistance","family":"grok","attachment":true,
  "reasoning":true,"reasoning_options":[],"tool_call":true,
  "temperature":true,"knowledge":"2025-01","release_date":"2025-09-09",
  "last_updated":"2025-09-09","modalities":{"input":["text","image"],
  "output":["text"]},"open_weights":false,"limit":{"context":256000,
  "output":64000},"cost":{"input":3,"output":15,"cache_read":0.75,
  "cache_write":3}}
  ```
  Source: `https://models.dev/api.json` (retrieved 2026-07-04).

### Field-by-field confirmation (against the asked list)

| Field asked | Present? | Notes |
|---|---|---|
| `limit.context` | YES | integer (e.g. `256000`) |
| `limit.output` | YES | integer (e.g. `64000`) |
| `limit.input` | Sometimes | in the README schema (`limit.input`), but NOT in the grok-4 example — treat as optional |
| `cost` | YES | object: `input`, `output`, `cache_read`, `cache_write` (README also lists `cost.reasoning`, `cost.tiers`) |
| `reasoning` | YES | boolean |
| `tool_call` | YES | boolean |
| `release_date` | YES | ISO date string (`"2025-09-09"`) |

Additional model fields observed: `id`, `name`, `description`, `family`,
`attachment`, `reasoning_options`, `structured_output`, `temperature`,
`knowledge`, `last_updated`, `modalities.input[]`, `modalities.output[]`,
`open_weights`.
Source: `https://models.dev/api.json` and the schema list in the repo README,
`https://github.com/sst/models.dev` (both retrieved 2026-07-04).

### Schema reference (repo README) — CONFIRMED

The `sst/models.dev` README documents the endpoint (`curl
https://models.dev/api.json`) and the schema, listing model fields
`name, attachment, reasoning, tool_call, structured_output, temperature,
knowledge, release_date, last_updated, open_weights` plus nested
`cost.input / cost.output / cost.reasoning / cost.cache_read / cost.cache_write`,
`limit.context / limit.input / limit.output`, and
`modalities.input / modalities.output`.
Source: `https://github.com/sst/models.dev` (retrieved 2026-07-04).

### Cache / TTL guidance — NEGATIVE FINDING (SILENCE)

**No caching, TTL, refresh-cadence, or regeneration-frequency guidance is
documented.** Neither the models.dev landing page (`https://models.dev/`) nor the
repo README (`https://github.com/sst/models.dev`) states how often `api.json` is
regenerated or how consumers should cache it. This is a documented silence, not a
confirmed value — a consuming project must choose its own TTL. (models.dev is a
community-maintained, open-source catalog regenerated from PRs; cadence is not
promised in the docs.)
Sources: `https://models.dev/`, `https://github.com/sst/models.dev` (retrieved
2026-07-04).

---

## 2. OpenAI-style `/models` listing endpoints — DeepSeek, Groq, Mistral, OpenRouter

All four expose a list endpoint. Three (DeepSeek, Groq, Mistral) return the
canonical OpenAI envelope `{"object":"list","data":[{"id":...,"object":"model",...}]}`.
OpenRouter returns `{"data":[...]}` **without** the `"object":"list"` wrapper and
with a richer per-model schema. Details per provider:

### 2a. DeepSeek — CONFIRMED (OpenAI-shaped)

- **URL / method:** `GET https://api.deepseek.com/models`
  (base_url `https://api.deepseek.com`; DeepSeek is OpenAI-compatible so
  `/v1/models` also resolves — "v1" is a compatibility path, not API versioning).
- **Auth header:** `Authorization: Bearer ${DEEPSEEK_API_KEY}`.
- **Response shape (verbatim example from docs):**
  ```json
  {
    "object": "list",
    "data": [
      { "id": "deepseek-v4-flash", "object": "model", "owned_by": "deepseek" }
    ]
  }
  ```
- **Note:** the DeepSeek list endpoint returns only `id` / `object` / `owned_by`
  — **no context or output token limits.** Limits must come from models.dev or
  DeepSeek's model docs, not from `/models`.
Sources: `https://api-docs.deepseek.com/api/list-models`,
`https://api-docs.deepseek.com/` (retrieved 2026-07-04).

### 2b. Groq — CONFIRMED (OpenAI-shaped, with `context_window`)

- **URL / method:** `GET https://api.groq.com/openai/v1/models`
- **Auth header:** `Authorization: Bearer $GROQ_API_KEY`
- **Response shape (verbatim example from docs):**
  ```json
  {
    "object": "list",
    "data": [
      {
        "id": "gemma2-9b-it",
        "object": "model",
        "created": 1693721698,
        "owned_by": "Google",
        "active": true,
        "context_window": 8192,
        "public_apps": null
      }
    ]
  }
  ```
- **Note:** Groq's entries carry `context_window` (context limit) directly, which
  the consuming project can use to verify context size. No separate max-output
  field in this example.
Source: `https://console.groq.com/docs/api-reference` (retrieved 2026-07-04).

### 2c. Mistral — CONFIRMED (OpenAI-shaped, with `max_context_length` + capabilities)

- **URL / method:** `GET https://api.mistral.ai/v1/models`
  (operation `list_models_v1_models_get`).
- **Auth header:** `Authorization: Bearer $MISTRAL_API_KEY`
- **Response shape:** `{"object":"list","data":[ ... ]}`; each entry has `id`,
  `object":"model"`, `owned_by`, a `capabilities` object
  (`completion_chat`, `completion_fim`, `function_calling`, `fine_tuning`,
  `vision`, `classification`), and `max_context_length` (integer).
  Documentation example fragment:
  ```json
  "id":"<model_id>","capabilities":{"completion_chat":true,...},
  "object":"model","owned_by":"<owner_id>","max_context_length":32768
  ```
- **Note:** carries `max_context_length` (context limit) but no explicit
  max-output field.
Sources: `https://docs.mistral.ai/api/endpoint/models`, `https://docs.mistral.ai/api`
(retrieved 2026-07-04).

### 2d. OpenRouter — CONFIRMED endpoint, DIFFERENT envelope

- **URL / method:** `GET https://openrouter.ai/api/v1/models`
- **Auth:** **public — no API key required** for the list endpoint (verified by
  fetching the live endpoint successfully with no credential).
- **Response shape:** top-level `{"data":[ ... ]}`. **There is NO
  `"object":"list"` wrapper** — this is the one deviation from the canonical
  OpenAI envelope among the four. Each model object is far richer:
  `id`, `canonical_slug`, `name`, `created`, `context_length`,
  `architecture{modality,input_modalities,output_modalities,tokenizer}`,
  `pricing{prompt,completion,...}` (strings, USD, to avoid float error),
  `top_provider{context_length,max_completion_tokens,is_moderated}`.
- **Live verbatim first model object (retrieved 2026-07-04):**
  ```json
  {
    "id": "poolside/laguna-xs-2.1:free",
    "canonical_slug": "poolside/laguna-xs-2.1-20260625",
    "hugging_face_id": "poolside/Laguna-XS-2.1",
    "name": "Poolside: Laguna XS 2.1 (free)",
    "created": 1783002429,
    "context_length": 262144,
    "architecture": {
      "modality": "text->text",
      "input_modalities": ["text"],
      "output_modalities": ["text"],
      "tokenizer": "Other"
    },
    "pricing": { "prompt": "0", "completion": "0" },
    "top_provider": {
      "context_length": 262144,
      "max_completion_tokens": 32768,
      "is_moderated": false
    }
  }
  ```
- **Note:** OpenRouter is the richest for verification — it exposes
  `context_length` AND `top_provider.max_completion_tokens` (max output) AND
  pricing directly, no auth. The consuming code must NOT rely on `"object":"list"`
  for OpenRouter; key off `data[]`.
Sources: `https://openrouter.ai/api/v1/models` (live, retrieved 2026-07-04),
`https://openrouter.ai/docs/api/api-reference/models/get-models` (doc, via search,
retrieved 2026-07-04).

### 2e. Summary table

| Provider | Endpoint | Auth | `{"object":"list"}`? | Limits in listing |
|---|---|---|---|---|
| DeepSeek | `GET https://api.deepseek.com/models` | `Bearer` | YES | none (id/object/owned_by only) |
| Groq | `GET https://api.groq.com/openai/v1/models` | `Bearer` | YES | `context_window` |
| Mistral | `GET https://api.mistral.ai/v1/models` | `Bearer` | YES | `max_context_length` |
| OpenRouter | `GET https://openrouter.ai/api/v1/models` | none (public) | **NO** (bare `data[]`) | `context_length` + `top_provider.max_completion_tokens` |

---

## 3. xAI — the assumed "outlier"

**Finding contradicts the stored assumption.** The task framed xAI as the
provider that likely does NOT expose a `/models` listing endpoint. **As of
2026-07-04, xAI DOES expose an OpenAI-shaped `/v1/models` listing endpoint, plus
richer xAI-native listing endpoints.** The "outlier" premise appears outdated —
though there is a real nuance (below) that keeps xAI partly special.

### What xAI actually exposes today

Base URL: `https://api.x.ai/v1`. All endpoints require an API key
(`Authorization: Bearer <XAI_API_KEY>`).
Source: `https://docs.x.ai/developers/rest-api-reference/inference/models`,
`https://docs.x.ai/docs/api-reference` (retrieved 2026-07-04).

1. **`GET https://api.x.ai/v1/models`** — OpenAI-compatible. Returns
   `{"object":"list","data":[...]}`. Verbatim example structure:
   ```json
   {
     "data": [
       {
         "id": "latest",
         "aliases": [],
         "context_length": 131072,
         "created": 1776556800,
         "object": "model",
         "owned_by": "xai",
         "prompt_text_token_price": 12500
       }
     ],
     "object": "list"
   }
   ```
   Carries `context_length` (usable for verification) and pricing per token.
2. **`GET https://api.x.ai/v1/language-models`** — xAI-native, richer. Returns
   `{"models":[...]}` (NOT the OpenAI envelope), with extra fields
   (`fingerprint`, `version`, modalities, aliases) beyond `/v1/models`.
3. **`GET https://api.x.ai/v1/models/{model_id}`** — single model object.
4. Plus `GET /v1/image-generation-models`, `/v1/video-generation-models` and
   their `/{model_id}` variants (all `{"models":[...]}` shaped).
Source: `https://docs.x.ai/developers/rest-api-reference/inference/models`
(retrieved 2026-07-04).

### The genuine nuance (why xAI is still partly "special")

- The **inference API reference page** (`https://docs.x.ai/docs/api-reference`)
  does NOT list a models-listing endpoint alongside chat/responses; it instead
  tells users the model name is "Obtainable from
  `https://console.x.ai/team/default/models` or `https://docs.x.ai/docs/models`."
  So depending on which xAI docs page you land on, model discovery reads as
  "look at the console / the docs table," not "call an endpoint."
  Source: `https://docs.x.ai/docs/api-reference` (retrieved 2026-07-04).
- The **models docs page** (`https://docs.x.ai/docs/models`) presents models as a
  **static/hardcoded pricing table** with no mention of a `/v1/models` endpoint;
  its guidance is prose ("For everything else, use Grok 4.3").
  Source: `https://docs.x.ai/docs/models` (retrieved 2026-07-04).
- The `/v1/models` listing surfaces alias-style ids (e.g. `"id":"latest"`) rather
  than only concrete build ids, which can complicate "does model X exist" checks.

**Verdict for the consuming project:** xAI is programmatically enumerable via
`GET https://api.x.ai/v1/models` (OpenAI-shaped, `context_length` present) — it
need not be hardcoded. The historical "outlier / hardcode the list" treatment is
now optional; the richer native list is `GET /v1/language-models`. Where xAI is
still awkward: two of its own docs pages point users at a console/static table
instead of the endpoint, and the endpoint returns alias ids.

---

## 4. Does Anthropic document that Claude Code forwards Read-tool FILE CONTENTS to a non-Anthropic backend via `ANTHROPIC_BASE_URL`?

**VERDICT: IMPLIED (strongly) — NOT explicitly stated. The specific phrase
"Read-tool file contents are forwarded" appears nowhere in Anthropic's docs.**
Anthropic documents that the **full Anthropic-Messages request body** is POSTed
to the `ANTHROPIC_BASE_URL` backend, and that body — by the Messages API contract
— contains the conversation `messages` including `tool_result` blocks (which is
where Read-tool output lives). Anthropic never singles out the Read tool or "file
contents." So the premise follows by construction from documented behavior, but
is not asserted verbatim. Reported honestly as **implied, not documented**.

### What IS explicitly documented (Anthropic official)

The official Claude Code page **"Gateway protocol reference"**
(`https://code.claude.com/docs/en/llm-gateway-protocol`, retrieved 2026-07-04) —
titled "what Claude Code sends to a gateway" — states:

- Requests go to `/v1/messages` (Anthropic Messages format) at the base URL:
  "Inference requests post to `/v1/messages?beta=true`."
- "Claude Code treats an `ANTHROPIC_BASE_URL` gateway as an Anthropic-format
  endpoint and **sends it the beta headers and request body fields it sends to
  `api.anthropic.com`**." (i.e. the same full payload as first-party.)
- Tool content travels in that body: the feature-pass-through table covers
  "Beta tool fields … pair with tool schema fields," and it warns: **"A gateway
  that rewrites or redacts request bodies for content inspection breaks the
  pairing … so inspect without modifying."** This is the closest Anthropic comes
  to acknowledging that request bodies contain inspectable content sent to the
  backend — but it speaks of "request bodies," never "file contents."
- "Anthropic doesn't endorse, maintain, or audit third-party gateway products,
  and doesn't support routing Claude Code to non-Claude models through any
  gateway." (`https://code.claude.com/docs/en/llm-gateway`, retrieved 2026-07-04.)

**What is NOT stated anywhere in these Anthropic pages:** the words "Read tool",
"file contents", or an explicit statement that files a user opens are transmitted
to a third-party backend. The docs describe the transport (full Messages body →
`/v1/messages` at the base URL) and are silent on itemizing what the body
contains. That silence is why this is "implied," not "documented."
Sources: `https://code.claude.com/docs/en/llm-gateway-protocol`,
`https://code.claude.com/docs/en/llm-gateway` (retrieved 2026-07-04).

### Corroboration from claude-code-router (third-party, not Anthropic)

The `musistudio/claude-code-router` project and its ecosystem confirm the
mechanism from the other side: it "intercepts requests, rewrites them for
whatever provider you point it at," and — critically — the target endpoint "has
to accept POST requests to the messages path, stream server-sent events back, and
**preserve `tool_use` and `tool_result` blocks** if you want the agent to call
tools." Since Read-tool output is delivered to the model as a `tool_result`
block, this confirms tool results (hence Read output) are in the forwarded body —
but this is community documentation, not Anthropic's.
Sources: `https://github.com/musistudio/claude-code-router` and OpenRouter's
Claude Code integration guide `https://openrouter.ai/docs/guides/coding-agents/claude-code-integration`
(both via search, retrieved 2026-07-04).

### Bottom line

- **Transport is documented:** the entire Anthropic-Messages request body
  (system prompt + `messages`, incl. `tool_result` blocks) is sent to whatever
  `ANTHROPIC_BASE_URL` points at. Anthropic explicitly warns gateways not to
  redact request bodies. (Documented.)
- **"Read-tool file contents specifically" is NOT documented** as such by
  Anthropic. It is a correct inference from the Messages contract (Read output =
  a `tool_result` inside `messages`), corroborated only by third-party
  (claude-code-router) docs. (Implied.)
- **Do not assert to the user that Anthropic's docs state file contents are
  forwarded.** State it as: Anthropic documents full-request-body forwarding;
  file-content forwarding follows from that but is not spelled out.

---

## Sources verified 2026-07-04

- https://models.dev/api.json
- https://models.dev/
- https://github.com/sst/models.dev
- https://api-docs.deepseek.com/api/list-models
- https://api-docs.deepseek.com/
- https://console.groq.com/docs/api-reference
- https://docs.mistral.ai/api/endpoint/models
- https://docs.mistral.ai/api
- https://openrouter.ai/api/v1/models
- https://openrouter.ai/docs/api/api-reference/models/get-models
- https://docs.x.ai/developers/rest-api-reference/inference/models
- https://docs.x.ai/docs/models
- https://docs.x.ai/docs/api-reference
- https://code.claude.com/docs/en/llm-gateway-protocol
- https://code.claude.com/docs/en/llm-gateway
- https://github.com/musistudio/claude-code-router
- https://openrouter.ai/docs/guides/coding-agents/claude-code-integration

### Unreachable / partial sources (honest gaps)

- `https://openrouter.ai/docs/api-reference/list-available-models` and
  `https://openrouter.ai/docs/api/api-reference/models/get-models` returned HTTP
  404 to direct WebFetch; the OpenRouter shape was instead confirmed from the
  **live** `https://openrouter.ai/api/v1/models` endpoint plus WebSearch
  extraction of the docs page.
- `https://docs.mistral.ai/api/` renders its endpoint spec client-side; the
  first WebFetch could not see the `/v1/models` operation detail. Confirmed via
  the dedicated `https://docs.mistral.ai/api/endpoint/models` page instead.
- models.dev cache/TTL: no source documents it (silence recorded above).
