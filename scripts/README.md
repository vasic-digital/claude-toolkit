# Claude multi-account scripts

Bash toolkit for running multiple Claude Code accounts on a single host
while keeping conversation history, memory, todos, plans, plugins, and
settings unified across them. Pair this README with the longer write-up
at `../Claude_Multi_Account_Fine_Tuning.md`.

## Quick start

```bash
cd ~/Documents/scripts
bash install.sh         # bootstraps everything: symlinks + unify + docs
exec $SHELL -l          # reload shell so aliases load
claude-list-accounts    # show the resulting setup
```

## Scripts

| Script                      | Purpose                                                     |
| --------------------------- | ----------------------------------------------------------- |
| `install.sh`                | One-shot bootstrap. Idempotent.                             |
| `claude-unify.sh`           | Merge per-account dirs into `~/.claude-shared` + symlink.   |
| `claude-add-account.sh`     | Add a new `claudeN` (or custom-named) account.              |
| `claude-remove-account.sh`  | Drop an account's alias + archive/delete its config dir.    |
| `claude-list-accounts.sh`   | Tabular status of every detected account.                   |
| `claude-rollback.sh`        | Restore the pre-unification backups.                        |
| `claude-export-docs.sh`     | Generate the `.html` and `.pdf` siblings of the markdown.   |
| `lib.sh`                    | Shared helpers (alias file, account detection). Sourced.    |

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
correctly on both. The alias mechanism reads `~/.bashrc` and `~/.zshrc`
— if you use fish or another shell, add `source ~/.local/share/claude-multi-account/aliases.sh`
to its equivalent rc by hand.
