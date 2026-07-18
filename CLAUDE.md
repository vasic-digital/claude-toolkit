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

# Sync the host's Claude plugin Skills/MCP/CLAUDE.md into OpenCode.
bash scripts/claude-opencode-sync.sh --dry-run --stats   # preview
bash scripts/claude-opencode-sync.sh                      # apply

# Prove everything works: hermetic suite + live OpenCode/providers/aliases +
# alias e2e + constitution (6 legs; evidence in scripts/tests/proof/).
bash scripts/tests/run-proof.sh
```

The per-account user commands installed by `install.sh` (`claude-unify`, `claude-add-account`, `claude-remove-account`, `claude-list-accounts`, `claude-rollback`, `claude-export-docs`, `claude-opencode-sync`, `claude-providers`, `claude-sync-state`, `claude-bootstrap`) end up as symlinks in `~/.local/bin` (`install.sh` auto-links every `claude-*.sh`).

## Architecture

All scripts source `scripts/lib.sh`, which defines the toolkit's vocabulary and the three env-var knobs every script honors:

- `SHARED_DIR` (default `~/.claude-shared`) — the single source of truth for cross-account state.
- `ALIAS_FILE` (default `~/.local/share/claude-multi-account/aliases.sh`) — managed alias file sourced from `~/.bashrc` and `~/.zshrc` on Linux, `~/.zshrc` only on macOS.
- `ACCOUNT_PREFIX` (default `.claude-`) — naming convention for per-account dirs under `$HOME` (e.g. `~/.claude-acct1`). `~/.claude` itself is treated as the user-scope plugin root (`DEFAULT_DIR`), **not** an account dir, and is excluded from auto-detection.

The unification model (`claude-unify.sh`) is:

1. For each item in `SHARED_ITEMS` (projects, todos, tasks, plans, history.jsonl, settings.json, plugins, etc.), merge contents from every detected account into `$SHARED_DIR`, then replace the per-account entry with a symlink into `$SHARED_DIR`.
2. Merge strategy varies by type:
   - **Directories**: two-pass rsync — first pass `--ignore-existing` per account (preserves union), second pass overlays the **last** account (assumed most recently active) to bias toward the freshest content for conflicting files.
   - **`history.jsonl`**: concat all sources + `awk` line-dedupe.
   - **`settings.json`**: `jq -s` deep-merge where right-most wins for top-level keys, except `enabledPlugins` which is a union across all accounts.
   - **`stats-cache.json`**: pick the newest by mtime.
3. `PRIVATE_ITEMS` (`.credentials.json`, `.claude.json`, `mcp-needs-auth-cache.json`) stay per-account (no symlinks into shared). But `.claude.json` is **partially synced** at unify time: `cma_merge_claude_json` deep-merges every account's file so the `projects` subtree (session/MCP/memory index), UX state, and caches are unioned across accounts. Auth keys defined in `CMA_CLAUDE_JSON_PRIVATE_KEYS` (`userID`, `oauthAccount`, `firstStartTime`, `claudeCodeFirstTokenDate`) are written back to each account untouched.
4. Plugin manifests (`installed_plugins.json`, `known_marketplaces.json`) get JSON-rewritten so absolute `installPath` / `installLocation` values point into `$SHARED_DIR/plugins/...` after the move.
5. `~/.claude/CLAUDE.md` (user-scope memory) is promoted into `$SHARED_DIR/CLAUDE.md` and symlinked from every account dir + `$DEFAULT_DIR`.

Every destructive replacement uses the `backup_and_remove` helper, which renames the target to `<path>.preunify.<timestamp>`. `claude-rollback.sh` / `claude-unify.sh --rollback` walks those backups to undo.

`claude-add-account.sh` mirrors the same `SHARED_ITEMS` list when wiring up a brand-new account, so a fresh account starts in lockstep without re-running unify. Keep the two lists in sync when adding new shared items.

**Runtime sync (`claude-sync-state.sh`)**: the alias file installs a `cma_run` shell function that wraps every `claudeN` invocation with a pre-launch `claude-sync-state pull` and post-exit `claude-sync-state push`. This is a lightweight `jq` merge of every account's `.claude.json` — no rsync — so sessions created under one account are visible to all others on the next launch, without anyone having to run `claude-unify` manually.

## Provider aliases and verification (`claude-providers.sh`)

`claude-providers sync` discovers LLM API keys in `~/api_keys.sh`, resolves each to a provider record via `providers_resolve.py` (models.dev catalog + `providers/key-aliases.json` + `providers/overrides.json`), verifies it, and generates: an env file, a shell alias (`cma_run_provider <id>`), and a config dir (`~/.claude-prov-<id>`) linked into the shared store. `sync --multi` scores every catalog model with `model_verify.py` and pairs the top ones into multiple aliases per provider.

Verification is strict (v1.14.0+) — an alias is launchable only when every applicable gate passes:

1. **Existence (`providers-verify.sh`)**: two live probes against the provider's chat endpoint with the exact alias model — a `VERIFY_OK` sentinel that must be echoed back, and a tool-calling probe (Claude Code is tool-driven, so a chat-only model is useless). Definitive rejections (400/401/402/403/404/412, missing sentinel, error-in-200, no tool call) ⇒ `failed` and the alias is not activated; transient conditions (429/5xx/timeout/no-network) ⇒ `unverified` (created, but the launch gate refuses it). Anthropic-native bases keep their `/anthropic` prefix and are probed as `/anthropic/v1/messages`; versioned bases (`…/v4`) get only `/chat/completions` appended.
2. **Semantic code-visibility (`providers-semantic.sh` + LLMsVerifier `semantic-code-visibility`)**: two rounds — exact-sentinel fixture echo (with a prompt-echo bluff guard) and an independent judge. Genuine failures (incl. 401/402/403/404 on the model under test) demote; transient and judge-side infra errors are an honest SKIP that never demotes.
3. **Live TUI (`verify_superpowers_tui.sh`)**: launches real Claude Code through the alias — opt-in via `claude-providers verify <id> --deep` and the live proof suite.

In the `--multi` path `model_verify.py` applies the same anti-bluff rules: the sentinel must be present, `verified` requires a passed tool-calling probe, and the 24h verification cache carries a schema version so results from older, weaker logic are never replayed.

**Kimi Code (OAuth subscription)**: when the `kimi` CLI is signed in, `detect_kimicode_record` discovers every model the subscription serves (`GET /coding/v1/models` ∪ catalog) and emits one alias per model (`kimi-k3`, `kimi-k2p7`, `kimi-for-coding-highspeed`, `kimi-for-coding`) with the same `_CMA_KIMICODE_OAUTH_` sentinel keyvar; OAuth records take precedence over `KIMI_API_KEY`/`ApiKey_Kimi` records (`unique_by` merge, detector first). The launch wrapper refreshes the ~15-minute OAuth token at launch (live credentials file → CLI refresh → snapshot), and routes all `kimi-*` aliases through `proxy/kimi_proxy.py` (`<family>_proxy.py` discovery), which normalizes tool schemas to the moonshot `#/$defs/` flavor k3 requires.

