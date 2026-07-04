#!/usr/bin/env bash
# claude-semantic-visibility.sh — build + run the LLMsVerifier semantic-code-visibility
# command (layer 3: "does this model actually SEE my code through the alias path?").
#
# Mirrors claude-verify-providers.sh: builds the Go binary (cached; rebuild if the
# command source is newer), then execs it, passing the caller's flags through. The
# command is stdlib-only (no cgo/database) so it builds without a C toolchain.
#
# Secrets: the command reads the model + judge keys from the env var NAMES given via
# --api-key-env / --judge-api-key-env (os.Getenv), never from argv.
#
# Env knobs: LLMSVERIFIER_DIR (submodule path), LV_SEMANTIC_BIN (cached binary path).
set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
LV_DIR="${LLMSVERIFIER_DIR:-$REPO_ROOT/submodules/LLMsVerifier}"
LV_MOD="$LV_DIR/llm-verifier"
BIN="${LV_SEMANTIC_BIN:-$REPO_ROOT/.local-cache/semantic-code-visibility}"
SRC="$LV_MOD/cmd/semantic-code-visibility/main.go"

case "${1:-}" in -h|--help) exec "$BIN" -h 2>/dev/null || { echo "semantic-code-visibility driver: builds + runs the LLMsVerifier command"; exit 0; } ;; esac

if [ ! -d "$LV_MOD" ]; then
  echo "error: LLMsVerifier submodule not initialized." >&2
  echo "  run: git submodule update --init submodules/LLMsVerifier" >&2
  exit 3
fi
if ! command -v go >/dev/null 2>&1; then
  echo "error: the Go toolchain is required to build the semantic verifier." >&2
  exit 4
fi

if [ ! -x "$BIN" ] || [ "$SRC" -nt "$BIN" ]; then
  mkdir -p "$(dirname "$BIN")"
  echo "building semantic-code-visibility (go build)…" >&2
  ( cd "$LV_MOD" && go build -o "$BIN" ./cmd/semantic-code-visibility/ ) \
    || { echo "error: semantic verifier build failed" >&2; exit 5; }
fi

exec "$BIN" "$@"
