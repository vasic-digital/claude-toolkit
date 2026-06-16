# Provider Verification Sweep — Batch A

- **Date:** 2026-06-16
- **Host:** nezha.local (`ssh milosvasic@nezha.local`)
- **Verifier:** `podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha …` (image `llm-verifier-mv:nezha`, id `3c453651e273`)
- **Constraints honored:** read-only curl + verifier image only; no deployed `llmsverifier_*` containers touched; no builds; no git.

## Summary

| Provider | Model | Status | CanSeeCode | Score | Error |
|---|---|---|---|---|---|
| huggingface | deepseek-ai/DeepSeek-V4-Pro | error (tool) / live (direct) | false | 0.00 | Verifier targets deprecated host `api-inference.huggingface.co` → DNS NXDOMAIN. Provider+key confirmed LIVE via router (HTTP 200). |
| huggingface | Qwen/Qwen3.6-27B | error (tool) | false | 0.00 | Same deprecated-host DNS failure (deterministic). |
| sambanova | Meta-Llama-3.3-70B-Instruct | error | false | 0.00 | HTTP 402 `PAYMENT_METHOD_REQUIRED` (balance_units 0). |
| sambanova | gpt-oss-120b | error | false | 0.00 | HTTP 402 (same billing block). |
| fireworks | accounts/fireworks/models/llama-v3p3-70b-instruct | error | false | 0.00 | HTTP 404; account suspended (see /models HTTP 412 below). |

## Verdicts (honest classification)

- **huggingface — FAILED via verifier tool / provider VERIFIED live.** The deployed verifier image is hardcoded to the deprecated endpoint `api-inference.huggingface.co/chat/completions`, which no longer resolves (the container resolves `router.huggingface.co` fine but `api-inference.huggingface.co` is NXDOMAIN — HF migrated to the router). A direct read-only probe of the configured base `https://router.huggingface.co/v1/chat/completions` with the same key returned **HTTP 200** with a valid completion. So: the **key and provider are good**; the **verifier tool cannot test HF** until its endpoint is updated to the router. This is a tool bug, not a provider/credential failure.
- **sambanova — FAILED (billing).** Both the verifier tool and a direct curl return **HTTP 402** `PAYMENT_METHOD_REQUIRED`, `balance_units: 0`. Key authenticates and `/models` lists models, but no inference is possible without a payment method. Not verifiable.
- **fireworks — FAILED (account suspended).** `/models` returns **HTTP 412 PRECONDITION_FAILED**: "Account milos85vasic-qmb1xfu is suspended, possibly due to reaching the monthly spending limit or failure to pay past invoices." Verifier inference attempt returns HTTP 404. No usable model id can be discovered or verified.

---

## EVIDENCE APPENDIX (real captured output)

### Environment check
```
$ ssh milosvasic@nezha.local 'podman images | grep llm-verifier-mv'
localhost/llm-verifier-mv                     nezha               3c453651e273  2 hours ago     31.8 MB
```

### Step 1 — model discovery (`/models`)

huggingface (router, HTTP 200):
```
['MiniMaxAI/MiniMax-M3', 'moonshotai/Kimi-K2.7-Code', 'deepseek-ai/DeepSeek-V4-Pro',
 'Qwen/Qwen3.6-35B-A3B', 'Qwen/Qwen3.6-27B', 'zai-org/GLM-5.1',
 'deepseek-ai/DeepSeek-V4-Flash', 'google/gemma-4-31B-it']
```

sambanova (HTTP 200, models listed despite billing block):
```
['DeepSeek-V3.1', 'DeepSeek-V3.2', 'Meta-Llama-3.3-70B-Instruct',
 'MiniMax-M2.7', 'gemma-4-31B-it', 'gpt-oss-120b']
```

