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
sandbox_stub "$HOME/.local/bin/claude-session" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  flags)     echo "--resume 11111111-2222-3333-4444-555555555555 --name testproj" ;;
  latest-id) echo "11111111-2222-3333-4444-555555555555" ;;
  existing-id) echo "11111111-2222-3333-4444-555555555555" ;;
  *)         exit 0 ;;
esac
exit 0
EOF
sandbox_stub "$HOME/.local/bin/claude-sync-state" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$HOME/.local/bin/claude-session" "$HOME/.local/bin/claude-sync-state"

# Fake ccr. The accepted subcommand set MIRRORS the bundled Go router
# (submodules/claude-code-router/cmd/ccr/main.go): start|ui|serve|web|stop|
# restart|config|help|-h|--help, plus the launch grammar the toolkit uses
# (`default-claude-code`, with `code` as its alias).
#
# The catch-all must FAIL LOUDLY. A silent `*) exit 0` is exactly what let the
# v1.23.0 Go-router swap through: the wrapper invoked `default-claude-code`, the
# stub fell to `*`, wrote NOTHING, and the assertions read a stale record file
# from a previous run. Any grammar drift must now break the test, not pass it.
FAKEBIN="$HOME/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ccr" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --help|-h|help) echo "Usage: ccr start [--host <host>]"; echo "  ccr serve [--host <host>]"; echo "  ccr restart [--host <host>]"; exit 0 ;;
  code|default-claude-code) shift; printf '%s\n' "$*" > "$REC_ARGS_OUT"; exit 0 ;;
  start|ui|serve|web|stop|restart|config) exit 0 ;;
  *) printf 'fake-ccr: unexpected subcommand %s — not implemented by the bundled Go router\n' "${1:-<none>}" >&2; exit 2 ;;
esac
EOF
chmod +x "$FAKEBIN/ccr"

# shellcheck source=/dev/null
source "$ALIAS_FILE"
# PROVENANCE GATE — see lib/assert.sh:assert_fn_from. The host's real
# cma_run_provider is already defined in this shell (BASH_ENV sources the
# production alias file), so a failed source above would silently hand every
# assertion below to host code.
it "HYGIENE: the cma_run_provider under test comes from the sandbox alias file"
assert_fn_from cma_run_provider "$ALIAS_FILE" "wrapper loaded from the sandbox, not the host"

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
: > "$rec_args"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" CLAUDE_BIN="$recorder" cma_run_provider acmenative </dev/null >/dev/null 2>&1 )
grep -q -- "--resume 11111111-2222-3333-4444-555555555555" "$rec_args"; assert_eq 0 $? "native bare launch resumed the project session"

it "router bare launch applies session flags (was missing before v1.17.0)"
: > "$rec_args"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" PATH="$FAKEBIN:/usr/bin:/bin" cma_run_provider acmerouter </dev/null >/dev/null 2>&1 )
grep -q -- "--resume 11111111-2222-3333-4444-555555555555" "$rec_args"; assert_eq 0 $? "router bare launch resumed the project session (ccr got the launch flags)"

# ===========================================================================
# Section 2 — conversation args get --resume injected
# ===========================================================================
it "-p prompt gets --resume injected when a session exists (native)"
: > "$rec_args"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" CLAUDE_BIN="$recorder" cma_run_provider acmenative -p "hello" </dev/null >/dev/null 2>&1 )
args="$(cat "$rec_args")"
case "$args" in --resume\ 11111111-2222-3333-4444-555555555555\ -p\ hello) ok=0 ;; *) ok=1 ;; esac
assert_eq 0 "$ok" "--resume precedes the prompt args verbatim ($args)"

it "-p prompt gets --resume injected (router)"
# NOTE the leading `--`. The router transport invokes
# `ccr default-claude-code -- "$@"` (scripts/lib.sh:953); the stub shifts off
# only the subcommand, so the separator is part of what it records. That is the
# agreed grammar, not drift — the router's own launch_test.go pins the same
# shape (`run([]string{"default-claude-code", "--", "-p", "hello"}, …)`).
#
# This expectation previously read `--resume … -p hello` (the NATIVE shape) and
# "passed" only because $rec_args was never truncated between runs: the router
# leg wrote nothing (the old stub fell through to `*) exit 0`) and the
# assertion matched the leftovers of the native run above. With truncation in
# place it now compares against a genuine router record. Kept as an exact match
# rather than a grep so argument order and double-injection regressions still
# fail loudly.
: > "$rec_args"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" PATH="$FAKEBIN:/usr/bin:/bin" cma_run_provider acmerouter -p "hello" </dev/null >/dev/null 2>&1 )
args="$(cat "$rec_args")"
case "$args" in --\ --resume\ 11111111-2222-3333-4444-555555555555\ -p\ hello) ok=0 ;; *) ok=1 ;; esac
assert_eq 0 "$ok" "--resume injected on the router path too, after the '--' separator ($args)"

it "explicit --resume is NEVER double-injected"
: > "$rec_args"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" CLAUDE_BIN="$recorder" cma_run_provider acmenative --resume deadbeef-0000 -p hi </dev/null >/dev/null 2>&1 )
n="$(grep -o -- "--resume" "$rec_args" | wc -l | tr -d ' ')"
assert_eq 1 "$n" "exactly one --resume (the user's own)"
grep -q "deadbeef-0000" "$rec_args"; assert_eq 0 $? "the user's own session id survived"

it "non-conversation subcommands are left verbatim (agents)"
: > "$rec_args"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" CLAUDE_BIN="$recorder" cma_run_provider acmenative agents </dev/null >/dev/null 2>&1 )
assert_eq "agents" "$(cat "$rec_args")" "'agents' passed through without injection"

it "no injection when no session exists yet"
sandbox_stub "$HOME/.local/bin/claude-session" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  flags)     echo "--session-id 99999999-8888-7777-6666-555555555555 --name testproj" ;;
  latest-id) printf '' ;;
  existing-id) printf '' ;;
  *)         exit 0 ;;
esac
exit 0
EOF
: > "$rec_args"
( set +eu; ACME_KEY=sk-test REC_ARGS_OUT="$rec_args" CLAUDE_BIN="$recorder" cma_run_provider acmenative -p "hello" </dev/null >/dev/null 2>&1 )
assert_eq "-p hello" "$(cat "$rec_args")" "no session -> prompt args verbatim (fresh start)"
# restore the stub with an existing session
sandbox_stub "$HOME/.local/bin/claude-session" <<'EOF'
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
