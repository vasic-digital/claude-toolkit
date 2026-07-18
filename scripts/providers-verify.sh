#!/usr/bin/env bash
# providers-verify.sh — pluggable verification adapter for claude-providers.
#
# Verifies that a provider's key works and a model exists/responds. Strategy,
# in order:
#   1. If the LLMsVerifier binary is built (submodules/LLMsVerifier/bin/
#      model-verification), use it — the authoritative "Do you see my code?"
#      check. Pass/fail is read from its stdout (Status: verified + Can See
#      Code: true), per its documented contract.
#   2. Else, if curl+jq are present, network is allowed, and the key is set,
#      run two live probes against the provider's CHAT endpoint with the
#      SELECTED model: a VERIFY_OK sentinel probe (anti-bluff — a bare 200
#      proves the key is accepted, not that the model responds) followed by a
#      tool-calling probe (Claude Code is entirely tool-driven, so a chat-only
#      model is a broken alias in practice).
#   3. Else, report 'unverified' (NOT a failure) — the alias is still usable;
#      full verification is opt-in (build the submodule).
#
# Output: one word on stdout — verified | failed | unverified — plus a reason
# on stderr. Exit code: 0 verified, 1 failed, 2 unverified.
#
# Args: --provider ID --model M --key-var VAR [--base-url URL] [--offline]
set -uo pipefail

