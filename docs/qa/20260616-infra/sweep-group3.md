# LLM Verifier Sweep — Group 3

**Date:** 2026-06-16
**Host:** nezha.local (via SSH as `milosvasic`)
**Runner:** `podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha`
**Image:** `localhost/llm-verifier-mv:nezha` (id `76fe7a7e6ffe`)
**Constraints honored:** read-only curl/podman only; no deployed `llmsverifier_*` containers touched; no builds; no git ops.

## Results

| Provider | Model | Status | CanSeeCode | Score | Error |
|---|---|---|---|---|---|
| nvidia | meta/llama-3.1-8b-instruct | verified | true | 1.00 | — |
| siliconflow | Qwen/Qwen2.5-7B-Instruct | error | false | 0.00 | API request failed with status 401 (auth) |
| hyperbolic | meta-llama/Meta-Llama-3.1-8B-Instruct → meta-llama/Llama-3.3-70B-Instruct | error | false | 0.00 | requested model not found; retried with valid id → status 402 (payment required) |

## Verdicts (honest)

- **nvidia / meta/llama-3.1-8b-instruct** — PASS. Genuinely verified, score 1.00, model affirmatively saw the code. Completed in ~11.5s.
- **siliconflow / Qwen/Qwen2.5-7B-Instruct** — FAIL. HTTP 401 from the SiliconFlow API. This is an authentication/credential failure (invalid or missing `SILICONFLOW_API_KEY`), not a model problem. Per protocol, 401 is not model-not-found, so no model-id retry was attempted.
- **hyperbolic / meta-llama/Meta-Llama-3.1-8B-Instruct** — FAIL. The originally requested id is not offered by Hyperbolic (verifier reported `model_not_found`; the provider `/v1/models` list does not contain any Llama 3.1 8B). Retried ONCE with the closest valid Llama instruct id `meta-llama/Llama-3.3-70B-Instruct`, which returned HTTP 402 (Payment Required) — a billing/credits failure, not a model or auth issue. Verdict remains FAIL.

## Evidence Appendix (real captured output)

### Environment checks

```
$ ssh milosvasic@nezha.local 'echo SSH_OK; podman images | grep -i llm-verifier-mv'
SSH_OK
localhost/llm-verifier-mv                     nezha               76fe7a7e6ffe  55 minutes ago     31.8 MB
```

### nvidia / meta/llama-3.1-8b-instruct

```
$ podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha \
    --provider nvidia --model meta/llama-3.1-8b-instruct --verbose
✅ Verification completed in 11.463668807s
Status: verified
Can See Code: true
Affirmative Response: true
Verification Score: 1.00
llmsverifier_modelverify_model_passed
```

### siliconflow / Qwen/Qwen2.5-7B-Instruct

```
$ podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha \
    --provider siliconflow --model Qwen/Qwen2.5-7B-Instruct --verbose
✅ Verification completed in 748.295698ms
Status: error
Can See Code: false
Affirmative Response: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with status 401 (avg response time: 748ms) (response length: 0)
llmsverifier_modelverify_model_failed
```

### hyperbolic / meta-llama/Meta-Llama-3.1-8B-Instruct (first attempt — model not found)

```
$ podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha \
    --provider hyperbolic --model meta-llama/Meta-Llama-3.1-8B-Instruct --verbose
llmsverifier_modelverify_banner
================================================================================

🔍 Verifying specific model: meta-llama/Meta-Llama-3.1-8B-Instruct from provider: hyperbolic
------------------------------------------------------------
llmsverifier_modelverify_model_not_found
```

### hyperbolic — provider model discovery (read-only curl)

```
$ set -a; . ~/helix-system/llmsverifier/.env; set +a; \
  curl -s -m10 -H "Authorization: Bearer ${HYPERBOLIC_API_KEY}" https://api.hyperbolic.xyz/v1/models
(model ids returned:)
deepseek-ai/DeepSeek-V3-0324
meta-llama/Llama-3.3-70B-Instruct
deepseek-ai/DeepSeek-R1
deepseek-ai/DeepSeek-R1-0528
Qwen/Qwen3-Coder-480B-A35B-Instruct
```

No Llama 3.1 8B variant is offered. Closest valid Llama instruct id: `meta-llama/Llama-3.3-70B-Instruct`.

### hyperbolic / meta-llama/Llama-3.3-70B-Instruct (single retry with valid id)

```
$ podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha \
    --provider hyperbolic --model meta-llama/Llama-3.3-70B-Instruct --verbose
✅ Verification completed in 455.44328ms
Status: error
Can See Code: false
Affirmative Response: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with status 402 (avg response time: 455ms) (response length: 0)
llmsverifier_modelverify_model_failed
```
