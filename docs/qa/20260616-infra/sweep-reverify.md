# LLM Provider Re-Verification Sweep

**Date:** 2026-06-16
**Host:** nezha.local (remote, via SSH)
**Method:** Ephemeral `podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha ...` + read-only `curl` to `/models`.
**Constraints honored:** No deployed `llmsverifier_*` containers touched. No builds. No git ops. Ephemeral runs only. Read-only curl only.

> NOTE: The verifier binary uses single-dash flags (`-provider`, `-model`, `-verbose`), not the
> double-dash form in the original brief. All runs below used the binary's actual flag syntax.
> Output format is `Status: / Can See Code: / Verification Score: / Error:` (no literal "passed/failed" line;
> a failing model emits `llmsverifier_modelverify_model_failed`).

## Summary Table

| Provider | Model | Status | Score | Error |
|---|---|---|---|---|
| openrouter | deepseek/deepseek-chat | error | 0.00 | API request failed with status **402** (billing/credits) |
| hyperbolic | meta-llama/Llama-3.3-70B-Instruct | error | 0.00 | API request failed with status **402** (billing/credits) |
| siliconflow | Qwen/Qwen2.5-7B-Instruct | error | 0.00 | API request failed with status **401** (invalid auth) |
| zai | glm-4.6 | error | 0.00 | API request failed with status **429** (quota/rate limit) |
| kimi | moonshot-v1-8k | model_not_found | n/a | Model not in verifier registry; raw API key also returns **401** |

**Verdict: 0 / 5 providers passing.** All five currently fail. None can see code (`Can See Code: false` everywhere). Failures are split across billing (402), auth (401), and quota (429) — no model logic/availability successes.

## Model ID Discovery (read-only curl to /models)

| Provider | Base | Discovery result |
|---|---|---|
| openrouter | https://openrouter.ai/api/v1 | `deepseek/deepseek-chat` **confirmed present** (also `deepseek-chat-v3.1`, `deepseek-chat-v3-0324`) |
| hyperbolic | https://api.hyperbolic.xyz/v1 | `meta-llama/Llama-3.3-70B-Instruct` **confirmed present** (HTTP 200 on /models) |
| zai | https://open.bigmodel.cn/api/paas/v4 | `glm-4.6` **confirmed present** (also glm-4.5, glm-4.5-air, glm-4.7) |
| siliconflow | https://api.siliconflow.cn/v1 | /models returns **HTTP 401 "Api key is invalid"** — could not discover; used common id `Qwen/Qwen2.5-7B-Instruct` |
| kimi | https://api.moonshot.cn/v1 | /models returns **HTTP 401 "Invalid Authentication"** (same on .ai global endpoint) — could not discover |

All five providers are present in the verifier registry (`-list-providers` shows `*_provider_configured` for hyperbolic, siliconflow, openrouter, kimi, zai).

## Per-Provider Current State

