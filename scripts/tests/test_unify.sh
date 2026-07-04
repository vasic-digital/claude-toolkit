#!/usr/bin/env bash
# test_unify.sh — exercises claude-unify.sh:
#   * basic merge of two accounts: all shared items become symlinks
#   * settings.json enabledPlugins is a strict union
#   * history.jsonl is concatenated and de-duplicated
#   * memory files survive merge (newest account wins conflicts)
#   * plugin manifest installPath is rewritten to the shared store
#   * N>2 accounts also work
#   * a second unify run produces the same state (idempotent)
#   * --rollback restores .preunify.* backups

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"   # defines cma_realpath etc. used directly below
# lib.sh enables `set -e`; this harness asserts on failures, so relax it.
set +e

make_sandbox

# Two fixture accounts with overlapping and unique data.
acct1="$(make_account acct1 --plugins \
  --settings '{"enabledPlugins":{"a":true,"b":true},"effortLevel":"high"}' \
  --history 'cmd1|cmd2|shared-line' \
  --memory 'user_role:role from acct1' \
  --todo todo-a-1)"
acct2="$(make_account acct2 --plugins \
  --settings '{"enabledPlugins":{"b":true,"c":true},"skipDangerousModePermissionPrompt":true}' \
  --history 'cmd3|shared-line|cmd4' \
  --memory 'user_role:role from acct2 (NEWER)' \
  --memory 'project_notes:notes from acct2 only' \
  --todo todo-b-1)"

# Make sure acct2 is the most recently touched so the unifier's "last
# account wins on conflicts" rule applies to it.
touch "$acct2/projects/-home-test/memory/user_role.md"

# shellcheck disable=SC2119  # test intentionally calls run_unify with no args
run_unify >/dev/null 2>&1
rc=$?
assert_eq 0 "$rc" "claude-unify exits 0"

it "every shared item becomes a symlink into the shared store"
# §11.4 own-settings: settings.json is intentionally NOT in this list — it is each
# dir's OWN real file, asserted separately below. Everything else (incl. the
# plugin CACHE and history) stays a shared symlink.
for item in projects todos tasks plans file-history paste-cache plugins \
            shell-snapshots session-env telemetry sessions backups cache \
            stats-cache.json history.jsonl; do
  case "$item" in
    stats-cache.json)
      # Only fixtures with this file get the symlink; skip if absent.
      [[ -e "$SHARED_DIR/$item" ]] || continue ;;
  esac
  assert_symlink_to "$acct1/$item" "$SHARED_DIR/$item" "$acct1 $item linked"
  assert_symlink_to "$acct2/$item" "$SHARED_DIR/$item" "$acct2 $item linked"
done

it "settings.json is each dir's OWN real file (§11.4 own-settings), not a shared symlink"
# Per-alias permissions/model/hooks must never leak, so unify gives every dir its
# OWN settings.json — while plugins (cache) + history stay shared symlinks (proven
# in the loop above). The propagated enabledPlugins union lives in each own copy.
assert_not_symlink "$acct1/settings.json" "acct1 settings.json is OWN"
assert_not_symlink "$acct2/settings.json" "acct2 settings.json is OWN"
assert_file "$acct1/settings.json" "acct1 own settings.json exists"
assert_file "$acct2/settings.json" "acct2 own settings.json exists"
assert_jq "$acct1/settings.json" '.enabledPlugins.a' "true" "acct1 own settings carries the enabledPlugins union"
assert_jq "$acct1/settings.json" '.enabledPlugins.c' "true" "acct1 own settings gained acct2's plugin via the propagated union"

it "shared TEMPLATE settings.json enabledPlugins is the union {a,b,c}"
# Unify unions ONLY the enabledPlugins map into the shared template so newly-
# enabled plugins propagate to every dir.
assert_jq "$SHARED_DIR/settings.json" '.enabledPlugins | keys | sort | join(",")' "a,b,c" "union"

