#!/usr/bin/env bash
# claude-session.sh — derive per-project session launch flags for the alias
# wrappers (cma_run / cma_run_provider).
#
# Each project (identified by its root directory) gets ONE long-lived Claude
# session so launching any alias inside it resumes the same ongoing work, or
# creates it the first time. The session is keyed by a STABLE id derived from
# the project root path, and named after the root dir in lowercase snake_case.
#
# It also marks the project as trusted in the launching account's .claude.json
# (suppresses the "workspace has not been trusted" warning), and prints a
# one-line color hint mapped from the alias label (Claude Code's /color is a
# TUI-only command that cannot be set non-interactively, so we can only suggest
# it — see docs/SESSION_COLOR.md).
#
# Subcommands:
#   flags <config_dir>          Print launch flags for `claude` on stdout:
#                               either `--resume <sid>` (session exists) or
#                               `--session-id <sid> --name <snake>` (first run).
#                               Side effect: trust the project in <config_dir>.
#   name  [path]                Print the snake_case session name for a path.
#   id    [path]                Print the stable session UUID for a path.
#   color <label>              Print the mapped color for an alias label.
#   hint  <label> [path]        Print a human color/session hint on stderr.
#
# All subcommands default <path> to $PWD's project root (git toplevel if any,
# else $PWD). Designed to be sourced-free: a normal PATH script with a shebang,
# so it runs under a known bash regardless of the user's interactive shell.
set -euo pipefail

# Claude Code's /color palette (verified from the native binary: the `Ky`
# array). Order is load-bearing for the deterministic label->color mapping.
CMA_COLORS=(red blue green yellow purple orange pink cyan)

# Resolve the project root: prefer the git working-tree root so every dir in a
# repo shares one session; fall back to the given path (or $PWD).
cma_project_root() {
  local p="${1:-$PWD}"
  local root
  if root="$(cd "$p" 2>/dev/null && git rev-parse --show-toplevel 2>/dev/null)"; then
    printf '%s\n' "$root"
  else
    ( cd "$p" 2>/dev/null && pwd -P ) || printf '%s\n' "$p"
  fi
}

# lowercase snake_case of the root dir's basename, no spaces/specials.
cma_session_name() {
  local root base
  root="$(cma_project_root "${1:-$PWD}")"
  base="$(basename "$root")"
  printf '%s\n' "$base" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/_/g; s/_+/_/g; s/^_//; s/_$//'
}

# Stable RFC-4122-shaped UUID derived from the project root path. md5 is enough
# (we only need determinism + valid UUID syntax, not crypto). Portable across
# Linux (md5sum) and macOS (md5).
cma_session_id() {
  local root hash
  root="$(cma_project_root "${1:-$PWD}")"
  if command -v md5sum >/dev/null 2>&1; then
    hash="$(printf '%s' "cma-session:$root" | md5sum | cut -d' ' -f1)"
  else
    hash="$(printf '%s' "cma-session:$root" | md5 -q)"
  fi
  printf '%s-%s-%s-%s-%s\n' \
    "${hash:0:8}" "${hash:8:4}" "${hash:12:4}" "${hash:16:4}" "${hash:20:12}"
}

