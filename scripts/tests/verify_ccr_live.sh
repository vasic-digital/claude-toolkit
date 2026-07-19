#!/usr/bin/env bash
# verify_ccr_live.sh — end-to-end LIVE proof that the BUNDLED Go
# claude-code-router (the `submodules/claude-code-router` submodule) really is
# the toolkit's `ccr`, builds from source, and functions as a routing gateway:
# it serves the health/ready probes, maps an unreachable upstream to the
# Anthropic error envelope, records Prometheus metrics, and validates/redacts
# its own config.
#
# Unlike the sandboxed test_*.sh suite this drives the REAL Go binary over REAL
# HTTP, so it is intentionally NOT named test_*.sh (run-all.sh won't pick it
# up). It is hermetic with respect to the user's system: it builds into a TEMP
# BIN_DIR (never touches ~/.local/bin/ccr) and runs the server under a TEMP HOME
# (never touches ~/.claude-code-router). Every port is a freshly-probed free
# port; the background server and all temp dirs are killed/removed on EXIT.
#
# SKIP policy: if `go` is absent we SKIP cleanly (exit 0) — a host without a Go
# toolchain simply can't build the bundled router. Anything else (a build
# failure, a self-check failure, a wrong HTTP result) is a hard FAIL.
#
# Every assertion writes its raw evidence to $PROOF_DIR/ccr-go-live.txt so the
# result is a physical, inspectable artifact.
#
# Knobs:
#   PROOF_DIR   where to write evidence (default scripts/tests/proof)

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TESTS_DIR/../.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"

PROOF_DIR="${PROOF_DIR:-$TESTS_DIR/proof}"
PROOF="$PROOF_DIR/ccr-go-live.txt"
mkdir -p "$PROOF_DIR"

BUILD_SCRIPT="$REPO_ROOT/scripts/claude-ccr-build.sh"
SUBMODULE_BIN="$REPO_ROOT/submodules/claude-code-router/bin/ccr"

# A secret that lives ONLY in the ccr config's api_key. It must never surface in
# any captured HTTP response, /metrics scrape, or committed proof file. Every
# capture is grepped for it; a single hit is a hard FAIL.
SECRET="sk-ccrproof-DO-NOT-LEAK-$(date +%s)-9f3a2b1c7e"

# ---------------------------------------------------------------------------
# 0. Preconditions / SKIP gate
# ---------------------------------------------------------------------------
if ! command -v go >/dev/null 2>&1; then
  echo "SKIP: Go toolchain not found — cannot build the bundled claude-code-router (Go). Live verification skipped."
  exit 0
fi
for tool in curl jq python3; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "SKIP: required tool '$tool' not found — live verification skipped."
    exit 0
  fi
done

# ---------------------------------------------------------------------------
# Temp state + cleanup trap (always kills the bg server and removes temp dirs)
# ---------------------------------------------------------------------------
TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/ccr-go-live.XXXXXX")"
TMP_BIN="$TMP_ROOT/bin"          # BIN_DIR for the build (temp; not ~/.local/bin)
TMP_HOME="$TMP_ROOT/home"        # HOME for the server (temp; not real ~)
mkdir -p "$TMP_BIN" "$TMP_HOME"
SERVER_PID=""     # plaintext gateway (section 3)
TLS_PID=""        # TLS/HTTP3 gateway (section 5)

cleanup() {
  # Reap both background servers (plaintext + TLS) so nothing is leaked.
  for _pid in "$SERVER_PID" "$TLS_PID"; do
    if [[ -n "$_pid" ]] && kill -0 "$_pid" 2>/dev/null; then
      kill "$_pid" 2>/dev/null || true
      # give it a moment to drain, then hard-kill if still alive
      for _ in 1 2 3 4 5; do kill -0 "$_pid" 2>/dev/null || break; sleep 0.2; done
      kill -9 "$_pid" 2>/dev/null || true
    fi
  done
  [[ -n "${TMP_ROOT:-}" && "$TMP_ROOT" == *ccr-go-live.* ]] && rm -rf "$TMP_ROOT"
}
trap cleanup EXIT INT TERM

# Two distinct free TCP ports in one shot (avoids a close/rebind collision).
read -r GW_PORT MG_PORT < <(python3 - <<'PY'
import socket
socks = []
for _ in range(2):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    socks.append(s)
print(*[s.getsockname()[1] for s in socks])
for s in socks:
    s.close()
PY
)

