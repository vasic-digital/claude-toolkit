# LLMsVerifier integration notes

Integration research for incorporating **vasic-digital/LLMsVerifier** (a Go LLM
verification platform) as a git submodule of this repo, and invoking it to
verify a provider's API key plus that a given model exists / responds.

All facts below are quoted from files retrieved via `gh api` against
`vasic-digital/LLMsVerifier` (default branch `main`) on 2026-06-16. Raw command
outputs are in the EVIDENCE appendix.

> Caveat: LLMsVerifier's own `go.mod` declares it is designed to be checked out
> "as a submodule of HelixAgent (which is the only supported layout)" and
> `require digital.vasic.challenges => ../challenges` — a sibling repo. A
> standalone build of the **full** module tree therefore needs `../challenges`
> too. The targeted `model-verification` binary builds from a narrower package
> set; see "Build" caveats below.

---

## 1. Repository facts

| Field | Value |
| --- | --- |
| Clone URL (https) | `https://github.com/vasic-digital/LLMsVerifier.git` |
| Clone URL (ssh) | `git@github.com:vasic-digital/LLMsVerifier.git` |
| Default branch | `main` |
| Description | "Benchmark and verify LLMs" |
| Module path | `llmsverifier` (Go), `go 1.25.3` (per `go.mod`) |
| Inner module | `digital.vasic.llmsverifier => ./llm-verifier` (replace directive) |

Source of truth for cross-account env / config lives under `llm-verifier/`.

---

## 2. Submodule add command

Recommended path: `submodules/LLMsVerifier`.

```bash
git submodule add -b main git@github.com:vasic-digital/LLMsVerifier.git submodules/LLMsVerifier
git submodule update --init --recursive submodules/LLMsVerifier
```

(Use the https URL `https://github.com/vasic-digital/LLMsVerifier.git` if SSH
keys are not available on the host.)

Default branch to pin: **`main`**.

---

## 3. Build

### Build system

Top-level `Makefile` `build` target (exact):

```make
LOAD_KEYS := if [ -f scripts/load_api_keys.sh ]; then . scripts/load_api_keys.sh; fi

build: ## Build the application
	@$(LOAD_KEYS); go build -o bin/llm-verifier ./cmd
```

So the primary build is:

```bash
make build          # -> ./bin/llm-verifier   (root CLI; config.yaml-driven)
```

Resulting binary: **`bin/llm-verifier`** (relative to the LLMsVerifier repo
root). `go.mod` shows `replace digital.vasic.llmsverifier => ./llm-verifier`, and
`./cmd` resolves to `llm-verifier/cmd/main.go`.

### The targeted verification binary

The root `llm-verifier` CLI is config-driven (it loads `config.yaml`, runs
`verifier.Verify()`, writes Markdown + JSON reports). For the specific goal
"verify a provider key + that a model exists/responds" there is a dedicated
entrypoint with `--provider` / `--model` flags:

`llm-verifier/cmd/model-verification/main.go`

The README documents building/invoking it as `model-verification`:

```bash
# Run model verification
./llm-verifier/cmd/model-verification/model-verification --verify-all
# Verify specific provider
./model-verification --provider openai
```

Build it explicitly (no dedicated Makefile target exists for it, so build the
package directly):

```bash
# from the LLMsVerifier repo root
go build -o bin/model-verification ./llm-verifier/cmd/model-verification
```

### Build caveats (Go toolchain required)

- **Yes — a full build requires the Go toolchain.** `go.mod` declares
  `go 1.25.3`; the README "Prerequisites" say `Go 1.21+` and `SQLite3`
  (`github.com/mattn/go-sqlite3` is a dependency → cgo / a C compiler is pulled
  in for the DB-backed paths).
- `go.mod` has `replace digital.vasic.challenges => ../challenges`. Building the
  full module (e.g. `make build`, `go test ./...`) requires the sibling
  `../challenges` repo to be present, or those packages to be excluded. Building
  only `./llm-verifier/cmd/model-verification` avoids the `challenges` test
  packages but still depends on `digital.vasic.llmsverifier` (in-tree via the
  replace), so it should compile from a plain submodule checkout. **This must be
  validated on the host once the submodule is added** — treat a failed
  `model-verification` build as the trigger for the wrapper's `unverified`
  status (see §6).

