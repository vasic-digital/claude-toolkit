#!/usr/bin/env bash
# verify_superpowers_tui.sh — layer-4 live test: launch REAL Claude Code through a
# provider alias and confirm (a) no trust/overwrite prompt fires and (b) the
# superpowers plugin engages end-to-end. This is the ONLY thing that flips a
# provider to fully 'verified' (§4.4, §11.4.108 layer-4 user-visible).
#
# Honest SKIP (§11.4.3), never a faked PASS: SKIPs (exit 0, prints "SKIP: <why>")
# when the real claude binary / the alias / a key / the network is absent.
# PASS -> exit 0 + "PASS: ...". FAIL -> exit 1 + "FAIL: ...".
#
# Usage: verify_superpowers_tui.sh --alias ID [--prompt STR] [--timeout N] [--out FILE]
set -uo pipefail
TESTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PDIR="$HOME/.local/share/claude-multi-account/providers"
ALIASES_FILE="${ALIAS_FILE:-$HOME/.local/share/claude-multi-account/aliases.sh}"

ALIAS_ID="" PROMPT="/using-superpowers" TIMEOUT=180 OUT=""
while (( $# )); do
  case "$1" in
    --alias)   ALIAS_ID="$2"; shift 2 ;;
    --prompt)  PROMPT="$2"; shift 2 ;;
    --timeout) TIMEOUT="$2"; shift 2 ;;
    --out)     OUT="$2"; shift 2 ;;
    -h|--help) sed -n '2,12p' "$0"; exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
: "${OUT:=${PROOF_DIR:-$TESTS_ROOT/tests/proof}/providers-${ALIAS_ID}-superpowers.txt}"
mkdir -p "$(dirname "$OUT")"

skip() { echo "SKIP: $1"; { echo "# SKIP $(date): $1"; } >> "$OUT" 2>/dev/null || true; exit 0; }

# --- preconditions (each an honest SKIP) ------------------------------------
[[ -n "$ALIAS_ID" ]] || skip "no --alias given"
CB="${CLAUDE_BIN:-$(command -v claude || true)}"
[[ -n "$CB" && "$CB" != "/usr/bin/true" && "$(basename "$CB")" == claude* ]] || skip "no real claude binary (CLAUDE_BIN=$CB)"
[[ -f "$ALIASES_FILE" ]] || skip "no alias file ($ALIASES_FILE) — run install.sh"
[[ -f "$PDIR/$ALIAS_ID.env" ]] || skip "alias '$ALIAS_ID' not installed"
command -v curl >/dev/null 2>&1 || skip "no curl (cannot pre-check network)"
# key present?
keyvar="$( set -a; . "$PDIR/$ALIAS_ID.env"; set +a; printf '%s' "${CMA_PROVIDER_KEYVAR:-}" )"
( set -a +u; [[ -f "${CMA_KEYS_FILE:-$HOME/api_keys.sh}" ]] && . "${CMA_KEYS_FILE:-$HOME/api_keys.sh}"; set +a
  eval "tok=\"\${$keyvar:-}\""; [[ -n "${tok:-}" ]] ) || skip "no key in \$$keyvar for '$ALIAS_ID'"

# --- launch (scrubbed env + throwaway cwd, like verify_claude_live.sh) -------
SCRUB=(env -u CLAUDECODE -u CLAUDE_CODE_CHILD_SESSION -u CLAUDE_CODE_ENTRYPOINT
       -u CLAUDE_CODE_SESSION_ID -u CLAUDE_CODE_EXECPATH -u CLAUDE_EFFORT
       -u CLAUDE_CONFIG_DIR -u ANTHROPIC_MODEL -u ANTHROPIC_BASE_URL
       -u ANTHROPIC_API_KEY -u ANTHROPIC_AUTH_TOKEN)
tmpd="$(mktemp -d "${TMPDIR:-/tmp}/cma-stui.XXXXXX")"
: > "$OUT"
out="$( timeout "$TIMEOUT" "${SCRUB[@]}" bash -c '
    cd "'"$tmpd"'" || exit 97
    source "'"$ALIASES_FILE"'" >/dev/null 2>&1
    cma_run_provider "'"$ALIAS_ID"'" -p "'"$PROMPT"'" --output-format json 2>&1
  ' )"
rc=$?
rmdir "$tmpd" 2>/dev/null || true
printf '%s\n' "$out" >> "$OUT"

# --- classify ---------------------------------------------------------------
# A trust/overwrite prompt makes the non-interactive launch hang -> timeout (124),
# or leaves its dialog text in the transcript.
if (( rc == 124 )); then echo "FAIL: launch hung within ${TIMEOUT}s (trust/overwrite prompt?)"; echo "# FAIL: timeout" >> "$OUT"; exit 1; fi
if printf '%s' "$out" | grep -qiE 'do you (trust|want to open)|overwrite.*config|trust the files'; then
  echo "FAIL: a trust/overwrite prompt fired"; echo "# FAIL: trust-prompt" >> "$OUT"; exit 1
fi
# superpowers engagement marker (review Finding 4 — HONESTY): a false PASS here
# is far worse than a false FAIL, since PASS is what flips a provider to
# 'verified' via `cmd_verify --deep`. The marker MUST NOT be satisfiable by the
# model merely ECHOING the injected prompt or using a generic word:
#   - bare 'skill'/'superpowers' matched refusals like "I don't have a skill
#     called using-superpowers, but..." -> false PASS.
#   - the literal prompt term 'using-superpowers' (PROMPT="/using-superpowers")
#     matched its own echo -> false PASS.
# The tightened marker requires either (a) the skill's actual self-announcement
# form ("Using superpowers:<name>", per using-superpowers/SKILL.md's own
# "Announce: 'Using [skill] to [purpose]'" convention -- distinct from the
# hyphenated prompt text) or (b) a named skill that using-superpowers can only
# chain into if its content genuinely loaded and ran (systematic-debugging,
# brainstorming), not just a word echoed from the prompt. Erring stricter is
# deliberate: a real engagement that fails to match should SKIP/FAIL, never a
# fabricated PASS.
#
# This tightening is NOT Tier-A testable (no real claude in the sandbox to
# generate a genuine negative-case transcript). The DEFINITIVE live check --
# real claude, superpowers NOT engaging, must NOT PASS -- is deferred to
# Task 5's Tier-B test.
if printf '%s' "$out" | grep -qiE 'superpowers:[a-z0-9_-]+'; then
  echo "PASS: superpowers engaged, no trust/overwrite prompt"; echo "# PASS" >> "$OUT"; exit 0
fi
echo "FAIL: session ran but superpowers did not engage"; echo "# FAIL: no-engagement" >> "$OUT"; exit 1