it "§11.4 own-settings: per-alias NON-plugin keys stay local — no leak to a sibling dir or to shared"
# effortLevel was set ONLY in acct1; skipDangerousModePermissionPrompt ONLY in
# acct2. Under own-settings each keeps its own key, neither leaks to the other,
# and NEITHER leaks into the shared template (which carries only the plugin union).
assert_jq "$acct1/settings.json" '.effortLevel' "high" "acct1 keeps its OWN effortLevel"
assert_jq "$acct2/settings.json" '.skipDangerousModePermissionPrompt' "true" "acct2 keeps its OWN permission flag"
assert_jq "$acct1/settings.json" '.skipDangerousModePermissionPrompt // "absent"' "absent" "acct2's permission flag did NOT leak into acct1"
assert_jq "$acct2/settings.json" '.effortLevel // "absent"' "absent" "acct1's effortLevel did NOT leak into acct2"
assert_jq "$SHARED_DIR/settings.json" '.effortLevel // "absent"' "absent" "effortLevel did NOT leak to the shared template"
assert_jq "$SHARED_DIR/settings.json" '.skipDangerousModePermissionPrompt // "absent"' "absent" "permission flag did NOT leak to the shared template"

it "history.jsonl contains every unique line, no duplicates"
expected_lines=5
actual_lines="$(sort -u "$SHARED_DIR/history.jsonl" | wc -l | tr -d ' ')"
assert_eq "$expected_lines" "$actual_lines" "5 unique lines"
assert_file_contains "$SHARED_DIR/history.jsonl" "cmd1" "cmd1 present"
assert_file_contains "$SHARED_DIR/history.jsonl" "cmd4" "cmd4 present"

it "memory: newest account's version wins on filename conflict"
assert_file_contains "$SHARED_DIR/projects/-home-test/memory/user_role.md" "NEWER" "acct2 wins"
assert_file "$SHARED_DIR/projects/-home-test/memory/project_notes.md" "acct2-only memory survives"

it "plugin manifest paths are rewritten to the shared store"
assert_jq "$SHARED_DIR/plugins/installed_plugins.json" \
  '.plugins["test-plugin@test-marketplace"][0].installPath' \
  "$SHARED_DIR/plugins/cache/test-marketplace/test-plugin/1.0.0" \
  "installPath rewritten"
assert_jq "$SHARED_DIR/plugins/known_marketplaces.json" \
  '.["test-marketplace"].installLocation' \
  "$SHARED_DIR/plugins/marketplaces/test-marketplace" \
  "installLocation rewritten"

it "credentials are NOT shared — each account keeps its own"
assert_not_symlink "$acct1/.credentials.json" "acct1 creds local"
assert_not_symlink "$acct2/.credentials.json" "acct2 creds local"
assert_file_contains "$acct1/.credentials.json" "acct1" "acct1 creds intact"
assert_file_contains "$acct2/.credentials.json" "acct2" "acct2 creds intact"

it "re-running claude-unify is idempotent (settings.json byte-stable)"
checksum_before="$(sha256sum "$SHARED_DIR/settings.json" | cut -d' ' -f1)"
target_before="$(cma_realpath "$acct1/projects")"  # readlink -f is unavailable on BSD/macOS
# shellcheck disable=SC2119  # test intentionally calls run_unify with no args
run_unify >/dev/null 2>&1
checksum_after="$(sha256sum "$SHARED_DIR/settings.json" | cut -d' ' -f1)"
target_after="$(cma_realpath "$acct1/projects")"
assert_eq "$checksum_before" "$checksum_after" "settings.json unchanged"
assert_eq "$target_before"   "$target_after"   "symlink target unchanged"

it "N>2 accounts: adding a third and re-running unifies it too"
acct3="$(make_account acct3 \
  --settings '{"enabledPlugins":{"d":true}}' \
  --history 'cmd5|cmd1')"
# shellcheck disable=SC2119  # test intentionally calls run_unify with no args
run_unify >/dev/null 2>&1
assert_symlink_to "$acct3/projects" "$SHARED_DIR/projects" "acct3 projects linked"
assert_jq "$SHARED_DIR/settings.json" '.enabledPlugins.d' "true" "acct3 plugin merged"
assert_file_contains "$SHARED_DIR/history.jsonl" "cmd5" "acct3 history merged"

