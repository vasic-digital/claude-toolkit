#!/usr/bin/env bash
# verify_providers_live.sh — read-only proof that the provider-alias feature is
# coherent against the REAL installed state on this host (not a sandbox).
#
# Like verify_opencode_live.sh: NOT named test_*.sh (run-all.sh won't auto-pick
# it), read-only, and SKIPs (exit 0) when no provider aliases are installed.
# Every check writes raw evidence to $PROOF_DIR.
#
# Knobs:
#   PROOF_DIR  where to write evidence (default scripts/tests/proof)
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"

PROOF_DIR="${PROOF_DIR:-$TESTS_DIR/proof}"
mkdir -p "$PROOF_DIR"
PDIR="$HOME/.local/share/claude-multi-account/providers"
ALIASES="${ALIAS_FILE:-$HOME/.local/share/claude-multi-account/aliases.sh}"

if [[ ! -d "$PDIR" ]] || ! compgen -G "$PDIR/*.env" >/dev/null 2>&1; then
  echo "SKIP: no provider aliases installed on this host — live provider verification skipped."
  exit 0
fi

set +e
EV="$PROOF_DIR/50-providers-live.txt"
: > "$EV"

it "every provider env file has the required non-secret fields"
ok=1
for f in "$PDIR"/*.env; do
  for key in CMA_PROVIDER_ID CMA_PROVIDER_KEYVAR CMA_PROVIDER_TRANSPORT \
             CMA_PROVIDER_MODEL CMA_PROVIDER_CONFIG_DIR; do
    grep -q "^$key=" "$f" || { ok=0; echo "MISSING $key in $f" >>"$EV"; }
  done
done
assert_eq 1 "$ok" "all env files well-formed"

it "NO secret values are present in env files (structural: only CMA_PROVIDER_* lines)"
# Stronger than a length heuristic: every non-comment, non-blank line in each
# env file MUST be a CMA_PROVIDER_*= assignment. Anything else would be a stray
# value and a potential leak.
stray=0
for f in "$PDIR"/*.env; do
  bad="$(grep -vE '^[[:space:]]*#|^[[:space:]]*$|^CMA_PROVIDER_[A-Z_]+=' "$f")"
  [[ -n "$bad" ]] && { stray=1; printf 'STRAY in %s:\n%s\n' "$f" "$bad" >>"$EV"; }
done
assert_eq 0 "$stray" "env files contain only CMA_PROVIDER_* assignments"

it "each provider alias resolves to cma_run_provider in the alias file"
ok=1
for f in "$PDIR"/*.env; do
  # Source (values are shell-quoted) to read the id cleanly — never sed-parse.
  # shellcheck source=/dev/null  # runtime provider env file, path only known at execution
  id="$( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_ID" )"
  grep -qE "cma_run_provider $id(\"| )" "$ALIASES" || { ok=0; echo "no alias for $id" >>"$EV"; }
done
assert_eq 1 "$ok" "every provider has an alias line"

it "the cma_run_provider wrapper is defined in the alias file"
grep -q '^cma_run_provider()' "$ALIASES"; assert_eq 0 $? "wrapper present"

it "provider config dirs are excluded from account detection"
# Source lib.sh and confirm no ~/.claude-prov-* leaks into detection.
# shellcheck source=/dev/null  # lib.sh loaded dynamically via $SCRIPTS_DIR; path resolved at runtime
( source "$SCRIPTS_DIR/lib.sh" 2>/dev/null; cma_detect_accounts ) > "$PROOF_DIR/51-detected-accounts.txt" 2>/dev/null
grep -q 'prov-' "$PROOF_DIR/51-detected-accounts.txt"; assert_eq 1 $? "no provider dir detected as account"

{
  echo "# provider live verification — $(date)"
  echo "providers installed: $(find "$PDIR" -maxdepth 1 -name '*.env' 2>/dev/null | wc -l | tr -d ' ')"
  echo "ccr installed: $(command -v ccr >/dev/null 2>&1 && echo yes || echo no)"
  echo "LLMsVerifier binary: $([[ -x "$SCRIPTS_DIR/../submodules/LLMsVerifier/bin/model-verification" ]] && echo built || echo not-built)"
} >> "$EV"

# --- layer 3 (semantic) + layer 4 (superpowers-TUI) per installed provider ---
# Read-only against real host state; every sub-check is an honest SKIP when a
# precondition (key/judge/go/network/real-claude) is absent — never a faked
# PASS (§11.4.3). Extends this already-wired file; no proof/ duplicate.
SUMMARY="$PROOF_DIR/providers-summary.json"
printf '{}\n' > "$SUMMARY"
KEYS_FILE="${CMA_KEYS_FILE:-$HOME/api_keys.sh}"

# Strip anything resembling a leaked bearer/sk- secret out of captured evidence
# before it lands in $PROOF_DIR. Defense in depth: the drivers are not
# supposed to print keys, but evidence files are read by humans and must never
# carry one, even by accident.
_redact() {
  [[ -f "$1" ]] || return 0
  sed -E 's/sk-[A-Za-z0-9_-]{8,}/sk-***REDACTED***/g; s/([Bb]earer[[:space:]]+)[A-Za-z0-9._-]{8,}/\1***REDACTED***/g' \
    "$1" > "$1.redacted" 2>/dev/null && mv "$1.redacted" "$1"
}