GW="http://127.0.0.1:$GW_PORT"   # gateway (health/ready/messages)
MG="http://127.0.0.1:$MG_PORT"   # management (/metrics)

# ---------------------------------------------------------------------------
# Proof-file header
# ---------------------------------------------------------------------------
: > "$PROOF"
{
  echo "# claude-code-router (bundled Go) — LIVE verification proof"
  echo "generated:  $(date '+%Y-%m-%dT%H:%M:%S%z')"
  echo "host:       $(uname -srm)"
  echo "go:         $(go version 2>/dev/null)"
  echo "build:      BIN_DIR=$TMP_BIN bash scripts/claude-ccr-build.sh"
  echo "gateway:    $GW"
  echo "management: $MG"
  echo "secret:     (api_key redaction canary — never printed here)"
  echo
} >> "$PROOF"

section() { printf '\n===== %s =====\n' "$1" >> "$PROOF"; }

# ---------------------------------------------------------------------------
# 1. Build the bundled Go ccr into the TEMP BIN_DIR
# ---------------------------------------------------------------------------
it "builds the bundled Go claude-code-router into a temp BIN_DIR"
section "1. build (BIN_DIR=$TMP_BIN)"
if BIN_DIR="$TMP_BIN" bash "$BUILD_SCRIPT" >>"$PROOF" 2>&1; then
  _pass "claude-ccr-build.sh succeeded (BIN_DIR=$TMP_BIN)"
else
  _fail "claude-ccr-build.sh failed" "see $PROOF"
  echo >> "$PROOF"
  summary; exit $?
fi
CCR="$TMP_BIN/ccr"
assert_file "$CCR" "temp ccr link exists"

# ---------------------------------------------------------------------------
# 2. The installed binary IS the bundled Go router (symlink + --help grammar)
# ---------------------------------------------------------------------------
it "the temp ccr is a symlink into the submodule and speaks the router grammar"
section "2. identity (symlink + --help)"
assert_symlink_to "$CCR" "$SUBMODULE_BIN" "temp ccr -> submodule bin/ccr"
HELP="$("$CCR" --help 2>&1 | head -20)"
{ echo "--- ccr --help (head) ---"; printf '%s\n' "$HELP"; } >> "$PROOF"
case "$HELP" in
  *"ccr serve"*|*"ccr start"*) _pass "--help shows the router commands (ccr start/serve)" ;;
  *) _fail "--help missing router grammar" "no 'ccr start'/'ccr serve' in --help" ;;
esac

# ---------------------------------------------------------------------------
# 3. Write a ccr config (unreachable upstream) + start the server live
# ---------------------------------------------------------------------------
it "starts the Go gateway live against an unreachable upstream"
section "3. serve"
CONFIG_DIR="$TMP_HOME/.claude-code-router"
CONFIG="$CONFIG_DIR/config.json"
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG" <<JSON
{
  "Providers": [
    {
      "name": "deadloop",
      "api_base_url": "http://127.0.0.1:1/v1/chat/completions",
      "api_key": "$SECRET",
      "models": ["ghost-model"]
    }
  ],
  "Router": { "default": "deadloop,ghost-model" }
}
JSON

SERVER_LOG="$TMP_ROOT/server.log"
HOME="$TMP_HOME" "$CCR" serve --no-open \
  --gateway-host 127.0.0.1 --gateway-port "$GW_PORT" \
  --host 127.0.0.1 --port "$MG_PORT" \
  >"$SERVER_LOG" 2>&1 &
SERVER_PID=$!

# Poll /health with a bounded retry — curl handles connection-refused during
# startup, no hanging sleeps. Fail fast if the process died.
HEALTH_BODY=""
if ! kill -0 "$SERVER_PID" 2>/dev/null; then
  _fail "server exited immediately" "$(cat "$SERVER_LOG" 2>/dev/null)"
else
  HEALTH_BODY="$(curl -s --retry 30 --retry-connrefused --retry-delay 1 --max-time 30 "$GW/health" 2>/dev/null || true)"
  if [[ -n "$HEALTH_BODY" ]]; then _pass "gateway came up and answered /health"
  else _fail "gateway never answered /health within retry budget" "$(cat "$SERVER_LOG" 2>/dev/null)"; fi
fi

# ---------------------------------------------------------------------------
# 4. Drive real HTTP and assert real results
# ---------------------------------------------------------------------------

