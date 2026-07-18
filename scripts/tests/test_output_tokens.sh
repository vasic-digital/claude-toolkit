#!/usr/bin/env bash
# test_output_tokens.sh — hermetic Tier-A coverage for the both-transports
# output-token cap (v1.16.0, _cma_out_guard). Root cause of the user-visible
# error "Claude's response exceeded the 128000 output token maximum": the
# wrapper exported CLAUDE_CODE_MAX_OUTPUT_TOKENS only on the native path, so
# every router provider ran with Claude Code's generic default cap.
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

# --- launch plumbing (sandbox alias file + recorder + stubs) -----------------
cma_ensure_alias_file
rec_env="$HOME/rec.env"
recorder="$HOME/recorder.sh"
cat > "$recorder" <<'EOF'
#!/usr/bin/env bash
env | grep -E '^CLAUDE_CODE_MAX_OUTPUT_TOKENS=' > "$REC_ENV_OUT" || true
exit 0
EOF
chmod +x "$recorder"
mkdir -p "$HOME/.local/bin"
for stub in claude-sync-state claude-session; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$HOME/.local/bin/$stub"
  chmod +x "$HOME/.local/bin/$stub"
done
# Fake ccr: answers `--help` with the router banner (the identity guard checks
# it for "ccr start"), records the environment on a launch subcommand — BOTH the legacy
# `ccr code` grammar AND the v3.0.6 `ccr default-claude-code` grammar the
# wrapper now uses — no-ops everything else.
FAKEBIN="$HOME/fakebin"; mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/ccr" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  --help) echo "Usage: ccr start [--host <host>] [--port <port>]"; echo "  ccr serve [--host <host>] [--port <port>]"; exit 0 ;;
  code|default-claude-code) shift; env | grep -E '^CLAUDE_CODE_MAX_OUTPUT_TOKENS=' > "$REC_ENV_OUT" || true; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/ccr"

# shellcheck source=/dev/null
source "$ALIAS_FILE"

# ===========================================================================
# Section 1 — the cap is exported for BOTH transports
# ===========================================================================
it "native launch: CLAUDE_CODE_MAX_OUTPUT_TOKENS exported from CMA_PROVIDER_MAX_OUTPUT"
cma_provider_write_env acmenative ACME_KEY native https://api.test/anthropic acme-big acme-fast "$HOME/.claude-prov-acmenative" 262144 131072 acmenative
cma_provider_write_alias acmenative acmenative
cma_status_write acmenative verified acme-big ""
run_native() {
  : > "$rec_env"
  ( set +eu; ACME_KEY=sk-test REC_ENV_OUT="$rec_env" CLAUDE_BIN="$recorder" cma_run_provider acmenative </dev/null >/dev/null 2>&1 )
}
run_native
# 131072 < 262144 (real output budget) BUT > the CLI's 128000 custom-model
# ceiling -> the merged guard exports it CLAMPED to 128000 (the xiaomi-class
# ">128000" fatal fix), not raw.
assert_eq "CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000" "$(cat "$rec_env")" "native path exports the catalog output cap (clamped <=128000)"

it "router launch: the SAME cap reaches the router (ccr) path (the v1.16.0 fix)"
cma_provider_write_env acmerouter ACME_KEY router https://api.test/v1 acme-big acme-fast "$HOME/.claude-prov-acmerouter" 262144 131072 acmerouter
cma_provider_write_alias acmerouter acmerouter
cma_status_write acmerouter verified acme-big ""
: > "$rec_env"
( set +eu; ACME_KEY=sk-test REC_ENV_OUT="$rec_env" PATH="$FAKEBIN:/usr/bin:/bin" cma_run_provider acmerouter </dev/null >/dev/null 2>&1 )
assert_eq "CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000" "$(cat "$rec_env")" "router path exports the cap, clamped <=128000 (was the 128000-default bug)"

it "no export when CMA_PROVIDER_MAX_OUTPUT is empty (provider limit unknown)"
cma_provider_write_env acmeempty ACME_KEY native https://api.test/anthropic acme-big "" "$HOME/.claude-prov-acmeempty" 262144 "" acmeempty
cma_provider_write_alias acmeempty acmeempty
cma_status_write acmeempty verified acme-big ""
: > "$rec_env"
( set +eu; ACME_KEY=sk-test REC_ENV_OUT="$rec_env" CLAUDE_BIN="$recorder" cma_run_provider acmeempty </dev/null >/dev/null 2>&1 )
assert_eq "" "$(cat "$rec_env" 2>/dev/null)" "empty provider limit leaves the var unset (Claude Code default)"

it "no export when limit.output >= limit.context (catalog conflation — the nvidia5 400 case)"
# nvidia5 (meta/llama-3.2-11b-vision-instruct): catalog gives context=131072
# AND output=131072, which is not a real output budget. Exporting it made
# Claude Code request 128000 completion tokens; 39k input + 128k output >
# 131k context -> provider 400. The guard must skip this case.
cma_provider_write_env acmeconfl ACME_KEY native https://api.test/anthropic acme-big "" "$HOME/.claude-prov-acmeconfl" 131072 131072 acmeconfl
cma_provider_write_alias acmeconfl acmeconfl
cma_status_write acmeconfl verified acme-big ""
: > "$rec_env"
( set +eu; ACME_KEY=sk-test REC_ENV_OUT="$rec_env" CLAUDE_BIN="$recorder" cma_run_provider acmeconfl </dev/null >/dev/null 2>&1 )
assert_eq "" "$(cat "$rec_env" 2>/dev/null)" "output==context (bogus catalog) leaves the var unset"

