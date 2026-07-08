#!/usr/bin/env bash
# providers-verify.sh — pluggable verification adapter for claude-providers.
#
# Verifies that a provider's key works and a model exists/responds. Strategy,
# in order:
#   1. If the LLMsVerifier binary is built (submodules/LLMsVerifier/bin/
#      model-verification), use it — the authoritative "Do you see my code?"
#      check. Pass/fail is read from its stdout (Status: verified + Can See
#      Code: true), per its documented contract.
#   2. Else, if curl is present, network is allowed, and the key is set, do a
#      lightweight HTTP probe of the provider's /models endpoint.
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

# --- Strategy 2: lightweight HTTP probe ------------------------------------
key="${!KEYVAR:-}"
if (( ! OFFLINE )) && command -v curl >/dev/null 2>&1 && [[ -n "$key" && -n "$BASEURL" ]]; then
  # Strip transport-specific path segments so the /models endpoint resolves
	  # correctly. Native-transport providers (base URL ending in /anthropic)
	  # need the /anthropic stripped to reach the model list at the API root.
	  probe="${BASEURL%/}"
	  probe="${probe%/anthropic}"
	  probe="${probe}/models"
  # Pass the bearer token via --config (a process-substituted fd), never via
  # -H on the command line, so the secret is not exposed in ps/argv. printf is
  # a shell builtin, so the key never appears as a process argument either.
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 \
            --config <(printf 'header = "Authorization: Bearer %s"\n' "$key") \
            "$probe" 2>/dev/null || echo 000)"
  case "$code" in
    200) emit verified "HTTP probe 200 at $probe"; exit 0 ;;
    401|403) emit failed "HTTP $code (auth rejected) at $probe"; exit 1 ;;
    *) emit unverified "HTTP probe inconclusive ($code at $probe); build LLMsVerifier for full check"; exit 2 ;;
  esac
fi

# --- Strategy 3: cannot verify here ----------------------------------------
emit unverified "no verifier binary and no probe possible; build submodules/LLMsVerifier for full verification"
exit 2
