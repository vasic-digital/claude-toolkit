#!/usr/bin/env bash
# providers-semantic.sh — layer-3 (semantic code-visibility) adapter for
# claude-providers. Runs AFTER existence/tool-call passed. Drives the
# LLMsVerifier semantic-code-visibility command with the toolkit-owned fixture,
# prompt, sentinel and rubric (the submodule stays project-not-aware; every
# consumer-specific input is a CLI arg — CONST-051).
#
# Output: one word on stdout — verified | unverified | skip. Exit: 0/1/2.
#   verified  round-1 sentinel + round-2 judge both passed.
#   unverified  a round failed (this alias cannot genuinely see your code / bluffed).
#   skip  a precondition was absent (no key/judge/go/network) — HONEST SKIP,
#         the caller MUST NOT downgrade on this (§11.4.3).
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
REPO_ROOT="$(cd "$LIB_DIR/.." && pwd)"

PROVIDER="" MODEL="" KEYVAR="" BASEURL="" OFFLINE=0
while (( $# )); do
  case "$1" in
    --provider) PROVIDER="$2"; shift 2 ;;
    --model)    MODEL="$2"; shift 2 ;;
    --key-var)  KEYVAR="$2"; shift 2 ;;
    --base-url) BASEURL="$2"; shift 2 ;;
    --offline)  OFFLINE=1; shift ;;
    *) echo "providers-semantic: unknown arg $1" >&2; exit 2 ;;
  esac
done

emit_skip() { echo skip; echo "providers-semantic[$PROVIDER]: skip — ${1:-precondition absent}" >&2; exit 2; }

DRIVER="${CMA_SEMANTIC_DRIVER:-$LIB_DIR/claude-semantic-visibility.sh}"
FIX="${CMA_SEMANTIC_FIXTURE:-$LIB_DIR/providers/fixture/code-visibility.md}"
PROMPT="${CMA_SEMANTIC_PROMPT:-$LIB_DIR/providers/fixture/prompt-template.txt}"
RUBRIC="${CMA_SEMANTIC_RUBRIC:-$LIB_DIR/providers/rubric/code-visibility-rubric.json}"
SENTINEL="${CMA_SEMANTIC_SENTINEL:-ZETA-9-ORANGE-7f3a}"

(( OFFLINE )) && emit_skip "offline"
[[ -f "$FIX" && -f "$PROMPT" && -f "$RUBRIC" ]] || emit_skip "toolkit seam files missing"
command -v jq >/dev/null 2>&1 || emit_skip "jq not available"

# --- keys (env only; never argv) -------------------------------------------
# The model-under-test key: the caller (cmd_sync) has already sourced the keys
# file into this process's env, so ${!KEYVAR} resolves. Re-export under the
# fixed name the Go command reads via --api-key-env.
mkey="${!KEYVAR:-}"
[[ -n "$mkey" ]] || emit_skip "no key in \$$KEYVAR for model under test"
export CMA_PROBE_KEY="$mkey"

# --- judge config (providers/judge.env overrides the template default) ------
JUDGE_ENV="${CMA_JUDGE_ENV:-$LIB_DIR/providers/judge.env}"
[[ -f "$JUDGE_ENV" ]] || JUDGE_ENV="$LIB_DIR/providers/judge.env.template"
# shellcheck source=/dev/null  # runtime judge config, non-secret (holds var NAMES + urls)
[[ -f "$JUDGE_ENV" ]] && { set -a +u; . "$JUDGE_ENV"; set +a; }
JUDGE_BASE="${CMA_JUDGE_BASE_URL:-}"
JUDGE_MODEL="${CMA_JUDGE_MODEL:-}"
JUDGE_KEYVAR="${CMA_JUDGE_KEYVAR:-}"
JUDGE_THRESHOLD="${CMA_JUDGE_THRESHOLD:-2}"
# Judge key: the value under $CMA_JUDGE_KEY (already set by tests) OR ${!JUDGE_KEYVAR}.
jkey="${CMA_JUDGE_KEY:-}"
[[ -z "$jkey" && -n "$JUDGE_KEYVAR" ]] && jkey="${!JUDGE_KEYVAR:-}"
[[ -n "$jkey" && -n "$JUDGE_BASE" && -n "$JUDGE_MODEL" ]] || emit_skip "no round-2 judge configured (see providers/judge.env)"
export CMA_JUDGE_KEY="$jkey"

# --- base-url normalization (the Go command appends /v1/chat/completions) ----
base="${BASEURL:-}"
base="${base%/}"; base="${base%/chat/completions}"; base="${base%/anthropic}"; base="${base%/v1}"
[[ -n "$base" ]] || emit_skip "no base url"

# --- split the toolkit prompt template into round-1 + round-2 ----------------
# The template carries a "Round 1 —" block and a "Round 2 —" block; the Go
# command takes them as two separate flags. Split on the first line starting
# with "Round 2" (a generic delimiter; the wording stays toolkit-owned).
tmp1="$(mktemp "${TMPDIR:-/tmp}/cma-r1.XXXXXX")"
tmp2="$(mktemp "${TMPDIR:-/tmp}/cma-r2.XXXXXX")"
awk 'BEGIN{p=1} /^Round 2/{p=2} p==1{print > R1} p==2{print > R2}' \
    R1="$tmp1" R2="$tmp2" "$PROMPT"

# --- render the rubric into a judge-prompt template (toolkit-owned) ----------
tmpj="$(mktemp "${TMPDIR:-/tmp}/cma-judge.XXXXXX")"
{
  echo "You grade whether a DESCRIPTION accurately reflects some REFERENCE code."
  echo
  echo "REFERENCE code:"
  echo "{{FIXTURE_CONTENT}}"
  echo
  echo "DESCRIPTION to grade:"
  echo "{{DESCRIPTION}}"
  echo
  echo "Score 0-3 using this rubric:"
  jq -r '.criteria | to_entries[] | "  \(.key) = \(.value)"' "$RUBRIC"
  echo "Fixture-specific details a good description names:"
  jq -r '.fixture_specific_details[] | "  - \(.)"' "$RUBRIC"
  echo
  echo "Reply with ONLY the single integer 0, 1, 2, or 3."
} > "$tmpj"

[[ -n "${CMA_SEMANTIC_DEBUG:-}" ]] && cat "$tmpj" >&2

cleanup() { rm -f "$tmp1" "$tmp2" "$tmpj"; }
trap cleanup EXIT

# --- run the command (keys via env, never argv) ------------------------------
mkdir -p "$REPO_ROOT/.local-cache"
set +e
"$DRIVER" \
  --base-url "$base" --model "$MODEL" --api-key-env CMA_PROBE_KEY \
  --fixture "$FIX" --prompt "$tmp1" --round2-prompt "$tmp2" --sentinel "$SENTINEL" \
  --judge-base-url "$JUDGE_BASE" --judge-model "$JUDGE_MODEL" --judge-api-key-env CMA_JUDGE_KEY \
  --judge-prompt "$tmpj" --judge-threshold "$JUDGE_THRESHOLD" \
  --format json >/dev/null 2>"$REPO_ROOT/.local-cache/semantic-last.err"
rc=$?
set -e

case "$rc" in
  0) echo verified;   echo "providers-semantic[$PROVIDER]: layer-3 sentinel+judge PASS" >&2; exit 0 ;;
  1) echo unverified; echo "providers-semantic[$PROVIDER]: layer-3 FAIL (cannot see code / bluffed)" >&2; exit 1 ;;
  *) emit_skip "semantic command config/precondition error (exit $rc)" ;;
esac
