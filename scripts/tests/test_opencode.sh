#!/usr/bin/env bash
# test_opencode.sh — sandboxed unit/integration tests for
# claude-opencode-sync.sh + opencode_sync.py.
#
# Builds a fake Claude plugin cache inside a throwaway $HOME and asserts the
# generated OpenCode config has the right shape: skills wired, MCP servers
# translated (wrapped + bare formats), dedup, collision-rename, secret/runtime
# enable gating, ${CLAUDE_PLUGIN_ROOT} expansion, instruction inclusion,
# preservation of pre-existing config, idempotency, and --dry-run safety.
#
# No network, no real ~/.claude, no real opencode binary required.

set -euo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="${SCRIPTS_DIR:-$(cd "$TESTS_DIR/.." && pwd)}"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
set +e   # let failing-by-design assertions report instead of aborting

SYNC="$SCRIPTS_DIR/claude-opencode-sync.sh"

# make_plugin NAME VERSION  — create $PLUGINS/NAME/VERSION and echo its path.
make_plugin() {
  local dir="$PLUGINS/$1/$2"
  mkdir -p "$dir"
  echo "$dir"
}
# add_skill PLUGIN_DIR SKILL_NAME
add_skill() {
  mkdir -p "$1/skills/$2"
  printf -- '---\nname: %s\ndescription: test skill %s\n---\n# %s\n' \
    "$2" "$2" "$2" > "$1/skills/$2/SKILL.md"
}
# add_mcp PLUGIN_DIR JSON  — write a .mcp.json verbatim
add_mcp() { printf '%s\n' "$2" > "$1/.mcp.json"; }

run_sync() {
  OPENCODE_CONFIG="$OC_CFG" \
  CLAUDE_PLUGINS_DIR="$PLUGINS" \
  SHARED_DIR="$HOME/.claude-shared" \
  OPENCODE_ALLOWLIST="$ALLOW" \
  bash "$SYNC" "$@"
}

# ----------------------------------------------------------------------------
make_sandbox
PLUGINS="$HOME/plugins"
OC_CFG="$HOME/.config/opencode/opencode.json"
mkdir -p "$PLUGINS" "$HOME/.claude-shared"
printf '# shared memory\n' > "$HOME/.claude-shared/CLAUDE.md"

# Pre-existing OpenCode config that MUST survive untouched.
mkdir -p "$(dirname "$OC_CFG")"
cat > "$OC_CFG" <<'JSON'
{
  "$schema": "https://opencode.ai/config.json",
  "provider": { "lmstudio": { "npm": "x", "name": "Local" } },
  "mcp": { "codegraph": { "type": "local", "command": ["codegraph"], "enabled": true } }
}
JSON

# --- fake plugins ---------------------------------------------------------
# docsy: a skill + a wrapped-format remote docs server (no auth).
p="$(make_plugin docsy 1.0.0)"
add_skill "$p" alpha
add_skill "$p" beta
add_mcp "$p" '{"mcpServers":{"docsy-docs":{"type":"http","url":"https://docs.example.com/mcp"}}}'

# toolsy: bare-format local server using python3 (always present runtime).
p="$(make_plugin toolsy 2.0.0)"
add_mcp "$p" '{"toolsy":{"command":"python3","args":["-c","print(1)"]}}'

# secretsy: local server requiring an unresolved secret env -> never auto-enabled.
p="$(make_plugin secretsy 1.0.0)"
# shellcheck disable=SC2016  # ${API_KEY} is a literal placeholder in JSON, not a shell variable
add_mcp "$p" '{"mcpServers":{"secretsy":{"command":"python3","args":["x"],"env":{"API_KEY":"${API_KEY}"}}}}'

# rooty: uses ${CLAUDE_PLUGIN_ROOT} which must be expanded to the install path.
p="$(make_plugin rooty 1.0.0)"
ROOTY_DIR="$p"
# shellcheck disable=SC2016  # ${CLAUDE_PLUGIN_ROOT} is a literal placeholder in JSON expanded at runtime
add_mcp "$p" '{"rooty":{"command":"python3","args":["${CLAUDE_PLUGIN_ROOT}/serve.py"]}}'

# dup-a / dup-b: identical remote url -> must dedup to one entry.
p="$(make_plugin dup-a 1.0.0)"; add_mcp "$p" '{"dupsrv":{"type":"http","url":"https://same.example.com/mcp"}}'
p="$(make_plugin dup-b 1.0.0)"; add_mcp "$p" '{"dupsrv":{"type":"http","url":"https://same.example.com/mcp"}}'

# clash-a / clash-b: same server NAME, different config -> second gets renamed.
p="$(make_plugin clash-a 1.0.0)"; add_mcp "$p" '{"clash":{"type":"http","url":"https://a.example.com/mcp"}}'
p="$(make_plugin clash-b 1.0.0)"; add_mcp "$p" '{"clash":{"type":"http","url":"https://b.example.com/mcp"}}'

