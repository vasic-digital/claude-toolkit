# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repo is

A POSIX-leaning bash toolkit (`scripts/`) for running multiple Claude Code accounts on one host while keeping conversation history, memory, todos, plans, plugins, and settings unified across them. Companion long-form documentation lives at the repo root (`Claude_Multi_Account_Fine_Tuning.md` and its rendered `.html` / `.pdf` siblings).

## Common commands

```bash
# Install / re-run bootstrap (symlinks scripts onto PATH, sets up aliases,
# runs unify, refreshes docs). Idempotent.
bash scripts/install.sh

# Run the full test suite (uses a sandboxed $HOME via mktemp).
bash scripts/tests/run-all.sh

# Run a single test file by suffix (e.g. tests/test_lib.sh).
bash scripts/tests/run-all.sh lib
bash scripts/tests/run-all.sh unify add_remove export list

# Regenerate Claude_Multi_Account_Fine_Tuning.{html,pdf} from the .md.
bash scripts/claude-export-docs.sh
```

The per-account user commands installed by `install.sh` (`claude-unify`, `claude-add-account`, `claude-remove-account`, `claude-list-accounts`, `claude-rollback`, `claude-export-docs`) end up as symlinks in `~/.local/bin`.

## Architecture

All scripts source `scripts/lib.sh`, which defines the toolkit's vocabulary and the three env-var knobs every script honors:

- `SHARED_DIR` (default `~/.claude-shared`) — the single source of truth for cross-account state.
- `ALIAS_FILE` (default `~/.local/share/claude-multi-account/aliases.sh`) — managed alias file sourced from `~/.bashrc` and `~/.zshrc`.
- `ACCOUNT_PREFIX` (default `.claude-`) — naming convention for per-account dirs under `$HOME` (e.g. `~/.claude-acct1`). `~/.claude` itself is treated as the user-scope plugin root (`DEFAULT_DIR`), **not** an account dir, and is excluded from auto-detection.

The unification model (`claude-unify.sh`) is:

1. For each item in `SHARED_ITEMS` (projects, todos, tasks, plans, history.jsonl, settings.json, plugins, etc.), merge contents from every detected account into `$SHARED_DIR`, then replace the per-account entry with a symlink into `$SHARED_DIR`.
2. Merge strategy varies by type:
   - **Directories**: two-pass rsync — first pass `--ignore-existing` per account (preserves union), second pass overlays the **last** account (assumed most recently active) to bias toward the freshest content for conflicting files.
   - **`history.jsonl`**: concat all sources + `awk` line-dedupe.
   - **`settings.json`**: `jq -s` deep-merge where right-most wins for top-level keys, except `enabledPlugins` which is a union across all accounts.
   - **`stats-cache.json`**: pick the newest by mtime.
3. `PRIVATE_ITEMS` (`.credentials.json`, `.claude.json`, `mcp-needs-auth-cache.json`) are intentionally **never** shared — they're account-locked auth/state.
4. Plugin manifests (`installed_plugins.json`, `known_marketplaces.json`) get JSON-rewritten so absolute `installPath` / `installLocation` values point into `$SHARED_DIR/plugins/...` after the move.
5. `~/.claude/CLAUDE.md` (user-scope memory) is promoted into `$SHARED_DIR/CLAUDE.md` and symlinked from every account dir + `$DEFAULT_DIR`.

Every destructive replacement uses the `backup_and_remove` helper, which renames the target to `<path>.preunify.<timestamp>`. `claude-rollback.sh` / `claude-unify.sh --rollback` walks those backups to undo.

`claude-add-account.sh` mirrors the same `SHARED_ITEMS` list when wiring up a brand-new account, so a fresh account starts in lockstep without re-running unify. Keep the two lists in sync when adding new shared items.

## Test harness conventions

Tests under `scripts/tests/` are plain bash. Each `test_*.sh` file:

1. Sources `tests/lib/assert.sh` and `tests/lib/sandbox.sh`.
2. Calls `make_sandbox`, which `mktemp`s a fresh `$HOME` and rebinds every env var the toolkit reads (`SHARED_DIR`, `ALIAS_FILE`, `DEFAULT_DIR`, `ACCOUNT_PREFIX`, `CLAUDE_BIN=/usr/bin/true`). An `EXIT` trap cleans up via a `cma-test.*` prefix check — never delete a sandbox path that wasn't produced by `mktemp`.
3. After sourcing `lib.sh` (which sets `set -e`), explicitly call `set +e` so failing-by-design assertions don't abort the script.
4. Uses `make_account NAME [--plugins] [--settings JSON] [--history ...] [--memory K:V] [--todo X]` to populate the sandbox before invoking `run_unify` / `run_add_account` / etc.
5. Ends with `summary`, whose exit code feeds `run-all.sh`'s tally.

When adding tests, the real `~/.claude*` state must never be touched — always go through `make_sandbox`.

## Doc pipeline

`claude-export-docs.sh` reads `~/Documents/Claude_Multi_Account_Fine_Tuning.md` (overridable via `MD_FILE` / `DOC_DIR`), preprocesses `<!-- INCLUDE: relative/path -->` markers via awk to inline external files, then renders self-contained HTML (`pandoc --embed-resources`) and PDF. PDF engines are tried in order: pandoc+weasyprint → pandoc+wkhtmltopdf → weasyprint-on-html → headless chromium. Install at least one PDF engine for full output.

## Upstream remotes

`upstreams/*.sh` each `export UPSTREAMABLE_REPOSITORY=...` for the four mirrors (GitHub, GitLab, GitFlic, GitVerse). These are sourced by external multi-remote push tooling, not by anything in this repo — leave them as one-line exports.
