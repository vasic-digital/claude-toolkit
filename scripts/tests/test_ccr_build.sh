#!/usr/bin/env bash
# test_ccr_build.sh — claude-ccr-build.sh builds the BUNDLED Go
# claude-code-router (submodule) and installs it as `ccr`, so provider aliases
# route through OUR vendored router rather than a separately-installed Node one.
#
# This test verifies the script's contract and its wiring into install.sh and
# lib.sh (structural + bash syntax). The go-PRESENT end-to-end build (git
# submodule + go build + symlink + `ccr --help`) needs the Go toolchain and a
# checked-out submodule, so it is exercised by the live proof / run-proof.sh,
# not this hermetic unit test.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
set +e

BUILD="$SCRIPTS_DIR/claude-ccr-build.sh"

it "claude-ccr-build.sh exists and is executable"
assert_file "$BUILD"
if [[ -x "$BUILD" ]]; then _pass "executable"; else _fail "not executable" "$BUILD"; fi

it "has valid bash syntax"
assert_exit 0 bash -n "$BUILD"

it "builds ./cmd/ccr into the submodule bin and self-checks the router grammar"
assert_file_contains "$BUILD" 'go build -o bin/ccr ./cmd/ccr'
assert_file_contains "$BUILD" 'ccr start' # self-check mirrors lib.sh's identity guard
assert_file_contains "$BUILD" 'ccr serve'

it "initialises the submodule when it is not checked out"
assert_file_contains "$BUILD" 'submodule update --init'

it "guards on a missing Go toolchain (best-effort, non-fatal to install)"
assert_file_contains "$BUILD" 'command -v go'
assert_file_contains "$BUILD" 'Go toolchain not found'

it "installs ccr onto PATH as a symlink, backing up a pre-existing different ccr"
assert_file_contains "$BUILD" 'ln -sf "$BIN" "$LINK"'
assert_file_contains "$BUILD" 'preccr'

it "install.sh builds the bundled router (best-effort) during install"
assert_file_contains "$SCRIPTS_DIR/install.sh" 'claude-ccr-build.sh'

it "lib.sh's provider-router guidance points at the bundled build"
assert_file_contains "$SCRIPTS_DIR/lib.sh" 'claude-ccr-build'

it ".gitmodules registers the claude-code-router submodule"
assert_file_contains "$REPO_ROOT/.gitmodules" 'submodules/claude-code-router'

summary
