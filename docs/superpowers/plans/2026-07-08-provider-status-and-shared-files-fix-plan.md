# Fix Plan: Provider Verification Status Persistence + Shared File Conflicts

## Overview

Two critical bugs found:

### Bug 1: `cmd_sync_multi` never writes verification status

**Root Cause**: In `scripts/claude-providers.sh`, the `cmd_sync_multi` function (line 537) runs full model verification via `model_verify.py` and generates aliases via `providers_generate.py`, but **never calls `cma_status_write`** for any generated alias. Every multi-alias (e.g. `openai2`, `openai3`) stays "pending" in `status.json`, so the activation gate in `cma_run_provider` blocks them with:

```
claude-providers: alias X is pending — not launching.
```

The user must use `--force` every time. This affects ALL multi-aliases — about half of the provider fleet.

**Secondary sub-issue**: `providers-verify.sh`'s HTTP probe (strategy 2) appends `/models` to the base URL verbatim. For native-transport providers with base URLs ending in `/anthropic` (e.g. Xiaomi), this produces `https://api.xiaomimimo.com/anthropic/models` — a 404. The probe returns `unverified` even though the key is valid.

### Bug 2: Shell environment leakage between cma_run_provider invocations

**Root Cause**: `cma_run_provider` sources the provider env file and then exports env vars like `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`, etc. on the native transport path, or rewrites the ccr config on the router path. When the user launches alias A, exits, then launches alias B in the same shell, env vars from alias A leak. If the user then launches alias A again, env vars from alias B can interfere.

The `cma_run` wrapper (used by native `claudeN` aliases) already solves this by `unset ANTHROPIC_BASE_URL ANTHROPIC_AUTH_TOKEN ANTHROPIC_MODEL ANTHROPIC_SMALL_FAST_MODEL`. But `cma_run_provider` has no such isolation for the provider-transport path — after a native-transport provider exits, `ANTHROPIC_*` vars remain set.

Additionally, `cma_own_settings_seed` creates a per-alias copy of `settings.json`, but `CLAUDE.md` and `history.jsonl` are symlinks — they ARE shared (correctly). The settings being per-alias means each provider alias can have its own hook scripts and permissions. But when the shared template `$SHARED_DIR/settings.json` changes (e.g. new always-on plugins), `cma_own_settings_seed` only merges `enabledPlugins` into existing per-alias copies — it never propagates other template fields.

## Tasks

### Task 1: Fix cmd_sync_multi — persist verification status for each alias
**Files**: `scripts/claude-providers.sh`
**Change**: After `cma_provider_write_alias` in the multi-alias loop (line 656-658), add `cma_status_write` calls for each alias. The verification status is available from the `model_verify.py` output; use the model score to determine verified vs unverified.

### Task 2: Fix native-transport HTTP probe URL in providers-verify.sh
**Files**: `scripts/providers-verify.sh`
**Change**: Before appending `/models` to the probe URL, strip any trailing `/anthropic` segment so the request goes to the correct endpoint.

### Task 3: Add env-isolation cleanup to cma_run_provider
**Files**: `scripts/lib.sh` (the cma_run_provider body in cma_ensure_alias_file)
**Change**: At the beginning of the `native` transport branch (after `else` at line 638), unset all previously-set provider env vars. Also unset them at the FUNCTION entry for the router path (so switching from native to router doesn't leak).

### Task 4: Comprehensive hermetic tests
**Files**: `scripts/tests/test_providers.sh`
**Tests**:
- `cmd_sync_multi` writes verification status for each alias
- `cma_status_read` returns proper status for multi-aliases
- Activation gate reads multi-alias status correctly
- `providers-verify.sh` correctly probes `/models` when base URL has `/anthropic`
- `cma_run_provider` env isolation prevents cross-alias leakage

### Task 5: Run full test suite and live verification, commit and push
- Run `bash scripts/tests/run-all.sh`
- Run `bash scripts/tests/run-proof.sh`
- Run `bash scripts/install.sh` to refresh
- Run `claude-providers sync` to verify fix
- Commit all changes and push to all upstreams

## Global Constraints
- All changes must be backward-compatible
- `set -euo pipefail` must not break (load-bearing)
- All tests must pass in isolation (sandboxed)
- No key material ever written to status cache or env files
- The activation gate remains as the security boundary: only 'verified' passes without --force
