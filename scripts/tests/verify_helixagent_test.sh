#!/usr/bin/env bash
# verify_helixagent_test.sh — hermetic test for the HelixAgent PATH-detection
# provider (detect_helixagent_record + resolve_records merge in
# claude-providers.sh).
#
# Fully self-contained: a sandboxed $HOME (make_sandbox), a FAKE `helixagent`
# binary placed on PATH, and a REAL local HTTP server answering `/v1/models`
# with an OpenAI-shaped model list. It then runs `claude-providers.sh sync`
# offline+no-verify and asserts the HelixAgent alias + <id>.env + resolved
# record were created with transport=router and the LIVE-enumerated models —
# real captured evidence (§11.4.69), not a mock that proves nothing.
#
# Three cases prove the honest behaviour of the detector:
#   A. binary on PATH + server up  -> alias/env/record with live models
#   B. binary NOT on PATH          -> NO helixagent alias/env (PATH gate)
#   C. binary on PATH + server DOWN -> alias/env STILL created off the pins,
#                                      honest 'unverified' (installed-not-running)
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
PROOF_DIR="$TESTS_DIR/proof"
mkdir -p "$PROOF_DIR"
PROOF="$PROOF_DIR/82-helixagent-detect.txt"
: > "$PROOF"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e   # lib.sh sets -e; the harness asserts on failures, so relax it.

PROVIDERS_SH="$SCRIPTS_DIR/claude-providers.sh"
PDIR="$HOME/.local/share/claude-multi-account/providers"
PCACHE="$PDIR/models.dev.cache.json"
mkdir -p "$PDIR"

# Empty models.dev catalog: HelixAgent is a LOCAL provider, never in the
# catalog. The resolver will emit only an 'unmapped' record for the key var;
# the detector supplies the real resolved HelixAgent record.
echo '{}' > "$PCACHE"

# Keys file with the HelixAgent key-var NAME (value is a dummy, never launched).
KEYS="$HOME/api_keys.sh"
cat > "$KEYS" <<'SH'
export HELIXAGENT_API_KEY="dummy-helix-key-never-real"
SH

# --- REAL local /v1/models server (ephemeral port) --------------------------
PORT_FILE="$HOME/.helix_srv_port"
python3 - "$PORT_FILE" >/dev/null 2>&1 <<'PY' &
import http.server, socketserver, sys, json
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.rstrip('/').endswith('/models'):
            body = json.dumps({"object": "list", "data": [
                {"id": "helix-debate", "object": "model"},
                {"id": "helix-llm",    "object": "model"},
            ]}).encode()
            self.send_response(200)
            self.send_header('Content-Type', 'application/json')
            self.send_header('Content-Length', str(len(body)))
            self.end_headers()
            self.wfile.write(body)
        else:
            self.send_response(404); self.end_headers()
    def log_message(self, *a):  # silence
        pass
srv = socketserver.TCPServer(('127.0.0.1', 0), H)
open(sys.argv[1], 'w').write(str(srv.server_address[1]))
srv.serve_forever()
PY
SRV_PID=$!
# Ensure the server is always reaped even if the sandbox trap fires first.
trap '[[ -n "${SRV_PID:-}" ]] && kill "$SRV_PID" 2>/dev/null; cleanup_sandbox' EXIT

for _ in $(seq 1 50); do [[ -s "$PORT_FILE" ]] && break; sleep 0.1; done
PORT="$(cat "$PORT_FILE" 2>/dev/null)"

# --- fake helixagent binary on PATH -----------------------------------------
mkdir -p "$HOME/.local/bin"
cat > "$HOME/.local/bin/helixagent" <<'EOF'
#!/usr/bin/env bash
# fake helixagent stub — only needs to exist for `command -v`.
echo "helixagent (test stub)"
EOF
chmod +x "$HOME/.local/bin/helixagent"
export PATH="$HOME/.local/bin:$PATH"

# Point the detector at the real local server (all knobs are env-overridable).
export CMA_HELIXAGENT_HOST=127.0.0.1
export CMA_HELIXAGENT_PORT="$PORT"
export CMA_HELIXAGENT_KEYVAR=HELIXAGENT_API_KEY

{
  echo "=== verify_helixagent_test.sh evidence ==="
  echo "date: $(date -u +%FT%TZ)"
  echo "server port: $PORT   pid: $SRV_PID"
  echo "PATH helixagent: $(command -v helixagent)"
  echo "--- live GET http://127.0.0.1:$PORT/v1/models ---"
  curl -s --max-time 8 "http://127.0.0.1:$PORT/v1/models"
  echo
} >> "$PROOF" 2>&1

# ===========================================================================
# CASE A — binary on PATH + server up
# ===========================================================================
it "CASE A: sync with helixagent on PATH + live server"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" \
  >>"$PROOF" 2>&1
a_rc=$?
assert_eq 0 "$a_rc" "sync exits cleanly"

assert_file "$PDIR/helixagent.env" "helixagent env file created (PATH-detected)"