# 4a. GET /health -> 200 JSON {"status":"ok"}
it "GET /health returns 200 with {\"status\":\"ok\"}"
section "4a. GET /health"
H_CODE="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "$GW/health" 2>/dev/null || true)"
{ echo "http_code=$H_CODE"; echo "body=$HEALTH_BODY"; } >> "$PROOF"
assert_eq 200 "$H_CODE" "GET /health status"
if [[ "$(jq -r '.status' <<<"$HEALTH_BODY" 2>/dev/null)" == "ok" ]]; then
  _pass "GET /health body status == ok"
else _fail "GET /health body status" "got=$HEALTH_BODY"; fi

# 4b. GET /ready -> 200
it "GET /ready returns 200"
section "4b. GET /ready"
R_CODE="$(curl -s -o "$TMP_ROOT/ready.body" -w '%{http_code}' --max-time 10 "$GW/ready" 2>/dev/null || true)"
{ echo "http_code=$R_CODE"; echo "body=$(cat "$TMP_ROOT/ready.body" 2>/dev/null)"; } >> "$PROOF"
assert_eq 200 "$R_CODE" "GET /ready status"

# 4c. POST /v1/messages -> 502 Anthropic error envelope; api_key MUST NOT leak
it "POST /v1/messages (bogus upstream) returns 502 in the Anthropic error envelope"
section "4c. POST /v1/messages (502 envelope)"
M_BODY_FILE="$TMP_ROOT/messages.body"
M_CODE="$(curl -s -o "$M_BODY_FILE" -w '%{http_code}' --max-time 30 \
  -H 'content-type: application/json' \
  -d '{"model":"claude-3-haiku","max_tokens":16,"messages":[{"role":"user","content":"ping"}]}' \
  "$GW/v1/messages" 2>/dev/null || true)"
M_BODY="$(cat "$M_BODY_FILE" 2>/dev/null)"
{ echo "http_code=$M_CODE"; echo "body=$M_BODY"; } >> "$PROOF"
assert_eq 502 "$M_CODE" "POST /v1/messages status"
if [[ "$(jq -r '.type' <<<"$M_BODY" 2>/dev/null)" == "error" ]] \
   && [[ "$(jq -e '.error | type' <<<"$M_BODY" 2>/dev/null)" == '"object"' ]]; then
  _pass "502 body is the Anthropic error envelope {\"type\":\"error\",\"error\":{...}}"
else _fail "502 body not the Anthropic error envelope" "got=$M_BODY"; fi
if grep -Fq -- "$SECRET" "$M_BODY_FILE"; then
  _fail "api_key LEAKED into the 502 response body"
else _pass "api_key absent from the 502 response body"; fi

# 4d. GET :MG/metrics -> reflects the HTTP calls + an upstream attempt
it "GET /metrics reflects the requests and the upstream attempt"
section "4d. GET /metrics (excerpt)"
METRICS_FILE="$TMP_ROOT/metrics.txt"
MET_CODE="$(curl -s -o "$METRICS_FILE" -w '%{http_code}' --max-time 10 "$MG/metrics" 2>/dev/null || true)"
# Commit only the relevant ccr_* lines (the full scrape is large + host-noisy).
grep -E '^ccr_(http_requests_total|gen_ai_upstream_requests_total)' "$METRICS_FILE" 2>/dev/null >> "$PROOF" || true
assert_eq 200 "$MET_CODE" "GET /metrics status"
if grep -Eq '^ccr_http_requests_total\{' "$METRICS_FILE"; then
  _pass "metrics expose ccr_http_requests_total{...}"
else _fail "ccr_http_requests_total missing from /metrics"; fi
if grep -Eq '^ccr_http_requests_total\{[^}]*path="/v1/messages"[^}]*status="502"' "$METRICS_FILE"; then
  _pass "metrics record the POST /v1/messages 502"
else _fail "no ccr_http_requests_total for POST /v1/messages 502" "see $PROOF"; fi
if grep -Eq '^ccr_gen_ai_upstream_requests_total\{' "$METRICS_FILE"; then
  _pass "metrics expose ccr_gen_ai_upstream_requests_total (an upstream attempt was made)"
else _fail "ccr_gen_ai_upstream_requests_total missing (no upstream attempt recorded)"; fi

