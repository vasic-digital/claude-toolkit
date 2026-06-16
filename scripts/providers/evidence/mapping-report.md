# models.dev Provider-Alias Mapping Report

All data in this report was derived from a LIVE fetch of `https://models.dev/api.json`. No values were fabricated.

## Raw counts

- api.json size: 2,354,151 bytes (2.25 MB)
- providers in api.json: 145
- total key vars extracted from api_keys.sh: 39
- LLM-classified keys: 33
- LLM keys matched to a models.dev provider: 24
- native transport: 4  (deepseek, kimi-for-coding, zhipuai, zai)
- router transport: 20
- LLM keys NOT mappable: 9  (HYPERBOLIC_API_KEY, SAMBANOVA_API_KEY, REPLICATE_API_KEY, VERTEX_API_KEY, PUBLICAI_API_KEY, VULAVULA_API_KEY, NIA_API_KEY, NLP_API_KEY, JUNIE_API_KEY)

## Full key table

| Key var | Class | Provider id | Verified in api.json | Strong model | Fast model | Transport |
|---|---|---|---|---|---|---|
| CEREBRAS_API_KEY | llm | cerebras | yes | zai-glm-4.7 | gpt-oss-120b | router |
| CHUTES_API_KEY | llm | chutes | yes | tngtech/DeepSeek-TNG-R1T2-Chimera-TEE | NousResearch/Hermes-4-14B | router |
| CODESTRAL_API_KEY | llm | mistral | yes | mistral-medium-2604 | labs-devstral-small-2512 | router |
| COHERE_API_KEY | llm | cohere | yes | north-mini-code-1-0 | north-mini-code-1-0 | router |
| DEEPSEEK_API_KEY | llm | deepseek | yes | deepseek-v4-pro | deepseek-v4-flash | native |
| FIREWORKS_API_KEY | llm | fireworks-ai | yes | accounts/fireworks/models/minimax-m3 | accounts/fireworks/models/gpt-oss-20b | router |
| GEMINI_API_KEY | llm | google | yes | gemini-3.5-flash | gemini-2.0-flash-lite | router |
| GITHUB_MODELS_API_KEY | llm | github-models | yes | deepseek/deepseek-r1-0528 | ai21-labs/ai21-jamba-1.5-mini | router |
| GROQ_API_KEY | llm | groq | yes | openai/gpt-oss-safeguard-20b | llama-3.1-8b-instant | router |
| HUGGINGFACE_API_KEY | llm | huggingface | yes | deepseek-ai/DeepSeek-V4-Pro | zai-org/GLM-4.7-Flash | router |
| HYPERBOLIC_API_KEY | llm | — | no | — | — | — |
| INFERENCE_API_KEY | llm | inference | yes | google/gemma-3 | meta/llama-3.2-1b-instruct | router |
| JUNIE_API_KEY | llm | — | no | — | — | — |
| KILO_API_KEY | llm | kilo | yes | x-ai/grok-build-0.1 | kilo-auto/free | router |
| KIMI_API_KEY | llm | kimi-for-coding | yes | k2p7 | k2p7 | native |
| MISTRAL_API_KEY | llm | mistral | yes | mistral-medium-2604 | labs-devstral-small-2512 | router |
| NIA_API_KEY | llm | — | no | — | — | — |
| NLP_API_KEY | llm | — | no | — | — | — |
| NOVITA_API_KEY | llm | novita-ai | yes | qwen/qwen3.7-max | inclusionai/ling-2.6-1t | router |
| NVIDIA_API_KEY | llm | nvidia | yes | nvidia/nemotron-3-ultra-550b-a55b | moonshotai/kimi-k2-instruct-0905 | router |
| OPENROUTER_API_KEY | llm | openrouter | yes | moonshotai/kimi-k2.7-code | meta-llama/llama-3.3-70b-instruct:free | router |
| PUBLICAI_API_KEY | llm | — | no | — | — | — |
| REPLICATE_API_KEY | llm | — | no | — | — | — |
| SAMBANOVA_API_KEY | llm | — | no | — | — | — |
| SARVAM_API_KEY | llm | sarvam | yes | sarvam-105b | sarvam-105b | router |
| SILICONFLOW_API_KEY | llm | siliconflow | yes | deepseek-ai/deepseek-v4-pro | tencent/Hunyuan-MT-7B | router |
| TENCENT_CLOUD_API_KEY | llm | tencent-tokenhub | yes | hy3-preview | hy3-preview | router |
| UPSTAGE_API_KEY | llm | upstage | yes | solar-pro3 | solar-mini | router |
| VENICE_API_KEY | llm | venice | yes | minimax-m3-preview | tencent-hy3-preview | router |
| VERTEX_API_KEY | llm | — | no | — | — | — |
| VULAVULA_API_KEY | llm | — | no | — | — | — |
| ZAI_API_KEY | llm | zai | yes | glm-5v-turbo | glm-4.7-flash | native |
| ZHIPU_API_KEY | llm | zhipuai | yes | glm-5v-turbo | glm-4.5-flash | native |
| GITFLIC_TOKEN | vcs | — | no | — | — | — |
| GITLAB_TOKEN | vcs | gitlab | yes | — | — | — |
| GITVERSE_TOKEN | vcs | — | no | — | — | — |
| CLOUDFLARE_API_KEY | infra | cloudflare-workers-ai | yes | @cf/moonshotai/kimi-k2.7-code | @cf/ibm-granite/granite-4.0-h-micro | router |
| FIRBASE_CLI_TOKEN | infra | — | no | — | — | — |
| MODAL_API_KEY | infra | — | no | — | — | — |

