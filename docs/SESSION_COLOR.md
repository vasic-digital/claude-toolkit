# Per-project sessions & per-alias colors

> One long-lived Claude session per project, shared across every account/provider alias, plus a deterministic, **auto-applied** color per alias (since v1.10.0). Implemented by `scripts/claude-session.sh`, driven by the `cma_run` / `cma_run_provider` alias wrappers in `scripts/lib.sh`.

## Overview

When you launch any toolkit alias with **no arguments** inside a project, the wrapper does two things for you:

1. **Auto-session** — it resumes (or, the first time, creates) *one* long-lived Claude session tied to the project's root directory, named after that directory. Every alias — `claude1`/`claude2`/`claude3` and every provider alias (`deepseek`, `kimi-for-coding`, …) — maps to the **same** session for a given project, so switching aliases continues the same ongoing work.
2. **Auto-color** — it auto-applies a deterministic, per-alias prompt color to that session (by writing the same `agent-color` record `/color` writes), so you can visually tell aliases apart in the TUI without typing anything.

Both behaviors are **opt-out by intent**: they trigger *only* on a bare launch. The moment you pass any argument (a prompt, `-p`, `--resume`, `--session-id`, a flag, anything), the wrapper steps aside and your arguments are passed to `claude` verbatim, and no color is auto-applied. See [Respecting explicit args](#respecting-explicit-args).

---

## Per-project auto-session naming

### How it works

On a bare launch the wrapper calls `claude-session flags`, which:

1. Resolves the **project root** — the git working-tree root if you are inside a repo (`git rev-parse --show-toplevel`), otherwise the current directory (`$PWD`). Because the whole repo shares one root, every subdirectory of a repo maps to the same session.
2. Derives a **stable session UUID** from that root path (md5 of `cma-session:<root>`, formatted as a UUID). The same project path always yields the same id, so the session is shared across all aliases and stable over time.
3. Derives a **session name** = the root directory's basename in lowercase `kebab-case`, sanitized: leading/trailing whitespace is trimmed, internal whitespace and underscores are collapsed to `-`, and any remaining characters that are not `[a-z0-9-]` are stripped.
4. Emits the launch flags:
   - **First time** (no session file on disk yet): `--session-id <uuid> --name <kebab>` — creates the session with that id and name.
   - **Afterwards** (session file exists): `--resume <uuid> --name <kebab>` — resumes the same session and re-applies the name.

It also marks the project as trusted in the launching account's `.claude.json` (suppresses the "workspace has not been trusted" prompt). This is best-effort and never blocks the launch.

### The kebab-case naming rule

The root directory's basename is lowercased, leading/trailing whitespace is trimmed, whitespace and underscores are collapsed to a single `-`, and any remaining characters that are not `[a-z0-9-]` are stripped. Consecutive `-` are collapsed and leading/trailing `-` are trimmed:

| Project directory | Session name |
|---|---|
| `claude_toolkit` | `claude-toolkit` |
| `Android 15` | `android-15` |
| `My-Cool Project` | `my-cool-project` |
| `  My!!!   Project  ` | `my-project` |

> Verified by running `bash scripts/claude-session.sh name <path>`:
> ```
> $ bash scripts/claude-session.sh name "$PWD"          # claude_toolkit repo
> claude-toolkit
> $ bash scripts/claude-session.sh name "/tmp/cma-demo/Android 15"
> android-15
> $ bash scripts/claude-session.sh name "/tmp/cma-demo/My-Cool Project"
> my-cool-project
> $ bash scripts/claude-session.sh name "/tmp/cma-demo/  My!!!   Project  "
> my-project
> ```

### Stable id = shared session

The session id is derived purely from the root path, so it is identical no matter which alias launches it:

```
$ bash scripts/claude-session.sh id "$PWD"
9fdcf748-0fab-00b3-bdb5-e2d6d3a944e9
```

Launch `claude1` in this repo today and `deepseek` tomorrow — both resume `9fdcf748-…`, the same conversation.

### Create vs. resume, and naming on both

The name is passed on **both** create and resume. On a fresh id it names the new session; on a resume it re-applies the name. This is deliberate: it means a session that was created *without* a name — by an older version of the wrapper, or by a plain `claude` invocation — finally gets named on its next bare launch.

> This was verified live against `claude 2.1.195`: `claude --resume <id> --name <x>` renames a previously **unnamed** session (its custom title goes from `<NONE>` to `<x>`). So legacy unnamed sessions are not stuck — they pick up the project name automatically the next time you launch an alias into them.

---

## Per-alias color (auto-applied)

Each alias deterministically maps to one of Claude Code's 8 prompt colors, and since v1.10.0 the toolkit **applies that color for you** on a bare launch. The palette (order is load-bearing, taken from the native binary) is:

```
red  blue  green  yellow  purple  orange  pink  cyan
```

The mapping is `md5(alias-label) mod 8` (`cma_label_color`), so a given alias always maps to the same color, and distinct aliases spread across the palette.

> Verified by running `bash scripts/claude-session.sh color <label>`:

| Alias label | Color |
|---|---|
| `claude1` | purple |
| `claude2` | red |
| `claude3` | orange |
| `deepseek` | red |
| `kimi-for-coding` | purple |
| `xiaomi` | pink |

(The label for a native alias is the config-dir basename with the `.claude-` prefix stripped; for a provider alias it is the provider id.)

### How it's auto-applied

On a bare launch the wrapper calls `claude-session apply-color`, which writes one `agent-color` record into the project session's `.jsonl`:

```json
{"type":"agent-color","agentColor":"purple","sessionId":"9fdcf748-0fab-00b3-bdb5-e2d6d3a944e9"}
```

This is **exactly** the record Claude Code's in-TUI `/color` command writes — the toolkit just writes it from outside the TUI. It is the **only** non-interactive mechanism for setting the prompt color (see [Why injection is the only mechanism](#why-injection-is-the-only-mechanism)).

The wrapper calls `apply-color` twice so the right thing happens in both states:

- **Before launch** — a resumable session's `.jsonl` already exists, so the color is set immediately for this run.
- **After exit** — a brand-new session's `.jsonl` only appears *during* the first launch, so the post-exit call colors it so the color is already in place on the next resume.

It is **idempotent**: the record is appended only when the session's current color differs from the alias's color. So re-launching the same alias adds nothing, and switching aliases on the same project (e.g. `claude1` → `claude2`) re-colors the **same** session by appending one new record — the file never grows unbounded.

> Verified live against `claude 2.1.195` (write + idempotency + re-color of the same session):
> ```
> $ bash scripts/claude-session.sh apply-color "$CFG" claude1   # writes purple
> $ bash scripts/claude-session.sh apply-color "$CFG" claude1   # no-op (same color)
> $ bash scripts/claude-session.sh apply-color "$CFG" claude2   # appends red to the SAME session
> $ grep '"type":"agent-color"' "$CFG/projects/.../<id>.jsonl"
> {"type":"agent-color","agentColor":"purple","sessionId":"9fdcf748-0fab-00b3-bdb5-e2d6d3a944e9"}
> {"type":"agent-color","agentColor":"red","sessionId":"9fdcf748-0fab-00b3-bdb5-e2d6d3a944e9"}
> ```
> The injected record also **persists across `claude --resume`** — re-opening the session keeps the color.

On launch the wrapper also prints a one-line confirmation:

```
$ bash scripts/claude-session.sh hint claude1     # inside the claude_toolkit repo
claude-session: project "claude_toolkit" — alias color: purple (auto-applied).
```

### Honest caveat — confirm it visually once

The toolkit writes the record and the record persists, using the same mechanism `/color` uses, but it **cannot programmatically observe the TUI**. So on the very first launch, glance at the prompt bar to confirm the color rendered as expected. (The in-TUI `/color <color>` still works for the current session, but note the next bare launch of that *same* alias re-applies the alias's deterministic color, since `apply-color` re-colors whenever the session's current color differs from the alias's.)

### Why injection is the only mechanism

There is no supported way to set the prompt color from the command line:

- Claude Code's `/color` is a **TUI-only** command, and `claude -p '/color purple'` is a **no-op** (the slash command is not interpreted in print mode).
- Verified against `claude 2.1.195` (and the official docs): there is **no** CLI flag, **no** `settings.json` key, and **no** environment variable that sets the prompt color.
- The color lives only *inside the session's `.jsonl`* as the `agent-color` record above. Writing that record — what `apply-color` does — is therefore the single non-interactive way to set it.

---

## Respecting explicit args

Auto-session and auto-color fire **only on a bare, no-argument launch** (`$# -eq 0` in both `cma_run` and `cma_run_provider`). If you pass anything, the wrapper does **not** inject `--session-id` / `--resume` / `--name` and does **not** auto-apply a color — your arguments go straight to `claude`:

```bash
claude1                              # auto: resume/create the project session, auto-apply purple
claude1 -p "summarize this file"     # explicit: passed verbatim, no auto-session, no auto-color
claude1 --resume <some-other-uuid>   # explicit: your resume wins
claude1 "write a haiku"              # explicit prompt: passed verbatim
deepseek                             # auto: same project session as claude1, auto-apply deepseek's color
```

The flags `claude-session` emits contain no shell metacharacters (just a UUID and a snake_case name), so the wrapper splits them safely in both bash and zsh.

---

## FAQ

**Why did my old session suddenly get a name?**
Because the name is re-applied on resume. The first time you bare-launch any alias into a project whose session predates this feature (or was created by plain `claude`), the wrapper runs `--resume <id> --name <project_kebab>`, which renames the previously-unnamed session. Verified live on `claude 2.1.195`.

**Is the color automatic?**
Yes, since v1.10.0. On a bare launch the wrapper writes the alias's deterministic color into the session as an `agent-color` record — the same record `/color` writes — via `claude-session apply-color`. Claude Code exposes no CLI flag, settings key, or env var for the color (verified against `claude 2.1.195` and the official docs), and `claude -p '/color x'` is a no-op, so injecting that record is the only non-interactive mechanism. It is idempotent and persists across `--resume`. The toolkit can't see the TUI, so confirm the prompt-bar rendering visually on first launch.

**Can I change the session name?**
The auto-name is just the project directory's basename in snake_case, so the simplest way is to rename (or work from) a differently-named directory. Within a running session you can also use Claude Code's own `/rename` to set a custom title; note that a later bare launch will re-apply the directory-derived name on resume.

**Do all my aliases really share one session per project?**
Yes — the session id is derived from the project root path, not from the alias, so `claude1`, `claude2`, `claude3`, and every provider alias resume the same id for a given project.

---

## Reference

- Implementation: `scripts/claude-session.sh` (`cma_project_root`, `cma_session_name`, `cma_session_id`, `cma_label_color`, `cma_trust_project`).
- Alias wrappers that call it: `cma_run` and `cma_run_provider` in `scripts/lib.sh`.
- Subcommands you can run yourself:
  - `claude-session name [path]` — print the kebab-case session name.
  - `claude-session id [path]` — print the stable session UUID.
  - `claude-session color <label>` — print the mapped color for an alias label.
  - `claude-session apply-color <config_dir> <label>` — write the alias's `agent-color` record into the project session's `.jsonl` (idempotent; used by the wrappers to auto-apply the color).
  - `claude-session hint <label> [path]` — print the human color/session confirmation (on stderr).
  - `claude-session flags <config_dir>` — print the launch flags (used by the wrappers).