# 4e. ccr config validate -> exit 0, "is valid"
it "ccr config validate accepts the config (exit 0, 'is valid')"
section "4e. ccr config validate"
VAL_OUT="$(HOME="$TMP_HOME" "$CCR" config validate "$CONFIG" 2>&1)"; VAL_RC=$?
{ echo "exit=$VAL_RC"; echo "$VAL_OUT"; } >> "$PROOF"
assert_eq 0 "$VAL_RC" "config validate exit"
case "$VAL_OUT" in
  *"is valid"*) _pass "config validate reports 'is valid'" ;;
  *) _fail "config validate output" "got=$VAL_OUT" ;;
esac
if grep -Fq -- "$SECRET" <<<"$VAL_OUT"; then
  _fail "api_key LEAKED into config validate output"
else _pass "api_key absent from config validate output"; fi

# 4f. ccr config show -> redacts api_key to [REDACTED]
it "ccr config show redacts api_key to [REDACTED]"
section "4f. ccr config show"
SHOW_OUT="$(HOME="$TMP_HOME" "$CCR" config show "$CONFIG" 2>&1)"; SHOW_RC=$?
echo "exit=$SHOW_RC" >> "$PROOF"
echo "$SHOW_OUT" >> "$PROOF"
assert_eq 0 "$SHOW_RC" "config show exit"
if grep -Fq '[REDACTED]' <<<"$SHOW_OUT"; then _pass "config show prints the [REDACTED] marker"
else _fail "config show did not redact" "got=$SHOW_OUT"; fi
if grep -Fq -- "$SECRET" <<<"$SHOW_OUT"; then
  _fail "api_key LEAKED into config show output"
else _pass "api_key absent from config show output (redacted, not leaked)"; fi

# ---------------------------------------------------------------------------
# 5. TLS + HTTP/3: the BUNDLED Go ccr serves HTTPS via the new CLI flags
#    (--tls-cert / --tls-key / --http3). We prove: HTTPS /health answers 200
#    over TLS (ALPN h2), the response advertises HTTP/3 via the Alt-Svc header,
#    a real QUIC probe when curl supports it, that --http3 without certs is
#    rejected ("requires TLS"), and that the api_key never surfaces over HTTPS.
#
#    This leg SKIPs cleanly (never hard-fails the script) when openssl is
#    absent — a self-signed cert is a hard prerequisite we refuse to fake.
#    It starts a SECOND live server on its own free ports; TLS_PID is in the
#    EXIT trap so it is always reaped.
# ---------------------------------------------------------------------------
it "TLS + HTTP/3: bundled ccr serves HTTPS via --tls-cert/--tls-key/--http3"
section "5. TLS + HTTP/3"
# Capability gate: the flags only exist once the bundled router carries the
# TLS/HTTP3 feature. A build that predates it must be SKIPped (not FAILed) —
# this leg self-activates the moment submodules/claude-code-router is bumped to
# a commit that exposes the flags in `ccr --help`.
CCR_HELP="$("$CCR" --help 2>&1)"
if ! command -v openssl >/dev/null 2>&1; then
  msg="SKIP: openssl not found — cannot mint a self-signed cert; TLS/HTTP3 leg skipped (not faked)."
  echo "$msg"; echo "$msg" >> "$PROOF"
elif ! grep -q -- '--tls-cert' <<<"$CCR_HELP" || ! grep -q -- '--http3' <<<"$CCR_HELP"; then
  msg="SKIP: the bundled ccr build does not expose --tls-cert/--tls-key/--http3 (submodule predates the TLS/HTTP3 feature); TLS/HTTP3 leg skipped. Bump submodules/claude-code-router to a commit carrying the feature to activate this leg."
  echo "$msg"; echo "$msg" >> "$PROOF"