Statuses live in `~/.local/share/claude-multi-account/providers/status.json`; `claude-providers list` shows only `verified`, `list-all` everything, `list-faulty` the filtered-out rest. The launch wrapper refuses non-`verified` aliases unless `--force`.

**Account-dir detection (`cma_detect_accounts`)**: matches `~/.claude-*` but skips (a) `*-shared` and (b) non-empty dirs that don't contain any Claude marker file (`projects/`, `todos/`, `plugins/`, `.claude.json`, `.credentials.json`, `history.jsonl`). This excludes tool-config dirs that share the prefix by coincidence (e.g. `.claude-server-commander` for an MCP server).

**rsync exit-code tolerance**: macOS `rsync` returns 23/24 (partial transfer warnings) for benign issues like `unlinkat: Directory not empty` when symlinks straddle the tree. `merge_dir_into_shared` and `absorb_default_plugins` explicitly tolerate those codes; anything else is fatal.

## Test harness conventions

Tests under `scripts/tests/` are plain bash. Each `test_*.sh` file:

1. Sources `tests/lib/assert.sh` and `tests/lib/sandbox.sh`.
2. Calls `make_sandbox`, which `mktemp`s a fresh `$HOME` and rebinds every env var the toolkit reads (`SHARED_DIR`, `ALIAS_FILE`, `DEFAULT_DIR`, `ACCOUNT_PREFIX`, `CLAUDE_BIN=/usr/bin/true`). An `EXIT` trap cleans up via a `cma-test.*` prefix check — never delete a sandbox path that wasn't produced by `mktemp`.
3. After sourcing `lib.sh` (which sets `set -e`), explicitly call `set +e` so failing-by-design assertions don't abort the script.
4. Uses `make_account NAME [--plugins] [--settings JSON] [--history ...] [--memory K:V] [--todo X]` to populate the sandbox before invoking `run_unify` / `run_add_account` / etc.
5. Ends with `summary`, whose exit code feeds `run-all.sh`'s tally.