it "§11.4 own-settings PROOF: a per-alias settings.json edit does NOT leak into another dir or shared"
# Add a unique per-alias NON-plugin key to acct1's OWN settings.json AFTER unify,
# then re-run unify. own-settings must keep it local: acct1 retains it, acct2
# never gains it, and the shared template never gains it (it carries only the
# enabledPlugins union). This is the load-bearing anti-leak guarantee of the
# refactor — a real behavioral proof, not a tautology.
jq '.model = "per-alias-model-acct1-only"' "$acct1/settings.json" > "$acct1/settings.json.probe" \
  && mv "$acct1/settings.json.probe" "$acct1/settings.json"
# shellcheck disable=SC2119  # test intentionally calls run_unify with no args
run_unify >/dev/null 2>&1
assert_jq "$acct1/settings.json" '.model' "per-alias-model-acct1-only" "acct1 keeps its OWN per-alias model after unify"
assert_jq "$acct2/settings.json" '.model // "absent"' "absent" "acct1's per-alias model did NOT leak into acct2"
assert_jq "$SHARED_DIR/settings.json" '.model // "absent"' "absent" "acct1's per-alias model did NOT leak to the shared template"
# The plugin union still flows to every dir (plugins ARE meant to be shared).
assert_jq "$acct2/settings.json" '.enabledPlugins.a' "true" "acct2 still carries the propagated enabledPlugins union"

# ── B1 / B2: absorb_default_plugins + link_default_plugin_subdirs ─────────────
# Use an isolated SHARED_DIR/DEFAULT_DIR/ACCOUNT_PREFIX triple so these tests
# don't interfere with the main sandbox state or the rollback assertions below.

b1_sd="$SANDBOX_HOME/.claude-shared-b1"
b1_dd="$SANDBOX_HOME/.claude-b1"
b1_acct="$SANDBOX_HOME/.claude-b1-acct"
mkdir -p "$b1_dd/plugins/cache/foo/1.0.0"
printf 'hello-b1\n' > "$b1_dd/plugins/cache/foo/1.0.0/file.txt"
mkdir -p "$b1_acct"
printf '{"name":"b1"}\n' > "$b1_acct/.credentials.json"
printf '{"name":"b1"}\n' > "$b1_acct/.claude.json"
printf '{"enabledPlugins":{}}\n' > "$b1_acct/settings.json"
SHARED_DIR="$b1_sd" DEFAULT_DIR="$b1_dd" ACCOUNT_PREFIX=".claude-b1-" \
  "$SCRIPTS_DIR/claude-unify.sh" >/dev/null 2>&1

it "absorb_default_plugins (B1): files under DEFAULT_DIR/plugins/cache are absorbed into shared store"
assert_file "$b1_sd/plugins/cache/foo/1.0.0/file.txt" \
  "absorb_default_plugins: file.txt absorbed from DEFAULT_DIR/plugins/cache into SHARED_DIR"

it "link_default_plugin_subdirs (B2): DEFAULT_DIR/plugins/cache becomes a symlink into shared store"
b2_is_link=1; [[ -L "$b1_dd/plugins/cache" ]] && b2_is_link=0
assert_eq 0 "$b2_is_link" "DEFAULT_DIR/plugins/cache is a symlink after unify"
b2_real="$(cma_realpath "$b1_dd/plugins/cache")"
assert_eq "$(cma_realpath "$b1_sd/plugins/cache")" "$b2_real" "symlink resolves to SHARED_DIR/plugins/cache"

it "link_default_plugin_subdirs (B2 idempotent): second unify creates no additional .preunify.* backup"
b2_pre="$(find "$b1_dd/plugins" -maxdepth 1 -name 'cache.preunify.*' 2>/dev/null | wc -l | tr -d ' ')"
SHARED_DIR="$b1_sd" DEFAULT_DIR="$b1_dd" ACCOUNT_PREFIX=".claude-b1-" \
  "$SCRIPTS_DIR/claude-unify.sh" >/dev/null 2>&1