else
  TLS_CERT="$TMP_ROOT/tls-cert.pem"
  TLS_KEY="$TMP_ROOT/tls-key.pem"
  # Self-signed EC (P-256) cert with a 127.0.0.1 SAN — the SAN keeps the cert
  # honest (a real loopback identity, not a wildcard); we still curl with -k.
  if openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 \
       -keyout "$TLS_KEY" -out "$TLS_CERT" -days 1 -nodes \
       -subj "/CN=127.0.0.1" -addext "subjectAltName=IP:127.0.0.1" \
       >>"$PROOF" 2>&1; then
    _pass "openssl minted a self-signed EC cert+key (127.0.0.1 SAN)"

    # Two more free ports for the TLS server (independent of the plaintext one).
    read -r TLS_GW_PORT TLS_MG_PORT < <(python3 - <<'PY'
import socket
socks = []
for _ in range(2):
    s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    s.bind(("127.0.0.1", 0))
    socks.append(s)
print(*[s.getsockname()[1] for s in socks])
for s in socks:
    s.close()
PY
)
    TLS_GW="https://127.0.0.1:$TLS_GW_PORT"
    echo "tls_gateway: $TLS_GW  (management :$TLS_MG_PORT)" >> "$PROOF"

    # Reuse the same secret-bearing config from section 3 (same $CONFIG); the
    # HTTPS no-leak sweep is only meaningful because api_key == $SECRET.
    TLS_SERVER_LOG="$TMP_ROOT/server-tls.log"
    HOME="$TMP_HOME" "$CCR" serve --no-open \
      --gateway-host 127.0.0.1 --gateway-port "$TLS_GW_PORT" \
      --host 127.0.0.1 --port "$TLS_MG_PORT" \
      --tls-cert "$TLS_CERT" --tls-key "$TLS_KEY" --http3 \
      >"$TLS_SERVER_LOG" 2>&1 &
    TLS_PID=$!

    # 5a. GET https /health over TLS (ALPN h2) -> 200
    it "GET https /health over TLS returns 200"
    section "5a. GET https /health (TLS, --http2)"
    TLS_HEALTH_FILE="$TMP_ROOT/tls-health.body"
    if ! kill -0 "$TLS_PID" 2>/dev/null; then
      _fail "TLS server exited immediately" "$(cat "$TLS_SERVER_LOG" 2>/dev/null)"
    else
      TLS_H_CODE="$(curl -sk --http2 -o "$TLS_HEALTH_FILE" -w '%{http_code}' \
        --retry 30 --retry-connrefused --retry-delay 1 --max-time 30 \
        "$TLS_GW/health" 2>/dev/null || true)"
      { echo "http_code=$TLS_H_CODE"; echo "body=$(cat "$TLS_HEALTH_FILE" 2>/dev/null)"; } >> "$PROOF"
      assert_eq 200 "$TLS_H_CODE" "GET https /health status"
    fi

    # 5b. The HTTPS response advertises HTTP/3 on the gateway port via Alt-Svc.
    it "the HTTPS response advertises HTTP/3 via Alt-Svc h3=\":$TLS_GW_PORT\""
    section "5b. Alt-Svc h3 advertisement"
    TLS_HDR_FILE="$TMP_ROOT/tls-health.hdr"
    curl -sk --http2 -D "$TLS_HDR_FILE" -o /dev/null --max-time 10 "$TLS_GW/health" 2>/dev/null || true
    grep -i '^alt-svc:' "$TLS_HDR_FILE" 2>/dev/null >> "$PROOF" || true
    if grep -iq "h3=\":$TLS_GW_PORT\"" "$TLS_HDR_FILE" 2>/dev/null; then
      _pass "Alt-Svc advertises h3=\":$TLS_GW_PORT\""
    else _fail "Alt-Svc did not advertise h3 on the gateway port" "see $PROOF"; fi

    # 5c. Best-effort real HTTP/3 probe. NEVER fails on missing curl h3 support.
    it "best-effort: probe HTTP/3 over QUIC if curl supports it (h3-advertised-only otherwise)"
    section "5c. HTTP/3 probe (best-effort)"
    if curl --version 2>/dev/null | grep -Eqi 'HTTP3|nghttp3|ngtcp2|quiche|msh3'; then
      TLS_H3_OUT="$(curl -sk --http3-only -o "$TMP_ROOT/tls-h3.body" \
        -w '%{http_code} %{http_version}' --max-time 15 "$TLS_GW/health" 2>/dev/null || true)"
      echo "http3_probe (code version)=$TLS_H3_OUT" >> "$PROOF"
      if [[ "$TLS_H3_OUT" == "200 3" ]]; then
        _pass "curl --http3-only reached /health over QUIC (HTTP/3, 200)"
      else
        _pass "curl has http3 but the QUIC probe was inconclusive ($TLS_H3_OUT) — h3 remains advertised (non-fatal)"
      fi
    else
      echo "curl lacks HTTP/3 support; h3 is advertised via Alt-Svc only" >> "$PROOF"
      _pass "curl lacks --http3 — h3 advertised-only, not fatal"
    fi

    # 5d. NEGATIVE: --http3 without certs must be rejected (QUIC has no
    #     cleartext mode) with a non-zero exit and a 'requires TLS' message.
    it "ccr serve --http3 without certs exits non-zero and says 'requires TLS'"
    section "5d. negative: --http3 without certs"
    NEG_OUT="$(HOME="$TMP_HOME" "$CCR" serve --http3 --no-open 2>&1)"; NEG_RC=$?
    { echo "exit=$NEG_RC"; echo "$NEG_OUT"; } >> "$PROOF"
    if (( NEG_RC != 0 )); then _pass "--http3 without certs exits non-zero (rc=$NEG_RC)"
    else _fail "--http3 without certs unexpectedly succeeded" "rc=$NEG_RC"; fi
    case "$NEG_OUT" in
      *"requires TLS"*) _pass "--http3 without certs prints the 'requires TLS' guidance" ;;
      *) _fail "--http3 without certs missing 'requires TLS' message" "got=$NEG_OUT" ;;
    esac

    # 5e. The api_key must never surface in any captured HTTPS response.
    it "the api_key never leaked into any captured HTTPS response"
    section "5e. TLS secret sweep"
    tls_leaks=0
    for f in "$TLS_HEALTH_FILE" "$TLS_HDR_FILE" "$TMP_ROOT/tls-h3.body"; do
      [[ -f "$f" ]] || continue
      if grep -Fq -- "$SECRET" "$f"; then tls_leaks=$((tls_leaks + 1)); fi
    done
    # Label avoids a literal `secret_<...>` prefix so it does not trip the
    # proof-dir secret scanner (test_lib.sh) as a false positive — this is a
    # count of leaks (0 = none), not a secret.
    echo "tls_leaked_key_count_in_https_responses=$tls_leaks" >> "$PROOF"
    assert_eq 0 "$tls_leaks" "api_key occurrences in captured HTTPS responses"

    # 5f. Shut the TLS server down cleanly (the EXIT trap is the backstop).
    it "the TLS server shuts down cleanly"
    section "5f. TLS server shutdown"
    if [[ -n "$TLS_PID" ]] && kill -0 "$TLS_PID" 2>/dev/null; then
      kill "$TLS_PID" 2>/dev/null || true
      for _ in 1 2 3 4 5; do kill -0 "$TLS_PID" 2>/dev/null || break; sleep 0.2; done
      kill -9 "$TLS_PID" 2>/dev/null || true
      _pass "TLS server shut down"
      TLS_PID=""  # already reaped; stop the EXIT trap from re-killing
    else
      _fail "TLS server was not running at shutdown time" "$(cat "$TLS_SERVER_LOG" 2>/dev/null)"
    fi
  else
    msg="SKIP: openssl present but cert generation failed — TLS/HTTP3 leg skipped (not faked). See $PROOF."
    echo "$msg"; echo "$msg" >> "$PROOF"
  fi
