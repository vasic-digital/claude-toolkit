# Claude Code: `/color` persistence + custom-provider env-var support

Research date: 2026-06-16
Host: macOS (Darwin 24.5.0), arm64
Branch: `feat/provider-aliases`

| Fact | Value |
|------|-------|
| `which claude` | `/Users/milosvasic/.local/bin/claude` |
| symlink target | `/Users/milosvasic/.local/share/claude/versions/2.1.178` |
| `claude --version` | `2.1.178 (Claude Code)` |
| binary type | Mach-O 64-bit arm64 (Bun-compiled single binary, ~226 MB) — no extractable `cli.js`; evidence gathered via `strings`/`perl` against the binary |

All secret values encountered were redacted as `<redacted>`. No secrets are reproduced in this document.

---

## 1. Color persistence

### What `/color` actually is

The `/color` slash command is registered in the binary as:

```
name:"color",
description:"Set the prompt bar color for this session",
immediate:!0,
argumentHint:`[${[...uY,"default"].join("|")}]`,
requires:{ink:!0},
load:()=>Promise.resolve().then(...)   // lazy module a64
```

Key observations:

- Description is literally **"Set the prompt bar color for this session"** — session-scoped wording.
- `requires:{ink:!0}` — the command only runs inside the interactive Ink TUI.
- The valid color arguments come from the array
  `uY=["red","blue","green","yellow","purple","orange","pink","cyan"]`
  plus `default`/`reset`/`none`/`gray`/`grey`. **`orange` is a valid value.**
- The handler module (`a64`/`EAq`) wires up React/Ink state setters. It does **not** call any global-config (`.claude.json`) or `settings.json` write path. There is no `saveGlobalConfig`/`setConfig` tied to the color value.

### Searching for a persisted value

This session was reportedly set to `green` via `/color`. Searches for a persisted color value found nothing relevant:

- `grep -rl '"green"'` across `~/.claude*` returned **only plugin JSON schema files** (SAP MDK control colors, hyperframes caption themes) — pure noise, no session-color setting.
- `jq` over every `.claude.json` (`~/.claude.json` and all `~/.claude-*/.claude.json`): the only `color` scalars are unrelated feature-tip caches:
  - `cachedDynamicConfigs.tengu-top-of-feed-tip.color = ""`
  - `cachedGrowthBookFeatures.tengu-top-of-feed-tip.color = warning`
  - The other `color`/`theme` hits are tip counters (`tipsHistory.color-when-multi-clauding`, `tipsHistory.theme-command`, `tipLifetimeShownCounts.*`).
- No `color` field exists in the per-project subtree of `.claude.json` (project keys are session/cost/tool metadata only — no `color`/`terminalColor`/`sessionColor`).
- The settings schema in the binary has exactly one color/theme-related persisted key: `"theme"` (22 occurrences). There is **no** `messageColor`, `promptBarColor`, `sessionColor`, or `defaultColor` settings key (0 occurrences of each).

### What IS persisted

`settings.json` persists `"theme"` (light/dark/etc.), confirmed present in every account file:

```
/Users/milosvasic/.claude-shared/settings.json:215:  "theme": "dark"
/Users/milosvasic/.claude-milos85vasic/settings.json:215:  "theme": "dark"
/Users/milosvasic/.claude-milos85vasic2nd/settings.json:215:  "theme": "dark"
/Users/milosvasic/.claude-milos85vasic3rd/settings.json:215:  "theme": "dark"
```

`theme` controls the overall light/dark palette — it is NOT the per-session prompt-bar color that `/color` sets.

### CONCLUSION (Color persistence)

**There is no persistable on-disk mechanism to default a config dir's `/color` (prompt-bar) color to orange in Claude Code 2.1.178.** The `/color` command sets the prompt-bar color *for the current interactive session only* (`requires:{ink:!0}`, "for this session"), holds it in in-memory TUI state, and writes it to neither `settings.json` nor `.claude.json`. No `color`-family settings key exists in the binary's settings schema; the only persisted appearance key is `"theme"` (light/dark), which is a different concept.

Documented fallback for seeding per-provider dirs: there is no supported config key, so the only ways to make a new provider dir start orange are operational, not config:
1. Have the launcher/alias for that provider run `/color orange` automatically at startup — e.g. pipe it as the first input, or use a session-bootstrap that issues the `/color orange` command after the TUI loads. (`orange` is a valid argument.)
2. Use the distinct, persistable `"theme"` key in that dir's `settings.json` if a different overall palette — not a prompt-bar accent — is acceptable.
If neither is acceptable, file/track an upstream request, because the prompt-bar color is intentionally session-only in this version.

---

## 2. Env-var support for custom providers

The installed `claude` 2.1.178 binary contains all four requested environment variable names as literal strings (counts from `strings | grep | uniq -c` over the binary):

```
54  ANTHROPIC_AUTH_TOKEN
50  ANTHROPIC_BASE_URL
56  ANTHROPIC_DEFAULT_HAIKU_MODEL
19  ANTHROPIC_MODEL
35  ANTHROPIC_SMALL_FAST_MODEL
13  CLAUDE_CODE_SUBAGENT_MODEL
```

Corroborating evidence that these are *read* (not just incidental strings):

- The binary embeds a built-in "profile" concept for alternate providers. A help string reads:
  `"...sets ANTHROPIC_AUTH_TOKEN (and ANTHROPIC_BASE_URL if the profile has one). Output is bare KEY=value (no \`export\`), so use \`set -a\` to auto-export for..."`
  — this directly ties `ANTHROPIC_AUTH_TOKEN` + `ANTHROPIC_BASE_URL` to provider/profile selection.