b2_post="$(find "$b1_dd/plugins" -maxdepth 1 -name 'cache.preunify.*' 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "$b2_pre" "$b2_post" "no new .preunify.* backup created on second unify run (idempotent)"

# ── B4: sync_claude_md seed branches ─────────────────────────────────────────
# (b) DEFAULT_DIR has a real CLAUDE.md; no account CLAUDE.md.
#     sync_claude_md should seed shared CLAUDE.md from DEFAULT_DIR.

b4b_sd="$SANDBOX_HOME/.claude-shared-b4b"
b4b_dd="$SANDBOX_HOME/.claude-b4b"
b4b_acct="$SANDBOX_HOME/.claude-b4b-acct"
mkdir -p "$b4b_dd" "$b4b_acct"
printf 'default-memory\n' > "$b4b_dd/CLAUDE.md"
printf '{"name":"b4b"}\n' > "$b4b_acct/.credentials.json"
printf '{"name":"b4b"}\n' > "$b4b_acct/.claude.json"
printf '{"enabledPlugins":{}}\n' > "$b4b_acct/settings.json"
SHARED_DIR="$b4b_sd" DEFAULT_DIR="$b4b_dd" ACCOUNT_PREFIX=".claude-b4b-" \
  "$SCRIPTS_DIR/claude-unify.sh" >/dev/null 2>&1

it "sync_claude_md (B4b): DEFAULT_DIR/CLAUDE.md seeds shared CLAUDE.md when no account has one"
assert_file_contains "$b4b_sd/CLAUDE.md" "default-memory" \
  "sync_claude_md: DEFAULT_DIR/CLAUDE.md content seeded into shared store"

# (c) No DEFAULT_DIR CLAUDE.md; an account has a real CLAUDE.md.
#     sync_claude_md should fall back and seed from the first account's CLAUDE.md.

b4c_sd="$SANDBOX_HOME/.claude-shared-b4c"
b4c_dd="$SANDBOX_HOME/.claude-b4c"
b4c_acct="$SANDBOX_HOME/.claude-b4c-acct"
mkdir -p "$b4c_dd" "$b4c_acct"
# No CLAUDE.md in b4c_dd (the DEFAULT_DIR).
printf 'acct2-memory\n' > "$b4c_acct/CLAUDE.md"
printf '{"name":"b4c"}\n' > "$b4c_acct/.credentials.json"
printf '{"name":"b4c"}\n' > "$b4c_acct/.claude.json"
printf '{"enabledPlugins":{}}\n' > "$b4c_acct/settings.json"
SHARED_DIR="$b4c_sd" DEFAULT_DIR="$b4c_dd" ACCOUNT_PREFIX=".claude-b4c-" \
  "$SCRIPTS_DIR/claude-unify.sh" >/dev/null 2>&1

it "sync_claude_md (B4c): account CLAUDE.md seeds shared CLAUDE.md when DEFAULT_DIR has none"
assert_file_contains "$b4c_sd/CLAUDE.md" "acct2-memory" \
  "sync_claude_md: account CLAUDE.md seeded into shared store when DEFAULT_DIR lacks one"

# ── R1: history.jsonl merge must not fuse records across a source that lacks a
# trailing newline. Regression for cat-based concat gluing one file's last line
# onto the next file's first line.
r1_sd="$SANDBOX_HOME/.claude-shared-r1"
r1_a="$SANDBOX_HOME/.claude-r1-a"
r1_b="$SANDBOX_HOME/.claude-r1-b"
mkdir -p "$r1_a" "$r1_b"
printf '{"n":"r1a"}\n' > "$r1_a/.credentials.json"; printf '{"name":"r1a"}\n' > "$r1_a/.claude.json"
printf '{"n":"r1b"}\n' > "$r1_b/.credentials.json"; printf '{"name":"r1b"}\n' > "$r1_b/.claude.json"
printf '{"enabledPlugins":{}}\n' > "$r1_a/settings.json"
printf '{"enabledPlugins":{}}\n' > "$r1_b/settings.json"
# acct a's history has NO trailing newline (the bug trigger); acct b follows it.
printf '{"e":"one"}\n{"e":"two"}' > "$r1_a/history.jsonl"
printf '{"e":"three"}\n{"e":"four"}\n' > "$r1_b/history.jsonl"
SHARED_DIR="$r1_sd" DEFAULT_DIR="$SANDBOX_HOME/.claude-r1" ACCOUNT_PREFIX=".claude-r1-" \
  "$SCRIPTS_DIR/claude-unify.sh" >/dev/null 2>&1

