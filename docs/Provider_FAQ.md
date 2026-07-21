# Provider Aliases — FAQ

## General

### What is a provider alias?

A provider alias is a named configuration that lets you run Claude Code through a non-Anthropic LLM provider. Each alias has its own config directory, API key, and model selection.

### How many providers can I have?

There's no hard limit. Each provider gets its own config directory (`~/.claude-prov-<name>/`) and alias in the shell.

### What's the difference between `native` and `router` transport?

- **Native:** The provider speaks the Anthropic Messages API directly (a base URL ending in `/anthropic`, served as `/anthropic/v1/messages`). Claude Code talks to it without a router. As of v1.19.0 no provider ships pinned to native — see the next question.
- **Router:** The provider speaks the OpenAI chat/completions API. Requests go through `ccr` (claude-code-router), which translates between Claude Code's Anthropic format and the provider's OpenAI format.

### Why are all providers now on router transport?

Both deepseek and xiaomi have OpenAI-compatible endpoints that work through ccr. Router transport is more uniform and easier to debug — all providers go through the same path.

## Model selection

### Which model does an alias run?

The strongest one your account can actually pay for. If the provider account has credit or purchased tokens, the alias runs the strongest **paid** model that passes verification. If it has no credit, the alias runs the strongest **free** model. This applies to both the main model and the fast/background model, and to every alias `sync --multi` creates.

### What if the toolkit can't tell whether I have credit?

Unknown is treated as *no credit*, so you get the free model. That is deliberate: a paid model on an unfunded key fails at launch with a 402/403 and leaves you with a dead alias, while a free model on a funded key only costs some capability. Re-run `claude-providers sync` once the credit signal is readable and the paid model is picked up.

### I bought credit — how do I get the paid model?

Run `claude-providers sync`. Model tier is decided at sync time, not at launch, so an alias created while the account was empty keeps its free model until the next sync re-evaluates it.

### Can I force a specific model regardless of credit?

Yes. Pin `strong_model` / `fast_model` for that provider in `scripts/providers/overrides.json` and re-sync. A pin always wins over the automatic tier choice — including a paid pin on an account with no readable credit, in which case the resulting launch failure is expected.

### Are free models verified less strictly?

No. A free model goes through exactly the same sentinel and tool-calling probes as a paid one, and its alias is not activated unless both pass. The credit rule decides *which* model is tested, never *how strictly*.

## Verification

### Why is my provider showing as "failed"?

Run `claude-providers list-faulty` to see the failure layer. Common causes:
- **failed/existence:** API key invalid, account suspended, or endpoint unreachable
- **failed/tool-call:** Model doesn't support tool calling

### Why is my provider showing as "unverified"?

The provider passed existence but failed a later layer. Run `claude-providers list-all` to see which layer failed.

### What does `# FAIL: route-mismatch` in an evidence file mean?

The live-TUI (layer 4) turn was served by a *different* backend than the alias under test, so it proves nothing about that alias. Router-transport providers share one ccr `Router.default`, and an alias whose `base_url` is the gateway itself skips its own rewrite and inherits the previous provider's route. Each evidence file records `# ROUTE-INTENDED:` and `# ROUTE-RESOLVED:`; when they differ the leg fails rather than passing unattributably. `# FAIL: route-unknown` is the same refusal when the resolved route cannot be read at all (including when `jq` is missing — for a router-transport alias that is a hard precondition, not a skip).

Two sibling failures exist for the same reason. `# FAIL: route-mismatch-background` means `.Router.default` matched but `.Router.background` did not, so background sub-requests of that same turn were served by another backend — partly-foreign evidence is no more attributable than wholly-foreign evidence. `# FAIL: route-unproven` means the config file named the right route but nothing proves the running gateway ever loaded it: the launch wrapper's `ccr restart` runs under `|| true` and can be refused (an authenticated gateway will not bounce without `CCR_API_KEYS` visible), which would leave the previous provider serving while the file reads back correct. Since the router offers no live-route query, the leg demands a restart receipt bracketing the launch — a fresh `gateway listening on` line in `~/.claude-code-router/service.log`, or a changed `service.json` — and fails closed without one.

### How do I re-verify a provider?

```bash
# Re-verify a single provider
claude-providers verify <id> --deep

# Re-verify all providers
claude-providers sync
```

### Can I force-launch a provider that's not verified?

Yes, but it's not recommended:
```bash
claude-providers verify <id> --force
```

## ccr (claude-code-router)

### What is ccr?

ccr is the claude-code-router — a local proxy that translates between Claude Code's Anthropic format and the OpenAI chat/completions format used by most providers.

### How do I install ccr?

```bash
npm install -g @musistudio/claude-code-router
```

### ccr says "Profile not found" — what's wrong?

You have a different tool named `ccr` on your PATH. The toolkit's identity check uses `ccr --help` to verify the correct tool is installed. Fix by removing the shadowing binary or reinstalling:
```bash
npm install -g @musistudio/claude-code-router
```

### How does ccr know about my providers?

The toolkit writes provider configurations to `~/.claude-code-router/config.json` during `claude-providers sync`. Each provider's API key is injected at launch time (never stored in the config).

## Keys and Security

### Where are my API keys stored?

Keys are stored in `~/api_keys.sh` as environment variables. They are sourced at launch time inside a subshell and never written to the toolkit's config files, alias files, or status cache.

### Can I use the same key for multiple providers?

Yes, if the provider allows it. Each provider references a key by variable name (e.g., `DEEPSEEK_API_KEY`), and multiple providers can reference the same variable.

### My key expired — how do I update it?

1. Update the key in `~/api_keys.sh`
2. Run `claude-providers sync` to re-verify
3. The provider should pass verification with the new key

## Sessions and Continuity

### Can I resume a session from one provider in another?

Yes. Sessions are shared across all providers via the unified `~/.claude-shared/` store. A session created under `deepseek` is visible from `xiaomi` and vice versa.

### What happens to my session if a provider goes down?

Your session history is preserved in `~/.claude-shared/projects/`. You can resume it through any other verified provider.
