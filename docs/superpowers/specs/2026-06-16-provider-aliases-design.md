# Provider Aliases for the Claude Multi-Account Toolkit — Design Spec

**Date:** 2026-06-16
**Status:** Approved design (pending written-spec review)
**Author:** Claude (brainstormed with Milos Vasic)

## 1. Problem & Goal

The toolkit already runs multiple **Claude** accounts (`claude1..N`) on one host with
unified history/memory/todos/plans/plugins/settings via symlink convergence into
`$SHARED_DIR`. We now want to run **other LLM providers** through the same Claude Code
binary, each as its own shell alias, fully **dynamically** — no hardcoded provider
list, base URLs, or model IDs.

For every LLM provider whose API key is present in the keys file, generate a Claude Code
alias whose:

- **command name** derives from the provider (DeepSeek → `dseek`),
- **models** are set to that provider's *strongest* (main) + a *fast* (background) model,
- session **default color is purple** (to visually distinguish provider sessions),
- **all installed plugins** (from `claude1..N`) are available,
- these are always ready: **superpowers, systematic-debugging, frontend-design
  ("claude design"), code-review**.

The command is **re-runnable** (add new providers / refresh / sync), supports full
lifecycle (create/update/sync/list/show/remove/add), is **fully tested**, **fully
documented** (README + long-form doc + user guide + diagrams, exported to HTML/PDF/DOCX),
**code-reviewed**, then committed and pushed to all four upstreams with a GitHub + GitLab
release.

### Non-negotiable safety constraints

- Existing `claude1..N` aliases keep working **unchanged**.
- Creating regular accounts via `claude-add-account` still works **unchanged**.
- All `.bashrc`/`.zshrc` manipulation is automatic and idempotent (reuse existing
  `cma_ensure_alias_file` machinery — never hand-edit rc files).
- Secrets never land in the repo or in the alias file.
- Nothing is hardcoded that can be derived at runtime.

## 2. Inputs (the data sources — nothing hardcoded)

| Source | Role | Notes |
|--------|------|-------|
| `~/api_keys.sh` (override: `--keys-file` / `$CMA_KEYS_FILE`) | Which keys/providers the user has | Sourced only at launch + during verify; key **values** never leave it. |
| `models.dev/api.json` | Catalog: provider→`env`,`api`,`npm`,`models{cost,limit,reasoning,release_date,...}` | Cached locally with TTL; graceful degrade when offline. |
| `submodules/LLMsVerifier` (git submodule) | Validation/verification of keys + model existence/responsiveness | Pluggable: used if built binary present, else built-in probe. |
| Official provider `/models` APIs | Verification fallback + cross-check | Used by the built-in probe. |
| `providers/key-aliases.json` (small, editable) | Normalize key var name ↔ models.dev provider id | Only for human-named mismatches (KIMI→moonshot, ZAI→zhipu, GITHUB_MODELS→github-models, …). |
| `providers/overrides.json` (optional, editable) | Per-provider manual override of strong/fast model, base URL, transport, alias name | Empty by default; lets a user pin choices. |

### Key classification

Each var in the keys file is classified:

- **llm** — matches a models.dev provider (directly or via `key-aliases.json`) → alias candidate.
- **vcs** — `GITHUB_*`, `GITLAB_TOKEN`, `GITFLIC_TOKEN`, `GITVERSE_TOKEN` → reused by the release step, never an alias.
- **infra** — `FIRBASE_CLI_TOKEN`, `CLOUDFLARE_API_KEY`, `MODAL_API_KEY*` → ignored for aliases.
- **unmapped** — looks like an LLM key but no models.dev match and no alias entry → skipped with a logged note; re-checked next sync.

## 3. Architecture

### 3.1 Entry command: `claude-providers`

One re-runnable command (symlinked into `~/.local/bin` like the rest of the `claude-*`
family), with subcommands:

- `sync` *(default)* — run the discovery→select→verify→generate pipeline; create/refresh
  one alias per present, verified LLM key. **Idempotent.**
- `list` — table of installed provider aliases: command name, provider, strong+fast model,
  transport (native/router), verification status, key-present?.