it "history.jsonl (R1): a source missing its trailing newline does not fuse records"
r1_two=1;   grep -qxF '{"e":"two"}'   "$r1_sd/history.jsonl" 2>/dev/null && r1_two=0
r1_three=1; grep -qxF '{"e":"three"}' "$r1_sd/history.jsonl" 2>/dev/null && r1_three=0
r1_fused=0; grep -qF  '"two"}{"e":"three"' "$r1_sd/history.jsonl" 2>/dev/null && r1_fused=1
assert_eq 0 "$r1_two"   "history line {\"e\":\"two\"} preserved intact"
assert_eq 0 "$r1_three" "history line {\"e\":\"three\"} preserved intact"
assert_eq 0 "$r1_fused" "no fused two+three record"

# ── R2: enabledPlugins union must keep "any true" regardless of account order.
# Regression: rightmost-wins let the lexically-last account's false clobber a
# plugin an earlier account had enabled.
r2_sd="$SANDBOX_HOME/.claude-shared-r2"
r2_a="$SANDBOX_HOME/.claude-r2-a"
r2_b="$SANDBOX_HOME/.claude-r2-b"
mkdir -p "$r2_a" "$r2_b"
printf '{"n":"r2a"}\n' > "$r2_a/.credentials.json"; printf '{"name":"r2a"}\n' > "$r2_a/.claude.json"
printf '{"n":"r2b"}\n' > "$r2_b/.credentials.json"; printf '{"name":"r2b"}\n' > "$r2_b/.claude.json"
# a (lexically first) enables foo; b (lexically LAST, the overlay account) disables it.
printf '{"enabledPlugins":{"foo":true}}\n'             > "$r2_a/settings.json"
printf '{"enabledPlugins":{"foo":false,"bar":true}}\n' > "$r2_b/settings.json"
SHARED_DIR="$r2_sd" DEFAULT_DIR="$SANDBOX_HOME/.claude-r2" ACCOUNT_PREFIX=".claude-r2-" \
  "$SCRIPTS_DIR/claude-unify.sh" >/dev/null 2>&1

it "enabledPlugins (R2): a plugin enabled in any account stays enabled (any-true union)"
assert_jq "$r2_sd/settings.json" '.enabledPlugins.foo' "true" "foo stays true despite last account false"
assert_jq "$r2_sd/settings.json" '.enabledPlugins.bar' "true" "bar from last account present"

# ── R3: a single malformed settings.json must not abort the whole unify.
# Regression: the multi-file jq -s merge ran unguarded under set -e.
r3_sd="$SANDBOX_HOME/.claude-shared-r3"
r3_a="$SANDBOX_HOME/.claude-r3-a"
r3_b="$SANDBOX_HOME/.claude-r3-b"
mkdir -p "$r3_a" "$r3_b"
printf '{"n":"r3a"}\n' > "$r3_a/.credentials.json"; printf '{"name":"r3a"}\n' > "$r3_a/.claude.json"
printf '{"n":"r3b"}\n' > "$r3_b/.credentials.json"; printf '{"name":"r3b"}\n' > "$r3_b/.claude.json"
printf '{"enabledPlugins":{"ok":true}}\n' > "$r3_a/settings.json"
printf '%s\n' '{ this is not valid json'  > "$r3_b/settings.json"
SHARED_DIR="$r3_sd" DEFAULT_DIR="$SANDBOX_HOME/.claude-r3" ACCOUNT_PREFIX=".claude-r3-" \
  "$SCRIPTS_DIR/claude-unify.sh" >/dev/null 2>&1
