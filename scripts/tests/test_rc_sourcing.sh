#!/usr/bin/env bash
# test_rc_sourcing.sh — strict tests for how cma_ensure_alias_file manages the
# `source <alias-file>` line in the user's rc files.
#
# Regression for a real bug: a transient/moved ALIAS_FILE left a DANGLING
# `source "/tmp/.../aliases.sh"` line behind, so every new login shell printed
#   -bash: /tmp/.../aliases.sh: No such file or directory
# The hermetic suite never caught it because it sandboxes $HOME and never
# inspected the rc files OR sourced them in a fresh shell. These tests do both.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
# lib.sh sets -e; this harness asserts on failures, so relax it.
set +e

# Canonical, real alias file (must exist so it resolves and is never pruned).
real_af="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$real_af")"
ALIAS_FILE="$real_af"
CMA_RC_FILES=("$SANDBOX_HOME/.unused-rc")   # keep the create step from touching real rc files
cma_ensure_alias_file >/dev/null 2>&1
[[ -f "$real_af" ]] || { echo "setup failed: canonical alias file not created"; exit 1; }

# Count rc lines that source an aliases.sh (excludes leading-# comments).
count_alias_sources() { grep -cE '^[[:space:]]*(source|\.)[[:space:]]+"?[^"[:space:]]*aliases\.sh' "$1" 2>/dev/null; }
# 1 if any aliases.sh source line in $1 points to a missing file, else 0.
has_dangling() {
  local f t d=0
  while IFS= read -r t; do
    t="${t/#\$HOME/$HOME}"; t="${t/#\~/$HOME}"; [[ -f "$t" ]] || d=1
  done < <(grep -oE '(source|\.)[[:space:]]+"?[^"[:space:]]*aliases\.sh' "$1" 2>/dev/null \
           | sed -E 's/^(source|\.)[[:space:]]+"?//')
  echo "$d"
}

# ── 1. prune: drops a dangling line, keeps valid + comments + unrelated lines ──
it "prune: drops a dangling aliases.sh source line, preserves everything else"
rc1="$SANDBOX_HOME/rc1"
{
  printf 'export FOO=bar\n'
  printf 'source "%s"\n' "$real_af"                              # valid
  printf 'source "%s/gone-1111/aliases.sh"\n' "$SANDBOX_HOME"    # DANGLING
  printf '# migrated to %s: alias claude1=...\n' "$real_af"      # comment — must survive
  printf 'alias x=1\n'
} > "$rc1"
cma_prune_stale_alias_sources "$rc1"
assert_eq 0 "$(has_dangling "$rc1")" "no dangling aliases.sh source line remains"
grep -Fq "source \"$real_af\"" "$rc1"; assert_eq 0 $? "valid source line preserved"
grep -Fq '# migrated to' "$rc1";       assert_eq 0 $? "comment line NOT pruned"
{ grep -Fq 'export FOO=bar' "$rc1" && grep -Fq 'alias x=1' "$rc1"; }; assert_eq 0 $? "unrelated lines preserved"

# ── 2. THE bug: ensure self-heals a dangling line; a fresh shell sources cleanly ──
it "ensure: a pre-existing dangling source line is removed (self-heal)"
rc2="$SANDBOX_HOME/rc2"
printf 'source "%s/zonk-2222/aliases.sh"\n' "$SANDBOX_HOME" > "$rc2"
CMA_RC_FILES=("$rc2")
cma_ensure_alias_file >/dev/null 2>&1
gone=1; grep -q 'zonk-2222' "$rc2" && gone=0
assert_eq 1 "$gone" "ensure removed the dangling source line"
cma_rc_sources_alias_file "$rc2" "$real_af"; assert_eq 0 $? "ensure left a working source line for the alias file"

it "ensure: a fresh shell sources the rc with NO 'No such file' error (the reported symptom)"
err="$(bash -c 'source "$1" 2>&1 1>/dev/null' _ "$rc2")"
clean=1; [[ "$err" == *"No such file"* || "$err" == *"aliases.sh:"* ]] && clean=0
assert_eq 1 "$clean" "fresh shell sourced rc cleanly (stderr: '${err:-<empty>}')"

# ── 3. idempotent: repeated ensure never accumulates duplicate source lines ──
it "ensure: idempotent — 3 calls leave exactly ONE aliases.sh source line"
rc3="$SANDBOX_HOME/rc3"; : > "$rc3"
CMA_RC_FILES=("$rc3")
cma_ensure_alias_file >/dev/null 2>&1
cma_ensure_alias_file >/dev/null 2>&1
cma_ensure_alias_file >/dev/null 2>&1
assert_eq 1 "$(count_alias_sources "$rc3")" "exactly one source line after 3 ensures"
assert_eq 0 "$(has_dangling "$rc3")" "and it is not dangling"

# ── 4. cross-form dedup: a '. "$HOME/…"' line blocks a duplicate 'source "/abs/…"' ──
it "dedup: an equivalent dot/\$HOME-form source line is recognized — no duplicate appended"
rc4="$SANDBOX_HOME/rc4"
# shellcheck disable=SC2016  # $HOME is a literal in the rc line, expanded at source time
printf '. "$HOME/.local/share/claude-multi-account/aliases.sh"\n' > "$rc4"
CMA_RC_FILES=("$rc4")
cma_ensure_alias_file >/dev/null 2>&1
assert_eq 1 "$(count_alias_sources "$rc4")" "no duplicate added when an equivalent dot/\$HOME source exists"

summary
