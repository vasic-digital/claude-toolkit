# Per-project sessions & per-alias colors

> One long-lived Claude session per project, shared across every account/provider alias, plus a deterministic color hint per alias. Implemented by `scripts/claude-session.sh`, driven by the `cma_run` / `cma_run_provider` alias wrappers in `scripts/lib.sh`.

## Overview

When you launch any toolkit alias with **no arguments** inside a project, the wrapper does two things for you:

1. **Auto-session** — it resumes (or, the first time, creates) *one* long-lived Claude session tied to the project's root directory, named after that directory. Every alias — `claude1`/`claude2`/`claude3` and every provider alias (`deepseek`, `kimi-for-coding`, …) — maps to the **same** session for a given project, so switching aliases continues the same ongoing work.
2. **Color hint** — it prints a deterministic, per-alias `/color` suggestion so you can visually tell aliases apart in the TUI.

Both behaviors are **opt-out by intent**: they trigger *only* on a bare launch. The moment you pass any argument (a prompt, `-p`, `--resume`, `--session-id`, a flag, anything), the wrapper steps aside and your arguments are passed to `claude` verbatim. See [Respecting explicit args](#respecting-explicit-args).

---

## Per-project auto-session naming

### How it works

On a bare launch the wrapper calls `claude-session flags`, which:

1. Resolves the **project root** — the git working-tree root if you are inside a repo (`git rev-parse --show-toplevel`), otherwise the current directory (`$PWD`). Because the whole repo shares one root, every subdirectory of a repo maps to the same session.
2. Derives a **stable session UUID** from that root path (md5 of `cma-session:<root>`, formatted as a UUID). The same project path always yields the same id, so the session is shared across all aliases and stable over time.
3. Derives a **session name** = the root directory's basename in lowercase `snake_case`.
4. Emits the launch flags:
   - **First time** (no session file on disk yet): `--session-id <uuid> --name <snake>` — creates the session with that id and name.
   - **Afterwards** (session file exists): `--resume <uuid> --name <snake>` — resumes the same session and re-applies the name.

It also marks the project as trusted in the launching account's `.claude.json` (suppresses the "workspace has not been trusted" prompt). This is best-effort and never blocks the launch.

### The snake_case naming rule

The root directory's basename is lowercased and every run of non-`[a-z0-9]` characters is collapsed to a single `_`, with leading/trailing underscores trimmed:

| Project directory | Session name |
|---|---|
| `claude_toolkit` | `claude_toolkit` |
| `Android 15` | `android_15` |
| `My-Cool Project` | `my_cool_project` |

> Verified by running `bash scripts/claude-session.sh name <path>`:
> ```
> $ bash scripts/claude-session.sh name "$PWD"          # claude_toolkit repo
> claude_toolkit
> $ bash scripts/claude-session.sh name "/tmp/cma-demo/Android 15"
> android_15
> $ bash scripts/claude-session.sh name "/tmp/cma-demo/My-Cool Project"
> my_cool_project
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

## Per-alias color (and its limitation)

Each alias deterministically maps to one of Claude Code's 8 prompt colors. The palette (order is load-bearing, taken from the native binary) is:

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

### Why it's a hint, not auto-applied

**The toolkit cannot set the color for you.** This is a limitation of Claude Code itself, not the toolkit:

- Claude Code's `/color` is a **TUI-only** command. It cannot be set non-interactively.
- Verified against `claude 2.1.195` (and the official docs): there is **no** CLI flag, **no** `settings.json` key, and **no** environment variable that sets the prompt color.
- The chosen color lives only *inside the session's `.jsonl`* as an `agent-color` record, which is written by the in-TUI `/color` command — there is no supported way to write it from outside.

So instead of silently failing, the wrapper **prints a hint** on launch telling you exactly what to type:

```
$ bash scripts/claude-session.sh hint claude1     # inside the claude_toolkit repo
claude-session: project "claude_toolkit" — tip: type  /color purple  to tag this alias.
```

### How to apply it manually

Inside the Claude Code TUI, type the suggested command once per alias, e.g.:

```
/color purple
```

Claude Code persists the choice in the session, so you only need to do it once per session.

---

## Respecting explicit args

Auto-session and the color hint fire **only on a bare, no-argument launch** (`$# -eq 0` in both `cma_run` and `cma_run_provider`). If you pass anything, the wrapper does **not** inject `--session-id` / `--resume` / `--name` — your arguments go straight to `claude`:

```bash
claude1                              # auto: resume/create the project session, print color hint
claude1 -p "summarize this file"     # explicit: passed verbatim, no auto-session
claude1 --resume <some-other-uuid>   # explicit: your resume wins
claude1 "write a haiku"              # explicit prompt: passed verbatim
deepseek                             # auto: same project session as claude1, deepseek color hint
```

The flags `claude-session` emits contain no shell metacharacters (just a UUID and a snake_case name), so the wrapper splits them safely in both bash and zsh.

---

## FAQ

**Why did my old session suddenly get a name?**
Because the name is re-applied on resume. The first time you bare-launch any alias into a project whose session predates this feature (or was created by plain `claude`), the wrapper runs `--resume <id> --name <project_snake>`, which renames the previously-unnamed session. Verified live on `claude 2.1.195`.

**Why isn't the color automatic?**
Because Claude Code only supports setting the prompt color via the interactive `/color` command — there is no CLI flag, settings key, or env var to do it non-interactively (verified against `claude 2.1.195` and the official docs). The toolkit prints a deterministic hint so you can apply it yourself with one `/color <color>`.

**Can I change the session name?**
The auto-name is just the project directory's basename in snake_case, so the simplest way is to rename (or work from) a differently-named directory. Within a running session you can also use Claude Code's own `/rename` to set a custom title; note that a later bare launch will re-apply the directory-derived name on resume.

**Do all my aliases really share one session per project?**
Yes — the session id is derived from the project root path, not from the alias, so `claude1`, `claude2`, `claude3`, and every provider alias resume the same id for a given project.

---

## Reference

- Implementation: `scripts/claude-session.sh` (`cma_project_root`, `cma_session_name`, `cma_session_id`, `cma_label_color`, `cma_trust_project`).
- Alias wrappers that call it: `cma_run` and `cma_run_provider` in `scripts/lib.sh`.
- Subcommands you can run yourself:
  - `claude-session name [path]` — print the snake_case session name.
  - `claude-session id [path]` — print the stable session UUID.
  - `claude-session color <label>` — print the mapped color for an alias label.
  - `claude-session hint <label> [path]` — print the human color/session hint (on stderr).
  - `claude-session flags <config_dir>` — print the launch flags (used by the wrappers).