# Allow the two no-secret servers + the secret one (to prove secret gating wins).
ALLOW=$'docsy/docsy-docs\ntoolsy/toolsy\nsecretsy/secretsy'

# ==========================================================================
it "generates a valid OpenCode config"
run_sync --no-backup >/dev/null 2>&1
assert_file "$OC_CFG" "config written"
if jq -e . "$OC_CFG" >/dev/null 2>&1; then _pass "valid JSON"; else _fail "valid JSON"; fi

it "preserves pre-existing provider and mcp entries"
assert_jq "$OC_CFG" '.provider.lmstudio.name' 'Local' "provider kept"
assert_jq "$OC_CFG" '.mcp.codegraph.enabled' 'true' "existing mcp kept"

it "wires skill folders into skills.paths"
assert_jq "$OC_CFG" '.skills.paths | map(select(endswith("docsy/1.0.0/skills"))) | length' '1' "docsy skills path present"

it "includes the shared CLAUDE.md as an instruction"
assert_jq "$OC_CFG" '.instructions | map(select(endswith(".claude-shared/CLAUDE.md"))) | length' '1' "instructions wired"

it "translates a wrapped-format remote server and enables it (allowlisted, no auth)"
assert_jq "$OC_CFG" '.mcp["docsy-docs"].type' 'remote' "remote type"
assert_jq "$OC_CFG" '.mcp["docsy-docs"].url'  'https://docs.example.com/mcp' "remote url"
assert_jq "$OC_CFG" '.mcp["docsy-docs"].enabled' 'true' "remote enabled"

it "translates a bare-format local server and enables it (runtime present)"
assert_jq "$OC_CFG" '.mcp.toolsy.type' 'local' "local type"
assert_jq "$OC_CFG" '.mcp.toolsy.command[0]' 'python3' "local command"
assert_jq "$OC_CFG" '.mcp.toolsy.enabled' 'true' "local enabled"

it "keeps a secret-requiring server DISABLED even when allowlisted"
assert_jq "$OC_CFG" '.mcp.secretsy.enabled' 'false' "secret gated off"
# shellcheck disable=SC2016  # ${API_KEY} is the literal JSON value to assert against, not a shell var
assert_jq "$OC_CFG" '.mcp.secretsy.environment.API_KEY' '${API_KEY}' "secret env retained"

it "expands \${CLAUDE_PLUGIN_ROOT} to the real install path"
assert_jq "$OC_CFG" '.mcp.rooty.command[1]' "$ROOTY_DIR/serve.py" "plugin root expanded"
assert_jq "$OC_CFG" '.mcp.rooty.command | map(select(contains("CLAUDE_PLUGIN_ROOT"))) | length' '0' "no leftover placeholder"

it "deduplicates identical servers across plugins"
assert_jq "$OC_CFG" '[.mcp | to_entries[] | select(.value.url=="https://same.example.com/mcp")] | length' '1' "single deduped entry"

it "renames a colliding server name (different config)"
assert_jq "$OC_CFG" '.mcp.clash.url' 'https://a.example.com/mcp' "first keeps name"
assert_jq "$OC_CFG" '.mcp["clash-b-clash"].url' 'https://b.example.com/mcp' "second renamed"

it "is idempotent (server count stable across re-runs)"
before="$(jq '.mcp | length' "$OC_CFG")"
run_sync --no-backup >/dev/null 2>&1
run_sync --no-backup >/dev/null 2>&1
after="$(jq '.mcp | length' "$OC_CFG")"
assert_eq "$before" "$after" "mcp count stable"
dupes="$(jq -r '.skills.paths | (length - (unique | length))' "$OC_CFG")"
assert_eq "0" "$dupes" "no duplicate skill paths"

it "--dry-run writes nothing"
rm -f "$OC_CFG"
run_sync --dry-run >/dev/null 2>&1
if [[ ! -f "$OC_CFG" ]]; then _pass "dry-run left no file"; else _fail "dry-run wrote a file"; fi

it "--enable-all turns on a normally-disabled server"
# Rebuild a fresh config, then enable everything.
cat > "$OC_CFG" <<'JSON'
{ "$schema": "https://opencode.ai/config.json" }
JSON
run_sync --no-backup --enable-all >/dev/null 2>&1
assert_jq "$OC_CFG" '.mcp.clash.enabled' 'true' "enable-all enabled clash"
assert_jq "$OC_CFG" '[.mcp[] | select(.enabled==false)] | length' '0' "nothing left disabled"

it "creates a timestamped backup when overwriting"
run_sync >/dev/null 2>&1   # default: backup on
shopt -s nullglob
baks=( "$OC_CFG".bak.* )
if (( ${#baks[@]} >= 1 )); then _pass "backup created (${#baks[@]})"; else _fail "no backup created"; fi

summary
