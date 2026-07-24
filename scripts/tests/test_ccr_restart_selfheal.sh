#!/usr/bin/env bash
# test_ccr_restart_selfheal.sh — a STALE bundled ccr (one built before the
# 'restart' subcommand existed) must not brick router-alias launches.
#
# Field failure (v1.25.0): the ccr binary is a gitignored build artifact, so a
# submodule bump that added `ccr restart` did NOT rebuild it. A stale ccr parsed
# `restart` as a PROFILE name and replied `Profile "restart" was not found or is
# disabled` (rc=1); cma_run_provider's fail-safe then (correctly) refused —
# bricking EVERY router-transport alias at once, with an opaque message.
#
# Fix under test: on that specific shape cma_run_provider SELF-HEALS — rebuild
# once via claude-ccr-build + retry `ccr restart` — and only if that cannot help
# does it refuse, now with an actionable "rebuild it: claude-ccr-build" message.
#
# This EXECUTES the real generated wrapper against stubbed ccr / claude-ccr-build
# (it does not grep the text), so a regression that drops the self-heal fails here.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

# --- a verified router-transport provider + a seed ccr config in the sandbox ---
pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
cma_provider_write_env testrtr TESTKEY router "http://127.0.0.1:9/v1" testmodel testmodel \
  "$SANDBOX_HOME/.claude-prov-testrtr" 200000 8192 testrtr
cma_status_write testrtr verified testmodel ""
export TESTKEY="dummy-key-present"
mkdir -p "$SANDBOX_HOME/.claude-code-router"
printf '{}\n' > "$SANDBOX_HOME/.claude-code-router/config.json"

# --- generate the alias file (embeds cma_run_provider with the self-heal) ---
ALIAS_FILE="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$ALIAS_FILE")" "$SANDBOX_HOME/.local/bin"
CMA_RC_FILES=("$SANDBOX_HOME/.unused-rc")
cma_ensure_alias_file >/dev/null 2>&1

# --- stubs: a STALE ccr that only learns 'restart' after claude-ccr-build runs ---
marker="$SANDBOX_HOME/ccr-rebuilt"
ccrlog="$SANDBOX_HOME/ccr.calls"
cbuild_log="$SANDBOX_HOME/ccrbuild.calls"
sandbox_stub "$SANDBOX_HOME/.local/bin/ccr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$ccrlog"
case "\$1" in
  # A STALE bundled router: its --help LACKS 'ccr restart' (the audit I3
  # discriminator) and the OLD build treats 'restart' as a profile name —
  # exactly the field failure. A rebuild (marker) ADDS 'ccr restart' to the help
  # AND adds the 'restart' subcommand so both the identity gate and the route
  # apply pass.
  --help)
    if [ -f "$marker" ]; then
      printf 'Usage:\n  ccr start [...]\n  ccr serve [...]\n  ccr restart [...]\n  ccr stop\n'; exit 0
    else
      printf 'Usage:\n  ccr start [...]\n  ccr serve [...]\n  ccr stop\n'; exit 0
    fi ;;
  restart)
    if [ -f "$marker" ]; then echo "ccr started (pid 1)"; exit 0
    else echo 'Profile "restart" was not found or is disabled.'; exit 1; fi ;;
  default-claude-code) exit 0 ;;
  *) exit 0 ;;
esac
STUB
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-ccr-build" <<STUB
#!/usr/bin/env bash
printf 'rebuild\n' >> "$cbuild_log"
: > "$marker"   # a real rebuild ADDS the 'restart' subcommand
exit 0
STUB
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-sync-state" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-session" <<'STUB'
#!/usr/bin/env bash
[ "$1" = flags ] && echo ""
exit 0
STUB
export PATH="$SANDBOX_HOME/.local/bin:$PATH"

# shellcheck source=/dev/null
source "$ALIAS_FILE"
it "HYGIENE: cma_run_provider under test comes from the sandbox alias file"
assert_fn_from cma_run_provider "$ALIAS_FILE" "wrapper loaded from the sandbox, not the host"
export CLAUDE_BIN=/usr/bin/true