r3_rc=$?

it "settings.json (R3): one malformed account file does not abort unify"
assert_eq 0 "$r3_rc" "unify still exits 0 despite a malformed settings.json"
r3_tmp=0; [[ -e "$r3_sd/settings.json.tmp" ]] && r3_tmp=1
assert_eq 0 "$r3_tmp" "no orphaned settings.json.tmp left behind"
# The valid account's settings must NOT become a dangling symlink (silent loss):
# the merge must still write shared from the valid file(s) and link to it.
r3_readable=0; [[ -f "$r3_a/settings.json" ]] && r3_readable=1
assert_eq 1 "$r3_readable" "valid account settings.json still readable (not a dangling symlink)"
assert_jq "$r3_a/settings.json" '.enabledPlugins.ok' "true" "valid account's settings survive a malformed sibling"

# ── R4: directory merge must resolve file conflicts by newest mtime, not by the
# lexically-last account name. Regression: pass 2 overlaid ACCOUNTS[-1]
# (alphabetically last) unconditionally, so a stale lexically-last account
# clobbered fresher content from an earlier account.
r4_sd="$SANDBOX_HOME/.claude-shared-r4"
r4_a="$SANDBOX_HOME/.claude-r4-a"
r4_b="$SANDBOX_HOME/.claude-r4-b"
mkdir -p "$r4_a/projects/p/memory" "$r4_b/projects/p/memory"
printf '{"n":"r4a"}\n' > "$r4_a/.credentials.json"; printf '{"name":"r4a"}\n' > "$r4_a/.claude.json"
printf '{"n":"r4b"}\n' > "$r4_b/.credentials.json"; printf '{"name":"r4b"}\n' > "$r4_b/.claude.json"
printf '{"enabledPlugins":{}}\n' > "$r4_a/settings.json"
printf '{"enabledPlugins":{}}\n' > "$r4_b/settings.json"
# Same file in both. b (lexically LAST) is STALE; a (lexically first) is FRESH.
# Set explicit mtimes (touch -t, portable) so a is strictly newer than b.
printf 'OLD-from-b\n' > "$r4_b/projects/p/memory/note.md"
printf 'NEW-from-a\n' > "$r4_a/projects/p/memory/note.md"
touch -t 202001010000 "$r4_b/projects/p/memory/note.md"
touch -t 202601010000 "$r4_a/projects/p/memory/note.md"
SHARED_DIR="$r4_sd" DEFAULT_DIR="$SANDBOX_HOME/.claude-r4" ACCOUNT_PREFIX=".claude-r4-" \
  "$SCRIPTS_DIR/claude-unify.sh" >/dev/null 2>&1

it "dir merge (R4): freshest file wins conflicts regardless of account name order"
assert_file_contains "$r4_sd/projects/p/memory/note.md" "NEW-from-a" \
  "newer file from lexically-earlier account wins (not the stale lexically-last one)"

# ── R5: rollback must not leave a dangling symlink for an item an account never
# had. Such items get a shared-store symlink but NO .preunify backup, so the
# restore loop never visits them; once SHARED_DIR is moved aside they dangle.
r5_sd="$SANDBOX_HOME/.claude-shared-r5"
r5_a="$SANDBOX_HOME/.claude-r5-a"
r5_b="$SANDBOX_HOME/.claude-r5-b"
mkdir -p "$r5_a/projects" "$r5_b/projects" "$r5_b/todos"   # only b has todos
printf '{"n":"r5a"}\n' > "$r5_a/.credentials.json"; printf '{"name":"r5a"}\n' > "$r5_a/.claude.json"
printf '{"n":"r5b"}\n' > "$r5_b/.credentials.json"; printf '{"name":"r5b"}\n' > "$r5_b/.claude.json"
printf '{"enabledPlugins":{}}\n' > "$r5_a/settings.json"
printf '{"enabledPlugins":{}}\n' > "$r5_b/settings.json"
SHARED_DIR="$r5_sd" DEFAULT_DIR="$SANDBOX_HOME/.claude-r5" ACCOUNT_PREFIX=".claude-r5-" \
  "$SCRIPTS_DIR/claude-unify.sh" >/dev/null 2>&1
