# Provider Verification Guide

## Overview

Every provider alias goes through a 4-layer verification pipeline before it can launch Claude Code. A provider that passes all available layers is marked `verified` and is launchable. A provider that fails any layer is marked `failed` or `unverified` and is refused by the activation gate.

## The Four Layers

### Layer 1: Existence

The existence probe sends a minimal chat request to the provider's API endpoint. It checks:
- The endpoint is reachable (HTTP response received)
- The API key is valid (not 401/403)
- The account is active (not 412/suspended)

**Runner:** `providers-verify.sh`
**On fail:** status → `failed` with layer `existence`
**On inconclusive (no network, timeout):** status → `unverified` with layer `existence`

### Layer 2: Tool-Call

The tool-call probe sends a request with a tool definition and checks that the model:
- Recognizes the tool schema
- Returns a valid tool call in the response

This is critical because Claude Code is tool-driven — a chat-only model is useless.

**Runner:** `providers-verify.sh` (same script, second probe)
**On fail:** status → `failed`
**On pass:** status → `verified` (so far)

### Layer 3: Semantic Code-Visibility

The semantic layer tests whether the model can actually "see" and describe code content. It uses a two-round test:

1. **Round 1 (sentinel):** A code fixture is embedded in the prompt. The model must return a specific sentinel string (`ZETA-9-ORANGE-7f3a`) verbatim.
2. **Round 2 (judge):** An independent judge model evaluates whether the model's description of the code is accurate.

**Runner:** `providers-semantic.sh` → Go binary (`semantic-code-visibility`)
**On fail:** status → `unverified` with layer `semantic`
**On skip (no Go, no key, no network):** keeps prior verdict (no downgrade)
**On pass:** keeps `verified`

### Layer 4: Superpowers-TUI

The superpowers-TUI layer launches a real Claude Code session through the provider alias and checks whether it can engage with the superpowers plugin. This is the final, definitive test.

**Runner:** `verify_superpowers_tui.sh`
**On fail:** status → `unverified` with layer `superpowers_tui`
**On skip (no real claude, no PTY):** keeps prior verdict (no downgrade)
**On pass:** status → `verified` (final)

## Status Vocabulary

| Status | Meaning |
|--------|---------|
| `verified` | All testable layers passed; none failed |
| `unverified` | Existence passed but a later layer failed or was inconclusive |
| `failed` | Existence or tool-call failed |
| `pending` | Not yet run |

**Key rule:** A layer that cannot run (no key, no network, no Go, no real claude) is an honest **SKIP** and does NOT downgrade a provider. Only a real layer *failure* downgrades.

## Commands

```bash
# List verified providers only (default)
claude-providers list

# List all providers including failed/unverified
claude-providers list-all

# List only faulty providers
claude-providers list-faulty

# Re-sync all providers (re-runs verification)
claude-providers sync

# Deep-verify a single provider (all 4 layers)
claude-providers verify <id> --deep

# Refresh aliases without re-verifying
claude-providers list --refresh-aliases
```

## The Activation Gate

When you launch a provider alias (e.g., `deepseek`), the activation gate checks the provider's status in `~/.local/share/claude-multi-account/providers/status.json`. If the status is not `verified`, the launch is refused with an actionable message.

To override the gate (e.g., for testing):
```bash
claude-providers verify <id> --force
```

## Common Issues

### "ccr on PATH is not @musistudio/claude-code-router"

The `ccr` binary on your PATH is not the claude-code-router. Fix:
```bash
npm install -g @musistudio/claude-code-router
```

### Provider shows "failed/existence"

The API endpoint is unreachable or the API key is invalid. Check:
1. Is the API key set in `~/api_keys.sh`?
2. Is the account active (not suspended)?
3. Can you reach the endpoint? `curl -4 -s <base_url>/chat/completions`

### Provider shows "unverified/semantic"

The semantic code-visibility test failed. This means the model can't reliably describe code content. Possible causes:
- The model doesn't support the chat/completions format
- The model's context window is too small for the fixture
- The judge model is unavailable

### Provider shows "unverified/superpowers_tui"

The superpowers-TUI test failed. This means the model can't engage with the superpowers plugin. Possible causes:
- The model doesn't support tool calling
- The model's output is too short for the engagement check
- Claude Code couldn't launch through the alias

## File Locations

| File | Purpose |
|------|---------|
| `~/.local/share/claude-multi-account/providers/status.json` | Verification status for all providers |
| `~/.local/share/claude-multi-account/providers/<id>.env` | Provider configuration (non-secret) |
| `~/.local/share/claude-multi-account/aliases.sh` | Shell aliases for launching providers |
| `~/.claude-code-router/config.json` | ccr router configuration |
| `~/api_keys.sh` | API keys (sourced at launch, never stored by toolkit) |
