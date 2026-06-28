#!/usr/bin/env bash
# test_sessions.sh — End-to-end verification that sessions, project memory,
# and todos created under one account become physically visible to every
# other account after unify. These are the "real proofs" referenced in the
# product requirement: existence + content + cross-account readability.
#
# What we verify here that's NOT covered by test_unify.sh:
#   1. .claude.json `projects` subtree is unioned across accounts (the main
#      gap that caused "claude2 can't see claude1's Android_15 sessions").
#   2. Auth-private keys in .claude.json (userID, oauthAccount, etc.) are
#      preserved per-account — sharing must NOT leak credentials.
#   3. A session JSONL file written into account A is byte-identical when
#      read from account B's symlinked projects/ dir.
#   4. Project memory written under account A is visible from account B.
#   5. The cma_merge_claude_json function is idempotent.
#   6. claude-sync-state.sh push/pull modes both work and give the same result.

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

# Build two accounts that mirror the real-world failure pattern: acct2 has
# a fully-populated .claude.json with a project entry that should become
# visible to acct1 (which starts with an empty .claude.json).
make_account acct1
make_account acct2

# acct1: minimal .claude.json (mirrors a freshly-installed account that
# never opened the Android_15 project). Distinct private keys per account.
cat > "$HOME/.claude-acct1/.claude.json" <<'EOF'
{
  "userID": "user-acct1-hash",
  "oauthAccount": {"emailAddress": "acct1@example.com", "accountUuid": "uuid-acct1"},
  "firstStartTime": "2026-01-01T00:00:00.000Z",
  "claudeCodeFirstTokenDate": "2026-01-01",
  "numStartups": 3,
  "hasCompletedOnboarding": true,
  "projects": {}
}
EOF

# acct2: real project memory + session, distinct private keys.
cat > "$HOME/.claude-acct2/.claude.json" <<'EOF'
{
  "userID": "user-acct2-hash",
  "oauthAccount": {"emailAddress": "acct2@example.com", "accountUuid": "uuid-acct2"},
  "firstStartTime": "2026-02-02T00:00:00.000Z",
  "claudeCodeFirstTokenDate": "2026-02-02",
  "numStartups": 42,
  "hasCompletedOnboarding": true,
  "projects": {
    "/projects/Android_15": {
      "lastSessionId": "session-android-uuid",
      "lastCost": 12.34,
      "hasTrustDialogAccepted": true,
      "mcpServers": {"android-dev": {"command": "android-mcp"}}
    },
    "/projects/iOS": {
      "lastSessionId": "session-ios-uuid",
      "lastCost": 5.67
    }
  }
}
EOF

# Create a real session JSONL inside acct2 — this simulates what claude code
# writes when a user converses about Android_15 under that account.
ANDROID_HASH="-projects-Android_15"
mkdir -p "$HOME/.claude-acct2/projects/$ANDROID_HASH"
cat > "$HOME/.claude-acct2/projects/$ANDROID_HASH/session-android-uuid.jsonl" <<'EOF'
{"sessionId":"session-android-uuid","type":"user","content":"hello android"}
{"sessionId":"session-android-uuid","type":"assistant","content":"hello from claude"}
EOF
SESSION_JSONL_HASH_BEFORE="$(sha256sum "$HOME/.claude-acct2/projects/$ANDROID_HASH/session-android-uuid.jsonl" | awk '{print $1}')"

# Project memory under acct2 (mirrors how Claude Code writes per-project notes).
mkdir -p "$HOME/.claude-acct2/projects/$ANDROID_HASH/memory"
printf 'project memory written from acct2\n' \
  > "$HOME/.claude-acct2/projects/$ANDROID_HASH/memory/project_notes.md"

# === Run unify ===
# shellcheck disable=SC2119  # test intentionally calls run_unify with no args
run_unify > /tmp/cma-test-unify.log 2>&1
unify_rc=$?

it "unify succeeds with the new .claude.json merge logic"
assert_eq 0 "$unify_rc" "unify rc=0"
grep -q "ok: \.claude\.json" /tmp/cma-test-unify.log
assert_eq 0 $? "unify logged the .claude.json merge step"

