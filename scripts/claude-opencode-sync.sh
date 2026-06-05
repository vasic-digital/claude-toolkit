#!/usr/bin/env bash
# claude-opencode-sync.sh — Make a host-installed OpenCode share the Claude
# Code ecosystem already present on this machine: every plugin's Skills,
# MCP servers, and the user-scope CLAUDE.md instructions.
#
# Claude Code "plugins" are hook/JS bundles OpenCode cannot execute, but the
# portable *contents* of those plugins — Anthropic-format Skills (SKILL.md),
# MCP server definitions (.mcp.json), and instruction files — map cleanly onto
# OpenCode's own `skills.paths`, `mcp`, and `instructions` config keys. This
# script scans the installed plugin cache and writes those into OpenCode's
# config, preserving anything already there.
#
# It is idempotent and additive: existing providers / MCP keys are never
# clobbered, and re-running only refreshes the generated entries.
#
# Knobs (all overridable from the environment, which is what the test suite
# leans on):
#   OPENCODE_CONFIG     opencode.json to update   (default ~/.config/opencode/opencode.json)
#   CLAUDE_PLUGINS_DIR  plugin cache to scan       (default ~/.claude/plugins/cache/claude-plugins-official)
#   SHARED_DIR          source of CLAUDE.md        (default ~/.claude-shared, from lib.sh)
#   OPENCODE_ALLOWLIST  newline/space list of "plugin/server" MCPs to enable
#   OPENCODE_EXTRA_SKILL_DIRS  extra skill roots (space separated)
#
# Flags:
#   --dry-run        print the resulting config to stdout, write nothing
#   --enable-all-local-runnable  enable every local MCP whose runtime exists
#                                and which needs no secret env
#   --enable-all     enable every MCP server (heavy startup; power users)
#   --no-backup      do not snapshot the prior config before writing
#   --stats          print a machine-readable STATS json line to stdout
#   -h, --help       show this help

set -euo pipefail

# macOS ships bash 3.2; re-exec under a 4+ if we can (mapfile etc.).
if (( BASH_VERSINFO[0] < 4 )); then
  for newer in /opt/homebrew/bin/bash /usr/local/bin/bash; do
    [[ -x "$newer" ]] && exec "$newer" "$0" "$@"
  done
fi

# Resolve LIB_DIR through any symlinks (install.sh symlinks into ~/.local/bin).
_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

OPENCODE_CONFIG="${OPENCODE_CONFIG:-$HOME/.config/opencode/opencode.json}"
CLAUDE_PLUGINS_DIR="${CLAUDE_PLUGINS_DIR:-$HOME/.claude/plugins/cache/claude-plugins-official}"
SHARED_CLAUDE_MD="${SHARED_CLAUDE_MD:-$SHARED_DIR/CLAUDE.md}"

DRY_RUN=0 NO_BACKUP=0 PRINT_STATS=0 ENABLE_ALL=0 ENABLE_ALL_LOCAL=0
while (( $# )); do
  case "$1" in
    --dry-run)                   DRY_RUN=1 ;;
    --no-backup)                 NO_BACKUP=1 ;;
    --stats)                     PRINT_STATS=1 ;;
    --enable-all)                ENABLE_ALL=1 ;;
    --enable-all-local-runnable) ENABLE_ALL_LOCAL=1 ;;
    -h|--help)
      sed -n '2,40p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) cma_die "unknown argument: $1 (try --help)" ;;
  esac
  shift
done

cma_require python3

[[ -d "$CLAUDE_PLUGINS_DIR" ]] || cma_die "plugin cache not found: $CLAUDE_PLUGINS_DIR"

# Default curated allowlist: MCP servers verified to start with zero secrets
# and no interactive OAuth. Remote entries are public documentation servers;
# local entries use runtimes (npx/uvx) that this script confirms are present.
# Everything else lands in the config disabled, ready to flip on after the
# user supplies credentials / runs `opencode mcp auth <name>`.
DEFAULT_ALLOWLIST=$'context7/context7\nmicrosoft-docs/microsoft-learn\ncloudflare/cloudflare-docs\nmintlify/Mintlify\nqt-development-skills/qt-docs\naws-dev-toolkit/awsknowledge\nappwrite/appwrite-docs\nmapbox/mapbox-docs\naws-dev-toolkit/awsiac\naws-dev-toolkit/awspricing\nshopify/shopify-mcp'
ALLOWLIST="${OPENCODE_ALLOWLIST:-$DEFAULT_ALLOWLIST}"

# Which MCP runtimes are actually installed — used to decide whether a local
# server is safe to enable.
AVAILABLE_RUNTIMES=""
for rt in npx node uvx uv python3 bun deno jbang toolbox railway semgrep fiftyone-mcp; do
  command -v "$rt" >/dev/null 2>&1 && AVAILABLE_RUNTIMES+="$rt "
done

cma_log "scanning plugins in $CLAUDE_PLUGINS_DIR"

OC_TMP="$(mktemp)"
STATS_TMP="$(mktemp)"
trap 'rm -f "$OC_TMP" "$STATS_TMP"' EXIT

OC_CONFIG="$OPENCODE_CONFIG" \
OC_PLUGINS_DIR="$CLAUDE_PLUGINS_DIR" \
OC_SHARED_CLAUDE_MD="$SHARED_CLAUDE_MD" \
OC_ALLOWLIST="$ALLOWLIST" \
OC_EXTRA_SKILL_DIRS="${OPENCODE_EXTRA_SKILL_DIRS:-}" \
OC_AVAILABLE_RUNTIMES="$AVAILABLE_RUNTIMES" \
OC_ENABLE_ALL="$ENABLE_ALL" \
OC_ENABLE_ALL_LOCAL="$ENABLE_ALL_LOCAL" \
OC_OUT="$OC_TMP" \
OC_STATS="$STATS_TMP" \
python3 "$LIB_DIR/opencode_sync.py"

if (( DRY_RUN )); then
  cat "$OC_TMP"
  (( PRINT_STATS )) && cat "$STATS_TMP"
  cma_log "dry-run: no files written"
  exit 0
fi

# Backup any prior config, then install atomically.
mkdir -p "$(dirname "$OPENCODE_CONFIG")"
if [[ -f "$OPENCODE_CONFIG" && $NO_BACKUP -eq 0 ]]; then
  bak="${OPENCODE_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"
  cp "$OPENCODE_CONFIG" "$bak"
  cma_log "backed up prior config -> $bak"
fi
cp "$OC_TMP" "$OPENCODE_CONFIG"
cma_log "wrote $OPENCODE_CONFIG"

# Human summary.
python3 - "$STATS_TMP" <<'PY'
import json, sys
s = json.load(open(sys.argv[1]))
print(f"  skills paths : {s['skill_paths']}")
print(f"  mcp servers  : {s['mcp_total']}  (enabled {s['mcp_enabled']}, ready-to-enable {s['mcp_total']-s['mcp_enabled']})")
print(f"  instructions : {s['instructions']}")
PY

(( PRINT_STATS )) && cat "$STATS_TMP"
exit 0
