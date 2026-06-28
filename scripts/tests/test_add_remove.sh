#!/usr/bin/env bash
# test_add_remove.sh — exercises claude-add-account.sh and
# claude-remove-account.sh end-to-end:
#   * add suggests the next free claudeN
#   * add creates the dir with the right symlinks
#   * add writes a shell-safe alias line
#   * add refuses to overwrite an existing dir
#   * add accepts a custom alias name
#   * remove drops the alias line
#   * remove archives the dir by default, --delete removes it

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox

# Start with two existing accounts and a unified shared store.
acct1="$(make_account acct1)"
acct2="$(make_account acct2)"
run_unify >/dev/null 2>&1

it "claude-add-account --yes uses sensible defaults"
run_add_account --alias claude3 --yes >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "exit 0"
new_dir="$HOME/.claude-claude3"
assert_dir "$new_dir" "config dir created"
assert_symlink_to "$new_dir/projects" "$SHARED_DIR/projects" "projects linked"
assert_symlink_to "$new_dir/settings.json" "$SHARED_DIR/settings.json" "settings linked"
assert_symlink_to "$new_dir/CLAUDE.md" "$SHARED_DIR/CLAUDE.md" "CLAUDE.md linked"
assert_file_contains "$ALIAS_FILE" "alias claude3=" "alias line written"
assert_file_contains "$ALIAS_FILE" "CLAUDE_CONFIG_DIR=$new_dir" "alias points at new dir"

it "claude-add-account refuses to overwrite an existing dir"
( run_add_account --alias claude3 --yes >/dev/null 2>&1 )
rc=$?
[[ $rc -ne 0 ]]; assert_eq 0 $? "exits non-zero when dir exists"

it "claude-add-account accepts a custom alias name and custom dir"
custom_dir="$HOME/.claude-mywork"
run_add_account --alias mywork --dir "$custom_dir" --yes >/dev/null 2>&1
assert_dir "$custom_dir" "custom dir created"
assert_symlink_to "$custom_dir/projects" "$SHARED_DIR/projects" "projects linked"
assert_file_contains "$ALIAS_FILE" "alias mywork=" "custom alias written"

it "claude-add-account validates alias names"
( run_add_account --alias "bad name" --yes >/dev/null 2>&1 )
rc=$?
[[ $rc -ne 0 ]]; assert_eq 0 $? "rejects bad alias"

it "claude-add-account is non-interactive without --yes (CMA_NONINTERACTIVE=1)"
export CMA_NONINTERACTIVE=1
run_add_account --alias claude4 >/dev/null 2>&1
rc=$?
unset CMA_NONINTERACTIVE
assert_eq 0 "$rc" "exit 0 without --yes"
assert_dir "$HOME/.claude-claude4" "config dir created via defaults"
assert_file_contains "$ALIAS_FILE" "alias claude4=" "alias written non-interactively"
# Regression (cma_run_provider migration mis-fire): adding more accounts must
# not chop previously-written alias lines. All earlier aliases must survive.
assert_file_contains "$ALIAS_FILE" "alias claude3=" "earlier claude3 alias survives"
assert_file_contains "$ALIAS_FILE" "alias mywork=" "earlier mywork alias survives"

it "claude-remove-account --archive moves the dir aside"
run_remove_account --alias claude3 --archive --yes >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "exit 0"
[[ ! -d "$HOME/.claude-claude3" ]]; assert_eq 0 $? "original dir gone"
archived="$(find "$HOME" -maxdepth 1 -name '.claude-claude3.removed.*' -type d 2>/dev/null | head -1)"
[[ -n "$archived" ]]; assert_eq 0 $? "archived sibling exists"
assert_file_not_contains "$ALIAS_FILE" "alias claude3=" "alias line removed"

it "claude-remove-account --delete actually deletes"
run_remove_account --alias mywork --delete --yes >/dev/null 2>&1
[[ ! -d "$HOME/.claude-mywork" ]]; assert_eq 0 $? "dir deleted"
[[ -z "$(find "$HOME" -maxdepth 1 -name '.claude-mywork.removed.*' 2>/dev/null)" ]]; assert_eq 0 $? "no archive sibling"

it "claude-remove-account rejects unknown alias"
( run_remove_account --alias nonexistent --yes >/dev/null 2>&1 )
rc=$?
[[ $rc -ne 0 ]]; assert_eq 0 $? "unknown alias errors out"

summary
