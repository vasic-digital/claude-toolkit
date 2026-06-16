# LLM Verifier Sweep — Group 2

- **Date:** 2026-06-16
- **Host:** nezha.local (via SSH as `milosvasic`)
- **Runner:** `podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha ...`
- **Image:** `localhost/llm-verifier-mv:nezha` (id `76fe7a7e6ffe`, built ~55 min before run)
- **Scope:** read-only verification runs + read-only `/models` discovery curls. No deployed `llmsverifier_*` containers touched, no builds, no git ops.

## Results

| Provider | Model (requested → used)            | Status        | Can See Code | Score | Error |
|----------|-------------------------------------|---------------|--------------|-------|-------|
| zai      | glm-4-flash → glm-4.6 (retry)       | error         | false        | 0.00  | API request failed with status 429 (rate limit / quota) |
| kimi     | moonshot-v1-8k (retry blocked)      | not_found / unverifiable | n/a | n/a | Model not found; `/models` returns `Invalid Authentication` on both `.cn` and `.ai` — cannot retry |
| novita   | meta-llama/llama-3.1-8b-instruct    | verified      | true         | 1.00  | — (passed) |

### Honest verdicts

- **novita / meta-llama/llama-3.1-8b-instruct — PASS.** Genuine verified run, score 1.00, `Can See Code: true`, completed in 9.82s. Real working credential + model.
- **zai / glm-4-flash — FAIL (model invalid; valid model rate-limited).** Requested `glm-4-flash` does not exist on the account (`model_not_found`). `/models` lists current ids (glm-4.5, glm-4.5-air, glm-4.6, glm-4.7, glm-5, ...) — no `glm-4-flash`. Retried once with a valid id (`glm-4.6`): credential and routing work (request reached the API), but it returned HTTP 429. Verdict: cannot confirm a passing verification; provider is configured/reachable but quota/rate-limited at test time.
- **kimi / moonshot-v1-8k — UNVERIFIABLE (auth failure).** Requested model `model_not_found`. The single configured `KIMI_API_KEY` is rejected with `Invalid Authentication` on both `https://api.moonshot.cn/v1/models` and `https://api.moonshot.ai/v1/models`, so no valid model id could be discovered for the one-shot retry. Verdict: kimi credential appears invalid/expired; provider cannot be verified.

## EVIDENCE Appendix (real captured output)

### Connectivity / image check
```
$ ssh milosvasic@nezha.local 'echo CONNECTED; podman images | grep -i llm-verifier-mv'
CONNECTED
localhost/llm-verifier-mv                     nezha               76fe7a7e6ffe  55 minutes ago     31.8 MB
```

### zai — first attempt (glm-4-flash)
```
$ podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha --provider zai --model glm-4-flash --verbose
llmsverifier_modelverify_banner
================================================================================

🔍 Verifying specific model: glm-4-flash from provider: zai
------------------------------------------------------------
llmsverifier_modelverify_model_not_found
```

### zai — /models discovery (read-only curl)
```
$ curl -s -m10 -H "Authorization: Bearer ${ZAI_API_KEY}" https://open.bigmodel.cn/api/paas/v4/models
{"object":"list","data":[{"id":"glm-4.5",...},{"id":"glm-4.5-air",...},{"id":"glm-4.6",...},
{"id":"glm-4.7",...},{"id":"glm-5",...},{"id":"glm-5-turbo",...},{"id":"glm-5.1",...},{"id":"glm-5.2",...}]}
```
(No `glm-4-flash` present.)

### zai — retry (glm-4.6)
```
$ podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha --provider zai --model glm-4.6 --verbose
✅ Verification completed in 610.245737ms
Status: error
Can See Code: false
Affirmative Response: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with status 429 (avg response time: 610ms) (response length: 0)
llmsverifier_modelverify_model_failed
```

### kimi — first attempt (moonshot-v1-8k)
```
$ podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha --provider kimi --model moonshot-v1-8k --verbose
llmsverifier_modelverify_banner
================================================================================

🔍 Verifying specific model: moonshot-v1-8k from provider: kimi
------------------------------------------------------------
llmsverifier_modelverify_model_not_found
```

### kimi — /models discovery (read-only curl, both endpoints)
```
$ curl -s -m10 -H "Authorization: Bearer ${KIMI_API_KEY}" https://api.moonshot.cn/v1/models
{"error":{"message":"Invalid Authentication","type":"invalid_authentication_error"}}

$ curl -s -m10 -H "Authorization: Bearer ${KIMI_API_KEY}" https://api.moonshot.ai/v1/models
{"error":{"message":"Invalid Authentication","type":"invalid_authentication_error"}}
```
(env confirms a single `KIMI_API_KEY` is defined; no separate base/key vars. Retry not possible — no discoverable valid model id.)

### novita — meta-llama/llama-3.1-8b-instruct
```
$ podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha --provider novita --model meta-llama/llama-3.1-8b-instruct --verbose
✅ Verification completed in 9.815598625s
Status: verified
Can See Code: true
Affirmative Response: true
Verification Score: 1.00
llmsverifier_modelverify_model_passed
```