_cma_src="${BASH_SOURCE[0]}"
while [ -L "$_cma_src" ]; do
  _cma_tgt="$(readlink "$_cma_src")"
  case "$_cma_tgt" in /*) _cma_src="$_cma_tgt" ;; *) _cma_src="$(dirname "$_cma_src")/$_cma_tgt" ;; esac
done
LIB_DIR="$(cd "$(dirname "$_cma_src")" && pwd)"
unset _cma_src _cma_tgt

PROVIDER="" MODEL="" KEYVAR="" BASEURL="" OFFLINE=0
while (( $# )); do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    --key-var)  KEYVAR="$2"; shift 2 ;;
    --base-url) BASEURL="$2"; shift 2 ;;
    --offline)  OFFLINE=1; shift ;;
    *) echo "providers-verify: unknown arg $1" >&2; exit 2 ;;
  esac
done

VERIFIER_BIN="$LIB_DIR/../submodules/LLMsVerifier/bin/model-verification"

emit() { echo "$1"; [[ -n "${2:-}" ]] && echo "providers-verify[$PROVIDER]: $2" >&2; }

# --- Strategy 1: LLMsVerifier binary ---------------------------------------
if [[ -x "$VERIFIER_BIN" ]]; then
  out="$("$VERIFIER_BIN" --provider "$PROVIDER" --model "$MODEL" --verbose 2>&1)"
  if grep -q 'Status: verified' <<<"$out" && grep -q 'Can See Code: true' <<<"$out"; then
    emit verified "LLMsVerifier confirmed model + code visibility"; exit 0
  fi
  emit failed "LLMsVerifier did not confirm (see its output)"; exit 1
fi

# --- Strategy 2: live chat + tool-calling probes -----------------------------
key="${!KEYVAR:-}"
if (( ! OFFLINE )) && command -v curl >/dev/null 2>&1 && command -v jq >/dev/null 2>&1 \
   && [[ -n "$key" && -n "$BASEURL" ]]; then
  # Build the probe URL to match the URL the runtime actually calls.
  # An /anthropic segment in the ORIGINAL base selects the Anthropic
  # request/response shape — and the segment is KEPT, because native endpoints
  # (e.g. https://api.deepseek.com/anthropic) serve /v1/messages UNDER that
  # prefix, not at the host root. For the OpenAI shape: a base that already
  # ends in a version segment (/v1, /v4, …) takes only /chat/completions
  # (e.g. https://api.z.ai/api/coding/paas/v4 -> …/paas/v4/chat/completions);
  # anything else gets the standard /v1/chat/completions.
  base="${BASEURL%/}"
  anthropic=0
  case "$base" in */anthropic*) anthropic=1 ;; esac
  base="${base%/chat/completions}"

  # Pass the API key via --config (a process-substituted fd), never via -H on
  # the command line, so the secret is not exposed in ps/argv. printf is a
  # shell builtin, so the key never appears as a process argument either. The
  # substitution must run per probe: each pipe drains after one read.
  if (( anthropic )); then
    base="${base%/v1/messages}"
    base="${base%/v1}"
    url="$base/v1/messages"
    auth_fmt='header = "x-api-key: %s"\nheader = "anthropic-version: 2023-06-01"\n'
    tools_json='[{"name":"get_weather","description":"Get weather","input_schema":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}]'
  else
    base="${base%/coding}"
    base="${base%/v1}"
    case "$base" in
      */chat/completions) url="$base" ;;
      *)
        if [[ "$base" =~ /v[0-9]+$ ]]; then url="$base/chat/completions"
        else url="$base/v1/chat/completions"; fi ;;
    esac
    auth_fmt='header = "Authorization: Bearer %s"\n'
    tools_json='[{"type":"function","function":{"name":"get_weather","description":"Get weather","parameters":{"type":"object","properties":{"city":{"type":"string"}},"required":["city"]}}}]'
  fi

  resp="$(mktemp "${TMPDIR:-/tmp}/cma-verify.XXXXXX")"
  trap 'rm -f "$resp"' EXIT

  # chat_probe BODY — prints the HTTP code (000 on transport error, which curl
  # already emits via -w) and leaves the response body in $resp.
  chat_probe() {
    # shellcheck disable=SC2059  # auth_fmt is a fixed per-shape template chosen above, not user input
    curl -s -o "$resp" -w '%{http_code}' --max-time 15 \
      -H 'Content-Type: application/json' \
      --config <(printf "$auth_fmt" "$key") \
      -d "$1" "$url" 2>/dev/null || true
  }

  chat_body="$(jq -nc --arg m "$MODEL" \
    '{model:$m,max_tokens:128,messages:[{role:"user",content:"Reply with exactly: VERIFY_OK"}]}')"
  tools_body="$(jq -nc --arg m "$MODEL" --argjson t "$tools_json" \
    '{model:$m,max_tokens:128,messages:[{role:"user",content:"What is the weather in Paris? Use the tool."}],tools:$t}')"

  # Retry policy: auth/billing codes (401/402/403) are deterministic — never
  # retried. Other definitive-looking outcomes DO flap: 400/404/412/000 on
  # load-balanced gateways, and a 200 with a missing sentinel or missing tool
  # call on weak models (instruction-following is non-deterministic — the same
  # model can pass and fail minutes apart). Each gets exactly ONE retry; the
  # second result decides. Consistent bluffs fail both attempts, so the
  # anti-bluff guarantee is preserved.
  retry_if_flappy() {  # $1=code $2=body -> prints the (possibly retried) code
    case "$1" in
      400|404|412|000)
        sleep 3
        chat_probe "$2" ;;
      *) printf '%s' "$1" ;;
    esac
  }

  # Extract the text content of a chat response ($resp): OpenAI shape
  # (choices[0].message.content) or Anthropic (text blocks in content[]).
  # Invalid JSON extracts as empty and fails downstream checks.
  extract_content() {
    jq -r 'if ((.choices // []) | length) > 0
             then .choices[0].message.content // ""
             else ([.content[]? | select(.type == "text") | .text] | join(""))
             end' "$resp" 2>/dev/null
  }
  has_tool_call() {
    jq -e '((.choices[0].message.tool_calls // []) | length) > 0
           or (.choices[0].message.function_call != null)
           or (([.content[]? | select(.type == "tool_use")] | length) > 0)' \
      "$resp" >/dev/null 2>&1
  }

  # Probe 1: the sentinel. A 200 without VERIFY_OK (or with an error object
  # smuggled into the body) is a bluff — the endpoint answered *something*,
  # not the requested model — and that is a definitive failure, not transient.
  # Weak models flake on instruction-following, so a missing sentinel gets ONE
  # retry (see retry policy above); consistent bluffs fail both attempts.
  attempt=0
  while :; do
    attempt=$((attempt+1))
    code="$(chat_probe "$chat_body")"
    code="$(retry_if_flappy "$code" "$chat_body")"
    case "$code" in
      200)
        if jq -e '.error' "$resp" >/dev/null 2>&1; then
          emit failed "chat probe returned HTTP 200 with an error body at $url"; exit 1
        fi
        content="$(extract_content)"
        case "$content" in
          *VERIFY_OK*) break ;;  # sentinel confirmed -> probe 2
          *)
            if (( attempt < 2 )); then sleep 3; continue; fi
            emit failed "chat probe 200 but VERIFY_OK sentinel missing at $url on both attempts (bluff or non-functional model)"; exit 1 ;;
        esac ;;
      400|401|402|403|404|412)
        emit failed "chat probe HTTP $code at $url (auth/billing/model-missing/account-suspended is definitive)"; exit 1 ;;
      *)
        emit unverified "chat probe inconclusive (HTTP $code at $url)"; exit 2 ;;
    esac
  done

  # Probe 2: tool calling. A tool call shows up as tool_calls / function_call
  # (OpenAI) or a tool_use content block (Anthropic). A 200 without one means
  # no tool support — a failure, since Claude Code cannot drive the model.
  # Models non-deterministically skip tool calls, so a missing call gets ONE
  # retry before the failure is declared (see retry policy above).
  attempt=0
  while :; do
    attempt=$((attempt+1))
    code="$(chat_probe "$tools_body")"
    code="$(retry_if_flappy "$code" "$tools_body")"
    case "$code" in
      200)
        if has_tool_call; then
          emit verified "chat + tool-calling probes passed at $url"; exit 0
        fi
        if (( attempt < 2 )); then sleep 3; continue; fi
        emit failed "chat probe passed but the model made no tool call at $url on both attempts (tool calling is required by Claude Code)"; exit 1 ;;
      429)
        emit unverified "chat probe passed but tool probe rate-limited (HTTP 429 at $url)"; exit 2 ;;
      4??)
        emit failed "tool-calling probe rejected (HTTP $code at $url)"; exit 1 ;;
      *)
        emit unverified "chat probe passed but tool probe inconclusive (HTTP $code at $url)"; exit 2 ;;
    esac
  done
fi

# --- Strategy 3: cannot verify here ----------------------------------------
emit unverified "no verifier binary and no probe possible; build submodules/LLMsVerifier for full verification"
exit 2
