# Provider Aliases — Diagrams

Mermaid sources for the `claude-providers` feature. Render with any Mermaid
tool (e.g. `mmdc`, the GitHub viewer, or the doc export pipeline).

## 1. Component architecture

```mermaid
flowchart TB
  subgraph Inputs["Inputs (no hardcoding)"]
    KEYS["~/api_keys.sh\n(key var NAMES)"]
    MDEV["models.dev/api.json\n(catalog: api, npm, models)"]
    KA["providers/key-aliases.json\n(name normalization)"]
    OV["providers/overrides.json\n(per-provider pins)"]
  end

  subgraph Engine["claude-providers"]
    CP["claude-providers.sh\n(sync/list/show/remove/add)"]
    RES["providers_resolve.py\n(dynamic resolver)"]
    VER["providers-verify.sh\n(LLMsVerifier | HTTP probe)"]
    LIB["lib.sh helpers\n(env/alias/link/enable)"]
  end

  subgraph Verifier["submodules/LLMsVerifier (optional)"]
    BIN["bin/model-verification"]
  end

  subgraph Outputs
    ENV["providers/<id>.env\n(non-secret)"]
    ALIAS["aliases.sh\n(alias <name>=cma_run_provider <id>)"]
    DIR["~/.claude-prov-<id>\n(shared items symlinked)"]
    CCR["~/.claude-code-router/config.json\n(router providers, at launch)"]
  end

  KEYS --> CP
  MDEV --> RES
  KA --> RES
  OV --> RES
  CP --> RES
  CP --> VER
  VER -.uses if built.-> BIN
  CP --> LIB
  LIB --> ENV
  LIB --> ALIAS
  LIB --> DIR
  CP --> CCR
```

## 2. `sync` pipeline

```mermaid
flowchart LR
  A["read key var NAMES\n(grep, no exec)"] --> B["fetch + cache\nmodels.dev (TTL)"]
  B --> C["resolve per key\n(provider, models, transport)"]
  C --> D{classification}
  D -- vcs/infra --> S1["skip"]
  D -- no match --> S2["unmapped\n(log, retry next run)"]
  D -- llm match --> E["dedupe by provider_id"]
  E --> F{verify?}
  F -- failed --> S3["disabled\n(alias NOT activated)"]
  F -- verified/unverified --> G["write env + alias\n+ link config dir"]
  G --> H["enable always-on plugins\n(shared settings)"]
```

## 3. Launch data flow (`cma_run_provider`)

```mermaid
sequenceDiagram
  participant U as User shell
  participant W as cma_run_provider
  participant K as ~/api_keys.sh
  participant C as claude / ccr
  U->>W: dseek  (alias)
  W->>W: source providers/<id>.env (non-secret)
  W->>K: source keys file (secret in-memory only)
  alt native transport
    W->>C: claude  (ANTHROPIC_BASE_URL/AUTH_TOKEN/MODEL/SMALL_FAST_MODEL)
  else router transport
    W->>W: upsert provider into ccr config (chmod 600, live key)
    W->>C: ccr code  (translates Anthropic<->OpenAI/Gemini)
  end
  C-->>U: Claude Code session on the provider's models
```