- **openrouter / deepseek/deepseek-chat** — Reaches the API; fails with HTTP **402**. The model id is valid (present in /models). This is a billing/credit-exhaustion failure, not auth or a bad model. Add credits to recover.
- **hyperbolic / meta-llama/Llama-3.3-70B-Instruct** — Model id valid (/models HTTP 200, id present). Fails with HTTP **402** — billing/credit issue. Key is accepted (it lists models) but account lacks balance.
- **siliconflow / Qwen/Qwen2.5-7B-Instruct** — Fails with HTTP **401**. The raw API key is rejected (/models also 401, "Api key is invalid"). This is an auth/key problem; key needs to be replaced/rotated. Model id could not be confirmed because /models is gated behind the same failing auth.
- **zai / glm-4.6** — Model id valid (present in /models, which DID respond). Verifier fails with HTTP **429** — quota/rate-limit. Key authenticates but is throttled or out of quota. Retry after cooldown / increase quota.
- **kimi / moonshot-v1-8k** — Verifier returns **model_not_found** (the id is not in the verifier's registry, and it cannot enumerate models because the key is invalid). Raw /models on both api.moonshot.cn and api.moonshot.ai returns HTTP **401 "Invalid Authentication"**. Root cause is an invalid key; a discovered id is moot until auth is fixed.

---

## EVIDENCE APPENDIX (real captured output)

### Environment / key presence (.env, names only)
```
$ grep -oE '^[A-Z_]+_API_KEY' ~/helix-system/llmsverifier/.env | sort -u
... OPENROUTER_API_KEY, HYPERBOLIC_API_KEY, SILICONFLOW_API_KEY, ZAI_API_KEY, KIMI_API_KEY (all present) ...
SILICONFLOW key len: 51
KIMI key len: 72
```

### Verifier provider registry
```
$ podman run --rm --env-file ... llm-verifier-mv:nezha -list-providers
hyperbolic           llmsverifier_modelverify_provider_configured
siliconflow          llmsverifier_modelverify_provider_configured
openrouter           llmsverifier_modelverify_provider_configured
kimi                 llmsverifier_modelverify_provider_configured
zai                  llmsverifier_modelverify_provider_configured
```

### Model discovery (read-only curl)
```
=== OPENROUTER deepseek ids ===
"id":"deepseek/deepseek-chat-v3.1"
"id":"deepseek/deepseek-chat-v3-0324"
"id":"deepseek/deepseek-chat"
=== HYPERBOLIC Llama ids ===
"id":"meta-llama/Llama-3.3-70B-Instruct"
(hyperbolic raw status): 200
=== ZAI glm ids ===
{"object":"list","data":[{"id":"glm-4.5",...},{"id":"glm-4.5-air",...},{"id":"glm-4.6",...},{"id":"glm-4.7",...
=== SILICONFLOW /models ===  "Api key is invalid"   (HTTP 401)
=== KIMI /models ===  {"error":{"message":"Invalid Authentication","type":"invalid_authentication_error"}}  (HTTP 401, both .cn and .ai)
```

### openrouter
```
$ podman run --rm --env-file ... llm-verifier-mv:nezha -provider openrouter -model deepseek/deepseek-chat -verbose
🔍 Verifying specific model: deepseek/deepseek-chat from provider: openrouter
✅ Verification completed in 804.805326ms
Status: error
Can See Code: false
Verification Score: 0.00
Last Verified: 2026-06-16T15:37:53Z
Error: Meaningful response verification failed: API request failed: API request failed with status 402 (avg response time: 804ms) (response length: 0)
llmsverifier_modelverify_model_failed
```

### hyperbolic
```
$ podman run --rm --env-file ... llm-verifier-mv:nezha -provider hyperbolic -model meta-llama/Llama-3.3-70B-Instruct -verbose
🔍 Verifying specific model: meta-llama/Llama-3.3-70B-Instruct from provider: hyperbolic
✅ Verification completed in 444.746848ms
Status: error
Can See Code: false
Verification Score: 0.00
Last Verified: 2026-06-16T15:37:55Z
Error: Meaningful response verification failed: API request failed: API request failed with status 402 (avg response time: 444ms) (response length: 0)
llmsverifier_modelverify_model_failed
```

### siliconflow
```
$ podman run --rm --env-file ... llm-verifier-mv:nezha -provider siliconflow -model Qwen/Qwen2.5-7B-Instruct -verbose
🔍 Verifying specific model: Qwen/Qwen2.5-7B-Instruct from provider: siliconflow
✅ Verification completed in 441.683404ms
Status: error
Can See Code: false
Verification Score: 0.00
Last Verified: 2026-06-16T15:38:18Z
Error: Meaningful response verification failed: API request failed: API request failed with status 401 (avg response time: 441ms) (response length: 0)
llmsverifier_modelverify_model_failed
```

### zai
```
$ podman run --rm --env-file ... llm-verifier-mv:nezha -provider zai -model glm-4.6 -verbose
🔍 Verifying specific model: glm-4.6 from provider: zai
✅ Verification completed in 658.598413ms
Status: error
Can See Code: false
Verification Score: 0.00
Last Verified: 2026-06-16T15:38:02Z
Error: Meaningful response verification failed: API request failed: API request failed with status 429 (avg response time: 658ms) (response length: 0)
llmsverifier_modelverify_model_failed
```

### kimi
```
$ podman run --rm --env-file ... llm-verifier-mv:nezha -provider kimi -model moonshot-v1-8k -verbose
🔍 Verifying specific model: moonshot-v1-8k from provider: kimi
llmsverifier_modelverify_model_not_found

$ curl -s -o /dev/null -w 'kimi /models HTTP %{http_code}\n' -H "Authorization: Bearer $KIMI_API_KEY" https://api.moonshot.cn/v1/models
kimi /models HTTP 401
```
