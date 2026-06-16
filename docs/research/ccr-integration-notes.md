# claude-code-router (ccr) integration notes

Research notes for routing toolkit provider aliases (OpenAI-compatible / Gemini
backends) through Claude Code via **claude-code-router** (`@musistudio/claude-code-router`).

- Repo: `/Volumes/T7/Projects/claude_tookit`
- Branch: `feat/provider-aliases`  · Commit at research time: `15bbcc4`
- Date: 2026-06-16
- Upstream: <https://github.com/musistudio/claude-code-router>

> No fabrication: every claim below is backed by real command output (see the
> EVIDENCE appendix) or a direct quote from the upstream README. API keys are
> redacted.

---

## 1. Install status (this host)

**Not installed.** The `ccr` binary is absent, there is no global npm package,
and no `~/.claude-code-router` config directory exists.

```
which ccr            -> ccr not found
ccr -v / ccr version -> (no output; command not found)
npm ls -g | grep ... -> (no match for claude-code-router / musistudio)
ls -la ~/.claude-code-router -> (directory does not exist)
```

Node/npm are present and recent (`node v22.22.3`, `npm 10.9.8`), so a global
install will work without extra prerequisites.

## 2. Exact install command

```bash
npm install -g @musistudio/claude-code-router
```

(Claude Code itself is the separate prerequisite: `@anthropic-ai/claude-code`.)

## 3. config.json schema + concrete element

**Location:** `~/.claude-code-router/config.json`

Top-level keys (from README): `APIKEY` (secures the local router via Bearer /
`x-api-key`), `PROXY_URL`, `LOG` (default `true`), `API_TIMEOUT_MS`,
`NON_INTERACTIVE_MODE`, `Providers[]`, `Router{}`.

A `Providers[]` element:

| field          | meaning |
| -------------- | ------- |
| `name`         | unique provider id used by `Router` (left side of `provider,model`) |
| `api_base_url` | **full chat-completions URL** (note: includes the path, not just host) |
| `api_key`      | provider credential |
| `models`       | array of model ids this provider exposes |
| `transformer`  | optional request/response shaping (`openrouter`, `deepseek`, `gemini`, `maxtoken`, `tooluse`, …) |

`Router{}` maps routing scenarios to a `"provider_name,model_name"` string:
`default`, `background`, `think`, `longContext`, `longContextThreshold`
(default `60000`), `webSearch`, `image`.

Concrete config (verbatim from README, keys redacted):

```json
{
  "APIKEY": "your-secret-key",
  "PROXY_URL": "http://127.0.0.1:7890",
  "LOG": true,
  "API_TIMEOUT_MS": 600000,
  "NON_INTERACTIVE_MODE": false,
  "Providers": [
    {
      "name": "openrouter",
      "api_base_url": "https://openrouter.ai/api/v1/chat/completions",
      "api_key": "sk-xxx",
      "models": ["google/gemini-2.5-pro-preview", "anthropic/claude-sonnet-4"],
      "transformer": { "use": ["openrouter"] }
    },
    {
      "name": "deepseek",
      "api_base_url": "https://api.deepseek.com/chat/completions",
      "api_key": "sk-xxx",
      "models": ["deepseek-chat", "deepseek-reasoner"],
      "transformer": { "use": ["deepseek"], "deepseek-chat": { "use": ["tooluse"] } }
    }
  ],
  "Router": {
    "default": "deepseek,deepseek-chat",
    "background": "ollama,qwen2.5-coder:latest",
    "think": "deepseek,deepseek-reasoner",
    "longContext": "openrouter,google/gemini-2.5-pro-preview",
    "longContextThreshold": 60000,
    "webSearch": "gemini,gemini-2.5-flash"
  }
}
```

OpenAI-compatible / Gemini examples (verbatim):

