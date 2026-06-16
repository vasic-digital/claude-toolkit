#!/usr/bin/env bash
# run-proof.sh — one command that produces rock-solid, physical evidence the
# whole toolkit works: it runs the hermetic sandbox suite AND the live
# OpenCode verification, then writes a dated PROOF.md tying the two together.
#
# Exit code is 0 only if BOTH the sandbox suite and the live verification pass.
# The live verification SKIPs (counts as pass) when opencode is absent.

set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROOF_DIR="${PROOF_DIR:-$TESTS_DIR/proof}"
mkdir -p "$PROOF_DIR"
STAMP="$(date '+%Y-%m-%dT%H:%M:%S%z')"

SAND_LOG="$PROOF_DIR/40-sandbox-suite.log"
LIVE_LOG="$PROOF_DIR/41-live-verify.log"

echo "==> sandbox test suite"
bash "$TESTS_DIR/run-all.sh" 2>&1 | tee "$SAND_LOG"
sand_rc=${PIPESTATUS[0]}

echo
echo "==> live OpenCode verification"
bash "$TESTS_DIR/verify_opencode_live.sh" 2>&1 | tee "$LIVE_LOG"
live_rc=${PIPESTATUS[0]}

echo
echo "==> live provider-alias verification"
PROV_LOG="$PROOF_DIR/42-live-providers.log"
bash "$TESTS_DIR/verify_providers_live.sh" 2>&1 | tee "$PROV_LOG"
prov_rc=${PIPESTATUS[0]}

# Distil the tallies for the report.
# Strip ANSI colour so the distilled report is clean plain text.
strip_ansi() { sed -E 's/\x1b\[[0-9;]*m//g'; }
sand_line="$(grep -E 'Test files:|ALL GREEN' "$SAND_LOG" | tail -2 | strip_ansi | tr '\n' ' ')"
live_line="$(grep -E '[0-9]+ passed|SKIP:' "$LIVE_LOG" | tail -1 | strip_ansi)"
prov_line="$(grep -E '[0-9]+ passed|SKIP:' "$PROV_LOG" | tail -1 | strip_ansi)"

{
  echo "# Toolkit proof of work"
  echo
  echo "- generated: \`$STAMP\`"
  echo "- host: \`$(uname -srm)\`"
  echo
  echo "## Sandbox suite (hermetic, no network)"
  echo '```'
  echo "$sand_line"
  echo '```'
  echo "exit code: \`$sand_rc\`  ·  full log: [40-sandbox-suite.log](40-sandbox-suite.log)"
  echo
  echo "## Live OpenCode verification (real binary + real config)"
  echo '```'
  sed -n '1,200p' "$PROOF_DIR/00-summary.txt" 2>/dev/null
  echo '```'
  echo "result: \`$live_line\`  ·  exit code: \`$live_rc\`"
  echo
  echo "## Live provider-alias verification (real installed state)"
  echo '```'
  echo "$prov_line"
  echo '```'
  echo "exit code: \`$prov_rc\`  ·  evidence: [50-providers-live.txt](50-providers-live.txt)"
  echo
  echo "Artifacts: \`10-debug-config.json\`, \`21-skill-names.txt\`," \
       "\`31-mcp-list.clean.txt\`, \`50-providers-live.txt\`."
} > "$PROOF_DIR/PROOF.md"

echo
echo "============================================"
echo "PROOF written to $PROOF_DIR/PROOF.md"
echo "sandbox rc=$sand_rc   live rc=$live_rc   providers rc=$prov_rc"
if (( sand_rc == 0 && live_rc == 0 && prov_rc == 0 )); then
  echo "ALL GREEN — evidence is in $PROOF_DIR"
  exit 0
fi
echo "FAILURES PRESENT — inspect logs in $PROOF_DIR"
exit 1
