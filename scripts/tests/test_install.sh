#!/usr/bin/env bash
# test_install.sh — exercises scripts/install.sh end-to-end in a sandbox HOME.
#
# install.sh is otherwise never executed by the suite (it is only statically
# referenced), so this is the sole coverage that the bootstrap actually works:
#   * exits 0 in a clean $HOME
#   * symlinks every claude-*.sh onto PATH (~/.local/bin -> SCRIPTS_DIR)
#   * creates the managed alias file with the cma_run wrapper + CLAUDE_BIN export
#   * appends its PATH line to a pre-existing rc file
#   * is idempotent (a 2nd run exits 0 and does not duplicate cma_run/PATH line)
#
# Honest side effect: install.sh runs `npm install` in the REAL repo root for
# the optional TOON utility. It is idempotent (a no-op once deps are present,
# a soft warning if npm is absent) and only ever touches the gitignored
# node_modules/ — no tracked file is modified. Everything else stays inside the
# sandboxed $HOME / $SHARED_DIR. This test does NOT source lib.sh.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
export SCRIPTS_DIR

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox

# Choose the rc file install.sh would target, the SAME way lib.sh derives
# CMA_RC_FILES (Darwin -> ~/.zshrc only; Linux -> ~/.bashrc + ~/.zshrc).
# install.sh only appends its PATH/source lines to rc files that ALREADY
# exist, so pre-create one — otherwise the PATH-line assertion is vacuous.
if [[ "$(uname -s)" == "Darwin" ]]; then
  RC_FILE="$HOME/.zshrc"
else
  RC_FILE="$HOME/.bashrc"
fi
: > "$RC_FILE"

# The exact literal install.sh writes (single-quoted: $HOME/$PATH stay literal).
# shellcheck disable=SC2016  # intentional literal, must match the rc-file content verbatim
PATH_LINE='export PATH="$HOME/.local/bin:$PATH"'
install_log="$SANDBOX_HOME/install.log"

# Run install.sh with the SAME bash that runs this test. install.sh needs
# bash 4+ (and re-execs to a Homebrew bash on macOS); using $BASH guarantees a
# compatible interpreter on every host. BIN_DIR is pinned into the sandbox.
run_install() {
  BIN_DIR="$HOME/.local/bin" "${BASH:-bash}" "$SCRIPTS_DIR/install.sh" >"$install_log" 2>&1
}

it "install.sh exits 0 in a clean sandbox HOME"
run_install
rc=$?
assert_eq 0 "$rc" "install.sh exit code"
# Surface the cause if it failed (sandbox is torn down on EXIT).
[[ $rc -eq 0 ]] || sed 's/^/    install.log| /' "$install_log"

it "install.sh symlinks claude-* commands into ~/.local/bin -> SCRIPTS_DIR"
assert_symlink_to "$HOME/.local/bin/claude-unify"         "$SCRIPTS_DIR/claude-unify.sh"         "claude-unify linked"
assert_symlink_to "$HOME/.local/bin/claude-add-account"   "$SCRIPTS_DIR/claude-add-account.sh"   "claude-add-account linked"
assert_symlink_to "$HOME/.local/bin/claude-list-accounts" "$SCRIPTS_DIR/claude-list-accounts.sh" "claude-list-accounts linked"

it "install.sh creates the managed alias file with the wrapper + CLAUDE_BIN export"
assert_file "$ALIAS_FILE" "alias file created"
assert_file_contains "$ALIAS_FILE" "cma_run()"         "cma_run wrapper present"
assert_file_contains "$ALIAS_FILE" "export CLAUDE_BIN=" "CLAUDE_BIN exported"

it "install.sh appends its PATH line to a pre-existing rc file"
assert_file_contains "$RC_FILE" "$PATH_LINE"            "PATH line appended"

it "install.sh is idempotent on a second run"
run_install
rc=$?
assert_eq 0 "$rc" "second install.sh exit code"
[[ $rc -eq 0 ]] || sed 's/^/    install.log| /' "$install_log"
# cma_run() must be defined exactly once (literal-paren match also excludes
# cma_run_provider()). A duplicate would mean the idempotency guard regressed.
cma_run_count="$(grep -c '^cma_run()' "$ALIAS_FILE" || true)"
assert_eq 1 "$cma_run_count" "cma_run defined exactly once after re-run"
# ...and the PATH line must not be doubled in the rc file.
path_line_count="$(grep -F -c -- "$PATH_LINE" "$RC_FILE" || true)"
assert_eq 1 "$path_line_count" "PATH line not duplicated after re-run"

summary
