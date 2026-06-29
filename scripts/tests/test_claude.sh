#!/usr/bin/env bash
# test_claude.sh — prove claudeN aliases are untouched by provider code.
set +e
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TESTS_DIR/lib/assert.sh"

ALIAS_FILE="$HOME/.local/share/claude-multi-account/aliases.sh"
[[ -f "$ALIAS_FILE" ]] || { echo "SKIP: no alias file"; exit 0; }

# Extract a full wrapper body. A fixed `grep -A<N>` window silently missed
# markers near the end once the cma_run body grew (apply-color, v1.10.0) — the
# push call slipped past -A30. Anchor on the function header and stop at its
# closing brace (column-0 `}`), like the other suites do.
_cma_run_body()  { awk '/^cma_run\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE"; }
_cma_prov_body() { awk '/^cma_run_provider\(\) ?\{/{f=1} f{print} f&&/^}/{exit}' "$ALIAS_FILE"; }

test_claude() {
  it "cma_run has sync-state pull"
  _cma_run_body | grep -q 'claude-sync-state.*pull'
  assert_eq 0 $? "cma_run has pull"

  it "cma_run has sync-state push"
  _cma_run_body | grep -q 'claude-sync-state.*push'
  assert_eq 0 $? "cma_run has push"

  it "cma_run has NO proxy code"
  _cma_run_body | grep -q '_proxy_script\|_proxy_pid\|cleancache\|streamoptions'
  assert_eq 1 $? "cma_run clean: no proxy code"

  it "cma_run has NO transformer code"
  _cma_run_body | grep -q 'transformer'
  assert_eq 1 $? "cma_run clean: no transformer"

  it "cma_run_provider has proxy detection"
  _cma_prov_body | grep -q '_proxy_script\|_proxy_pid'
  assert_eq 0 $? "cma_run_provider has proxy detection"

  for a in claude1 claude2 claude3; do
    it "$a uses cma_run (not cma_run_provider)"
    grep "^alias $a=" "$ALIAS_FILE" | grep -q 'cma_run"'
    assert_eq 0 $? "$a uses cma_run"
  done

  for a in poe deepseek xiaomi; do
    it "$a uses cma_run_provider"
    grep "^alias $a=" "$ALIAS_FILE" | grep -q 'cma_run_provider'
    assert_eq 0 $? "$a uses cma_run_provider"
  done
}

test_claude
summary
