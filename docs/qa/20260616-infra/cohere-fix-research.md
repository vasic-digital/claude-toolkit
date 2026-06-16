# Cohere Verification Fix — Research

Date: 2026-06-16
Host: nezha.local (probed read-only via SSH; key sourced from `~/helix-system/llmsverifier/.env`)

## Problem

The verifier was posting OpenAI-shaped `/chat/completions` requests to Cohere's
`/v2` base, which returned **HTTP 405** (method/route mismatch — `/v2/chat` is
Cohere's native shape, not OpenAI-compatible).

## Fix

Cohere exposes an **OpenAI-compatibility endpoint**. Point the verifier at it.

- **Correct base URL:** `https://api.cohere.ai/compatibility/v1`
  - Chat path: `https://api.cohere.ai/compatibility/v1/chat/completions`
  - Models path: `https://api.cohere.ai/compatibility/v1/models`
- **Confirmed working model id:** `command-r-08-2024`
  - (`command-a-03-2025`, the current flagship, also returns 200.)
- **Auth:** `Authorization: Bearer $COHERE_API_KEY` (unchanged).

## Evidence (captured live on nezha)

### 1. Compat `/models` reachable

```
$ curl ... https://api.cohere.ai/compatibility/v1/models
compat /models http=200
```

### 2. Real chat completion — `command-r-08-2024` → HTTP 200

Request:
```json
{"model":"command-r-08-2024","messages":[{"role":"user","content":"hello"}],"max_tokens":10}
```
POST to `https://api.cohere.ai/compatibility/v1/chat/completions`

Response body (OpenAI-shaped, verbatim):
```json
{"id":"92a44147-f8d4-4020-afe0-2c51329f03b0","choices":[{"index":0,"finish_reason":"stop","message":{"role":"assistant","content":"Hello! How can I assist you today?"},"logprobs":null}],"created":1781624073,"model":"command-r-08-2024","object":"chat.completion","usage":{"prompt_tokens":1,"completion_tokens":9,"total_tokens":10,...}}
http=200
```

### 3. Flagship sanity check — `command-a-03-2025` → HTTP 200

```
command-a-03-2025 http=200
```

### 4. Valid chat-capable model ids (from compat `/models`)

`command-a-03-2025`, `command-a-plus-05-2026`, `command-a-reasoning-08-2025`,
`command-a-vision-07-2025`, `command-r-08-2024`, `command-r-plus-08-2024`,
`command-r7b-12-2024`, `command-r7b-arabic-02-2025`, plus
`c4ai-aya-expanse-32b` / `c4ai-aya-vision-32b`.

Note: `command-r` and `command-r-plus` (unversioned aliases) are **not** in the
list — use the dated ids (`command-r-08-2024`, `command-r-plus-08-2024`).
Non-chat entries (`embed-*`, `rerank-*`, `*-transcribe-*`) must not be used for
`/chat/completions`.

## Summary

| Item | Value |
|------|-------|
| Base URL | `https://api.cohere.ai/compatibility/v1` |
| Chat endpoint | `/chat/completions` (OpenAI shape) |
| Working model | `command-r-08-2024` (200) |
| Alt working model | `command-a-03-2025` (200) |
| Auth | `Authorization: Bearer $COHERE_API_KEY` |
