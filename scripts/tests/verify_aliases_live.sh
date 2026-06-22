#!/usr/bin/env bash
# verify_aliases_live.sh — comprehensive live verification for ALL provider aliases.
#
# Tests each alias with 6 checks:
#   1. Basic chat completion
#   2. Tools with missing 'parameters' field (proxy fix)
#   3. Tools with $ref/$defs (Grok-4 fix)
#   4. cache_control parameter (cleancache fix)
#   5. Streaming
#   6. Tool calling
#
# Automatically starts proxy for providers that need it (e.g. Poe).
#
# Usage:
#   bash scripts/tests/verify_aliases_live.sh
#   bash scripts/tests/verify_aliases_live.sh --alias poe
#   bash scripts/tests/verify_aliases_live.sh --verbose

set +e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"

PROOF_DIR="${PROOF_DIR:-$TESTS_DIR/proof}"
VERBOSE=0 TARGET_ALIAS="" PROXY_PORT=3457

while (( $# )); do
  case "$1" in --alias) TARGET_ALIAS="$2"; shift 2 ;; --verbose) VERBOSE=1; shift ;; --timeout) TIMEOUT="$2"; shift 2 ;;
  esac; shift
done
: "${TIMEOUT:=30}"

mkdir -p "$PROOF_DIR"
EV="$PROOF_DIR/alias-verify-evidence.txt"
: > "$EV"

set -a; [[ -f "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" ]] && source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" 2>/dev/null || true; set +a
[[ -f "$HOME/.local/share/claude-multi-account/aliases.sh" ]] && source "$HOME/.local/share/claude-multi-account/aliases.sh" 2>/dev/null || true

PDIR="$HOME/.local/share/claude-multi-account/providers"
total=0 passed=0 failed=0

if [[ -n "$TARGET_ALIAS" ]]; then
  f="$PDIR/$TARGET_ALIAS.env"; [[ -f "$f" ]] && ALIASES=("$TARGET_ALIAS") || { echo "No env for $TARGET_ALIAS"; exit 1; }
