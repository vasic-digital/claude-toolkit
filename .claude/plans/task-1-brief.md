# Task 1 — Config: register Xiaomi MiMo provider in key-aliases.json + overrides.json

## Where this fits
This repo (`claude_tookit`) has a dynamic provider-alias generator. A provider is
added purely via two JSON config files (never code). Xiaomi MiMo's key-var name
(`XIAOMI_MIMO_API_KEY`) does not match the models.dev `xiaomi` provider's env entry
(`XIAOMI_API_KEY`), so a key-alias bridges it; and Xiaomi has a real Anthropic-native
endpoint, so it gets pinned to native transport. This is the exact pattern used for
Z.AI (v1.2.0) and DeepSeek.

## Exact changes to make

### File 1: scripts/providers/key-aliases.json
Current content is:
```json
{
  "ZAI_API_KEY": "zai-coding-plan",
  "CODESTRAL_API_KEY": "mistral",
  "HUGGINGFACE_API_KEY": "huggingface",
  "GITHUB_MODELS_API_KEY": "github-models",
  "TENCENT_CLOUD_API_KEY": "tencent-tokenhub"
}
```
Add ONE entry `"XIAOMI_MIMO_API_KEY": "xiaomi"`. Keep all existing entries. Result:
```json
{
  "ZAI_API_KEY": "zai-coding-plan",
  "CODESTRAL_API_KEY": "mistral",
  "HUGGINGFACE_API_KEY": "huggingface",
  "GITHUB_MODELS_API_KEY": "github-models",
  "TENCENT_CLOUD_API_KEY": "tencent-tokenhub",
  "XIAOMI_MIMO_API_KEY": "xiaomi"
}
```

### File 2: scripts/providers/overrides.json
Current content is:
```json
{
  "deepseek": {
    "transport": "native",
    "base_url": "https://api.deepseek.com/anthropic",
    "strong_model": "deepseek-chat",
    "fast_model": "deepseek-chat"
  },
  "zai-coding-plan": {
    "strong_model": "glm-5.2",
    "fast_model": "glm-4.7"
  }
}
```
Add a `xiaomi` section. Keep existing sections byte-for-byte. Result:
```json
{
  "deepseek": {
    "transport": "native",
    "base_url": "https://api.deepseek.com/anthropic",
    "strong_model": "deepseek-chat",
    "fast_model": "deepseek-chat"
  },
  "zai-coding-plan": {
    "strong_model": "glm-5.2",
    "fast_model": "glm-4.7"
  },
  "xiaomi": {
    "transport": "native",
    "base_url": "https://api.xiaomimimo.com/anthropic",
    "strong_model": "mimo-v2.5-pro",
    "fast_model": "mimo-v2-flash"
  }
}
```

## Exact values to use verbatim (do NOT paraphrase or "improve")
- key-aliases key: `XIAOMI_MIMO_API_KEY`  value: `xiaomi`
- overrides section key: `xiaomi`
- transport: `native`
- base_url: `https://api.xiaomimimo.com/anthropic`
- strong_model: `mimo-v2.5-pro`
- fast_model: `mimo-v2-flash`

## Global constraints (binding)
- Do NOT touch any other file. No code changes. Config-only.
- Preserve the existing entries in both files exactly.
- Valid JSON (2-space indent, matching the existing style), trailing newline.

## Validation you MUST run and paste into your report
1. `jq . scripts/providers/key-aliases.json` parses; `jq -r '.XIAOMI_MIMO_API_KEY'` prints `xiaomi`.
2. `jq . scripts/providers/overrides.json` parses; `jq '.xiaomi'` prints the new block.
3. Resolver check against the LIVE cached catalog (this proves the wiring end-to-end):
   ```bash
   CACHE="$(scripts/claude-providers.sh --help >/dev/null 2>&1; echo $HOME/.local/share/claude-multi-account/providers/models.dev.cache.json)"
   python3 scripts/providers_resolve.py \
     --models-dev "$CACHE" \
     --key-aliases scripts/providers/key-aliases.json \
     --overrides scripts/providers/overrides.json \
     --keys XIAOMI_MIMO_API_KEY \
     --only xiaomi
   ```
   If the cache doesn't exist yet, fetch it first:
   `curl -s https://models.dev/api.json -o "$HOME/.local/share/claude-multi-account/providers/models.dev.cache.json"` (mkdir -p the dir first).
   The output record MUST show: `"status": "resolved"`, `"provider_id": "xiaomi"`,
   `"transport": "native"`, `"base_url": "https://api.xiaomimimo.com/anthropic"`,
   `"strong_model": "mimo-v2.5-pro"`, `"fast_model": "mimo-v2-flash"`. Paste this JSON.

## Commit
`feat(providers): add Xiaomi MiMo provider alias (native transport)`
Stage ONLY the two JSON files. End the commit message with:
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>

## Report
Write your full report to /Volumes/T7/Projects/claude_tookit/.claude/plans/task-1-report.md
(sections: Changes, Validation [paste the jq + resolver outputs], Commit [the hash]).
Return ONLY: status word (DONE/DONE_WITH_CONCERNS/BLOCKED), the commit hash, and a
one-line summary. Do not paste the full report into your final message.
