#!/usr/bin/env bash
# test_bootstrap.sh — hermetic coverage for claude-bootstrap.sh, the
# clean-slate provisioner that creates N empty per-account dirs, wires them
# to a single shared store, and registers the `claudeN` aliases on a host
# with ZERO accounts logged in.
#
# bootstrap runs as a SUBPROCESS (it sources lib.sh itself and re-derives
# SHARED_DIR/ALIAS_FILE/DEFAULT_DIR/ACCOUNT_PREFIX from the sandbox HOME and
# the exported env vars), so this file does NOT source lib.sh and never calls
# cma_* directly — exactly like test_add_remove.sh. Everything is asserted
# from the filesystem the subprocess left behind.
#
# This is REAL execution (not the static bash -n fallback): bootstrap needs
# no network or interactivity — its only prompt is gated behind
# `cma_can_prompt`, which CMA_NONINTERACTIVE=1 forces off (lib.sh:672-674),
# and we additionally pass its real non-interactive flag `--yes`. We keep a
# couple of cheap static/flag-parsing checks too, but the core path runs the
# script for real against a sandbox HOME.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

# Global "never prompt" switch the toolkit honors (lib.sh:672-674). Belt and
# suspenders alongside --yes so a missing PTY can never block this suite.
export CMA_NONINTERACTIVE=1

make_sandbox

# Run claude-bootstrap.sh as a subprocess against the sandbox HOME.
run_bootstrap() {
  bash "$SCRIPTS_DIR/claude-bootstrap.sh" "$@"
}

# --- Static / flag-parsing checks (no state mutation). -----------------------

it "claude-bootstrap.sh passes bash -n syntax check"
( bash -n "$SCRIPTS_DIR/claude-bootstrap.sh" >/dev/null 2>&1 )
rc=$?
assert_eq 0 "$rc" "parses without syntax errors"

it "claude-bootstrap --help prints usage and exits 0"
help_file="$HOME/bootstrap-help.txt"
run_bootstrap --help > "$help_file" 2>&1
rc=$?
assert_eq 0 "$rc" "--help exits 0"
assert_file_contains "$help_file" "Usage:" "usage banner printed"
assert_file_contains "$help_file" "--count" "documents --count flag"
assert_file_contains "$help_file" "--aliases" "documents --aliases flag"
assert_file_contains "$help_file" "--yes" "documents --yes flag"

it "claude-bootstrap rejects an unknown flag"
( run_bootstrap --bogus --yes >/dev/null 2>&1 )
rc=$?
cond=$(( rc != 0 ? 0 : 1 )); assert_eq 0 "$cond" "unknown arg exits non-zero (claude-bootstrap.sh:89)"

it "claude-bootstrap rejects --count 0"
( run_bootstrap --count 0 --yes >/dev/null 2>&1 )
rc=$?
cond=$(( rc != 0 ? 0 : 1 )); assert_eq 0 "$cond" "--count must be >= 1 (claude-bootstrap.sh:101)"
# Nothing should have been provisioned by the rejected runs above.
cond=1; [[ ! -e "$HOME/.claude-claude1" ]] && cond=0
assert_eq 0 "$cond" "rejected runs left no account dir behind"

# --- Core path: real provisioning of 2 accounts. -----------------------------

it "claude-bootstrap --count 2 --yes provisions cleanly"
run_bootstrap --count 2 --yes >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "exit 0"

# Shared store created and seeded.
assert_dir "$SHARED_DIR" "shared store created"
assert_dir "$SHARED_DIR/projects" "shared projects dir created"
assert_file "$SHARED_DIR/settings.json" "shared settings.json seeded"
assert_file_contains "$SHARED_DIR/settings.json" "{}" "settings.json seeded with empty object"

# Per-account dirs exist under the sandbox HOME.
d1="$HOME/.claude-claude1"
d2="$HOME/.claude-claude2"
assert_dir "$d1" "account 1 dir created"
assert_dir "$d2" "account 2 dir created"