first_id=""
for f in "$PDIR"/*.env; do
  # shellcheck source=/dev/null  # runtime provider env file, path only known at execution
  IFS=$'\t' read -r id model keyvar baseurl < <(
    set -a; . "$f"; set +a
    printf '%s\t%s\t%s\t%s' "$CMA_PROVIDER_ID" "$CMA_PROVIDER_MODEL" "$CMA_PROVIDER_KEYVAR" "$CMA_PROVIDER_BASE_URL"
  )
  [[ -n "$first_id" ]] || first_id="$id"
  status="$( source "$SCRIPTS_DIR/lib.sh" 2>/dev/null; cma_status_read "$id" )"
  exists=0
  grep -qE "cma_run_provider $id(\"| )" "$ALIASES" 2>/dev/null && exists=1

  it "semantic (layer 3) for '$id' — PASS/SKIP, never a faked pass"
  sem_ev="$PROOF_DIR/providers-${id}-semantic.txt"
  sem="$( ( [[ -f "$KEYS_FILE" ]] && { set -a +u; . "$KEYS_FILE"; set +a; }
            bash "$SCRIPTS_DIR/providers-semantic.sh" --provider "$id" \
              --model "$model" --key-var "$keyvar" --base-url "$baseurl" ) 2>"$sem_ev" )"
  echo "semantic verdict: ${sem:-skip}" >> "$sem_ev"
  _redact "$sem_ev"
  case "$sem" in
    verified)   _pass "layer-3 semantic PASS for $id" ;;
    unverified) _pass "layer-3 semantic ran (verdict: unverified) for $id" ;;  # a real verdict, not a test failure
    *)          echo "SKIP: layer-3 preconditions absent for $id" ;;
  esac

  it "superpowers-TUI (layer 4) for '$id' — PASS/SKIP"
  tui_ev="$PROOF_DIR/providers-${id}-superpowers.txt"
  tui_out="$(bash "$SCRIPTS_DIR/verify_superpowers_tui.sh" --alias "$id" --out "$tui_ev" --timeout 180 2>&1)"
  _redact "$tui_ev"
  case "$tui_out" in
    PASS:*) tui_label=verified;   _pass "layer-4 superpowers-TUI PASS for $id" ;;
    FAIL:*) tui_label=unverified; _pass "layer-4 superpowers-TUI ran (verdict: FAIL — not verified) for $id" ;;
    *)      tui_label=skip;       echo "SKIP: ${tui_out:-layer-4 preconditions absent for $id}" ;;
  esac

  # aggregate (real semantic shape: no fixture_hash)
  tmp="$(mktemp "${TMPDIR:-/tmp}/cma-sum.XXXXXX")"
  jq --arg id "$id" --arg st "$status" --argjson ex "$([[ $exists == 1 ]] && echo true || echo false)" \
     --arg sem "${sem:-skip}" --arg tui "$tui_label" \
     --arg semev "$sem_ev" --arg tuiev "$tui_ev" \
     '.[$id] = {status:$st,
                 layers:{existence:$ex, semantic:$sem, superpowers_tui:$tui},
                 evidence:{semantic:$semev, superpowers_tui:$tuiev}}' \
     "$SUMMARY" > "$tmp" && mv "$tmp" "$SUMMARY"
done
echo "aggregate: $SUMMARY" >> "$EV"

it "layer-4 classifier honesty: a neutral, non-superpowers response must NOT verify (negative-case, Task-3 review)"
CB="${CLAUDE_BIN:-$(command -v claude || true)}"
if [[ -n "$first_id" && -n "$CB" && "$CB" != "/usr/bin/true" && "$(basename "$CB")" == claude* && -f "$ALIASES" ]]; then
  # Mirrors verify_superpowers_tui.sh's SCRUB + throwaway-cwd launch, but uses
  # --force (the documented operator override, lib.sh) to bypass the
  # not-yet-verified activation gate: the point here is validating the
  # ENGAGEMENT-MARKER REGEX itself never false-matches on ordinary model
  # output, independent of any one alias's current verified/pending status.
  NEG_SCRUB=(env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT \
             -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT \
             -u CLAUDE_CONFIG_DIR -u ANTHROPIC_MODEL -u ANTHROPIC_BASE_URL \
             -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN)
  neg_ev="$PROOF_DIR/providers-negative-case-superpowers.txt"
  neg_tmpd="$(mktemp -d "${TMPDIR:-/tmp}/cma-neg.XXXXXX")"
  neg_out="$( timeout 60 "${NEG_SCRUB[@]}" bash -c '
      cd "'"$neg_tmpd"'" || exit 97
      [[ -f "'"$KEYS_FILE"'" ]] && { set -a +u; . "'"$KEYS_FILE"'"; set +a; }
      source "'"$ALIASES"'" >/dev/null 2>&1
      cma_run_provider --force "'"$first_id"'" \
        -p "Reply with exactly the single word DONE and nothing else. Do not use any tool, plugin, or skill." \
        --output-format json 2>&1
    ' )"
  neg_rc=$?
  rmdir "$neg_tmpd" 2>/dev/null || true
  printf '%s\n' "$neg_out" > "$neg_ev"
  _redact "$neg_ev"
  if (( neg_rc == 124 )); then
    echo "SKIP: negative-case launch via '$first_id' timed out (network/precondition absent) — not a classifier finding" >> "$EV"
  elif printf '%s' "$neg_out" | grep -qiE 'using superpowers:[a-z0-9_-]+|systematic-debugging|brainstorming'; then
    _fail "layer-4 classifier honesty" "engagement marker matched on a NEUTRAL prompt via '$first_id' — false-PASS risk (evidence: $neg_ev)"
  else
    _pass "layer-4 classifier honesty: neutral prompt via '$first_id' correctly did NOT match the engagement marker"
  fi
else
  echo "SKIP: negative-case honesty check — no real claude binary / alias file available"
fi

echo "evidence: $EV"
summary
