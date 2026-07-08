# Toolkit proof of work

- generated: `2026-07-08T17:56:14+0500`
- host: `Linux 6.12.41-6.12-alt1 x86_64`

## Sandbox suite (hermetic, no network)
```
Test files: 20   passed: 20   failed: 0 ALL GREEN 
```
exit code: `0`  ·  full log: [40-sandbox-suite.log](40-sandbox-suite.log)

## Live OpenCode verification (real binary + real config)
```
# OpenCode live verification proof
generated: 2026-06-26T18:37:33+0300
host:      Darwin 24.5.0 arm64
opencode:  1.16.2
config:    /Users/milosvasic/.config/opencode/opencode.json
mcp_total=136 mcp_enabled=8 skill_paths=145
skills_resolved=1237 (threshold 200)
mcp_connected=27 mcp_failed=0
instructions=1

result: see PASS/FAIL tally below
```
result: `SKIP: opencode not installed on this host — live verification skipped.`  ·  exit code: `0`

## Live provider-alias verification (real installed state)
```
✓ 30 passed, 0 failed
```
exit code: `0`  ·  evidence: [50-providers-live.txt](50-providers-live.txt)

## Live alias verification (real provider + Claude aliases)
```
PASS: 4 FAIL: 15 TOTAL: 19
```
exit code: `15`  ·  full log: [43-live-aliases.log](43-live-aliases.log)  ·  evidence: [alias-verify-evidence.txt](alias-verify-evidence.txt)

Artifacts: `10-debug-config.json`, `21-skill-names.txt`, `31-mcp-list.clean.txt`, `50-providers-live.txt`, `43-live-aliases.log`.