it "CASE A: env file carries router transport + live base_url + enumerated models"
grep -qE "^CMA_PROVIDER_TRANSPORT='?router'?" "$PDIR/helixagent.env"
assert_eq 0 $? "transport=router (OpenAI-compat -> ccr)"
grep -qF "http://127.0.0.1:$PORT/v1" "$PDIR/helixagent.env"
assert_eq 0 $? "base_url = live endpoint"
grep -qE "^CMA_PROVIDER_MODEL='?helix-debate'?" "$PDIR/helixagent.env"
assert_eq 0 $? "strong model = helix-debate (from live /v1/models)"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?helix-llm'?" "$PDIR/helixagent.env"
assert_eq 0 $? "fast model = helix-llm (from live /v1/models)"
grep -qE "^CMA_PROVIDER_KEYVAR='?HELIXAGENT_API_KEY'?" "$PDIR/helixagent.env"
assert_eq 0 $? "key-var NAME recorded (secret never stored)"

it "CASE A: NO secret value leaked into the env file"
assert_file_not_contains "$PDIR/helixagent.env" "dummy-helix-key-never-real" \
  "secret value absent from helixagent.env"

it "CASE A: shell alias registered -> cma_run_provider helixagent"
grep -q '^alias helixagent="cma_run_provider helixagent"' "$ALIAS_FILE"
assert_eq 0 $? "helixagent alias line present"

it "CASE A: verification status persisted (unverified under --no-verify)"
assert_eq "unverified" "$(cma_status_read helixagent)" "helixagent status persisted"

it "CASE A: exactly ONE helixagent.env (no duplicate registration)"
n_env="$(ls "$PDIR"/helixagent.env 2>/dev/null | wc -l | tr -d ' ')"
assert_eq "1" "$n_env" "exactly one helixagent.env"

it "CASE A: detector emits a well-formed resolved record with live models"
# The module is source-guarded, so sourcing loads the functions without running
# dispatch — we can call detect_helixagent_record directly and assert its JSON.
DET="$(CMA_HELIXAGENT_HOST=127.0.0.1 CMA_HELIXAGENT_PORT="$PORT" \
       CMA_HELIXAGENT_KEYVAR=HELIXAGENT_API_KEY \
       bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record')"
echo "--- detect_helixagent_record output (CASE A) ---" >> "$PROOF"
echo "$DET" >> "$PROOF"
assert_eq "resolved"     "$(jq -r '.[0].status'        <<<"$DET")" "record status=resolved"
assert_eq "helixagent"   "$(jq -r '.[0].provider_id'   <<<"$DET")" "provider_id=helixagent"
assert_eq "router"       "$(jq -r '.[0].transport'     <<<"$DET")" "transport=router"
assert_eq "helix-debate" "$(jq -r '.[0].strong_model'  <<<"$DET")" "strong=helix-debate"
assert_eq "helix-llm"    "$(jq -r '.[0].fast_model'    <<<"$DET")" "fast=helix-llm"
assert_eq "128000"       "$(jq -r '.[0].context_limit' <<<"$DET")" "context_limit=128000"

# ===========================================================================
# CASE B — binary NOT on PATH -> PATH gate blocks registration
# ===========================================================================
it "CASE B: no helixagent binary on PATH -> detector emits empty array"
DET_B="$(CMA_HELIXAGENT_BIN=helixagent-not-installed-xyz \
         bash -c 'source "'"$PROVIDERS_SH"'" >/dev/null 2>&1; detect_helixagent_record')"
assert_eq "[]" "$(echo "$DET_B" | tr -d '[:space:]')" "empty record when binary absent"

it "CASE B: a fresh sandbox with NO helixagent gets NO helixagent alias"
# Remove the fake binary + prior artefacts, re-sync, assert nothing registered.
rm -f "$HOME/.local/bin/helixagent" "$PDIR/helixagent.env"
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >>"$PROOF" 2>&1
[[ ! -f "$PDIR/helixagent.env" ]]; assert_eq 0 $? "no helixagent.env when binary off PATH"

# ===========================================================================
# CASE C — binary on PATH but server DOWN -> honest installed-not-running
# ===========================================================================
it "CASE C: helixagent present but server down -> alias STILL created off pins"
# Restore the binary, kill the server (simulate 'installed but not running').
cat > "$HOME/.local/bin/helixagent" <<'EOF'
#!/usr/bin/env bash
echo "helixagent (test stub)"
EOF
chmod +x "$HOME/.local/bin/helixagent"
kill "$SRV_PID" 2>/dev/null; wait "$SRV_PID" 2>/dev/null; SRV_PID=""
# Point at a dead port so /v1/models is genuinely unreachable.
export CMA_HELIXAGENT_PORT=1   # port 1 is not listening
export CMA_HELIXAGENT_HTTP_TIMEOUT=2
bash "$PROVIDERS_SH" sync --offline --no-verify --keys-file "$KEYS" >>"$PROOF" 2>&1
assert_file "$PDIR/helixagent.env" "helixagent.env created even with server down"
grep -qE "^CMA_PROVIDER_MODEL='?helix-debate'?" "$PDIR/helixagent.env"
assert_eq 0 $? "strong model falls back to configured pin (helix-debate)"
grep -qE "^CMA_PROVIDER_FAST_MODEL='?helix-llm'?" "$PDIR/helixagent.env"
assert_eq 0 $? "fast model falls back to configured pin (helix-llm)"
assert_eq "unverified" "$(cma_status_read helixagent)" "honest unverified when unreachable"

echo >> "$PROOF"
echo "=== helixagent.env (final) ===" >> "$PROOF"
cat "$PDIR/helixagent.env" >> "$PROOF" 2>&1

summary
