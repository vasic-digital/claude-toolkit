#!/usr/bin/env bash
# test_lib.sh — unit tests for the helper functions in lib.sh.
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
# lib.sh enables `set -e`. The test harness is intentionally tolerant of
# non-zero exits (we assert on them), so turn it back off here.
set +e

it "cma_validate_alias accepts well-formed names"
( set -e; cma_validate_alias "claude3" ); assert_eq 0 $? "claude3"
( set -e; cma_validate_alias "work_acct-1" ); assert_eq 0 $? "work_acct-1"

it "cma_validate_alias rejects invalid names"
( cma_validate_alias "3claude" >/dev/null 2>&1 ); assert_eq 1 $? "rejects digit-leading"
( cma_validate_alias "bad name" >/dev/null 2>&1 ); assert_eq 1 $? "rejects spaces"
( cma_validate_alias "" >/dev/null 2>&1 ); assert_eq 1 $? "rejects empty"

it "cma_suggest_alias starts at claude1 when nothing exists"
suggestion="$(cma_suggest_alias)"
assert_eq "claude1" "$suggestion" "first suggestion"

it "cma_suggest_alias increments past existing claudeN aliases"
cma_write_alias claude1 "$HOME/.claude-acct1"
cma_write_alias claude2 "$HOME/.claude-acct2"
cma_write_alias claude5 "$HOME/.claude-acct5"   # gap
suggestion="$(cma_suggest_alias)"
assert_eq "claude6" "$suggestion" "skips past highest, not count"

it "cma_write_alias is idempotent — rewriting same alias doesn't duplicate"
cma_write_alias claude1 "$HOME/.claude-acct1"   # second write
count="$(grep -c '^alias claude1=' "$ALIAS_FILE")"
assert_eq "1" "$count" "one alias line for claude1"

it "cma_remove_alias removes the line"
cma_remove_alias claude5
assert_file_not_contains "$ALIAS_FILE" "alias claude5=" "claude5 removed"

it "cma_ensure_alias_file sources from the shell rc file"
# lib.sh manages .zshrc on macOS and .bashrc + .zshrc on Linux (CMA_RC_FILES).
# Assert against the platform-appropriate target, selected the same way lib.sh
# selects it, so the test is correct on both OSes.
if [[ "$(uname -s)" == "Darwin" ]]; then RC_FILE="$HOME/.zshrc"; else RC_FILE="$HOME/.bashrc"; fi
touch "$RC_FILE"
rm -f "$ALIAS_FILE"
cma_ensure_alias_file
assert_file "$ALIAS_FILE" "alias file created"
assert_file_contains "$RC_FILE" "source \"$ALIAS_FILE\"" "rc file gets source line"

it "cma_detect_accounts skips the shared store"
mkdir -p "$HOME/.claude-shared" "$HOME/.claude-acct1"
found=(); while IFS= read -r _l; do found+=("$_l"); done < <(cma_detect_accounts)
joined="${found[*]:-}"
cond=1; [[ "$joined" == *".claude-acct1"* ]] && cond=0; assert_eq 0 "$cond" "finds .claude-acct1"
cond=1; [[ "$joined" != *".claude-shared"* ]] && cond=0; assert_eq 0 "$cond" "excludes .claude-shared"

it "cma_detect_accounts excludes non-Claude .claude-* dirs (e.g. .claude-server-commander)"
# Mimic the real-world false positive seen on mistborn.local: an MCP server
# config dir whose name happens to start with .claude- but has only its own
# config files, no Claude markers.
mkdir -p "$HOME/.claude-server-commander"
printf '{}\n' > "$HOME/.claude-server-commander/config.json"
printf '{}\n' > "$HOME/.claude-server-commander/feature-flags.json"
found=(); while IFS= read -r _l; do found+=("$_l"); done < <(cma_detect_accounts)
joined="${found[*]:-}"
cond=1; [[ "$joined" != *".claude-server-commander"* ]] && cond=0; assert_eq 0 "$cond" "excludes .claude-server-commander"
cond=1; [[ "$joined" == *".claude-acct1"* ]] && cond=0; assert_eq 0 "$cond" "still finds the legit empty account"

it "cma_detect_accounts includes a populated account dir even if it has foreign config too"
# A real account dir with the Claude marker (projects/) shouldn't get
# falsely excluded just because some other file happens to be there.
mkdir -p "$HOME/.claude-real/projects"
printf '{}\n' > "$HOME/.claude-real/some-other-tool.json"
found=(); while IFS= read -r _l; do found+=("$_l"); done < <(cma_detect_accounts)
joined="${found[*]:-}"
cond=1; [[ "$joined" == *".claude-real"* ]] && cond=0; assert_eq 0 "$cond" "finds .claude-real"

it "cma_realpath resolves a symlink chain to its canonical target (no readlink -f)"
mkdir -p "$HOME/rp/real"
: > "$HOME/rp/real/file"
ln -s "$HOME/rp/real/file" "$HOME/rp/link1"
ln -s "$HOME/rp/link1" "$HOME/rp/link2"          # chain: link2 -> link1 -> real/file
got="$(cma_realpath "$HOME/rp/link2")"
want="$(cd "$HOME/rp/real" && pwd -P)/file"
assert_eq "$want" "$got" "cma_realpath follows the symlink chain"
# A plain (non-symlink) path canonicalizes to itself.
got2="$(cma_realpath "$HOME/rp/real/file")"
assert_eq "$want" "$got2" "cma_realpath is identity on a real path"