# Shared items are symlinked into each account dir.
assert_symlink_to "$d1/projects" "$SHARED_DIR/projects" "claude1 projects linked"
assert_symlink_to "$d1/CLAUDE.md" "$SHARED_DIR/CLAUDE.md" "claude1 CLAUDE.md linked"
assert_symlink_to "$d2/projects" "$SHARED_DIR/projects" "claude2 projects linked"
assert_symlink_to "$d2/todos" "$SHARED_DIR/todos" "claude2 todos linked"

# §11.4 own-settings: settings.json is each dir's OWN real file (NOT a shared
# symlink) — per-alias permissions/model/hooks never leak across aliases. It is
# seeded from the shared template (empty {} on a fresh bootstrap). The plugin
# CACHE (plugins/) and history stay SHARED symlinks so plugins/history are one
# store across all aliases.
assert_not_symlink "$d1/settings.json" "claude1 settings.json is OWN (not a shared symlink)"
assert_file "$d1/settings.json" "claude1 has own real settings.json"
assert_jq "$d1/settings.json" 'type' "object" "claude1 own settings.json is valid JSON object"
assert_symlink_to "$d1/plugins" "$SHARED_DIR/plugins" "claude1 plugins (cache) still shared"
assert_symlink_to "$d1/history.jsonl" "$SHARED_DIR/history.jsonl" "claude1 history.jsonl still shared"
assert_not_symlink "$d2/settings.json" "claude2 settings.json is OWN (not a shared symlink)"

# Private files are real (per-account), NOT symlinks into shared.
assert_file "$d1/.claude.json" "claude1 has private .claude.json"
assert_not_symlink "$d1/.claude.json" "claude1 .claude.json stays private"
assert_not_symlink "$d1/mcp-needs-auth-cache.json" "claude1 mcp-auth-cache stays private"

# Managed alias file gained the expected `alias ...=` lines pointing at the dirs.
assert_file "$ALIAS_FILE" "alias file created"
assert_file_contains "$ALIAS_FILE" "alias claude1=" "claude1 alias written"
assert_file_contains "$ALIAS_FILE" "alias claude2=" "claude2 alias written"
assert_file_contains "$ALIAS_FILE" "CLAUDE_CONFIG_DIR=$d1" "claude1 alias points at its dir"
assert_file_contains "$ALIAS_FILE" "CLAUDE_CONFIG_DIR=$d2" "claude2 alias points at its dir"

# --- Documented re-run behavior: refuses to clobber existing account dirs. ----
# bootstrap is for FRESH hosts; re-running with the same aliases must abort
# rather than overwrite (claude-bootstrap.sh:124-130). It is NOT idempotent.

it "claude-bootstrap refuses to clobber existing account dirs on re-run"
( run_bootstrap --count 2 --yes >/dev/null 2>&1 )
rc=$?
cond=$(( rc != 0 ? 0 : 1 )); assert_eq 0 "$cond" "re-run exits non-zero (claude-bootstrap.sh:124-130)"
# The original accounts and aliases must be left intact by the refused re-run.
assert_dir "$d1" "claude1 dir survives refused re-run"
assert_file_contains "$ALIAS_FILE" "alias claude1=" "claude1 alias survives refused re-run"

# --- Custom alias names via --aliases (distinct names, fresh dirs). -----------

it "claude-bootstrap --aliases provisions custom names"
run_bootstrap --aliases personal,work --yes >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "exit 0"
assert_dir "$HOME/.claude-personal" "personal dir created"
assert_dir "$HOME/.claude-work" "work dir created"
assert_symlink_to "$HOME/.claude-personal/projects" "$SHARED_DIR/projects" "personal projects linked"
assert_file_contains "$ALIAS_FILE" "alias personal=" "personal alias written"
assert_file_contains "$ALIAS_FILE" "alias work=" "work alias written"
# Earlier aliases must not have been chopped by the second provisioning run.
assert_file_contains "$ALIAS_FILE" "alias claude1=" "claude1 alias survives second run"

summary
