#!/usr/bin/env bash
# test_session_flags.sh — hermetic Tier-A coverage for the unified session
# flags (v1.17.0, _cma_session_flags): session resolution applies to BOTH
# transports (was native-only) and also to conversation args (was
# bare-launch-only). Root cause of "a session left under xiaomi is invisible
# from deepseek": router aliases never resumed, and `alias -p …` always
# started a fresh session.
set -u
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

# --- launch plumbing ---------------------------------------------------------
cma_ensure_alias_file
rec_args="$HOME/rec.args"
recorder="$HOME/recorder.sh"
cat > "$recorder" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$REC_ARGS_OUT"
exit 0
EOF
chmod +x "$recorder"

# Fake claude-session: deterministic flags/latest-id, silent hint/apply-color.
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/claude-session" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  flags)     echo "--resume 11111111-2222-3333-4444-555555555555 --name testproj" ;;
  latest-id) echo "11111111-2222-3333-4444-555555555555" ;;
  existing-id) echo "11111111-2222-3333-4444-555555555555" ;;
  *)         exit 0 ;;
esac
exit 0
EOF
cat > "$HOME/.local/bin/claude-sync-state" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$HOME/.local/bin/claude-session" "$HOME/.local/bin/claude-sync-state"

# Fake ccr: answers version, records args on `code`.
FAKEBIN="$HOME/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ccr" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  version) echo "claude-code-router version: 2.0.0"; exit 0 ;;
  code) shift; printf '%s\n' "$*" > "$REC_ARGS_OUT"; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/ccr"

# shellcheck source=/dev/null
source "$ALIAS_FILE"

cma_provider_write_env acmenative ACME_KEY native https://api.test/anthropic acme-big "" "$HOME/.claude-prov-acmenative" 262144 "" acmenative
cma_provider_write_alias acmenative acmenative
cma_status_write acmenative verified acme-big ""
cma_provider_write_env acmerouter ACME_KEY router https://api.test/v1 acme-big "" "$HOME/.claude-prov-acmerouter" 262144 "" acmerouter
cma_provider_write_alias acmerouter acmerouter
cma_status_write acmerouter verified acme-big ""

# ===========================================================================
# Section 1 — bare launches get session flags on BOTH transports
# ===========================================================================
it "native bare launch applies session flags"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" CLAUDE_BIN="$recorder" cma_run_provider acmenative </dev/null >/dev/null 2>&1 )
grep -q -- "--resume 11111111-2222-3333-4444-555555555555" "$rec_args"; assert_eq 0 $? "native bare launch resumed the project session"

it "router bare launch applies session flags (was missing before v1.17.0)"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" PATH="$FAKEBIN:/usr/bin:/bin" cma_run_provider acmerouter </dev/null >/dev/null 2>&1 )
grep -q -- "--resume 11111111-2222-3333-4444-555555555555" "$rec_args"; assert_eq 0 $? "router bare launch resumed the project session (ccr code got the flags)"

# ===========================================================================
# Section 2 — conversation args get --resume injected
# ===========================================================================
it "-p prompt gets --resume injected when a session exists (native)"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" CLAUDE_BIN="$recorder" cma_run_provider acmenative -p "hello" </dev/null >/dev/null 2>&1 )
args="$(cat "$rec_args")"
case "$args" in --resume\ 11111111-2222-3333-4444-555555555555\ -p\ hello) ok=0 ;; *) ok=1 ;; esac
assert_eq 0 "$ok" "--resume precedes the prompt args verbatim ($args)"

it "-p prompt gets --resume injected (router)"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" PATH="$FAKEBIN:/usr/bin:/bin" cma_run_provider acmerouter -p "hello" </dev/null >/dev/null 2>&1 )
args="$(cat "$rec_args")"
case "$args" in --resume\ 11111111-2222-3333-4444-555555555555\ -p\ hello) ok=0 ;; *) ok=1 ;; esac
assert_eq 0 "$ok" "--resume injected on the router path too ($args)"

it "explicit --resume is NEVER double-injected"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" CLAUDE_BIN="$recorder" cma_run_provider acmenative --resume deadbeef-0000 -p hi </dev/null >/dev/null 2>&1 )
n="$(grep -o -- "--resume" "$rec_args" | wc -l | tr -d ' ')"
assert_eq 1 "$n" "exactly one --resume (the user's own)"
grep -q "deadbeef-0000" "$rec_args"; assert_eq 0 $? "the user's own session id survived"

it "non-conversation subcommands are left verbatim (agents)"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" CLAUDE_BIN="$recorder" cma_run_provider acmenative agents </dev/null >/dev/null 2>&1 )
assert_eq "agents" "$(cat "$rec_args")" "'agents' passed through without injection"

it "no injection when no session exists yet"
cat > "$HOME/.local/bin/claude-session" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  flags)     echo "--session-id 99999999-8888-7777-6666-555555555555 --name testproj" ;;
  latest-id) printf '' ;;
  existing-id) printf '' ;;
  *)         exit 0 ;;
esac
exit 0
EOF
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" CLAUDE_BIN="$recorder" cma_run_provider acmenative -p "hello" </dev/null >/dev/null 2>&1 )
assert_eq "-p hello" "$(cat "$rec_args")" "no session -> prompt args verbatim (fresh start)"
# restore the stub with an existing session
cat > "$HOME/.local/bin/claude-session" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  flags)     echo "--resume 11111111-2222-3333-4444-555555555555 --name testproj" ;;
  latest-id) echo "11111111-2222-3333-4444-555555555555" ;;
  existing-id) echo "11111111-2222-3333-4444-555555555555" ;;
  *)         exit 0 ;;
esac
exit 0
EOF

# ===========================================================================
# Section 3 — migration
# ===========================================================================
it "migration regenerates a wrapper that lacks _cma_session_flags"
_mig="$ALIAS_FILE.migtest-sf"
cat > "$_mig" <<'OLD'
export CLAUDE_BIN="/usr/bin/true"

cma_run_provider() {
  # claude-sync-state set -a +u claude-session apply-color _cma_compact_cap _cma_proxy_dir
  # command -v cma_log _cma_force >| "$tmp" unset ANTHROPIC_BASE_URL
  # ! git rev-parse --show-toplevel >/dev/null 2>&1
  # command -v "${CLAUDE_BIN:-}" _family_id kimi-code/credentials/kimi-code.json _cma_out_guard
  :
}

alias acme="cma_run_provider acme"
OLD
bash -n "$_mig"; assert_eq 0 $? "old-format alias file parses (bash -n)"
grep -q '_cma_session_flags' "$_mig"; assert_eq 1 $? "old body lacks the unified-flags marker (pre-migration)"
( ALIAS_FILE="$_mig" cma_ensure_alias_file ) >/dev/null 2>&1
mig_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$_mig")"
# herestring (<<<), NOT `printf … | grep -q`: under pipefail, grep -q exits at
# the first match and printf's remaining write to the (post-merge larger) body
# takes SIGPIPE (rc 141) -> false FAIL though the match IS present.
grep -q '_cma_session_flags' <<<"$mig_body"; assert_eq 0 $? "regenerated body carries the unified session flags"
grep -c '^alias acme=' "$_mig" >/dev/null; assert_eq 1 "$(grep -c '^alias acme=' "$_mig")" "alias preserved through migration"
rm -f "$_mig"

summary
