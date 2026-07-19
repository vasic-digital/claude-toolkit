#!/usr/bin/env bash
# claude-ccr-build.sh — build the BUNDLED claude-code-router (Go) from the
# submodule and install it as the toolkit's `ccr`.
#
# The toolkit's provider aliases route through `ccr` (the OpenAI<->Anthropic
# gateway). Historically that meant a separately-installed Node
# `@musistudio/claude-code-router` on PATH. This repository now VENDORS a
# from-scratch Go reimplementation as the `submodules/claude-code-router`
# submodule; this script builds it and symlinks the result onto PATH so the
# toolkit is self-contained and uses OUR router.
#
# It is idempotent: re-running rebuilds the binary in place and re-points the
# symlink. Gated on the Go toolchain — with no `go`, it explains how to proceed
# and exits non-zero (install.sh treats it as best-effort so install still
# completes).
#
# Env knobs:
#   BIN_DIR   where `ccr` is symlinked (default ~/.local/bin, same as install.sh)
set -euo pipefail

# Resolve this script's real dir through any symlinks (install.sh links it into
# ~/.local/bin), the same idiom install.sh uses.
_src="${BASH_SOURCE[0]}"
while [ -L "$_src" ]; do
  _tgt="$(readlink "$_src")"
  case "$_tgt" in /*) _src="$_tgt" ;; *) _src="$(dirname "$_src")/$_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_src")" && pwd)"
unset _src _tgt
# shellcheck source=lib.sh
source "$LIB_DIR/lib.sh"

REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"
SUBMODULE="$REPO_ROOT/submodules/claude-code-router"

# 1. Ensure the submodule is checked out.
if [ ! -f "$SUBMODULE/go.mod" ] || [ ! -d "$SUBMODULE/cmd/ccr" ]; then
  cma_log "claude-code-router submodule not checked out — initialising ..."
  if ! git -C "$REPO_ROOT" submodule update --init --recursive submodules/claude-code-router 2>/dev/null; then
    printf 'claude-ccr-build: submodule submodules/claude-code-router is missing and could not be initialised.\n  Run: git -C %s submodule update --init --recursive\n' "$REPO_ROOT" >&2
    exit 1
  fi
fi
if [ ! -d "$SUBMODULE/cmd/ccr" ]; then
  printf 'claude-ccr-build: %s does not contain cmd/ccr (unexpected submodule layout).\n' "$SUBMODULE" >&2
  exit 1
fi

# 2. Require the Go toolchain.
if ! command -v go >/dev/null 2>&1; then
  cma_warn "Go toolchain not found — cannot build the bundled claude-code-router (Go)."
  printf '  Install Go (https://go.dev/dl/) then re-run: claude-ccr-build\n  (Last resort only, if Go is unavailable: a Node @musistudio/claude-code-router on PATH also satisfies the ccr guard.)\n' >&2
  exit 1
fi

# 3. Build ./cmd/ccr into the submodule's bin/ccr (matches the submodule
#    Makefile's output path).
BIN="$SUBMODULE/bin/ccr"
cma_log "building bundled claude-code-router (Go): $(cd "$SUBMODULE" && go version 2>/dev/null | awk '{print $3}') ..."
if ! ( cd "$SUBMODULE" && mkdir -p bin && go build -o bin/ccr ./cmd/ccr ); then
  printf 'claude-ccr-build: go build failed in %s\n' "$SUBMODULE" >&2
  exit 1
fi

# 4. Self-check: the built binary must present the router grammar the toolkit's
#    identity guard (lib.sh) requires — `ccr start` / `ccr serve` in --help.
_help="$("$BIN" --help 2>&1 | head -12 || true)"
case "$_help" in
  *"ccr start"*|*"ccr serve"*) : ;;
  *)
    printf 'claude-ccr-build: built binary failed its self-check — `%s --help` did not show the router commands.\n' "$BIN" >&2
    exit 1
    ;;
esac

# 5. Symlink it onto PATH as `ccr`, backing up any pre-existing DIFFERENT ccr so
#    nothing is silently clobbered.
BIN_DIR="${BIN_DIR:-$HOME/.local/bin}"
mkdir -p "$BIN_DIR"
LINK="$BIN_DIR/ccr"
if [ -L "$LINK" ] && [ "$(cma_realpath "$LINK" 2>/dev/null)" = "$(cma_realpath "$BIN" 2>/dev/null)" ]; then
  : # already ours — nothing to do
elif [ -e "$LINK" ] || [ -L "$LINK" ]; then
  _bak="${LINK}.preccr.$(date +%Y%m%d%H%M%S)"
  mv "$LINK" "$_bak"
  cma_warn "backed up existing $LINK -> $_bak"
fi
ln -sf "$BIN" "$LINK"
cma_log "installed bundled Go ccr: $LINK -> $BIN"

# 6. Informational: confirm PATH resolution points at our link.
_resolved="$(command -v ccr 2>/dev/null || true)"
if [ -n "$_resolved" ] && [ "$(cma_realpath "$_resolved" 2>/dev/null)" = "$(cma_realpath "$BIN" 2>/dev/null)" ]; then
  cma_log "ccr on PATH now resolves to the bundled Go router ($_resolved)"
else
  cma_warn "an EARLIER 'ccr' shadows $LINK on PATH ($_resolved). Ensure $BIN_DIR precedes it, or remove the shadowing ccr."
fi