- `claude --help` documents `--model` ("Model for the current session... an alias for the latest model... settings still apply. Auth, model...") and `--fallback-model`, consistent with `ANTHROPIC_MODEL` driving the main model and `ANTHROPIC_SMALL_FAST_MODEL` driving the small/fast (background) model.
- These four variables are the long-standing, officially-documented Claude Code custom-API-provider knobs: `ANTHROPIC_BASE_URL` (provider endpoint), `ANTHROPIC_AUTH_TOKEN` (bearer token sent as `Authorization`), `ANTHROPIC_MODEL` (primary model id), `ANTHROPIC_SMALL_FAST_MODEL` (background/haiku-class model id). Their presence as embedded strings in this exact build is the local confirmation. (No network/official-docs fetch was performed; this is the on-disk evidence.)

### CONCLUSION (Env var support)

**Confirmed.** Claude Code `2.1.178` reads all four: `ANTHROPIC_BASE_URL`, `ANTHROPIC_AUTH_TOKEN`, `ANTHROPIC_MODEL`, and `ANTHROPIC_SMALL_FAST_MODEL` (all present as literal env-var strings in the binary, with a built-in profile mechanism that explicitly sets `ANTHROPIC_AUTH_TOKEN`/`ANTHROPIC_BASE_URL`). The build also supports the related `ANTHROPIC_DEFAULT_HAIKU_MODEL` and `CLAUDE_CODE_SUBAGENT_MODEL`. Custom per-provider config dirs can be driven entirely through these env vars.

---

## EVIDENCE appendix (raw, redacted)

### E1 — binary identity
```
$ which claude
/Users/milosvasic/.local/bin/claude
$ ls -l ~/.local/bin/claude
... /Users/milosvasic/.local/bin/claude -> /Users/milosvasic/.local/share/claude/versions/2.1.178
$ claude --version
2.1.178 (Claude Code)
$ file <target>
/Users/milosvasic/.local/share/claude/versions/2.1.178: Mach-O 64-bit executable arm64  (226032672 bytes)
```

### E2 — color/theme keys in config files
```
$ grep -in 'color\|theme' ~/.claude-shared/settings.json
215:  "theme": "dark"
# identical line 215 in ~/.claude-milos85vasic{,2nd,3rd}/settings.json
$ grep -in 'color\|theme' ~/.claude/settings.json
(no matches)
$ jq 'paths(scalars) | select(.[-1]=="color")' ~/.claude.json
cachedDynamicConfigs.tengu-top-of-feed-tip.color = ""
cachedGrowthBookFeatures.tengu-top-of-feed-tip.color = warning
```
(`.claude.json` `color`/`theme` hits at depth: `tipsHistory.theme-command`, `tipsHistory.color-when-multi-clauding`, `tipLifetimeShownCounts.*`, `cachedDynamicConfigs/cachedGrowthBookFeatures.tengu-top-of-feed-tip.color` — all tip/feature caches, no session color.)

### E3 — `grep '"green"'` across ~/.claude* (representative)
```
$ grep -rl --include='*.json' -i '"green"' ~/.claude* 2>/dev/null
.../plugins/.../sap-mdk-server/.../SectionedTable/Control/ObjectCell.json
.../plugins/.../sap-mdk-server/.../SectionedTable/Control/TagItem.json
.../plugins/.../hyperframes/.../skills/embedded-captions/themes/vhs.json
   (all hits are plugin schema/theme assets — no Claude session-color setting)
```

### E4 — `/color` command registration (from binary)
```
name:"color",description:"Set the prompt bar color for this session",immediate:!0,
  argumentHint:`[${[...uY,"default"].join("|")}]`,requires:{ink:!0},
  load:()=>Promise.resolve().then(() => (EAq(),a64))

uY=["red","blue","green","yellow","purple","orange","pink","cyan"]
EAq=L(()=>{ ... ; EpO=["default","reset","none","gray","grey"] })
```

### E5 — no color settings key (only theme)
```
$ strings <bin> | grep -oE '"(theme|messageColor|promptBarColor|defaultColor|sessionColor)"' | sort | uniq -c
  22 "theme"
   # messageColor / promptBarColor / defaultColor / sessionColor : 0 occurrences
```

### E6 — env vars present in binary
```
$ strings -a <bin> | grep -oE 'ANTHROPIC_BASE_URL|ANTHROPIC_AUTH_TOKEN|ANTHROPIC_MODEL|ANTHROPIC_SMALL_FAST_MODEL|ANTHROPIC_DEFAULT_HAIKU_MODEL|CLAUDE_CODE_SUBAGENT_MODEL' | sort | uniq -c
  54 ANTHROPIC_AUTH_TOKEN
  50 ANTHROPIC_BASE_URL
  56 ANTHROPIC_DEFAULT_HAIKU_MODEL
  19 ANTHROPIC_MODEL
  35 ANTHROPIC_SMALL_FAST_MODEL
  13 CLAUDE_CODE_SUBAGENT_MODEL
```

### E7 — provider/profile help string tying env vars together
```
... sets ANTHROPIC_AUTH_TOKEN (and ANTHROPIC_BASE_URL if the profile has one).
# Output is bare KEY=value (no `export`), so use `set -a` to auto-export ...
```