---

## 4. The verify invocation

### Targeted single-model verification (best fit for the goal)

`llm-verifier/cmd/model-verification/main.go` flags (verbatim from source):

```go
configPath          = flag.String("config", "", "Path to configuration file")
outputDir           = flag.String("output", "./verified-configs", "Output directory ...")
verifyAll           = flag.Bool("verify-all", false, "Verify all available models")
provider            = flag.String("provider", "", "Specific provider to verify (e.g., openai, anthropic)")
model               = flag.String("model", "", "Specific model to verify")
disableVerification = flag.Bool("no-verify", false, "Disable verification (for testing)")
strictMode          = flag.Bool("strict", true, "Enable strict mode (only verified models are usable)")
listProviders       = flag.Bool("list-providers", false, "List all available providers")
statistics          = flag.Bool("stats", false, "Show verification statistics")
verbose             = flag.Bool("verbose", false, "Enable verbose logging")
```

Dispatch logic (verbatim):

```go
if *model != "" && *provider != "" {
    verifySpecificModel(ctx, enhancedService, *provider, *model, logger)
} else if *provider != "" {
    verifyProviderModels(ctx, enhancedService, *provider, logger)
} else if *verifyAll {
    verifyAllModels(ctx, enhancedService, logger)
} else {
    generateVerifiedConfiguration(enhancedService, *outputDir, logger)
}
```

So the exact invocation to verify one provider key + one model:

```bash
./bin/model-verification --provider <provider_id> --model <model_id> --verbose
```

Providers are registered from environment variables, not flags:

```go
// Register all providers from environment variables
logger.Info("Registering all providers from environment variables", nil)
enhancedService.RegisterAllProviders()
```

i.e. the API key is supplied via the provider's env var (e.g. `OPENAI_API_KEY`,
`ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY` — see `config_full.yaml` for the full
list of `${..._API_KEY}` names), loaded by `scripts/load_api_keys.sh` (prefers
`$HOME/api_keys.sh`, falls back to `.env`).

### Config-driven verification (root CLI)

`make build` → `./bin/llm-verifier` reads `config.yaml`. Schema (from
`llm-verifier/config.yaml` + README quickstart + `config_full.yaml`):

```yaml
global:
  base_url: https://api.openai.com/v1
  max_retries: 3
  timeout: 30s
database:
  path: ./llm-verifier.db
  encryption_key: ''
llms:
  - name: "openai-gpt4"
    provider: "openai"
    api_key: "${OPENAI_API_KEY}"
    model: "gpt-4"
    enabled: true
model_verification:
  enabled: true
  strict_mode: true
  require_affirmative: true
  max_retries: 3
  timeout_seconds: 30
  min_verification_score: 0.7
```

Run: `./bin/llm-verifier --config config.yaml` (writes Markdown + JSON reports to
`--output`, default `./reports`).

For a scriptable single-key/single-model check, **prefer the
`model-verification` binary** — it takes `--provider`/`--model` directly and
prints a per-model verdict.

---

## 5. Pass/fail detection contract

**Important: pass/fail is conveyed on stdout, NOT via a distinct process exit
code.** `model-verification` only calls `os.Exit(1)` if the logger fails to
initialise; the verification result paths `return` after printing. Treat exit
code as "the tool ran", and parse stdout for the verdict.

`verifySpecificModel` prints (verbatim):

```go
fmt.Printf("Status: %s\n", result.VerificationStatus)
fmt.Printf("Can See Code: %t\n", result.CanSeeCode)
fmt.Printf("Affirmative Response: %t\n", result.AffirmativeResponse)
fmt.Printf("Verification Score: %.2f\n", result.VerificationScore)
...
// Determine overall result
if result.VerificationStatus == "verified" && result.CanSeeCode && result.AffirmativeResponse {
    fmt.Println("\n" + tr("llmsverifier_modelverify_model_passed"))
} else {
    fmt.Println("\n" + tr("llmsverifier_modelverify_model_failed"))
}
```