## Base URL + transport detail (matched LLM providers)

| Provider id | base_url (api) | npm | transport |
|---|---|---|---|
| cerebras | — | @ai-sdk/cerebras | router |
| chutes | https://llm.chutes.ai/v1 | @ai-sdk/openai-compatible | router |
| cohere | — | @ai-sdk/cohere | router |
| deepseek | https://api.deepseek.com | @ai-sdk/openai-compatible | native |
| fireworks-ai | https://api.fireworks.ai/inference/v1/ | @ai-sdk/openai-compatible | router |
| google | — | @ai-sdk/google | router |
| groq | — | @ai-sdk/groq | router |
| inference | https://inference.net/v1 | @ai-sdk/openai-compatible | router |
| kilo | https://api.kilo.ai/api/gateway | @ai-sdk/openai-compatible | router |
| kimi-for-coding | https://api.kimi.com/coding/v1 | @ai-sdk/anthropic | native |
| mistral | — | @ai-sdk/mistral | router |
| novita-ai | https://api.novita.ai/openai | @ai-sdk/openai-compatible | router |
| nvidia | https://integrate.api.nvidia.com/v1 | @ai-sdk/openai-compatible | router |
| openrouter | https://openrouter.ai/api/v1 | @openrouter/ai-sdk-provider | router |
| sarvam | https://api.sarvam.ai/v1 | @ai-sdk/openai-compatible | router |
| siliconflow | https://api.siliconflow.com/v1 | @ai-sdk/openai-compatible | router |
| upstage | https://api.upstage.ai/v1/solar | @ai-sdk/openai-compatible | router |
| venice | — | venice-ai-sdk-provider | router |
| zhipuai | https://open.bigmodel.cn/api/paas/v4 | @ai-sdk/openai-compatible | native |
| zai | https://api.z.ai/api/paas/v4 | @ai-sdk/openai-compatible | native |
| mistral | — | @ai-sdk/mistral | router |
| huggingface | https://router.huggingface.co/v1 | @ai-sdk/openai-compatible | router |
| github-models | https://models.github.ai/inference | @ai-sdk/openai-compatible | router |
| tencent-tokenhub | https://tokenhub.tencentmaas.com/v1 | @ai-sdk/openai-compatible | router |

## Key vars whose name differs from the models.dev `env` name (key-aliases.json)

| Key var | mapped provider_id | provider's real env |
|---|---|---|
| ZAI_API_KEY | zai | ZHIPU_API_KEY |
| CODESTRAL_API_KEY | mistral | MISTRAL_API_KEY |
| HUGGINGFACE_API_KEY | huggingface | HF_TOKEN |
| GITHUB_MODELS_API_KEY | github-models | GITHUB_TOKEN |
| TENCENT_CLOUD_API_KEY | tencent-tokenhub | TENCENT_TOKENHUB_API_KEY |

## Keys that could not be mapped

These LLM keys have no provider in the live api.json (no id and no env match):

- HYPERBOLIC_API_KEY
- SAMBANOVA_API_KEY
- REPLICATE_API_KEY
- VERTEX_API_KEY (google-vertex exists but authenticates via GOOGLE_VERTEX_* service-account vars, not an API key)
- PUBLICAI_API_KEY
- VULAVULA_API_KEY
- NIA_API_KEY
- NLP_API_KEY
- JUNIE_API_KEY

## Notes on resolution decisions

- KIMI_API_KEY resolves to `kimi-for-coding`, whose real `env` array IS `KIMI_API_KEY` (exact match) and whose `api` uses the `@ai-sdk/anthropic` npm transport → native. (The task's tentative KIMI→moonshot guess was overridden by the real data.)
- ZHIPU_API_KEY exactly matches the `env` of provider `zhipuai`. ZAI_API_KEY has no exact env (upstream `zai` also lists ZHIPU_API_KEY) so it is recorded as an alias → `zai`.
- CODESTRAL_API_KEY → `mistral` (Codestral is a Mistral model family; no standalone provider).
- TENCENT_CLOUD_API_KEY → `tencent-tokenhub` (generic Tencent endpoint; the only non-coding-plan Tencent provider).
- CLOUDFLARE_API_KEY maps to provider `cloudflare-workers-ai` in models.dev but is classified `infra` per the task rules, so it is excluded from llm aliasing.
- native = api endpoint contains `/anthropic` OR provider in {deepseek, moonshotai, zhipu/zai, kimi-for-coding}; else router.
