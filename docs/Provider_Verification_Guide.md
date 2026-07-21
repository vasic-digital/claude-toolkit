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

**Route attribution.** A PASS here is only meaningful if the turn was actually served by the alias under test. Every router-transport provider rewrites ccr's shared `Router.default` to itself before launching, but an alias whose `base_url` *is* the gateway trips a self-reference guard, skips that rewrite, and inherits the previous provider's route — `helixagent` was once badged `verified` on a turn served by a different provider. Every evidence file now records both routes:

```
# ROUTE-INTENDED: <provider>/<model> (transport=router)
# ROUTE-INTENDED-BACKGROUND: <provider>/<model>
# ROUTE-RESOLVED: <provider>/<model>
# ROUTE-RESOLVED-BACKGROUND: <provider>/<model>
# ROUTE-APPLIED: <restart receipt, or <unproven>>
```

`ROUTE-RESOLVED` is read *after* the launch, so it reflects the rewrite rather than the stale pre-launch value. If the two differ the leg fails with `# FAIL: route-mismatch`; if the resolved route cannot be read at all the leg fails with `# FAIL: route-unknown` — an unattributable turn is never a silent pass.

Both router entries are checked, not just `.Router.default`. Claude Code dispatches background sub-requests of the *same* turn through `.Router.background`, so a turn served only partly by another backend fails with `# FAIL: route-mismatch-background`.

**A config file is not a live gateway.** Reading `config.json` back proves what it *says*, not what the daemon serves: the launch wrapper runs `ccr restart` under `|| true`, and `cmdRestart` genuinely refuses to bounce an authenticated gateway when `CCR_API_KEYS` is not visible to the call (`cmd/ccr/service.go:385-390`, returns 1) — a swallowed failure leaves the *previous* provider serving while the file reads back correct. The router exposes no live-route query (its `/health` reports a provider *count*, not a route), so the leg requires a **restart receipt** bracketing the launch: either a new `gateway listening on` line appended to `~/.claude-code-router/service.log` past the pre-launch byte offset, or a changed `~/.claude-code-router/service.json` pidfile. With neither, the leg **fails closed** with `# FAIL: route-unproven`.

Two honest limits on that guarantee: the receipt brackets the whole launch rather than the individual request (a concurrent rewrite is excluded by the suite lock, not by this gate), and it proves that *a* config load happened, not that the loaded bytes were the ones read back.

`jq` is a hard precondition for router-transport aliases, not a silent skip — without it the resolved route is unreadable and the leg takes `route-unknown`. The whole attribution check runs *before* any transcript-derived verdict, so a route failure is never explained away by the provider's status: a rejected key explains a provider that cannot answer, but nothing about an account explains evidence attributed to the wrong backend. Native-transport aliases talk to their endpoint directly, so they record an explicit `n/a` and are not route-checked.

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

## What Gets Verified: the Credit-Aware Model Tier

The four layers verify *the model the alias will actually run*, and which model that is depends on the provider account's credit state:

| Credit state | Model put under test |
|--------------|----------------------|
| Credit / purchased tokens available | the strongest **paid** model the provider serves |
| No credit | the strongest **free** model (free tier / `$0` cost) |
| Unknown / undeterminable | treated as *no credit* — the free model |

Two consequences for verification specifically:

1. **The gates are identical in both tiers.** A free model is not verified more leniently. It must pass the same sentinel probe and the same tool-calling probe, or its alias is not activated. The tier decides *which* model is tested, never *how strictly*.
2. **The conservative unknown-branch avoids a whole class of `failed` verdicts.** Probing a paid model on an unfunded key returns 401/402/403, which Layer 1 correctly treats as a definitive rejection — the alias would be marked `failed` and refuse to launch. Defaulting an unreadable credit state to the free tier means an unfunded provider ends up with a working free alias instead of a dead paid one. Re-run `claude-providers sync` once the account is funded and the paid model is picked up and re-verified.

A `strong_model` / `fast_model` pin in `scripts/providers/overrides.json` overrides the tier choice; the pinned model is then the one verified, whatever its cost tier.

> The mechanism behind this (in `providers_resolve.py` and in LLMsVerifier's corresponding detection) landed alongside this section. The rules above are the behavioural contract — read the source for the current flag and field names.

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
- **`# FAIL: route-mismatch`** in the evidence file — the turn was served by a *different* backend than the alias under test (a gateway-based alias skipping its own `Router.default` rewrite and inheriting the previous provider's route), so it proves nothing either way. Re-run the leg on its own rather than after another router alias.
- **`# FAIL: route-mismatch-background`** — `.Router.default` matched, but `.Router.background` named another backend, so background sub-requests of that same turn were served elsewhere. Partly-foreign evidence is refused for the same reason wholly-foreign evidence is.
- **`# FAIL: route-unknown`** — ccr's resolved route could not be read (no `jq`, or no `Router.default` / `Router.background` in `~/.claude-code-router/config.json`). The turn is unattributable and is refused rather than passed.
- **`# FAIL: route-unproven`** — the config file names the right route, but no `ccr restart` receipt brackets the launch (no new `gateway listening on` line in `~/.claude-code-router/service.log`, and `service.json` unchanged), so the running gateway may still be serving the previous provider. Fails closed. Usually means the restart was refused — most often an authenticated gateway restarted without `CCR_API_KEYS` visible.

## File Locations

| File | Purpose |
|------|---------|
| `~/.local/share/claude-multi-account/providers/status.json` | Verification status for all providers |
| `~/.local/share/claude-multi-account/providers/<id>.env` | Provider configuration (non-secret) |
| `~/.local/share/claude-multi-account/aliases.sh` | Shell aliases for launching providers |
| `~/.claude-code-router/config.json` | ccr router configuration |
| `~/api_keys.sh` | API keys (sourced at launch, never stored by toolkit) |