```json
{
  "name": "deepseek",
  "api_base_url": "https://api.deepseek.com/chat/completions",
  "api_key": "sk-xxx",
  "models": ["deepseek-chat", "deepseek-reasoner"]
}
```
```json
{
  "name": "gemini",
  "api_base_url": "https://generativelanguage.googleapis.com/v1beta/models/",
  "api_key": "sk-xxx",
  "models": ["gemini-2.5-flash", "gemini-2.5-pro"]
}
```

## 4. Service / launch commands

```bash
ccr code        # launch a Claude Code coding session routed through ccr
ccr start       # start the router service
ccr stop        # stop the service
ccr status      # check status
ccr restart     # restart (do this after editing config.json)
```

**Local endpoint:** `http://127.0.0.1:3456` (default). The README states `ccr code`
stands up this local service and that `ccr activate` emits shell-compatible
exports setting `ANTHROPIC_BASE_URL=http://127.0.0.1:3456` and
`ANTHROPIC_AUTH_TOKEN` from `APIKEY`, redirecting Claude Code through the router.

## 5. Recommended alias-launch approach

**Use `ccr code` for `transport: "router"` providers.** Justification:

1. `ccr code` already does what option (a) does by hand — it ensures the service
   is up, sets `ANTHROPIC_BASE_URL=http://127.0.0.1:3456` and
   `ANTHROPIC_AUTH_TOKEN`, then execs Claude Code. Re-implementing that in the
   alias duplicates upstream behavior we'd have to keep in sync.
2. It is the single documented, supported entry point; manual env export is the
   internal mechanism `ccr activate` exposes, not the recommended UX.
3. Routing logic (which backend serves `default` vs `background` vs `think` vs
   `longContext`) lives in `Router{}`, so one `ccr code` invocation gives the
   alias the full provider/model story without per-call env juggling.

This maps cleanly onto the toolkit's existing two-transport model
(`scripts/providers/evidence/models-dev-mapping.json`):

- `transport: "native"` providers (e.g. `deepseek` direct, Anthropic-shaped
  endpoints) keep launching via the plain Claude Code path the design doc
  already describes — export `ANTHROPIC_BASE_URL` / `ANTHROPIC_AUTH_TOKEN` /
  `ANTHROPIC_MODEL` / `ANTHROPIC_SMALL_FAST_MODEL` and run `claude`.