# Deterministic alias-label -> color. Hash the label with md5 and reduce the
# leading hex digits mod the palette size: same alias always maps to the same
# color, and distinct aliases (claude1/claude2/xiaomi/…) spread across the
# palette far better than a raw byte-sum (which clustered many on one color).
cma_label_color() {
  local label="${1:-}" hash num
  if command -v md5sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$label" | md5sum | cut -d' ' -f1)"
  elif command -v md5 >/dev/null 2>&1; then
    hash="$(printf '%s' "$label" | md5 -q)"
  else
    hash="$(printf '%s' "$label" | cksum | cut -d' ' -f1)"
  fi
  # Take 6 leading hex digits -> integer -> mod palette size.
  num=$(( 0x${hash:0:6} % ${#CMA_COLORS[@]} ))
  printf '%s\n' "${CMA_COLORS[$num]}"
}

# Mark the project as trusted in <config_dir>/.claude.json so Claude Code does
# not warn "this workspace has not been trusted". Idempotent; no-op without jq
# or a writable file. Never throws (the launch must proceed regardless).
cma_trust_project() {
  local config_dir="$1" root="$2" f tmp
  f="$config_dir/.claude.json"
  command -v jq >/dev/null 2>&1 || return 0
  [[ -f "$f" ]] || printf '{}\n' > "$f" 2>/dev/null || return 0
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX" 2>/dev/null)" || return 0
  if jq --arg p "$root" '
        .projects = (.projects // {})
        | .projects[$p] = ((.projects[$p] // {}) + {hasTrustDialogAccepted: true})
      ' "$f" > "$tmp" 2>/dev/null && [[ -s "$tmp" ]]; then
    mv "$tmp" "$f" 2>/dev/null || rm -f "$tmp"
  else
    rm -f "$tmp"
  fi
}

main() {
  local cmd="${1:-flags}"; shift 2>/dev/null || true
  case "$cmd" in
    name)  cma_session_name "${1:-$PWD}" ;;
    id)    cma_session_id "${1:-$PWD}" ;;
    color) cma_label_color "${1:-}" ;;
    flags)
      local config_dir="${1:-$CLAUDE_CONFIG_DIR}" root sid name proj_slug sess_file
      root="$(cma_project_root "$PWD")"
      sid="$(cma_session_id "$root")"
      name="$(cma_session_name "$root")"
      # Best-effort trust (never blocks launch).
      cma_trust_project "$config_dir" "$root" || true
      # Claude stores sessions at <config_dir>/projects/<slug>/<uuid>.jsonl,
      # where <slug> replaces EACH non-alnum char with '-' (NO run-collapsing —
      # verified against claude 2.1.195's real on-disk dirs, e.g. /tmp/.private
      # -> -tmp--private). The old collapsing form caused a false-negative
      # existence check for paths with consecutive separators (hidden dirs,
      # __pycache__), making the launcher re-create instead of resume.
      proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
      sess_file="$config_dir/projects/$proj_slug/$sid.jsonl"
      # Always pass --name: on a fresh id it names the new session; on --resume it
      # (re)applies the name, which is how an EXISTING unnamed session — created by
      # an older wrapper or by plain `claude` — finally gets named. Verified live
      # against claude 2.1.195: `claude --resume <id> --name <x>` renames a
      # previously-unnamed session (custom-title goes <NONE> -> <x>).
      if [[ -f "$sess_file" ]]; then
        printf -- '--resume %s --name %s\n' "$sid" "$name"
      else
        printf -- '--session-id %s --name %s\n' "$sid" "$name"
      fi
      ;;
    apply-color)
      # Auto-apply the per-alias prompt-bar color by writing an `agent-color`
      # record into the session jsonl — the ONLY non-interactive way to set color
      # in claude 2.1.195 (/color is TUI-only; `claude -p '/color x'` is a no-op).
      # Verified live: an injected agent-color record is exactly what /color
      # writes and it PERSISTS across --resume. Idempotent: only appends when the
      # session's current color differs (e.g. you switched aliases on the same
      # session), so the file never grows unbounded. No-op until the session
      # file exists, so the launcher calls this AFTER launch too (to colour a
      # freshly-created session for next time) and BEFORE (to colour a resume now).
      local config_dir="${1:-$CLAUDE_CONFIG_DIR}" label="${2:-}" root sid color proj_slug sess_file latest
      root="$(cma_project_root "$PWD")"
      sid="$(cma_session_id "$root")"
      color="$(cma_label_color "$label")"
      proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
      sess_file="$config_dir/projects/$proj_slug/$sid.jsonl"
      [[ -f "$sess_file" ]] || return 0
      # NOTE: `|| latest=""` is load-bearing — the script runs under `set -e -o
      # pipefail`, and on a session with NO existing agent-color record grep
      # exits 1, which would otherwise abort the function BEFORE we write the
      # colour (the exact case we need to handle: colouring a fresh session).
      latest="$(grep '"type":"agent-color"' "$sess_file" 2>/dev/null | tail -1 \
                | sed -E 's/.*"agentColor":"([^"]*)".*/\1/')" || latest=""
      [[ "$latest" == "$color" ]] && return 0
      printf '{"type":"agent-color","agentColor":"%s","sessionId":"%s"}\n' "$color" "$sid" >> "$sess_file"
      ;;
    hint)
      local label="${1:-}" color name
      color="$(cma_label_color "$label")"
      name="$(cma_session_name "$PWD")"
      printf 'claude-session: project "%s" — alias color: %s (auto-applied).\n' \
        "$name" "$color" >&2
      ;;
    *) printf 'usage: claude-session {flags|name|id|color|apply-color|hint} [args]\n' >&2; return 2 ;;
  esac
}

main "$@"
