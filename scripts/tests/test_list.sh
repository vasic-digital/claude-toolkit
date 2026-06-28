#!/usr/bin/env bash
# test_list.sh — claude-list-accounts.sh reports accurate state.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox

# Empty-host case first.
it "lists nothing when no accounts exist"
# shellcheck disable=SC2119  # test intentionally calls run_list_accounts with no args
out="$(run_list_accounts 2>&1)"
cond=1; [[ "$out" == *"ALIAS"* ]] && cond=0; assert_eq 0 "$cond" "header always printed"
echo "$out" | grep -E '^\-' >/dev/null; rc=$?
cond=$(( rc != 0 ? 0 : 1 )); assert_eq 0 "$cond" "no account rows"

make_account acct1 >/dev/null  # side-effect only; returned path not needed
make_account acct2 >/dev/null  # side-effect only; returned path not needed
# shellcheck disable=SC2119  # test intentionally calls run_unify with no args
run_unify >/dev/null 2>&1
run_add_account --alias claude3 --yes >/dev/null 2>&1

it "shows every account dir with creds + link status"
# shellcheck disable=SC2119  # test intentionally calls run_list_accounts with no args
out="$(run_list_accounts 2>&1)"
assert_file_contains <(printf '%s\n' "$out") ".claude-acct1" "acct1 listed"
assert_file_contains <(printf '%s\n' "$out") ".claude-acct2" "acct2 listed"
assert_file_contains <(printf '%s\n' "$out") ".claude-claude3" "claude3 listed"
assert_file_contains <(printf '%s\n' "$out") "claude3" "claude3 alias resolved"

it "reports the shared store path"
# shellcheck disable=SC2119  # test intentionally calls run_list_accounts with no args
out="$(run_list_accounts 2>&1)"
assert_file_contains <(printf '%s\n' "$out") "$SHARED_DIR" "shared store path printed"

it "flags accounts with missing credentials"
# claude3 was created by add-account; it has no .credentials.json.
# shellcheck disable=SC2119  # test intentionally calls run_list_accounts with no args
out="$(run_list_accounts 2>&1)"
line="$(echo "$out" | grep ".claude-claude3" || true)"
cond=1; [[ "$line" == *" no "* ]] && cond=0; assert_eq 0 "$cond" "claude3 creds:no"
line1="$(echo "$out" | grep ".claude-acct1" || true)"
cond=1; [[ "$line1" == *" yes "* ]] && cond=0; assert_eq 0 "$cond" "acct1 creds:yes"

summary