- `transport: "router"` providers (most `@ai-sdk/openai-compatible` and Gemini
  backends that aren't Anthropic-message-shaped) should ensure ccr is installed
  + configured, then launch with `ccr code` instead of `claude`. This is exactly
  the branch the design doc anticipates at step 3/4 of the launch flow ("For
  `router` transport: ensure `claude-code-router` is up; point
  `ANTHROPIC_BASE_URL` ...").

Fallback (option a) for environments where shelling out to `ccr code` is
undesirable (e.g. a non-interactive wrapper) — point Claude Code at the running
service directly:

```bash
ccr start    # idempotent; no-op if already running
ANTHROPIC_BASE_URL="http://127.0.0.1:3456" \
ANTHROPIC_AUTH_TOKEN="$CCR_APIKEY" \
claude
```

## 6. Programmatic provider injection (jq)

The toolkit discovers providers as
`{provider_id, base_url, strong_model, fast_model, key_var, transport}`
(see `models-dev-mapping.json`). Map one discovered provider into a ccr
`Providers[]` element + a `Router` rule. The credential should be the **literal
key**, read from the named env var at write time (never the var name) — ccr does
not expand env vars inside `config.json`, so resolve `${!key_var}` in the shell.

```bash
# inputs (from the discovery record)
PID="deepseek"                                   # provider_id  -> Providers[].name
BASE="https://api.deepseek.com/chat/completions" # base_url (MUST be full /chat/completions URL)
STRONG="deepseek-chat"                           # strong_model -> Router.default
FAST="deepseek-reasoner"                          # fast_model   -> Router.background
KEY_VAR="DEEPSEEK_API_KEY"
KEY="${!KEY_VAR}"                                 # resolve literal key; keep out of git/logs

CFG="$HOME/.claude-code-router/config.json"
[ -f "$CFG" ] || echo '{"Providers":[],"Router":{}}' > "$CFG"

# Idempotent upsert: drop any existing entry of the same name, append the new one,
# then set Router.default / Router.background. --arg keeps the key out of argv history
# better than interpolation; still redact in any captured logs.
jq --arg name "$PID" \
   --arg url  "$BASE" \
   --arg key  "$KEY" \
   --arg strong "$STRONG" \
   --arg fast   "$FAST" '
  .Providers = ([ .Providers[]? | select(.name != $name) ] + [{
      name: $name,
      api_base_url: $url,
      api_key: $key,
      models: [$strong, $fast]
    }])
  | .Router.default    = ($name + "," + $strong)
  | .Router.background = ($name + "," + $fast)
' "$CFG" > "$CFG.tmp" && mv "$CFG.tmp" "$CFG"

ccr restart   # pick up the new config
```

Notes / gotchas:

- **`api_base_url` is the full endpoint including the path** (e.g.
  `.../chat/completions`), not just the host. Several entries in
  `models-dev-mapping.json` store only a host or a base like
  `https://api.deepseek.com` — the translation step must append the
  OpenAI-compatible `/chat/completions` (and Gemini's `/v1beta/models/`) path.
- Some `base_url` values contain unexpanded placeholders (e.g.
  `${CLOUDFLARE_ACCOUNT_ID}` for `cloudflare-workers-ai`). Expand these in the
  shell before writing — ccr stores the literal string.
- Add `"transformer": {"use": ["gemini"]}` (or `openrouter`, `deepseek`) when
  the backend needs request shaping; pure OpenAI-compatible backends can omit it.

---

## EVIDENCE appendix

### A. Local install probe (real output, this host, 2026-06-16)

```
$ which ccr
ccr not found

$ ccr -v 2>/dev/null ; ccr version 2>/dev/null
(no output)

$ npm ls -g 2>/dev/null | grep -i 'claude-code-router\|musistudio'
(no match)

$ ls -la ~/.claude-code-router 2>/dev/null
(directory does not exist)

$ node -v ; npm -v
v22.22.3
10.9.8
```

No API keys were present to redact (no config dir exists).

### B. Upstream README quotes (https://github.com/musistudio/claude-code-router)

- Install: `npm install -g @musistudio/claude-code-router`
- Config path: `~/.claude-code-router/config.json`
- `Providers[]` fields: `name`, `api_base_url`, `api_key`, `models`, optional `transformer`.
- `Router{}` keys: `default`, `background`, `think`, `longContext`,
  `longContextThreshold` (default `60000`), `webSearch`, `image` (beta);
  values use the `"provider_name,model_name"` format.
- Commands: `ccr code`, `ccr start`, `ccr stop`, `ccr status`, `ccr restart`.
- Endpoint: "The local router endpoint (default: `http://127.0.0.1:3456`)";
  `ANTHROPIC_BASE_URL: http://localhost:3456`.
- "Running `ccr code` establishes a local routing service ... `ccr activate`
  outputs shell-compatible variables, setting `ANTHROPIC_BASE_URL` to
  `http://127.0.0.1:3456` and configuring `ANTHROPIC_AUTH_TOKEN` from your
  configuration to redirect Claude Code through the local router."
- Full config example and the DeepSeek / Gemini provider examples are quoted
  verbatim in sections 3 above.

### C. Toolkit cross-reference

- `scripts/providers/evidence/models-dev-mapping.json` — discovery records with
  `transport: "native" | "router"`, `base_url`, `key_var`, `strong_model`,
  `fast_model`. The `"router"` transport is the set that should launch via ccr.
- `docs/superpowers/specs/2026-06-16-provider-aliases-design.md` (launch flow,
  steps 3-4) already specifies: native transport exports `ANTHROPIC_*` and runs
  `claude`; router transport "ensure `claude-code-router` is up; point
  `ANTHROPIC_BASE_URL` ...".
