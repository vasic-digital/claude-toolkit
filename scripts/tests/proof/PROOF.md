# Toolkit proof of work

- generated: `2026-07-18T13:35:56+0300`
- host: `Linux 6.12.61-6.12-alt1 x86_64`

## Sandbox suite (hermetic, no network)
```
Test files: 24   passed: 24   failed: 0 ALL GREEN 
```
exit code: `0`  ·  full log: [40-sandbox-suite.log](40-sandbox-suite.log)

## Live OpenCode verification (real binary + real config)
```
# OpenCode live verification proof
generated: 2026-07-18T13:37:22+0300
host:      Linux 6.12.61-6.12-alt1 x86_64
opencode:  1.17.11
config:    /home/milosvasic/.config/opencode/opencode.json
mcp_total=150 mcp_enabled=9 skill_paths=174
skills_resolved=1432 (threshold 200)
mcp_connected=29 mcp_failed=0
instructions=1

result: see PASS/FAIL tally below
```
result: `✓ 9 passed, 0 failed`  ·  exit code: `0`

## Live provider-alias verification (real installed state)
```
✓ 51 passed, 0 failed
```
exit code: `0`  ·  evidence: [50-providers-live.txt](50-providers-live.txt)

## Live alias verification (real provider + Claude aliases)
```
PASS: 28 FAIL: 0 SKIP-QUOTA: 5 SKIP-TRANSIENT: 1 SKIP-GATED: 2 TOTAL: 36
```
exit code: `0`  ·  full log: [43-live-aliases.log](43-live-aliases.log)  ·  evidence: [alias-verify-evidence.txt](alias-verify-evidence.txt)

## Live alias end-to-end verification (provider endpoints)
```
  "total": 33,   "passed": 24,   "failed": 0, 
```
exit code: `0`  ·  full log: [44-alias-e2e.log](44-alias-e2e.log)

## Constitution / conformance static checks (Tier C)
```
✓ 5 passed, 0 failed
```
exit code: `0`  ·  full log: [45-constitution.log](45-constitution.log)  ·  evidence: [45-constitution.txt](45-constitution.txt)

Artifacts: `10-debug-config.json`, `21-skill-names.txt`, `31-mcp-list.clean.txt`, `50-providers-live.txt`, `43-live-aliases.log`, `44-alias-e2e.log`, `45-constitution.log`, `45-constitution.txt`.
