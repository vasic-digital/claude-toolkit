# LLM Verifier Sweep — Group 1

- Date: 2026-06-16
- Host: nezha.local (via SSH as `milosvasic`)
- Tool: `podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha --provider <P> --model <M> --verbose`
- Rule: a row is marked **verified** only if the tool printed `Status: verified`.

## Results

| provider   | model                  | Status   | CanSeeCode | Score | Error (if any) |
|------------|------------------------|----------|------------|-------|----------------|
| mistral    | mistral-small-latest   | verified | true       | 0.88  | —              |
| cerebras   | gpt-oss-120b (fallback)| verified | true       | 0.70  | —              |
| openrouter | deepseek/deepseek-chat | error    | false      | 0.00  | API 402 (out of credits / payment required) |

### Notes

- **cerebras**: the requested model `llama3.1-8b` returned `model_not_found`
  (no `Status:` line emitted). The provider `/v1/models` endpoint lists only
  `zai-glm-4.7` and `gpt-oss-120b` for this account — no llama3.1 model exists.
  Per the one-fallback rule, re-ran once with `gpt-oss-120b`, which returned
  `Status: verified` (score 0.70; note `Affirmative Response: false`, so the
  tool's own pass/fail tally printed `model_failed` despite the verified status).
- **openrouter**: model id `deepseek/deepseek-chat` is valid (confirmed present
  in `/api/v1/models`). The failure is an account-level **HTTP 402** (payment
  required / no credits), NOT a model-not-found/404 — so the model-id fallback
  does not apply. Recorded honestly as **error**.

---

## EVIDENCE Appendix (real captured tool output)

### 1. mistral / mistral-small-latest — VERIFIED

Command:
```
ssh milosvasic@nezha.local 'podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha --provider mistral --model mistral-small-latest --verbose 2>&1 | grep -iE "Status:|Can See Code:|Affirmative|Score:|Error:|completed in|passed|failed"'
```
Output:
```
✅ Verification completed in 7.699389475s
Status: verified
Can See Code: true
Affirmative Response: true
Verification Score: 0.88
llmsverifier_modelverify_model_passed
```

### 2. cerebras / llama3.1-8b — MODEL NOT FOUND (triggered fallback)

Command:
```
ssh milosvasic@nezha.local 'podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha --provider cerebras --model llama3.1-8b --verbose 2>&1 | tail -30'
```
Output (grep with Status filter returned nothing / exit 1; full tail shown):
```
llmsverifier_modelverify_banner
================================================================================

🔍 Verifying specific model: llama3.1-8b from provider: cerebras
------------------------------------------------------------
llmsverifier_modelverify_model_not_found
```

Fallback — query provider /models to find a valid id:
```
ssh milosvasic@nezha.local 'set -a; . ~/helix-system/llmsverifier/.env; set +a; curl -s -m10 -H "Authorization: Bearer ${CEREBRAS_API_KEY}" https://api.cerebras.ai/v1/models'
```
Output:
```
{"object":"list","data":[{"id":"zai-glm-4.7","object":"model","created":0,"owned_by":"Cerebras"},{"id":"gpt-oss-120b","object":"model","created":0,"owned_by":"Cerebras"}]}
```

### 2b. cerebras / gpt-oss-120b (fallback re-run) — VERIFIED

Command:
```
ssh milosvasic@nezha.local 'podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha --provider cerebras --model gpt-oss-120b --verbose 2>&1 | grep -iE "Status:|Can See Code:|Affirmative|Score:|Error:|completed in|passed|failed"'
```
Output:
```
✅ Verification completed in 3.27439364s
Status: verified
Can See Code: true
Affirmative Response: false
Verification Score: 0.70
llmsverifier_modelverify_model_failed
```

### 3. openrouter / deepseek/deepseek-chat — ERROR (HTTP 402)

Command:
```
ssh milosvasic@nezha.local 'podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha --provider openrouter --model deepseek/deepseek-chat --verbose 2>&1 | grep -iE "Status:|Can See Code:|Affirmative|Score:|Error:|completed in|passed|failed"'
```
Output:
```
✅ Verification completed in 414.23727ms
Status: error
Can See Code: false
Affirmative Response: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with status 402 (avg response time: 414ms) (response length: 0)
llmsverifier_modelverify_model_failed
```

Model-id validity check (confirms 402 is NOT a model-not-found, so no fallback):
```
ssh milosvasic@nezha.local 'set -a; . ~/helix-system/llmsverifier/.env; set +a; curl -s -m10 -H "Authorization: Bearer ${OPENROUTER_API_KEY}" https://openrouter.ai/api/v1/models | tr "," "\n" | grep -i "deepseek/deepseek-chat\"" | head -5'
```
Output:
```
{"id":"deepseek/deepseek-chat"
```