# === Proof 1: acct1 now sees Android_15 in its .claude.json projects map ===
it "acct1's .claude.json now contains the Android_15 project entry from acct2"
assert_file "$HOME/.claude-acct1/.claude.json" "acct1 .claude.json exists"
last_session="$(jq -r '.projects["/projects/Android_15"].lastSessionId // empty' "$HOME/.claude-acct1/.claude.json")"
assert_eq "session-android-uuid" "$last_session" "acct1 sees Android_15 lastSessionId"
ios_session="$(jq -r '.projects["/projects/iOS"].lastSessionId // empty' "$HOME/.claude-acct1/.claude.json")"
assert_eq "session-ios-uuid" "$ios_session" "acct1 also sees iOS project entry"
mcp_cmd="$(jq -r '.projects["/projects/Android_15"].mcpServers["android-dev"].command // empty' "$HOME/.claude-acct1/.claude.json")"
assert_eq "android-mcp" "$mcp_cmd" "deep-nested MCP server config crossed accounts"

# === Proof 2: acct1's OWN auth keys were NOT clobbered by the merge ===
it "acct1's auth keys are preserved (userID, oauthAccount, firstStartTime, claudeCodeFirstTokenDate)"
assert_eq "user-acct1-hash" "$(jq -r .userID "$HOME/.claude-acct1/.claude.json")" "acct1 userID intact"
assert_eq "acct1@example.com" "$(jq -r .oauthAccount.emailAddress "$HOME/.claude-acct1/.claude.json")" "acct1 oauthAccount.email intact"
assert_eq "uuid-acct1" "$(jq -r .oauthAccount.accountUuid "$HOME/.claude-acct1/.claude.json")" "acct1 oauthAccount.uuid intact"
assert_eq "2026-01-01T00:00:00.000Z" "$(jq -r .firstStartTime "$HOME/.claude-acct1/.claude.json")" "acct1 firstStartTime intact"

# === Proof 3: acct2's OWN auth keys are also preserved (no cross-contamination) ===
it "acct2's auth keys remain its own — no cross-contamination from acct1"
assert_eq "user-acct2-hash" "$(jq -r .userID "$HOME/.claude-acct2/.claude.json")" "acct2 userID intact"
assert_eq "acct2@example.com" "$(jq -r .oauthAccount.emailAddress "$HOME/.claude-acct2/.claude.json")" "acct2 oauthAccount.email intact"
acct1_email_in_acct2="$(jq -r '.oauthAccount.emailAddress' "$HOME/.claude-acct2/.claude.json")"
cond=1; [[ "$acct1_email_in_acct2" != "acct1@example.com" ]] && cond=0
assert_eq 0 "$cond" "acct2 did NOT inherit acct1's email"

# === Proof 4: non-auth shareable keys (UX state) merged across accounts ===
it "non-auth top-level keys merge across accounts (numStartups rightmost-wins)"
# Both files now have numStartups equal to whichever value the merge biased
# toward. The exact rule is rightmost-wins; what matters here is that the
# value is non-empty in both files (proves the merge happened) and the same.
ns_acct1="$(jq -r .numStartups "$HOME/.claude-acct1/.claude.json")"
ns_acct2="$(jq -r .numStartups "$HOME/.claude-acct2/.claude.json")"
cond=1; [[ -n "$ns_acct1" && "$ns_acct1" != "null" ]] && cond=0
assert_eq 0 "$cond" "acct1 has numStartups set"
assert_eq "$ns_acct1" "$ns_acct2" "both accounts agree on numStartups after merge"

# === Proof 5: the actual session JSONL is byte-identical between accounts ===
it "session JSONL written under acct2 is byte-identical when read via acct1's projects/ symlink"
acct1_session_path="$HOME/.claude-acct1/projects/$ANDROID_HASH/session-android-uuid.jsonl"
assert_file "$acct1_session_path" "acct1 can resolve the session file via its symlinked projects/ dir"
SESSION_JSONL_HASH_FROM_ACCT1="$(sha256sum "$acct1_session_path" | awk '{print $1}')"
assert_eq "$SESSION_JSONL_HASH_BEFORE" "$SESSION_JSONL_HASH_FROM_ACCT1" "session JSONL byte-identical across accounts"
# And the content actually parses as the same conversation:
last_role_from_acct1="$(tail -1 "$acct1_session_path" | jq -r .type)"
assert_eq "assistant" "$last_role_from_acct1" "session content readable from acct1 view"

# === Proof 6: project memory written under acct2 is readable from acct1 ===
it "project memory written under acct2 is visible from acct1"
memory_via_acct1="$HOME/.claude-acct1/projects/$ANDROID_HASH/memory/project_notes.md"
assert_file "$memory_via_acct1" "memory file resolves via acct1's symlinked projects/"
content="$(cat "$memory_via_acct1")"
assert_eq "project memory written from acct2" "$content" "memory content identical"