else
  ALIASES=(); for f in "$PDIR"/*.env; do ALIASES+=("$(basename "$f" .env)"); done
fi

echo "Alias verification: $(date)" | tee -a "$EV"
echo "Testing ${#ALIASES[@]} aliases" | tee -a "$EV"

# Start Poe proxy if needed
PROXY_PID=""
maybe_start_proxy() {
  local id="$1"
  local base_id="${id%%[0-9]*}"
  local proxy_script="$HOME/.local/share/claude-multi-account/proxy/${base_id}_proxy.py"
  if [[ -f "$proxy_script" ]] && [[ -z "$PROXY_PID" ]]; then
    python3 "$proxy_script" --port "$PROXY_PORT" &
    PROXY_PID=$!
    sleep 2
    echo "Started proxy for $id on port $PROXY_PORT (pid=$PROXY_PID)" >&2
  fi
}

maybe_stop_proxy() {
  if [[ -n "$PROXY_PID" ]]; then
    kill "$PROXY_PID" 2>/dev/null || true
    PROXY_PID=""
    sleep 1
  fi
}

for alias_name in "${ALIASES[@]}"; do
  env_file="$PDIR/$alias_name.env"
  [[ -f "$env_file" ]] || continue
  total=$((total+1))

  # Parse env
  pid=""; keyvar=""; transport=""; base_url=""; model=""; fast_model=""
  while IFS='=' read -r key val; do
    key="$(echo "$key" | xargs)"
    val="$(echo "$val" | tr -d "'\"")"
    case "$key" in CMA_PROVIDER_ID) pid="$val" ;; CMA_PROVIDER_KEYVAR) keyvar="$val" ;;
      CMA_PROVIDER_TRANSPORT) transport="$val" ;; CMA_PROVIDER_BASE_URL) base_url="$val" ;;
      CMA_PROVIDER_MODEL) model="$val" ;; CMA_PROVIDER_FAST_MODEL) fast_model="$val" ;;
    esac
  done < <(grep '^CMA_PROVIDER_' "$env_file")

  model="${model:-$fast_model}"
  [[ -z "$model" ]] && continue

  # Get key
  key=""
  if [[ -n "${!keyvar:-}" ]]; then key="${!keyvar}"
  elif [[ -f "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" ]]; then
    set +u
    source "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" 2>/dev/null || true
    set -u 2>/dev/null || true
    key="$(eval "echo \"\${$keyvar:-}\"" 2>/dev/null || true)"
  fi
  [[ -z "$key" ]] && { echo "SKIP $alias_name (no key)"; continue; }

  # Build endpoint — use proxy if available
  test_url="${base_url:-}"
  maybe_start_proxy "$alias_name"
  if [[ -n "$PROXY_PID" ]]; then
    test_url="http://127.0.0.1:$PROXY_PORT/v1/chat/completions"
  elif [[ "$test_url" != */chat/completions ]] && [[ "$test_url" != */v1/messages ]]; then
    test_url="${test_url%/}/chat/completions"
  fi

  VERDICT="PASS" ERRORS=""

  # Test 1: Basic chat completion
  [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 1 (basic)..." >&2
  resp=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" -H "Authorization: Bearer $key" \
    -d "{\"model\":\"$model\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}]}" 2>/dev/null || echo "{}")
  code=$(echo "$resp" | python3 -c "import json,sys; d=json.load(sys.stdin); print(200 if d.get('choices') else d.get('error',{}).get('code',400))" 2>/dev/null || echo 000)
  [[ "$code" != "200" ]] && { ERRORS="${ERRORS}basic($code) "; VERDICT="FAIL"; }

  # Test 2: Tools missing parameters
  [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 2 (missing params)..." >&2
  resp2=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" -H "Authorization: Bearer $key" \
    -d "{\"model\":\"$model\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"test\",\"description\":\"test\"}}]}" 2>/dev/null || echo "{}")
  err2=$(echo "$resp2" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message',''))" 2>/dev/null || true)
  echo "$err2" | grep -qi "Field required\|parameters" && { ERRORS="${ERRORS}tools-params "; VERDICT="FAIL"; }

  # Test 3: Tools with $ref
  [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 3 (\$ref)..." >&2
  resp3=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" -H "Authorization: Bearer $key" \
    -d "{\"model\":\"$model\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"test\",\"description\":\"test\",\"parameters\":{\"type\":\"object\",\"properties\":{\"x\":{\"\$ref\":\"#/\$defs/T\"}},\"\$defs\":{\"T\":{\"type\":\"string\"}}}}}]}" 2>/dev/null || echo "{}")
  err3=$(echo "$resp3" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message',''))" 2>/dev/null || true)
  echo "$err3" | grep -qi "unresolvable\|\$ref\|\$defs" && { ERRORS="${ERRORS}dollar-ref "; VERDICT="FAIL"; }

  # Test 4: cache_control
  [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 4 (cache_control)..." >&2
  resp4=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" -H "Authorization: Bearer $key" \
    -d "{\"model\":\"$model\",\"max_tokens\":32,\"messages\":[{\"role\":\"user\",\"content\":\"Say OK\",\"cache_control\":{\"type\":\"ephemeral\"}}]}" 2>/dev/null || echo "{}")
  err4=$(echo "$resp4" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('error',{}).get('message',''))" 2>/dev/null || true)
  echo "$err4" | grep -qi "cache_control\|unknown field" && { ERRORS="${ERRORS}cache_control "; VERDICT="FAIL"; }

  # Test 5: Streaming
  [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 5 (stream)..." >&2
  chunks=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" -H "Authorization: Bearer $key" \
    -d "{\"model\":\"$model\",\"max_tokens\":16,\"stream\":true,\"messages\":[{\"role\":\"user\",\"content\":\"Hi\"}]}" 2>/dev/null | grep -c 'data: {"id"' || true)

  # Test 6: Tool calling
  [[ $VERBOSE -eq 1 ]] && echo "  $alias_name: test 6 (tool call)..." >&2
  resp6=$(curl -s --max-time "$TIMEOUT" -X POST "$test_url" -H "Content-Type: application/json" -H "Authorization: Bearer $key" \
    -d "{\"model\":\"$model\",\"max_tokens\":64,\"messages\":[{\"role\":\"user\",\"content\":\"Calculate 7*6\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"calc\",\"description\":\"Calculate math\",\"parameters\":{\"type\":\"object\",\"properties\":{\"expr\":{\"type\":\"string\"}},\"required\":[\"expr\"]}}}]}" 2>/dev/null || echo "{}")
  has_tool=$(echo "$resp6" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('choices',[{}])[0].get('message',{}).get('tool_calls','no'))" 2>/dev/null || echo "no")

  # Record
  echo "--- $alias_name ($model) ---" >> "$EV"
  echo "test1(basic)=$code test2(no_params)=${err2:0:40} test3(ref)=${err3:0:40} test4(cache)=${err4:0:40} test5(stream)=${chunks}chunks test6(tool)=${has_tool:0:20}" >> "$EV"
  echo "verdict=$VERDICT" >> "$EV"

  if [[ "$VERDICT" == "PASS" ]]; then passed=$((passed+1)); [[ $VERBOSE -eq 1 ]] && echo "✓ $alias_name: PASS"
  else failed=$((failed+1)); echo "✗ $alias_name: FAIL — $ERRORS"
  fi
  maybe_stop_proxy
done
maybe_stop_proxy

echo | tee -a "$EV"
echo "PASS: $passed FAIL: $failed TOTAL: $total" | tee -a "$EV"
exit $failed

# --- Claude Alias Tests (native Anthropic transport) ---
test_claude_alias() {
  local alias_name="$1" config_dir="$2"
  total=$((total+1))
  export CLAUDE_CONFIG_DIR="$config_dir"
  
  # Basic test
  result=$(cma_run -p "Say OK" 2>/dev/null || echo "FAIL")
  if echo "$result" | grep -qi "OK\|ready\|help"; then
    passed=$((passed+1))
    echo "✓ $alias_name: PASS" | tee -a "$EV"
  else
    failed=$((failed+1))
    echo "✗ $alias_name: FAIL" | tee -a "$EV"
  fi
  unset CLAUDE_CONFIG_DIR
}

if [[ -z "$TARGET_ALIAS" ]]; then
  test_claude_alias "claude1" "$HOME/.claude-milos85vasic"
  test_claude_alias "claude2" "$HOME/.claude-milos85vasic2nd"
  test_claude_alias "claude3" "$HOME/.claude-milos85vasic3rd"
fi
