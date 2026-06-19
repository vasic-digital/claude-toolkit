# Toolkit proof of work

- generated: `2026-06-19T21:21:17+0300`
- host: `Darwin 24.5.0 arm64`

## Sandbox suite (hermetic, no network)
```
Test files: 8   passed: 8   failed: 0 ALL GREEN 
```
exit code: `0`  ·  full log: [40-sandbox-suite.log](40-sandbox-suite.log)

## Live OpenCode verification (real binary + real config)
```
# OpenCode live verification proof
generated: 2026-06-19T21:21:32+0300
host:      Darwin 24.5.0 arm64
opencode:  1.16.2
config:    /Users/milosvasic/.config/opencode/opencode.json
mcp_total=20 mcp_enabled=1 skill_paths=0
skills_resolved=7 (threshold 200)
mcp_connected=20 mcp_failed=0
instructions=0

result: see PASS/FAIL tally below
```
result: `✗ 2 failed, 7 passed`  ·  exit code: `1`

## Live provider-alias verification (real installed state)
```
✓ 5 passed, 0 failed
```
exit code: `0`  ·  evidence: [50-providers-live.txt](50-providers-live.txt)

Artifacts: `10-debug-config.json`, `21-skill-names.txt`, `31-mcp-list.clean.txt`, `50-providers-live.txt`.
