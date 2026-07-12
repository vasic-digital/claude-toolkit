# Claude multi-account scripts

Bash toolkit for running multiple Claude Code accounts on a single host
while keeping conversation history, memory, todos, plans, plugins, and
settings unified across them. Pair this README with the longer write-up
at `../Claude_Multi_Account_Fine_Tuning.md`.

## Quick start

```bash
# from the repo root (after cloning the toolkit):
bash scripts/install.sh   # bootstraps everything: symlinks + unify + docs
exec $SHELL -l            # reload shell so aliases load
claude-list-accounts      # show the resulting setup
```

## Scripts

| Script                      | Purpose                                                     |
| --------------------------- | ----------------------------------------------------------- |
| `install.sh`                | One-shot bootstrap: symlink scripts onto PATH, write the alias file + rc sourcing, run unify, refresh docs. Idempotent. |
| `curl-install.sh`           | One-line remote installer: detect platform, install hard deps, clone/pull the repo, run `install.sh`. |
| `claude-unify.sh`           | Merge every detected per-account dir into `~/.claude-shared` and replace per-account entries with symlinks. Re-runnable; `--rollback` to undo. |
| `claude-add-account.sh`     | Add a new account: create its config dir, link every shared item, register a shell alias (e.g. `claude3`). |
| `claude-remove-account.sh`  | Remove an account: drop its alias and archive/delete its config dir (shared store untouched). |
| `claude-list-accounts.sh`   | Print a status table of every detected account (alias, config dir, creds, symlink integrity). |
| `claude-rollback.sh`        | Convenience wrapper for `claude-unify.sh --rollback`: restore the `.preunify.*` backups, archive the shared store. |
| `claude-bootstrap.sh`       | Clean-slate provisioning on a host with zero logged-in accounts: create N empty account dirs, the shared store, and `claudeN` aliases. |
| `claude-sync-state.sh`      | Fast (no-rsync) per-launch merge of every account's `.claude.json` session/project index; called by the alias wrapper before and after each launch. |
| `claude-session.sh`         | Derive per-project session launch flags (one long-lived session per project root, kebab-case-named) plus the per-alias `/color` hint for the alias wrappers. |
| `claude-providers.sh`       | Create/refresh/list/remove Claude Code aliases for non-Anthropic LLM providers, driven by the models.dev catalog + editable config. |
| `claude-opencode-sync.sh`   | Mirror the host's Claude plugin Skills, MCP servers, and CLAUDE.md into OpenCode's config. Additive + idempotent. |
| `claude-export-docs.sh`     | Render the multi-account markdown doc to self-contained `.html` and `.pdf` siblings. |
| `lib.sh`                    | Shared helpers (env knobs, account detection, alias file, merge + provider helpers). Sourced by every script. |
| `toon.mjs`                  | Node CLI to encode JSON → / decode TOON (token-efficient prompt format) via `@toon-format/toon`. |
| `toon_encode.py`            | Python wrapper that shells out to `toon.mjs` to encode JSON to TOON. |
| `opencode_sync.py`          | Engine behind `claude-opencode-sync.sh`: scans the plugin cache and writes the merged OpenCode config (skills / mcp / instructions). |
| `providers_generate.py`     | From verified models, generate provider alias configs (env files, shell aliases, `overrides.json` entries). |
| `providers_resolve.py`      | Pure offline resolver: models.dev catalog + key names → concrete provider records (alias, base URL, transport, strong/fast model). |
| `model_verify.py`           | HTTP-probe + score every model for a provider (with anti-bluff detection); output a sorted verified-model list. |
| `providers-verify.sh`       | Pluggable provider verification adapter: LLMsVerifier binary, else HTTP probe, else reports `unverified`. |

## What lives where after unification

```
~/.claude-shared/                  # the only source of truth
  projects/  todos/  tasks/  plans/  file-history/  paste-cache/
  plugins/  shell-snapshots/  session-env/  telemetry/  sessions/
  backups/  cache/  CLAUDE.md  history.jsonl  settings.json
  stats-cache.json

~/.claude-<account>/                # per-account dir, mostly symlinks
  .credentials.json    # PRIVATE — account-locked
  .claude.json         # PRIVATE — account state
  mcp-needs-auth-cache.json  # PRIVATE — auth state
  projects -> ~/.claude-shared/projects
  ... (every shared item is a symlink)

~/.local/share/claude-multi-account/
  aliases.sh           # the managed alias file (sourced from rc files)
```

## Adding a 3rd, 4th, ... Nth account

```bash
claude-add-account                 # interactive: suggests claude3, claude4...
claude-add-account --alias work    # custom alias name + auto config dir
claude-add-account --alias work --dir ~/.claude-work --yes
exec $SHELL -l                     # reload aliases
claude3 /login                     # authenticate the new account
```

The new account starts with full access to the shared history, memory,
todos, plans, and the same enabled-plugins set as your existing accounts.

## Cross-platform notes

The scripts are POSIX-leaning bash and have been verified on Linux with
`jq 1.8+`, `rsync 3.x`, GNU `awk`, and `pandoc 3.x`. On macOS, install the
same toolchain via Homebrew (`brew install jq rsync gawk pandoc weasyprint`).
Default config dirs and shared store paths use `$HOME`, which resolves
correctly on both. The alias mechanism sources `~/.bashrc` and `~/.zshrc` on Linux, `~/.zshrc` only on macOS
— if you use fish or another shell, add `source ~/.local/share/claude-multi-account/aliases.sh`
to its equivalent rc by hand.