# ── Scenario A: stale ccr + claude-ccr-build present → SELF-HEAL ──
: > "$ccrlog"; : > "$cbuild_log"; rm -f "$marker"
outA="$( set +eu; cma_run_provider testrtr -p hi 2>&1 )"; rcA=$?

it "a stale ccr triggers an automatic claude-ccr-build at the identity gate (self-heal)"
grep -q rebuild "$cbuild_log"; assert_eq 0 $? "claude-ccr-build invoked — the identity gate detected a stale binary lacking 'ccr restart'"

it "ccr restart succeeds after the identity-level self-heal (one restart call)"
n="$(grep -c '^restart$' "$ccrlog")"; assert_eq 1 "$n" "restart called once — the identity-level self-heal rebuilt first, then restart succeeded"

it "after a successful self-heal the launch is NOT refused"
# here-string, not printf|grep -q: under pipefail grep -q closes the pipe on
# first match and printf takes SIGPIPE (rc 141) — a false result (suite lint).
notrefused=0; grep -q 'route was NOT applied' <<<"$outA" && notrefused=1
assert_eq 0 "$notrefused" "no 'route was NOT applied' refusal once the rebuild fixes ccr"

# ── Scenario B: rebuild runs but does NOT resolve it → actionable fail-closed ──
# A no-op claude-ccr-build (does not create the marker, so ccr stays stale). NOTE
# we STUB it rather than remove it: `command -v` would otherwise find the REAL
# claude-ccr-build further down $PATH and trigger a live go build.
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-ccr-build" <<'STUB'
#!/usr/bin/env bash
exit 0   # a rebuild that does NOT fix ccr (the marker is never created)
STUB
: > "$ccrlog"; rm -f "$marker"
outB="$( set +eu; cma_run_provider testrtr -p hi 2>&1 )"; rcB=$?

it "when the auto-rebuild does not resolve it, the refusal is ACTIONABLE (names claude-ccr-build)"
grep -q 'claude-ccr-build' <<<"$outB"; assert_eq 0 $? "operator is told exactly how to self-fix"
it "the refusal is fail-closed (returns non-zero; does NOT serve the wrong model)"
[ "$rcB" -ne 0 ]; assert_eq 0 $? "cma_run_provider refused (non-zero) rather than launching"

# ── Scenario C: a NON-stale restart failure (auth refusal) must NOT self-heal ──
# The rebuild is gated on the stale-binary shape ALONE. A different restart
# failure — here the documented CCR_API_KEYS auth refusal — must NOT trigger a
# rebuild and must still count. EXECUTED against the real wrapper, not asserted
# against a literal string (review F1: the literal form was vacuous — a mutation
# broadening the trigger to any rc!=0 would have passed it).
sandbox_stub "$SANDBOX_HOME/.local/bin/ccr" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  --help)  printf 'Usage:\n  ccr start\n  ccr serve\n  ccr restart\n'; exit 0 ;;
  restart) echo 'refusing to restart: CCR_API_KEYS is unset here'; exit 1 ;;
  *) exit 0 ;;
esac
STUB
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-ccr-build" <<STUB
#!/usr/bin/env bash
echo rebuild >> "$cbuild_log"   # records an (unwanted) invocation
exit 0
STUB
: > "$cbuild_log"
outC="$( set +eu; cma_run_provider testrtr -p hi 2>&1 )"; rcC=$?

it "a non-stale restart failure (auth refusal) does NOT trigger a rebuild"
[ ! -s "$cbuild_log" ]; assert_eq 0 $? "claude-ccr-build NOT invoked on an auth-refusal shape (rebuild is stale-shape-gated)"
it "a non-stale restart failure still refuses fail-closed"
[ "$rcC" -ne 0 ]; assert_eq 0 $? "cma_run_provider refused (non-zero) on the auth failure"
it "the auth-refusal message does NOT carry the rebuild hint"
grep -q 'claude-ccr-build' <<<"$outC"; assert_eq 1 $? "a non-stale refusal is not mislabeled a rebuild problem"

summary
