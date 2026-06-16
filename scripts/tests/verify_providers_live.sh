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
  id="$( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_ID" )"
  grep -qE "cma_run_provider $id(\"| )" "$ALIASES" || { ok=0; echo "no alias for $id" >>"$EV"; }
done
assert_eq 1 "$ok" "every provider has an alias line"

it "the cma_run_provider wrapper is defined in the alias file"
grep -q '^cma_run_provider()' "$ALIASES"; assert_eq 0 $? "wrapper present"

it "provider config dirs are excluded from account detection"
# Source lib.sh and confirm no ~/.claude-prov-* leaks into detection.
( source "$SCRIPTS_DIR/lib.sh" 2>/dev/null; cma_detect_accounts ) > "$PROOF_DIR/51-detected-accounts.txt" 2>/dev/null
grep -q 'prov-' "$PROOF_DIR/51-detected-accounts.txt"; assert_eq 1 $? "no provider dir detected as account"

{
  echo "# provider live verification — $(date)"
  echo "providers installed: $(ls "$PDIR"/*.env 2>/dev/null | wc -l | tr -d ' ')"
  echo "ccr installed: $(command -v ccr >/dev/null 2>&1 && echo yes || echo no)"
  echo "LLMsVerifier binary: $([[ -x "$SCRIPTS_DIR/../submodules/LLMsVerifier/bin/model-verification" ]] && echo built || echo not-built)"
} >> "$EV"

echo "evidence: $EV"
summary
