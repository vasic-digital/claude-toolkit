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
out="$(run_list_accounts 2>&1)"
[[ "$out" == *"ALIAS"* ]]; assert_eq 0 $? "header always printed"
echo "$out" | grep -E '^\-' >/dev/null
[[ $? -ne 0 ]]; assert_eq 0 $? "no account rows"

acct1="$(make_account acct1)"
acct2="$(make_account acct2)"
run_unify >/dev/null 2>&1
run_add_account --alias claude3 --yes >/dev/null 2>&1

it "shows every account dir with creds + link status"
out="$(run_list_accounts 2>&1)"
assert_file_contains <(printf '%s\n' "$out") ".claude-acct1" "acct1 listed"
assert_file_contains <(printf '%s\n' "$out") ".claude-acct2" "acct2 listed"
assert_file_contains <(printf '%s\n' "$out") ".claude-claude3" "claude3 listed"
assert_file_contains <(printf '%s\n' "$out") "claude3" "claude3 alias resolved"

it "reports the shared store path"
out="$(run_list_accounts 2>&1)"
assert_file_contains <(printf '%s\n' "$out") "$SHARED_DIR" "shared store path printed"

it "flags accounts with missing credentials"
# claude3 was created by add-account; it has no .credentials.json.
out="$(run_list_accounts 2>&1)"
line="$(echo "$out" | grep ".claude-claude3" || true)"
[[ "$line" == *" no "* ]]; assert_eq 0 $? "claude3 creds:no"
line1="$(echo "$out" | grep ".claude-acct1" || true)"
[[ "$line1" == *" yes "* ]]; assert_eq 0 $? "acct1 creds:yes"

summary