When adding tests, the real `~/.claude*` state must never be touched — always go through `make_sandbox`.

## OpenCode integration (`claude-opencode-sync.sh` + `opencode_sync.py`)

`claude-opencode-sync.sh` is a thin bash wrapper (knob parsing, runtime
detection, backup, atomic write) around `opencode_sync.py`, which does the
JSON-heavy scan/translate/merge. It is **additive and idempotent**: existing
OpenCode providers and MCP keys are never clobbered; skill paths and
instructions are unioned; re-running is a no-op on unchanged input.

What it maps from the Claude plugin cache (`CLAUDE_PLUGINS_DIR`, default
`~/.claude/plugins/cache/claude-plugins-official`) into `opencode.json`:

- Plugin `skills/` folders → `skills.paths`.
- `.mcp.json` servers → `mcp{}`, translated to OpenCode's `local`/`remote`
  shapes. **Both** on-disk formats are parsed: wrapped (`{"mcpServers":{…}}`)
  and bare (`{name:{…}}`). `${CLAUDE_PLUGIN_ROOT}` is expanded to the install
  path. Identical servers are deduped by transport identity; genuine name
  clashes are renamed `<plugin>-<name>`.
- `$SHARED_DIR/CLAUDE.md` → `instructions[]`.

**Enable policy** (`opencode_sync.py:build_mcp`): OpenCode connects to every
enabled MCP at startup, so the default enables only a curated allowlist
(`DEFAULT_ALLOWLIST` in the `.sh`) — public no-auth docs servers plus local
servers whose runtime is present and which need no secret env. Everything else
is written `enabled:false` (configured, ready to `opencode mcp auth`). Flags
`--enable-all-local-runnable` and `--enable-all` widen this. Override the list
with `OPENCODE_ALLOWLIST` (one `plugin/server` per line) — the test suite uses
this for deterministic, host-independent assertions.

Tests: `scripts/tests/test_opencode.sh` (hermetic — fakes a plugin tree in the
sandbox, no real `~/.claude`, no opencode binary). `verify_opencode_live.sh`
(live, read-only, writes evidence to `scripts/tests/proof/`; SKIPs if opencode
is absent). `run-proof.sh` runs both and emits `proof/PROOF.md`. The live
verifier captures the full `opencode debug skill` stream before counting —
counting it mid-stream undercounts.

## Portability notes (BSD vs GNU)

The toolkit targets Linux and macOS. Avoid GNU-only constructs: use 2-arg
`awk match()` + `substr`/`RSTART`/`RLENGTH` (not the 3-arg `match($0,re,arr)`
capture form), and portable `mktemp "${TMPDIR:-/tmp}/x.XXXXXX"` (not
`mktemp --suffix`). `cma_ensure_alias_file` only manages `~/.zshrc` on Darwin
(`CMA_RC_FILES`), so platform-sensitive tests must select the rc file the same
way lib.sh does.

## Doc pipeline

`claude-export-docs.sh` reads `~/Documents/Claude_Multi_Account_Fine_Tuning.md` (overridable via `MD_FILE` / `DOC_DIR`), preprocesses `<!-- INCLUDE: relative/path -->` markers via awk to inline external files, then renders self-contained HTML (`pandoc --embed-resources`) and PDF. PDF engines are tried in order: pandoc+weasyprint → pandoc+wkhtmltopdf → weasyprint-on-html → headless chromium. Install at least one PDF engine for full output.

## Upstream remotes

`upstreams/*.sh` each `export UPSTREAMABLE_REPOSITORY=...` for the four mirrors (GitHub, GitLab, GitFlic, GitVerse). These are sourced by external multi-remote push tooling, not by anything in this repo — leave them as one-line exports.
