#!/usr/bin/env bash
# test_ccr_path_shadowing.sh — a PATH-shadowing ccr DOPPELGÄNGER must not brick
# router-alias launches, and must not be misdiagnosed as a stale bundled ccr.
#
# Field failure (2026-07-22, helixagent): the npm `@musistudio/claude-code-router`
# package installs its own `ccr` into the nvm bin dir, which precedes
# ~/.local/bin on PATH. Its --help shows the same "ccr start" / "ccr serve"
# fingerprint (it passes the identity gate!) but it has NO `restart`
# subcommand — `ccr restart` replies `Profile "restart" was not found or is
# disabled` (rc=1). The self-heal then misdiagnosed this as a STALE bundled
# ccr, rebuilt the bundled binary (which was never the one being invoked),
# retried bare `ccr restart` → hit the doppelgänger again → refused the
# launch. A rebuild can never fix PATH shadowing.
#
# Fix under test (§11.4.111 resolve-by-stable-identity): cma_run_provider
# resolves OUR router by its stable install identity — $CMA_CCR_BIN override,
# else $HOME/.local/bin/ccr (the symlink claude-ccr-build maintains), falling
# back to PATH only when the bundled install is absent — and uses that
# resolved path for EVERY invocation (identity probe, restart, post-rebuild
# retry, and the launch itself).
#
# This EXECUTES the real generated wrapper against a stubbed doppelgänger +
# bundled pair (it does not grep lib.sh text), so a regression back to bare
# PATH resolution fails here.
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

# --- generate the alias file (embeds cma_run_provider with the resolver) ---
ALIAS_FILE="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$ALIAS_FILE")" "$SANDBOX_HOME/.local/bin" "$SANDBOX_HOME/shadowbin"
CMA_RC_FILES=("$SANDBOX_HOME/.unused-rc")
cma_ensure_alias_file >/dev/null 2>&1

goodlog="$SANDBOX_HOME/ccr-good.calls"
shadowlog="$SANDBOX_HOME/ccr-shadow.calls"
cbuild_log="$SANDBOX_HOME/ccrbuild.calls"

# --- the BUNDLED router at its stable install identity ($HOME/.local/bin/ccr):
# current build, restart works, launch works. Logs every first arg. ---
sandbox_stub "$SANDBOX_HOME/.local/bin/ccr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$goodlog"
case "\$1" in
  --help)  printf 'Usage:\n  ccr start [...]\n  ccr serve [...]\n  ccr stop\n  ccr restart [...]\n'; exit 0 ;;
  restart) echo "ccr started (pid 1)"; exit 0 ;;
  *) exit 0 ;;
esac
STUB

# --- the DOPPELGÄNGER earlier on PATH: same "ccr start/serve" help fingerprint
# (passes the identity gate) but NO restart subcommand — the npm shape. ---
sandbox_stub "$SANDBOX_HOME/shadowbin/ccr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$1" >> "$shadowlog"
case "\$1" in
  --help)  printf 'Usage:\n  ccr start [...]\n  ccr serve [...]\n  ccr stop\n  ccr <profile-name-or-id> [cli|app]\n'; exit 0 ;;
  restart) echo 'Profile "restart" was not found or is disabled.'; exit 1 ;;
  *) exit 0 ;;
esac
STUB

# --- a rebuild stub: records the (unwanted) invocation; a rebuild cannot fix
# PATH shadowing, so the fixed wrapper must never reach for it here. ---
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-ccr-build" <<STUB
#!/usr/bin/env bash
echo rebuild >> "$cbuild_log"
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

# The doppelgänger dir comes FIRST — the exact field PATH order (nvm bin
# before ~/.local/bin).
export PATH="$SANDBOX_HOME/shadowbin:$SANDBOX_HOME/.local/bin:$PATH"

# shellcheck source=/dev/null
source "$ALIAS_FILE"
it "HYGIENE: cma_run_provider under test comes from the sandbox alias file"
assert_fn_from cma_run_provider "$ALIAS_FILE" "wrapper loaded from the sandbox, not the host"
export CLAUDE_BIN=/usr/bin/true

# ── Scenario: bundled ccr present but PATH-shadowed by the doppelgänger ──
: > "$goodlog"; : > "$shadowlog"; : > "$cbuild_log"
outS="$( set +eu; cma_run_provider testrtr -p hi 2>&1 )"; rcS=$?

it "the launch is NOT refused when a doppelgänger ccr shadows the bundled one on PATH"
refused=0; grep -q 'route was NOT applied' <<<"$outS" && refused=1
assert_eq 0 "$refused" "no 'route was NOT applied' refusal — the bundled router must be found by stable path"

it "the route restart is served by the BUNDLED ccr (stable-path resolution)"
grep -q '^restart$' "$goodlog"; assert_eq 0 $? "bundled \$HOME/.local/bin/ccr received the restart"

it "the PATH doppelgänger never receives the restart"
sh_restarts=0; grep -q '^restart$' "$shadowlog" 2>/dev/null && sh_restarts=1
assert_eq 0 "$sh_restarts" "shadowing ccr was not invoked for restart"

it "shadowing is NOT misdiagnosed as staleness (no rebuild triggered)"
[ ! -s "$cbuild_log" ]; assert_eq 0 $? "claude-ccr-build not invoked — nothing was stale"

it "the launch itself goes through the bundled ccr"
grep -q '^default-claude-code$' "$goodlog"; assert_eq 0 $? "bundled ccr received the default-claude-code launch"

it "the shadowed launch exits 0 (the alias works end-to-end)"
assert_eq 0 "$rcS" "cma_run_provider returned success"

# ── Scenario B: bundled install ABSENT → PATH fallback fails at identity gate ──
# Remove the bundled stub; the doppelgänger is now the only ccr. The wrapper
# falls back to PATH (last resort) and the tightened identity gate (audit I3,
# §11.4.201(7)(a)) correctly identifies the doppelgänger as NOT ours — it lacks
# `ccr restart` in --help. Since the resolved binary is a PATH fallback, not the
# stable install path, the identity-level self-heal does NOT fire; the refusal is
# fail-closed with an actionable message. The pre-existing behaviour for a
# genuinely absent bundled router must not regress.
rm -f "$SANDBOX_HOME/.local/bin/ccr"
: > "$shadowlog"; : > "$cbuild_log"
outB="$( set +eu; cma_run_provider testrtr -p hi 2>&1 )"; rcB=$?

it "with no bundled install, PATH fallback reaches the doppelgänger for identity probe"
grep -q '^--help$' "$shadowlog"; assert_eq 0 $? "fallback resolution probed the PATH ccr's --help"

it "the doppelgänger is refused at the identity gate (no 'ccr restart' in --help)"
[ "$rcB" -ne 0 ]; assert_eq 0 $? "refused (non-zero) rather than serving the wrong model"
grep -q 'claude-ccr-build' <<<"$outB"; assert_eq 0 $? "operator told how to (re)build the bundled router"

summary