fireworks (`/models` → empty list; raw HTTP shows suspension):
```
$ curl -s -m10 -o /tmp/fw.json -w "HTTP %{http_code}\n" -H "Authorization: Bearer $FIREWORKS_API_KEY" \
    https://api.fireworks.ai/inference/v1/models
HTTP 412
{"error":{"message":"Account milos85vasic-qmb1xfu is suspended, possibly due to reaching the
 monthly spending limit or failure to pay past invoices. Please go to
 https://fireworks.ai/account/billing for more information.","param":null,
 "code":"PRECONDITION_FAILED","type":"error"},"request_id":"65e2231f-94da-4339-aeda-9ea0d400dfd7"}
FW key present (len 25)
```

### Step 2 — verifier tool runs

huggingface — DeepSeek-V4-Pro:
```
✅ Verification completed in 43.720262ms
Status: error
Can See Code: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: failed to make API request:
 Post "https://api-inference.huggingface.co/chat/completions": dial tcp: lookup
 api-inference.huggingface.co on 169.254.1.1:53: no such host (avg response time: 43ms)
 (response length: 0)
```

huggingface — Qwen/Qwen3.6-27B (determinism rerun):
```
→ verifying requested id directly against the provider API
✅ Verification completed in 46.004748ms
Status: error
Can See Code: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: failed to make API request:
 Post "https://api-inference.huggingface.co/chat/completions": dial tcp: lookup
 api-inference.huggingface.co on 169.254.1.1:53: no such host (avg response time: 45ms)
 (response length: 0)
```

sambanova — Meta-Llama-3.3-70B-Instruct:
```
✅ Verification completed in 259.268389ms
Status: error
Can See Code: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with
 status 402 (avg response time: 259ms) (response length: 0)
```

sambanova — gpt-oss-120b:
```
✅ Verification completed in 285.531499ms
Status: error
Can See Code: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with
 status 402 (avg response time: 285ms) (response length: 0)
```

fireworks — accounts/fireworks/models/llama-v3p3-70b-instruct:
```
→ verifying requested id directly against the provider API
✅ Verification completed in 405.410674ms
Status: error
Can See Code: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with
 status 404 (avg response time: 405ms) (response length: 0)
```

### Corroborating read-only direct probes

HF router direct chat (proves key + provider live; verifier limitation is endpoint-only):
```
$ curl ... -d '{"model":"deepseek-ai/DeepSeek-V4-Pro","messages":[{"role":"user",
    "content":"Reply with exactly: OK"}],"max_tokens":10}' \
    https://router.huggingface.co/v1/chat/completions
HTTP 200
{
  "id": "ooRfsTs-2byqsH-a0cb952739b5d673",
  "object": "chat.completion",
  "model": "deepseek-ai/DeepSeek-V4-Pro",
  "choices": [ { "index": 0, "message": { "role": "assistant", "content": "OK",
     "tool_calls": [] }, "finish_reason": "stop" } ],
  "usage": { "prompt_tokens": 9, "completion_tokens": 2, "total_tokens": 11 }
}
```

Container DNS resolution (explains the HF verifier failure root cause):
```
$ podman run --rm --env-file ... --entrypoint sh llm-verifier-mv:nezha -c \
    'getent hosts api-inference.huggingface.co || echo NO_OLD_HOST; \
     getent hosts router.huggingface.co || echo NO_ROUTER'
NO_OLD_HOST
13.249.8.108      router.huggingface.co  router.huggingface.co
```

SambaNova direct chat (confirms billing block, not key/network):
```
$ curl ... -d '{"model":"Meta-Llama-3.3-70B-Instruct","messages":[{"role":"user",
    "content":"Say OK"}],"max_tokens":5}' https://api.sambanova.ai/v1/chat/completions
HTTP 402
{"error":{"balance_units":0,"billing_portal_url":"https://cloud.sambanova.ai/plans/billing",
 "code":"PAYMENT_METHOD_REQUIRED",
 "message":"A payment method is required. Please set up a payment method to continue."}}
```