- `show <id>` — full detail for one provider (resolved env file, config dir, models, URLs).
- `remove <id>` — remove alias + config dir via `backup_and_remove`; keep caches.
- `add [--from-key VAR] [--id ID]` — register/normalize a provider mapping (writes
  `key-aliases.json`/`overrides.json`) then runs a scoped `sync`.

Global flags: `--keys-file PATH`, `--no-verify`, `--offline`, `--enable-all`,
`--dry-run`, `--yes`.

### 3.2 The sync pipeline (data-driven)

```
~/api_keys.sh ──► [parse key var names]
models.dev/api.json (cached) ──► [match env→provider via key-aliases.json]
                                  [select strong+fast from metadata / overrides.json]
LLMsVerifier or built-in probe ─► [verify key works + models exist/respond]
                                  ▼
                          for each verified provider:
                            • write providers/<id>.env (non-secret)
                            • ensure ~/.claude-prov-<id> (link SHARED_ITEMS, purple seed)
                            • write alias: alias <name>="cma_run_provider <id>"
                            • if router transport: add to claude-code-router config
                          unverified ► written disabled + logged reason
```

### 3.3 Runtime: `cma_run_provider <id>` (new wrapper in the alias file)

Sibling to existing `cma_run`. At launch:

1. Source `$CMA_KEYS_FILE` (default `~/api_keys.sh`) — get the secret into memory.
2. Read `providers/<id>.env` (base_url, key var **name**, strong/fast model, transport, config dir).
3. Export `CLAUDE_CONFIG_DIR`, `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN="${!key_var}"`,
   `ANTHROPIC_MODEL` (strong), `ANTHROPIC_SMALL_FAST_MODEL` (fast).
4. For `router` transport: ensure `claude-code-router` is up; point `ANTHROPIC_BASE_URL`
   at it.
5. Do the same sync-state pull/push as `cma_run`; launch `$CLAUDE_BIN "$@"`.

Secrets exist only in `~/api_keys.sh` and transiently in the launched process env.

### 3.4 Provider config dirs

- `~/.claude-prov-<id>` symlinks the same `SHARED_ITEMS` as accounts → **all plugins**,
  history, projects shared automatically.
- Auth files (`.claude.json`, `.credentials.json`, `mcp-needs-auth-cache.json`) stay
  private (and are unneeded — token comes from env).
- **Account auto-detection (`cma_detect_accounts`) is updated to skip `*-prov-*`** exactly
  as it skips `*-shared`, so provider dirs never merge into real-account auth and never
  interfere with unify/add/remove. This is the linchpin of "nothing breaks."

### 3.5 Always-on plugins/skills

`sync` ensures the shared `settings.json` `enabledPlugins` union includes superpowers,
systematic-debugging, frontend-design, code-review (additive; never removes existing).
Because settings + plugins are shared, every provider session inherits them. The
`using-superpowers` bootstrap already auto-loads at session start.

### 3.6 Default color = purple

Each provider config dir is seeded so its default session color is purple. **Mechanism to
be verified during implementation** by inspecting how `/color` persists (it set "green"
this session, so it writes a discoverable setting); if no persistable key exists, fall
back to a documented note in the user guide rather than fabricating behavior.

## 4. Strong/Fast model selection heuristic (documented, overridable)

From models.dev `models{}` for the provider:

- **strong** = prefer `reasoning:true`, then newest `release_date`, then largest
  `limit.context`; tie-break highest `cost.output` (proxy for flagship).
- **fast** = lowest `cost.input` among tool-call-capable models; tie-break smallest context.

`overrides.json` can pin either per provider. The heuristic and override schema are
documented in the user guide.

## 5. Components / files