SHARED_DIR="$r5_sd" DEFAULT_DIR="$SANDBOX_HOME/.claude-r5" ACCOUNT_PREFIX=".claude-r5-" \
  "$SCRIPTS_DIR/claude-unify.sh" --rollback >/dev/null 2>&1

it "rollback (R5): no dangling shared-store symlink left for a never-backed-up item"
r5_dangle=0; [[ -L "$r5_a/todos" ]] && r5_dangle=1
assert_eq 0 "$r5_dangle" "a/todos (symlink, no backup) is removed on rollback, not left dangling"

# ── R6: rollback restores the OLDEST .preunify backup (the true original) when a
# path has more than one, deterministically (find order is otherwise arbitrary).
r6_sd="$SANDBOX_HOME/.claude-shared-r6"
r6_a="$SANDBOX_HOME/.claude-r6-a"
mkdir -p "$r6_a"
printf '{"n":"r6a"}\n' > "$r6_a/.credentials.json"; printf '{"name":"r6a"}\n' > "$r6_a/.claude.json"
# Two backups for the same path; the oldest timestamp holds the true original.
printf 'OLDEST-original\n' > "$r6_a/memo.preunify.20200101000000"
printf 'newer-backup\n'    > "$r6_a/memo.preunify.20240101000000"
SHARED_DIR="$r6_sd" DEFAULT_DIR="$SANDBOX_HOME/.claude-r6" ACCOUNT_PREFIX=".claude-r6-" \
  "$SCRIPTS_DIR/claude-unify.sh" --rollback >/dev/null 2>&1

it "rollback (R6): oldest .preunify backup wins when a path has several"
assert_file_contains "$r6_a/memo" "OLDEST-original" "the true (oldest) original is restored deterministically"

it "--rollback restores backups and archives the shared store"
# shellcheck disable=SC2119  # test intentionally calls run_rollback with no args
run_rollback >/dev/null 2>&1
assert_dir "$acct1/projects" "acct1 projects restored as real dir"
assert_not_symlink "$acct1/projects" "no longer a symlink"
cond=1; [[ ! -d "$SHARED_DIR" ]] && cond=0; assert_eq 0 "$cond" "shared store moved aside"
shared_archive="$(find "$HOME" -maxdepth 1 -name '.claude-shared.removed.*' -type d 2>/dev/null | head -1)"
cond=0; [[ -n "$shared_archive" ]] || cond=1; assert_eq 0 "$cond" "archive sibling exists"

# Drift guard: claude-add-account wires CMA_SHARED_ITEMS (lib.sh) while
# claude-unify.sh carries its own SHARED_ITEMS. CLAUDE.md documents "keep the two
# lists in sync". They MUST agree EXCEPT for CLAUDE.md, which unify handles
# specially via sync_claude_md() (promotion from ~/.claude / DEFAULT_DIR — a
# generic rsync/symlink cannot do that). This catches accidental future drift
# (a new shared item added to one list only) without forcing the two paths to merge.
it "shared-item lists stay in sync: unify SHARED_ITEMS == CMA_SHARED_ITEMS minus the CLAUDE.md special-case"
_cma_items="$(awk '/^CMA_SHARED_ITEMS=\(/{f=1} f{print} f&&/\)/{exit}' "$SCRIPTS_DIR/lib.sh" | tr -d '()"' | tr ' ' '\n' | grep -vE 'CMA_SHARED_ITEMS=|^$|^CLAUDE\.md$' | sort | tr '\n' ' ')"
_uni_items="$(awk '/^SHARED_ITEMS=\(/{f=1} f{print} f&&/\)/{exit}' "$SCRIPTS_DIR/claude-unify.sh" | tr -d '()"' | tr ' ' '\n' | grep -vE 'SHARED_ITEMS=|^$' | sort | tr '\n' ' ')"
assert_eq "$_uni_items" "$_cma_items" "the two shared-item lists agree (modulo the intentional CLAUDE.md special-case)"

summary