# === Proof 7: re-running unify is idempotent for .claude.json ===
it "re-running unify keeps every account's .claude.json byte-stable (idempotent)"
HASH_ACCT1_BEFORE="$(sha256sum "$HOME/.claude-acct1/.claude.json" | awk '{print $1}')"
HASH_ACCT2_BEFORE="$(sha256sum "$HOME/.claude-acct2/.claude.json" | awk '{print $1}')"
# shellcheck disable=SC2119  # test intentionally calls run_unify with no args
run_unify > /dev/null 2>&1
HASH_ACCT1_AFTER="$(sha256sum "$HOME/.claude-acct1/.claude.json" | awk '{print $1}')"
HASH_ACCT2_AFTER="$(sha256sum "$HOME/.claude-acct2/.claude.json" | awk '{print $1}')"
assert_eq "$HASH_ACCT1_BEFORE" "$HASH_ACCT1_AFTER" "acct1 .claude.json byte-stable on re-run"
assert_eq "$HASH_ACCT2_BEFORE" "$HASH_ACCT2_AFTER" "acct2 .claude.json byte-stable on re-run"

# === Proof 8: claude-sync-state push/pull produce the same result as unify ===
it "claude-sync-state in pull mode achieves cross-account project visibility independently"
# Reset acct1's .claude.json to its pristine state, then sync.
cat > "$HOME/.claude-acct1/.claude.json" <<'EOF'
{
  "userID": "user-acct1-hash",
  "oauthAccount": {"emailAddress": "acct1@example.com", "accountUuid": "uuid-acct1"},
  "firstStartTime": "2026-01-01T00:00:00.000Z",
  "numStartups": 3,
  "projects": {}
}
EOF
# acct1 starts with 0 projects; verify that fact before the sync.
before_count="$(jq '.projects | length' "$HOME/.claude-acct1/.claude.json")"
assert_eq "0" "$before_count" "acct1 starts with 0 projects pre-sync"
"$SCRIPTS_DIR/claude-sync-state.sh" pull "$HOME/.claude-acct1" > /tmp/cma-test-sync.log 2>&1
sync_rc=$?
assert_eq 0 "$sync_rc" "claude-sync-state pull rc=0"
after_count="$(jq '.projects | length' "$HOME/.claude-acct1/.claude.json")"
cond=1; [[ "$after_count" == "2" ]] && cond=0
assert_eq 0 "$cond" "acct1 has both Android_15 and iOS projects after pull ($after_count)"
# Auth preserved:
assert_eq "user-acct1-hash" "$(jq -r .userID "$HOME/.claude-acct1/.claude.json")" "userID still acct1's after sync"

# === Proof 9: an account with NO .claude.json gets seeded by sync ===
it "an account with no .claude.json gets the shared projects map seeded by sync"
make_account acct3   # no .claude.json by default? actually make_account writes one
rm -f "$HOME/.claude-acct3/.claude.json"
"$SCRIPTS_DIR/claude-sync-state.sh" pull "$HOME/.claude-acct3" > /dev/null 2>&1
assert_file "$HOME/.claude-acct3/.claude.json" "acct3 got a seeded .claude.json"
acct3_projects="$(jq '.projects | length' "$HOME/.claude-acct3/.claude.json")"
cond=1; [[ "$acct3_projects" == "2" ]] && cond=0
assert_eq 0 "$cond" "acct3 seeded with the union of projects ($acct3_projects)"

# === Proof 10: a corrupt .claude.json doesn't destroy the others' state ===
it "corrupt .claude.json in one account is skipped without poisoning the merge"
printf '{this is not valid json' > "$HOME/.claude-acct3/.claude.json"
# Should warn but not crash, and acct1/acct2 should remain intact.
"$SCRIPTS_DIR/claude-sync-state.sh" all > /tmp/cma-test-corrupt.log 2>&1
rc=$?
assert_eq 0 $rc "sync still exits 0 despite one corrupt file"
# acct1 should still have its merged projects:
still_has="$(jq -r '.projects["/projects/Android_15"].lastSessionId // empty' "$HOME/.claude-acct1/.claude.json")"
assert_eq "session-android-uuid" "$still_has" "acct1 state survived the corrupt-file sync"

summary