it "no runtime script INVOKES 'readlink -f' (absent on BSD/macOS)"
# Strip comments first so explanatory comments mentioning the flag don't count;
# we only care about real invocations.
hits="$(for f in "$SCRIPTS_DIR"/lib.sh "$SCRIPTS_DIR"/install.sh "$SCRIPTS_DIR"/claude-*.sh; do sed 's/#.*//' "$f"; done 2>/dev/null | grep -c 'readlink -f')"
assert_eq 0 "$hits" "zero 'readlink -f' invocations in runtime scripts"

it "no committed proof artifact contains a literal secret"
# Regression guard for the H2 incident: live proof files (opencode debug config /
# mcp list) once committed a real API key + a DB connection-string password.
# We count *suspect* lines rather than print them, so a failure never re-echoes a
# secret into the test log. Provider-key prefixes + URL user:password@ are the
# signatures; redacted placeholders carry the word REDACTED and are excluded.
proof_dir="$SCRIPTS_DIR/tests/proof"
if [[ -d "$proof_dir" ]]; then
  leaks="$(grep -rIE \
    -e '(sk-ant-|sk-|gsk_|xai-|hf_|AIza|xoxb-|xoxp-|xoxs-|pc-|re_|secret_|ghp_|github_pat_|AKIA)[A-Za-z0-9_-]{12,}' \
    -e '://[^:/@ "]+:[^@/ "]{4,}@' \
    -e 'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}' \
    "$proof_dir" 2>/dev/null | grep -vc 'REDACTED' || true)"
  [[ -z "$leaks" ]] && leaks=0
  assert_eq 0 "$leaks" "proof dir free of literal secrets (suspect-line count)"
else
  _pass "no proof dir on this host (nothing to scan)"
fi

# cma_merge_claude_json must UNION the projects subtree across accounts while
# keeping each account's private auth keys (userID/oauthAccount/...) to ITSELF.
# A regression here would either lose sessions (no union) or leak credentials
# between accounts (CRITICAL). Locks the property verified by hand this session.
it "cma_merge_claude_json: private keys stay per-account; projects union (no credential leak)"
if command -v jq >/dev/null 2>&1; then
  mj_a="$SANDBOX_HOME/.mrg-a"; mj_b="$SANDBOX_HOME/.mrg-b"; mkdir -p "$mj_a" "$mj_b"
  printf '%s\n' '{"userID":"UID-A","oauthAccount":"a@x","projects":{"pa":{"v":1}}}' > "$mj_a/.claude.json"
  printf '%s\n' '{"userID":"UID-B","oauthAccount":"b@x","projects":{"pb":{"v":2}}}' > "$mj_b/.claude.json"
  cma_merge_claude_json "$mj_a" "$mj_b" >/dev/null 2>&1
  assert_eq "UID-A" "$(jq -r .userID "$mj_a/.claude.json")" "account A keeps its OWN userID after merge"
  assert_eq "UID-B" "$(jq -r .userID "$mj_b/.claude.json")" "account B keeps its OWN userID after merge"
  assert_eq '["pa","pb"]' "$(jq -rc '.projects|keys' "$mj_a/.claude.json")" "A sees both projects (union)"
  assert_eq '["pa","pb"]' "$(jq -rc '.projects|keys' "$mj_b/.claude.json")" "B sees both projects (union)"
  mj_leak=0
  grep -q 'UID-B\|b@x' "$mj_a/.claude.json" && mj_leak=1
  grep -q 'UID-A\|a@x' "$mj_b/.claude.json" && mj_leak=1
  assert_eq 0 "$mj_leak" "no cross-account credential leak in either direction"
else
  _pass "jq absent — skipping cma_merge_claude_json security test"
fi

it "cma_ensure_alias_file generates cma_run with project-scoped cwd-hook resolution"
# Verify the emitted cma_run body has the _cma_hook_root marker (project-local
# .claude-cwd-hook support) and the three-tier resolution order:
# 1. CMA_CWD_HOOK env var  2. <git-toplevel>/.claude-cwd-hook  3. global fallback
_mig_ph="$ALIAS_FILE.ph"
cat > "$_mig_ph" <<'PHFMT'
export CLAUDE_BIN="/usr/bin/true"

cma_run() {
  "$CLAUDE_BIN" "$@"
}

alias claude1="CLAUDE_CONFIG_DIR=$SANDBOX_HOME/.claude-1 cma_run"
PHFMT
( ALIAS_FILE="$_mig_ph" cma_ensure_alias_file ) >/dev/null 2>&1
# Extract the regenerated cma_run body and check the markers
_ph_body="$(awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$_mig_ph")"
printf '%s\n' "$_ph_body" | grep -q '_cma_hook_root'; assert_eq 0 $? "cma_run has _cma_hook_root marker (project-scoped hook support)"
# With no CMA_CWD_HOOK set, should check git toplevel first, then global
printf '%s\n' "$_ph_body" | grep -q 'git rev-parse --show-toplevel'; assert_eq 0 $? "cma_run resolves git toplevel for project-local hook"
printf '%s\n' "$_ph_body" | grep -q '\.claude-cwd-hook'; assert_eq 0 $? "cma_run checks for .claude-cwd-hook in project root"
printf '%s\n' "$_ph_body" | grep -q 'CMA_CWD_HOOK:-'; assert_eq 0 $? "cma_run respects CMA_CWD_HOOK env var override"
printf '%s\n' "$_ph_body" | grep -q '.local/bin/claude-cwd-hook'; assert_eq 0 $? "cma_run falls back to global claude-cwd-hook"
rm -f "$_mig_ph"

summary
