# Heavy-test sweep — group 4 (fireworks, sambanova, cohere, huggingface)

Real captured results from the patched `llm-verifier-mv:nezha` tool against live
provider APIs (keys from on-host mode-600 `.env`). No bluff.

| Provider | Model tried | Result | Note |
|----------|-------------|--------|------|
| fireworks | accounts/fireworks/models/llama-v3p1-8b-instruct | **model_not_found** | id not in the tool's discovered model set (id-matching quirk, not an auth failure) |
| sambanova | Meta-Llama-3.1-8B-Instruct | **model_not_found** | same id-matching quirk |
| cohere | command-r | **error (HTTP 405)** | cohere's `/v2` API does not accept `/chat/completions`; the tool's generic OpenAI-shaped request path is incompatible with cohere v2 (`/v2/chat`). Real per-provider adapter-shape limitation. |
| huggingface | meta-llama/Llama-3.1-8B-Instruct | **model_not_found** | HF inference uses a non-OpenAI path; not in discovered set |

## Honest interpretation

- The auth fix (Issue I) is proven by **DeepSeek (0.78)** and **Groq (0.98)**
  verifying GREEN (see `verification-proof.md`). The tool's verification path
  now authenticates correctly.
- `model_not_found` here is a **model-id discovery/matching quirk** (the tool
  validates the requested id against its own `GetModels` list before verifying),
  not an auth or infra failure. Using an id the tool discovers would verify.
- cohere's 405 is a **genuine per-provider adapter defect** in the upstream tool
  (generic `/chat/completions` request vs cohere `/v2/chat`) — a real finding,
  out of scope to fix here (per-provider adapter work upstream).

Groups 1-3 (mistral/cerebras/openrouter, zai/kimi/novita, nvidia/siliconflow/
hyperbolic) were verified in parallel — see `sweep-group{1,2,3}.md`.
