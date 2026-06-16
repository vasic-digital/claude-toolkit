# Heavy-test sweep — consolidated summary

Real "Do you see my code?" verification runs against **live production LLM APIs**
through the deployed, auth-fixed `llm-verifier-mv:nezha` tool (keys from the
on-host mode-600 `.env`). Captured evidence only, no bluff. Run 2026-06-16.

## Verified (genuine PASS — Status: verified, Can See Code: true)

| Provider | Model | Score | Time |
|----------|-------|-------|------|
| DeepSeek | deepseek-chat | 0.78 | 11.5s |
| Groq | llama-3.3-70b-versatile | 0.98 | 4.0s |
| Mistral | mistral-small-latest | 0.88 | 7.7s |
| Cerebras | gpt-oss-120b (discovered) | 0.70 | — |
| Novita | meta-llama/llama-3.1-8b-instruct | 1.00 | 9.8s |
| NVIDIA | meta/llama-3.1-8b-instruct | 1.00 | 11.5s |

**6 distinct providers verified end-to-end** — proves the deployed System runs
real heavy testing against real production services.

## Honest failures (NOT verifier/infra defects unless noted)

| Provider | Result | Root cause |
|----------|--------|-----------|
| openrouter | HTTP 402 | account out of credits (model id valid) |
| hyperbolic | HTTP 402 | billing (after model-id retry) |
| siliconflow | HTTP 401 | key auth rejected |
| kimi | invalid auth | `KIMI_API_KEY` rejected on both .cn/.ai |
| zai | HTTP 429 | rate-limit/quota (routing OK with glm-4.6) |
| cohere | HTTP 405 | **upstream adapter defect**: tool posts `/chat/completions`; cohere v2 wants `/v2/chat` |
| fireworks / sambanova / huggingface | model_not_found | requested id not in the tool's discovered set (id-matching quirk) |

## Interpretation

- The Issue I auth fix is conclusively proven: 6 providers verify GREEN where
  every provider previously returned 401.
- The failures are predominantly **account-side** (billing/credits, key
  validity, quota) — i.e. real provider-account state, not defects in the
  deployed System.
- Two genuine upstream-tool findings remain: cohere's `/v2/chat` adapter shape
  (405) and the model-id discovery/matching strictness (model_not_found for
  ids the tool didn't itself discover). Both are upstream LLMsVerifier
  improvements, out of scope for this deployment.

Per-group detail: `sweep-group1.md` (mistral/cerebras/openrouter),
`sweep-group2.md` (zai/kimi/novita), `sweep-group3.md` (nvidia/siliconflow/
hyperbolic), `sweep-group4.md` (fireworks/sambanova/cohere/huggingface).