```
scripts/
  claude-providers.sh            # entry command (subcommands)
  providers-verify.sh            # thin adapter → LLMsVerifier binary or built-in probe
  lib.sh                         # + cma_provider_* helpers, cma_run_provider, detection skip
  providers/
    key-aliases.json             # editable name normalization
    overrides.json               # editable per-provider overrides (empty default)
    models.dev.cache.json        # TTL cache (gitignored)
  tests/
    test_providers.sh            # hermetic sandbox suite
    verify_providers_live.sh     # read-only live verifier (SKIP if no net/binary)
submodules/LLMsVerifier          # git submodule
docs/
  Provider_Aliases_User_Guide.md # the manual
  diagrams/                       # mermaid sources + rendered svg/png
~/.local/share/claude-multi-account/
  providers/<id>.env             # generated, non-secret, per provider
```

`claude-add-account.sh` `SHARED_ITEMS` list and `claude-providers` must stay in sync
(same note as the existing add-account/unify coupling).

## 6. Testing (all supported types, hermetic)

`scripts/tests/test_providers.sh` via `make_sandbox` (fake `$HOME`, `CLAUDE_BIN=/usr/bin/true`,
fake keys file, fake models.dev cache, `--no-verify` or stubbed verifier):

- **Unit** — each `cma_provider_*` helper (parse keys, match env, select models, classify).
- **Integration** — `sync` end-to-end produces expected env files, aliases, config dirs, ccr config.
- **Idempotency** — second `sync` is a no-op (byte-stable).
- **Lifecycle** — `list`/`show`/`remove` behave; `add` writes mappings.
- **Regression (critical)** — existing `claudeN` aliases untouched; `add-account` still
  works; `cma_detect_accounts` excludes `*-prov-*`; rollback unaffected.
- **Offline** — graceful degrade with cache; clear error with no cache.
- **Security** — no secret value written to alias file / env files / repo.

Wired into `run-all.sh`; live read-only verifier added to `run-proof.sh`
(`verify_providers_live.sh`, SKIPs without network/binary, writes evidence to `proof/`).

## 7. Documentation & exports

- Update root `README.md`, `scripts/README.md`, and `Claude_Multi_Account_Fine_Tuning.md`
  (new "Provider Aliases" chapter, including the `models.dev` + LLMsVerifier flow).
- New `docs/Provider_Aliases_User_Guide.md` — every command/flag, the keys-file contract,
  provider table, color note, troubleshooting.
- Diagrams (mermaid → rendered): architecture + alias→wrapper→keys→backend data flow +
  sync pipeline.
- Extend `claude-export-docs.sh` to also emit **DOCX** (pandoc `--reference-doc` styling)
  alongside HTML/PDF, covering the new guide and the long-form doc.

## 8. Finish sequence (high-stakes — explicit checkpoint)

1. **Mandatory `/code-review`** of the full diff; address findings.
2. Run full test suite + proof (`run-all.sh`, `run-proof.sh`) green.
3. **Pause for explicit user go-ahead** (pushing to 4 remotes + publishing releases is
   irreversible/outward-facing).
4. Add LLMsVerifier submodule; commit submodule + main repo.
5. Push to all four upstreams (`origin` already fans out to github/gitlab/gitflic/gitverse).
6. `claude-providers sync` (the actual creation run) once everything is validated.
7. Cut GitHub + GitLab releases with a comprehensive changelog (CLI: `gh release`, `glab
   release`), using VCS tokens from the keys file.

## 9. Risks & mitigations

| Risk | Mitigation |
|------|-----------|
| Provider dirs polluting account merge | Exclude `*-prov-*` from `cma_detect_accounts` + regression test. |
| Secrets leaking | Wrapper-only injection; security test asserts no values in generated files. |
| models.dev offline | TTL cache + graceful degrade. |
| LLMsVerifier build heavy | Pluggable; built-in probe fallback. |
| Router (ccr) not installed | `sync` detects; router-backed aliases written disabled with install hint; native providers unaffected. |
| Key name mismatches | Editable `key-aliases.json`; `add` subcommand to register. |
| Breaking existing aliases/rc files | Reuse `cma_*` alias machinery; idempotent; regression tests. |

## 10. Out of scope (YAGNI)

- Non-LLM key types beyond classification (no Firebase/Cloudflare/Modal integrations).
- A GUI/TUI (LLMsVerifier has its own; not wrapped here).
- Per-message model switching inside a session (use Claude Code's own `/model`).