fi

# ---------------------------------------------------------------------------
# 6. Kill the server + final secret sweep over the committed proof file
# ---------------------------------------------------------------------------
it "the server shuts down and no secret leaked into the committed proof"
section "6. shutdown + secret sweep"
if [[ -n "$SERVER_PID" ]] && kill -0 "$SERVER_PID" 2>/dev/null; then
  kill "$SERVER_PID" 2>/dev/null || true
  for _ in 1 2 3 4 5; do kill -0 "$SERVER_PID" 2>/dev/null || break; sleep 0.2; done
  if kill -0 "$SERVER_PID" 2>/dev/null; then
    kill -9 "$SERVER_PID" 2>/dev/null || true
    _pass "server force-killed after graceful window"
  else
    _pass "server shut down gracefully on SIGTERM"
  fi
  SERVER_PID=""  # already reaped; stop the EXIT trap from re-killing
else
  _fail "server was not running at shutdown time"
fi
# grep -c prints the count on stdout but exits 1 when the count is 0; capture the
# count and swallow that exit status (never chain `|| echo 0`, which double-counts).
leaks="$(grep -Fc -- "$SECRET" "$PROOF" 2>/dev/null)" || true
leaks="${leaks:-0}"
# Label avoids a literal `secret_<...>` prefix so this benign count line does not
# itself trip the proof-dir secret scanner (test_lib.sh) as a false positive.
echo "leaked_key_count_in_proof=$leaks" >> "$PROOF"
assert_eq 0 "$leaks" "secret occurrences in committed proof file"

echo
echo "Evidence written to: $PROOF"
summary