Parseable contract for a wrapper:

- **PASS** when stdout contains `Status: verified` AND `Can See Code: true` AND
  `Affirmative Response: true` (these three together are exactly the source's
  pass condition). The success path also prints a leading `✅ Verification
  completed in ...`.
- **FAIL / not-found** signals on stdout:
  - `❌ Error: <...>` (couldn't fetch models / provider error)
  - model-not-found message (when the requested `--model` is absent from the
    provider's discovered model list) — source: `targetModel == nil` branch
    prints `llmsverifier_modelverify_model_not_found`.
  - `❌ Verification failed: <...>`
  - the localized "model_failed" line when the three pass conditions are not all
    true.

Verification semantics (from `VERIFICATION_HOW_IT_WORKS.md` and
`DYNAMIC_MODEL_DISCOVERY_SUCCESS.md`): real verification makes an HTTP call to
the provider's `/v1/models` to confirm the model exists, then a chat probe
("Do you see my code?") requiring an affirmative response, scored against
`min_verification_score: 0.7`.

---

## 6. Network / env / config requirements

- **Network: required.** Real verification makes live HTTP requests to the
  provider's `{endpoint}/models` (dynamic discovery) and a chat completion probe
  with a Bearer token. From `DYNAMIC_MODEL_DISCOVERY_SUCCESS.md`: "Makes HTTP GET
  request to `{endpoint}/models` ... Authenticates with Bearer token".
- **models.dev: NOT the source of truth.** `MODELS_DEV_IMPLEMENTATION.md`:
  "Models.dev is used as an **enhancement layer**, not the single source of
  truth. Provider APIs are still the primary verification source." The tool can
  fetch supplemental metadata from models.dev, but verification of existence /
  response is against the provider's own API.
- **Credentials: env vars.** `model-verification` calls
  `RegisterAllProviders()` which reads provider keys from environment variables
  (e.g. `OPENAI_API_KEY`, `ANTHROPIC_API_KEY`, `DEEPSEEK_API_KEY`, `GROQ_API_KEY`,
  `GEMINI_API_KEY`, ... — see `config_full.yaml`). The Makefile sources
  `scripts/load_api_keys.sh`, which prefers `$HOME/api_keys.sh` then `.env`.
- **Config file:** root CLI defaults to `config.yaml` (`-c/--config`).
  `model-verification` defaults `--config ""` (env-only) and `--output
  ./verified-configs`. SQLite DB path comes from `database.path` (default
  `./llm-verifier.db`).

---

## 7. Recommended wrapper contract: `scripts/providers-verify.sh`

A thin bash wrapper consistent with this repo's conventions (POSIX-leaning,
env-var knobs, degrade gracefully). It should NOT require LLMsVerifier to be
built — if the binary is absent, return `unverified` rather than fail.

### Inputs (positional or flags / env)

| Input | Meaning |
| --- | --- |
| `provider_id` | LLMsVerifier provider id, e.g. `openai`, `anthropic`, `deepseek` |
| `base_url` | provider API base URL (informational / passed through to config if config-mode is used) |
| `model` | model id to check exists/responds, e.g. `gpt-4` |
| `key_env_var` | name of the env var holding the API key, e.g. `OPENAI_API_KEY` |

Knobs (env): `LLMSVERIFIER_DIR` (default `submodules/LLMsVerifier`),
`LLMSVERIFIER_BIN` (default `$LLMSVERIFIER_DIR/bin/model-verification`).

### Behaviour

1. Resolve the binary: prefer a prebuilt
   `$LLMSVERIFIER_DIR/bin/model-verification`; else try
   `$LLMSVERIFIER_DIR/bin/llm-verifier`. **Do not** build implicitly.
2. If no binary AND `go` toolchain present, optionally attempt
   `go build -o bin/model-verification ./llm-verifier/cmd/model-verification`
   inside the submodule (best-effort, time-boxed). If build fails or `go` is
   absent → emit `unverified` with reason `binary-unavailable`.
3. Verify the key env var is set; if `${!key_env_var}` is empty → `unverified`
   with reason `missing-key:<key_env_var>` (do not call the network).
4. Export the key under the name LLMsVerifier expects (set both
   `<key_env_var>` and the canonical provider var if they differ), then run:
   ```bash
   "$LLMSVERIFIER_BIN" --provider "$provider_id" --model "$model" --verbose
   ```
5. Capture stdout; classify per §5.

### Output (single status word + reason on stderr/JSON)

Exactly one of:

- `verified` — stdout matched `Status: verified` + `Can See Code: true` +
  `Affirmative Response: true` (and/or the `✅ ... model_passed` line). Reason:
  include the parsed `Verification Score`.
- `failed` — tool ran but the model did not pass (model-not-found, auth error,
  `❌`, or the `model_failed` line). Reason: the first matching error/`❌` line,
  or `not-passed:<status>`.
- `unverified` — could not run the check (no binary, no Go toolchain, missing
  key, or network/exec error before a verdict was produced). Reason:
  `binary-unavailable` | `missing-key:<var>` | `exec-error:<msg>`.

Recommended machine-readable form (one line of JSON to stdout):

```json
{"provider":"openai","model":"gpt-4","status":"verified","reason":"score=0.95"}
```

Map the wrapper's own exit code: `0` for `verified`, `1` for `failed`, `2` for
`unverified` (so callers can distinguish "skipped" from "genuinely broken").

---

## EVIDENCE (raw command outputs)

All commands run against `vasic-digital/LLMsVerifier`, default branch `main`,
via the authenticated `gh` CLI.

### Repo metadata
```
$ gh api repos/vasic-digital/LLMsVerifier --jq '{default_branch, clone_url, ssh_url, description}'
{"clone_url":"https://github.com/vasic-digital/LLMsVerifier.git","default_branch":"main","description":"Benchmark and verify LLMs","ssh_url":"git@github.com:vasic-digital/LLMsVerifier.git"}
```

### Makefile build target
```
$ gh api repos/vasic-digital/LLMsVerifier/contents/Makefile --jq .content | base64 -d
...
LOAD_KEYS := if [ -f scripts/load_api_keys.sh ]; then . scripts/load_api_keys.sh; fi

# Building
build: ## Build the application
	@$(LOAD_KEYS); go build -o bin/llm-verifier ./cmd

build-all: ## Build for multiple platforms
	GOOS=linux GOARCH=amd64 go build -o bin/llm-verifier-linux-amd64 ./cmd
	...
run: ## Run the application locally
	go run ./cmd server
...
.DEFAULT_GOAL := help
```

### go.mod (module + replace directives)
```
$ gh api repos/vasic-digital/LLMsVerifier/contents/go.mod --jq .content | base64 -d
module llmsverifier
go 1.25.3
require (
	digital.vasic.llmsverifier v0.0.0
	...
	github.com/mattn/go-sqlite3 v1.14.32 // indirect
	...
)
replace digital.vasic.llmsverifier => ./llm-verifier
// digital.vasic.challenges lives outside this repo — at ../challenges
// relative to this go.mod when LLMsVerifier is checked out as a submodule
// of HelixAgent (which is the only supported layout). ...
require digital.vasic.challenges v0.0.0
replace digital.vasic.challenges => ../challenges
```

### cmd/ entrypoints (filtered tree)
```
$ gh api 'repos/vasic-digital/LLMsVerifier/git/trees/HEAD?recursive=1' --jq '.tree[].path' | grep -iE 'main\.go$|/cmd/'
llm-verifier/cmd/main.go
llm-verifier/cmd/model-verification/main.go
llm-verifier/cmd/full-verify/main.go
llm-verifier/cmd/quick-verify/main.go
llm-verifier/cmd/code-verification/main.go
llm-verifier/cmd/crush-config-converter/main.go
llm-verifier/cmd/testsuite/main.go
llm-verifier/cmd/tui/main.go
llm-verifier/cmd/ultimate-challenge/main.go
... (an `acp-cli` is referenced by the Makefile `build-acp` target but its
    source path was not present in the tree at HEAD; `test-acp-cli.sh` exists)
```

### model-verification flags + dispatch + verdict (llm-verifier/cmd/model-verification/main.go)
```
configPath          = flag.String("config", "", "Path to configuration file")
outputDir           = flag.String("output", "./verified-configs", "...")
verifyAll           = flag.Bool("verify-all", false, "Verify all available models")
provider            = flag.String("provider", "", "Specific provider to verify (e.g., openai, anthropic)")
model               = flag.String("model", "", "Specific model to verify")
strictMode          = flag.Bool("strict", true, "Enable strict mode ...")
...
enhancedService.RegisterAllProviders()   // providers from env vars
...
if *model != "" && *provider != "" { verifySpecificModel(...) }
...
fmt.Printf("Status: %s\n", result.VerificationStatus)
fmt.Printf("Can See Code: %t\n", result.CanSeeCode)
fmt.Printf("Affirmative Response: %t\n", result.AffirmativeResponse)
if result.VerificationStatus == "verified" && result.CanSeeCode && result.AffirmativeResponse {
    fmt.Println("\n" + tr("llmsverifier_modelverify_model_passed"))
} else {
    fmt.Println("\n" + tr("llmsverifier_modelverify_model_failed"))
}
```
(The only `os.Exit(1)` in this file is on logger-init failure, confirming
pass/fail is stdout-based, not exit-code based.)

### config.yaml (root CLI config schema)
```
$ gh api repos/vasic-digital/LLMsVerifier/contents/llm-verifier/config.yaml --jq .content | base64 -d
api: { enable_cors: true, jwt_secret: ..., port: '8080', rate_limit: 100 }
concurrency: 5
database: { encryption_key: '', path: ./llm-verifier.db }
global: { api_key: ${OPENAI_API_KEY}, base_url: https://api.openai.com/v1, max_retries: 3, request_delay: 1s, timeout: 30s }
llms: []
timeout: 60s
```

### config_full.yaml (llms[] schema; env-var key names)
```
llms:
- api_key: ${HUGGINGFACE_API_KEY}
  endpoint: https://api-inference.huggingface.co
  features: { embeddings: true, tool_calling: true }
  model: ''
  name: HuggingFace Provider
- api_key: ${DEEPSEEK_API_KEY}
  endpoint: https://api.deepseek.com/v1
  ...
- api_key: ${ANTHROPIC_API_KEY} ... endpoint: https://api.anthropic.com/v1
- api_key: ${OPENAI_API_KEY}    ... endpoint: https://api.openai.com/v1
- api_key: ${GROQ_API_KEY} | ${GEMINI_API_KEY} | ${OPENROUTER_API_KEY} | ${MISTRAL_API_KEY} | ...
```

### scripts/load_api_keys.sh (credential loading)
```
# Prefer ~/api_keys.sh (always honoured if present)
if [ -f "$HOME/api_keys.sh" ]; then . "$HOME/api_keys.sh"; return 0; fi
# Fallback: walk up to find .gitmodules (meta-repo root) for .env ...
```

### Network + models.dev posture
```
VERIFICATION_HOW_IT_WORKS.md (proposed real verification):
  testModelExists(): HTTP request to endpoint, Authorization: Bearer <key>, expect 200
DYNAMIC_MODEL_DISCOVERY_SUCCESS.md:
  "Makes HTTP GET request to {endpoint}/models ... Authenticates with Bearer token"
  "All 27 providers now fetch models dynamically via their /v1/models endpoints."
MODELS_DEV_IMPLEMENTATION.md:
  "Models.dev is used as an enhancement layer, not the single source of truth.
   Provider APIs are still the primary verification source."
```

### README documented invocations
```
./llm-verifier/cmd/model-verification/model-verification --verify-all
./model-verification --provider openai
./model-verification --output ./verified-configs --format opencode
go run cmd/main.go        # root CLI, config-driven
```