# ===========================================================================
# Section 2 — structure + migration
# ===========================================================================
it "emitted body exports the cap BEFORE the transport split (both paths covered)"
body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE")"
guard_line="$(grep -n '_cma_out_guard' <<<"$body" | head -1 | cut -d: -f1)"
split_line="$(grep -n 'CMA_PROVIDER_TRANSPORT:-native.*== "router"' <<<"$body" | head -1 | cut -d: -f1)"
ok=1; [[ -n "$guard_line" && -n "$split_line" && "$guard_line" -lt "$split_line" ]] && ok=0
assert_eq 0 "$ok" "_cma_out_guard (line $guard_line) precedes the router branch (line $split_line)"

it "migration regenerates a wrapper that lacks _cma_out_guard"
_mig="$ALIAS_FILE.migtest-out"
cat > "$_mig" <<'OLD'
export CLAUDE_BIN="/usr/bin/true"

cma_run_provider() {
  # claude-sync-state set -a +u claude-session apply-color _cma_compact_cap _cma_proxy_dir
  # command -v cma_log _cma_force >| "$tmp" unset ANTHROPIC_BASE_URL
  # ! git rev-parse --show-toplevel >/dev/null 2>&1
  # command -v "${CLAUDE_BIN:-}" _family_id kimi-code/credentials/kimi-code.json
  :
}

alias acme="cma_run_provider acme"
OLD
bash -n "$_mig"; assert_eq 0 $? "old-format alias file parses (bash -n)"
grep -q '_cma_out_guard' "$_mig"; assert_eq 1 $? "old body lacks the both-transports cap marker (pre-migration)"
( ALIAS_FILE="$_mig" cma_ensure_alias_file ) >/dev/null 2>&1
mig_body="$(awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$_mig")"
# herestring (<<<), NOT `printf … | grep -q`: SIGPIPE-safe on the larger body.
grep -q '_cma_out_guard' <<<"$mig_body"; assert_eq 0 $? "regenerated body carries the both-transports cap"
grep -c '^alias acme=' "$_mig" >/dev/null; assert_eq 1 "$(grep -c '^alias acme=' "$_mig")" "alias preserved through migration"
rm -f "$_mig"

# ===========================================================================
# Section 3 — router-path hardening: alias-proof mv + ccr identity guard
# ===========================================================================
it "router launch is robust against an interactive 'mv -i' alias (command mv -f)"
# The upsert used bare `mv`, which an interactive mv -i alias turns into a
# prompt — with stdin redirected from /dev/null the launch hung/failed (live
# issue). `command mv -f` bypasses both aliases and shell functions.
cma_provider_write_env acmemv ACME_KEY router https://api.test/v1 acme-big acme-fast "$HOME/.claude-prov-acmemv" 262144 131072 acmemv
cma_provider_write_alias acmemv acmemv
cma_status_write acmemv verified acme-big ""
: > "$rec_env"
( set +eu
  mv() { echo "SHADOW-MV-CALLED"; return 42; }
  ACME_KEY=sk-test REC_ENV_OUT="$rec_env" PATH="$FAKEBIN:/usr/bin:/bin" \
    cma_run_provider acmemv </dev/null >/dev/null 2>&1 )
launch_rc=$?
assert_eq 0 "$launch_rc" "router launch succeeded with a shadowing mv function present"
assert_file "$HOME/.claude-code-router/config.json" "ccr config upserted despite the mv shadow"

it "ccr identity guard: a foreign ccr (CCS-style) is refused with an actionable message"
cat > "$FAKEBIN/ccr-foreign" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then echo "CCS profile manager v9 — usage: ccs <command>"; exit 0; fi
exit 0
EOF
chmod +x "$FAKEBIN/ccr-foreign"
cp "$FAKEBIN/ccr-foreign" "$FAKEBIN/ccr"
out="$( ( set +eu; ACME_KEY=sk-test PATH="$FAKEBIN:/usr/bin:/bin" cma_run_provider acmemv </dev/null 2>&1 ) )"; rc=$?
assert_eq 127 "$rc" "foreign ccr refused (rc 127)"
case "$out" in *"not @musistudio/claude-code-router"*) ok=0 ;; *) ok=1 ;; esac
assert_eq 0 "$ok" "refusal message names the real router to install"

it "ccr identity guard: the real claude-code-router passes"
cat > "$FAKEBIN/ccr" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == "--help" ]]; then echo "Usage: ccr start [--host <host>]"; echo "  ccr serve [--host <host>]"; exit 0; fi
case "${1:-}" in
  code|default-claude-code) shift; env | grep -E '^CLAUDE_CODE_MAX_OUTPUT_TOKENS=' > "$REC_ENV_OUT" || true; exit 0 ;;
  *) exit 0 ;;
esac
EOF
chmod +x "$FAKEBIN/ccr"
: > "$rec_env"
( set +eu; ACME_KEY=sk-test REC_ENV_OUT="$rec_env" PATH="$FAKEBIN:/usr/bin:/bin" cma_run_provider acmemv </dev/null >/dev/null 2>&1 )
launch_rc=$?
assert_eq 0 "$launch_rc" "real ccr launches fine"
assert_eq "CLAUDE_CODE_MAX_OUTPUT_TOKENS=128000" "$(cat "$rec_env")" "cap (clamped <=128000) still exported through the guarded router path"

summary
