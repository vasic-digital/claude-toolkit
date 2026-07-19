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

## Verification

### Why is my provider showing as "failed"?

Run `claude-providers list-faulty` to see the failure layer. Common causes:
- **failed/existence:** API key invalid, account suspended, or endpoint unreachable
- **failed/tool-call:** Model doesn't support tool calling

### Why is my provider showing as "unverified"?

The provider passed existence but failed a later layer. Run `claude-providers list-all` to see which layer failed.

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
