#!/usr/bin/env bash
# claude-session.sh — derive per-project session launch flags for the alias
# wrappers (cma_run / cma_run_provider).
#
# Each project (identified by its root directory) gets ONE long-lived Claude
# session so launching any alias inside it resumes the same ongoing work, or
# creates it the first time. The session is named after the root dir in
# lowercase kebab-case.
#
# Subcommands:
#   flags <config_dir>          Print launch flags for `claude` on stdout:
#                               either `--resume <sid>` (session exists) or
#                               `--session-id <sid> --name <kebab>` (first run).
#                               Picks the MOST RECENTLY ACTIVE session by mtime.
#                               Side effect: trust the project in <config_dir>.
#   name  [path]                Print the kebab-case session name for a path.
#   id    [path]                Print the stable session UUID for a path.
#   latest-id [config_dir]      Print most-recently-active session UUID.
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

# Sanitize a user-facing session name: lowercase, collapse non-alnum to single
# dash, trim leading/trailing dashes.
cma_session_name() {
  local root base
  root="$(cma_project_root "${1:-$PWD}")"
  base="$(basename "$root")"
  printf '%s\n' "$base" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//; s/[^a-z0-9]+/-/g; s/-+/-/g; s/^-//; s/-$//'
}

# Stable RFC-4122-shaped UUID derived from the project root path.
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

# Deterministic alias-label -> color.
cma_label_color() {
  local label="${1:-}" hash num
  if command -v md5sum >/dev/null 2>&1; then
    hash="$(printf '%s' "$label" | md5sum | cut -d' ' -f1)"
  elif command -v md5 >/dev/null 2>&1; then
    hash="$(printf '%s' "$label" | md5 -q)"
  else
    hash="$(printf '%s' "$label" | cksum | cut -d' ' -f1)"
  fi
  num=$(( 0x${hash:0:6} % ${#CMA_COLORS[@]} ))
  printf '%s\n' "${CMA_COLORS[$num]}"
}

# Mark the project as trusted in <config_dir>/.claude.json
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

# Find the MOST RECENTLY active session UUID for a project directory.
# Scans *.jsonl (excluding subagents/), sorts by mtime descending.
# Falls back to the deterministic UUID on first launch.
cma_latest_session_id() {
  local config_dir="${1:-$CLAUDE_CONFIG_DIR}" root="${2:-}"
  root="${root:-$PWD}"
  local proj_slug sess_dir latest
  proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
  sess_dir="$config_dir/projects/$proj_slug"
  # ls -t sorts by mtime DESC; skip subagent dirs
  if [[ -d "$sess_dir" ]]; then
    # The `|| true` guard on head is load-bearing: with `set -o pipefail`
    # (line 30), `head -1` exits after reading one line, which sends SIGPIPE
    # to grep; pipefail turns that into exit 141, and `set -e` aborts the
    # script BEFORE the fallback to cma_session_id.  Without this guard,
    # EVERY launch is a "first run" — creating a fresh session instead of
    # resuming the shared one.  §12.7.0 session-sharing.
    latest="$(ls -t "$sess_dir"/*.jsonl 2>/dev/null \
      | grep -v '/subagents/' \
      | head -1 || true)"
    latest="$(basename "${latest:-}" .jsonl 2>/dev/null)" || latest=""
  fi
  if [[ -n "${latest:-}" ]]; then
    printf '%s\n' "$latest"
  else
    cma_session_id "$root"
  fi
}

# Print the most-recent session UUID ONLY when a real session file exists for
# this project (empty otherwise). Used by the wrapper's args resume-injection:
# injecting --resume with the deterministic-but-never-created fallback UUID
# makes Claude Code fail hard ("No conversation found with session ID").
cma_existing_session_id() {
  local config_dir="${1:-$CLAUDE_CONFIG_DIR}" root="${2:-}"
  root="${root:-$PWD}"
  local proj_slug sess_dir latest
  proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
  sess_dir="$config_dir/projects/$proj_slug"
  if [[ -d "$sess_dir" ]]; then
    latest="$(ls -t "$sess_dir"/*.jsonl 2>/dev/null \
      | grep -v '/subagents/' \
      | head -1 || true)"
    latest="$(basename "${latest:-}" .jsonl 2>/dev/null)" || latest=""
  fi
  [[ -n "${latest:-}" ]] && printf '%s\n' "$latest"
  return 0
}

main() {
  local cmd="${1:-flags}"; shift 2>/dev/null || true
  case "$cmd" in
    name)  cma_session_name "${1:-$PWD}" ;;
    id)    cma_session_id "${1:-$PWD}" ;;
    color) cma_label_color "${1:-}" ;;
    existing-id)
      local config_dir="${1:-$CLAUDE_CONFIG_DIR}" root
      root="$(cma_project_root "$PWD")"
      cma_existing_session_id "$config_dir" "$root"
      ;;
    latest-id)
      local config_dir="${1:-$CLAUDE_CONFIG_DIR}" root
      root="$(cma_project_root "$PWD")"
      cma_latest_session_id "$config_dir" "$root"
      ;;
    flags)
      local config_dir="${1:-$CLAUDE_CONFIG_DIR}" root sid name proj_slug sess_file
      root="$(cma_project_root "$PWD")"
      sid="$(cma_latest_session_id "$config_dir" "$root")"
      name="$(cma_session_name "$root")"
      cma_trust_project "$config_dir" "$root" || true
      proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
      sess_file="$config_dir/projects/$proj_slug/$sid.jsonl"
      if [[ -f "$sess_file" ]]; then
        printf -- '--resume %s --name %s\n' "$sid" "$name"
      else
        printf -- '--session-id %s --name %s\n' "$sid" "$name"
      fi
      ;;
    apply-color)
      local config_dir="${1:-$CLAUDE_CONFIG_DIR}" label="${2:-}" root sid color proj_slug sess_file latest
      root="$(cma_project_root "$PWD")"
      sid="$(cma_latest_session_id "$config_dir" "$root")"
      color="$(cma_label_color "$label")"
      proj_slug="$(printf '%s' "$root" | sed -E 's/[^A-Za-z0-9]/-/g')"
      sess_file="$config_dir/projects/$proj_slug/$sid.jsonl"
      [[ -f "$sess_file" ]] || return 0
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
    *) printf 'usage: claude-session {flags|name|id|color|apply-color|hint|latest-id} [args]\n' >&2; return 2 ;;
  esac
}

main "$@"
