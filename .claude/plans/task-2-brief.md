# Task 2 — Tests: hermetic resolver + sync coverage for Xiaomi MiMo

## Where this fits
`scripts/tests/test_providers.sh` already has resolver tests (Section 2) and an offline
sync e2e test (Section 3) that prove the provider system end-to-end inside a sandbox.
Z.AI (`zai-coding-plan`) is the exact precedent. This task adds the same coverage for
`xiaomi` — but with `native` transport and a deliberate stale-model guard.

## The file to edit
`scripts/tests/test_providers.sh` ONLY. It is hermetic (runs in `make_sandbox`). Do not
touch any other file. Match the file's existing style (the `it "…"` / `assert_eq` /
`rfield` helpers, hermetic fixtures, `set +e` after sourcing lib.sh).

## Exact changes

### Section 2 — add `xiaomi` to the resolver fixture + assertions
The Section 2 fixture catalog is at `$FIX/catalog.json` (currently has `acme`, `beta`,
`zai-coding-plan`). Add a `xiaomi` provider with:
- `env`: `["XIAOMI_API_KEY"]` (NOTE: the catalog env is XIAOMI_API_KEY; the user's KEY
  VAR is XIAOMI_MIMO_API_KEY — the key-aliases fixture maps the latter to the former.
  This deliberately tests the aliasing path, mirroring how the real system works.)
- `api`: `"https://api.xiaomimimo.com/v1"` (the OpenAI-compat URL the catalog carries —
  the override must REPLACE this with the /anthropic URL)
- `npm`: `"@ai-sdk/openai-compatible"` (so the resolver would default to `router` if not
  overridden — the override must force `native`)
- `models`: include a STALE model to prove overrides win:
  ```json
  "mimo-v2.5-pro-ultraspeed": {"id":"mimo-v2.5-pro-ultraspeed","reasoning":true,"tool_call":true,"release_date":"2026-07-01","limit":{"context":1000000},"cost":{"input":0,"output":0}},
  "mimo-v2.5-pro": {"id":"mimo-v2.5-pro","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":1000000},"cost":{"input":2,"output":8}},
  "mimo-v2-flash": {"id":"mimo-v2-flash","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":256000},"cost":{"input":0.1,"output":0.4}}
  ```
  The `ultraspeed` entry is newest+reasoning, so WITHOUT an override the resolver would
  auto-select it as strong. The override must pin `mimo-v2.5-pro` instead. This is the
  exact real-world guard: models.dev lists a stale ultraspeed id the live API rejects.

Also extend the Section 2 `$FIX/key-aliases.json` (currently `{ "LEGACY_BETA_KEY": "beta" }`)
to add the Xiaomi alias:
```json
{ "LEGACY_BETA_KEY": "beta", "XIAOMI_MIMO_API_KEY": "xiaomi" }
```

Add `XIAOMI_MIMO_API_KEY` to the resolver `--keys` argument list in the existing
`python3 "$RESOLVE" …` invocation (currently
`"ACME_API_KEY,BETA_API_KEY,ZAI_API_KEY,LEGACY_BETA_KEY,GITHUB_TOKEN,FOO_API_KEY"`).

Then add these assertions (after the existing zai-coding-plan assertions, using the
existing `rfield` helper and `it "…"` / `assert_eq EXPECTED ACTUAL "label"` idiom):
- `it "xiaomi resolves from the key-alias mapping on XIAOMI_MIMO_API_KEY"`
  - `provider_id == "xiaomi"`
  - `status == "resolved"`
- `it "xiaomi override forces native transport (beats openai-compatible npm)"`
  - `transport == "native"`
- `it "xiaomi override sets the /anthropic base_url (beats catalog /v1)"`
  - `base_url == "https://api.xiaomimimo.com/anthropic"`
- `it "xiaomi strong=mimo-v2.5-pro, fast=mimo-v2-flash (override beats stale ultraspeed)"`
  - `strong_model == "mimo-v2.5-pro"`
  - `fast_model == "mimo-v2-flash"`
- `it "the stale mimo-v2.5-pro-ultraspeed id is never selected"`
  - `[[ "$(rfield "$OUT" XIAOMI_MIMO_API_KEY strong_model)" != "mimo-v2.5-pro-ultraspeed" ]]`
  - `[[ "$(rfield "$OUT" XIAOMI_MIMO_API_KEY fast_model)" != "mimo-v2.5-pro-ultraspeed" ]]`
  - (use assert_eq 0 $? "…" for each)

### Section 3 — add `xiaomi` to the sync e2e fixture + assertions
The Section 3 fixture cache is `$PCACHE` (currently has acme, beta, mistral,
zai-coding-plan). Add a `xiaomi` provider entry (mirror the catalog shape):
```json
"xiaomi":{"env":["XIAOMI_API_KEY"],"api":"https://api.xiaomimimo.com/v1","npm":"@ai-sdk/openai-compatible",
          "models":{"u":{"id":"mimo-v2.5-pro-ultraspeed","reasoning":true,"tool_call":true,"release_date":"2026-07-01","limit":{"context":1000000},"cost":{"input":0,"output":0}},
                    "p":{"id":"mimo-v2.5-pro","reasoning":true,"tool_call":true,"release_date":"2026-06-01","limit":{"context":1000000},"cost":{"input":2,"output":8}},
                    "f":{"id":"mimo-v2-flash","reasoning":true,"tool_call":true,"release_date":"2026-05-01","limit":{"context":256000},"cost":{"input":0.1,"output":0.4}}}}
```
Add `export XIAOMI_MIMO_API_KEY="dummy-xiaomi"` to the fake keys file (`$KEYS`).

IMPORTANT: Section 3 uses the REAL `scripts/providers/key-aliases.json` and
`scripts/providers/overrides.json` (not the $FIX ones) — that's how it proves the actual
shipped config works. So the xiaomi mapping + override added in Task 1 are what make
XIAOMI_MIMO_API_KEY resolve here. (Verify this by reading the existing Section 3 code:
`resolve_records`/`cmd_sync` read `$KEY_ALIASES`/`$OVERRIDES` which point at the real
files.) Do NOT add a separate $KEY_ALIASES/$OVERRIDES override for Section 3.

Add these Section 3 assertions (after the zai-coding-plan sync assertions):
- `it "xiaomi env file created with native transport + /anthropic base + pinned models"`
  - `assert_file "$PDIR/xiaomi.env" "xiaomi env"`
  - `grep -qE "^CMA_PROVIDER_TRANSPORT='?native'?" "$PDIR/xiaomi.env"`
  - `grep -qE "^CMA_PROVIDER_BASE_URL='?https://api.xiaomimimo.com/anthropic'?" "$PDIR/xiaomi.env"`
  - `grep -qE "^CMA_PROVIDER_MODEL='?mimo-v2.5-pro'?" "$PDIR/xiaomi.env"`
  - `grep -qE "^CMA_PROVIDER_FAST_MODEL='?mimo-v2-flash'?" "$PDIR/xiaomi.env"`
- `it "xiaomi alias written via cma_run_provider"`
  - `grep -q '^alias xiaomi="cma_run_provider xiaomi"' "$ALIAS_FILE"`
- `it "xiaomi config dir created and shared items symlinked"`
  - `assert_dir "$HOME/.claude-prov-xiaomi" "xiaomi config dir"`
  - `assert_symlink_to "$HOME/.claude-prov-xiaomi/plugins" "$SHARED_DIR/plugins" "plugins linked"`
- `it "xiaomi provider dir excluded from account detection"`
  - run `det="$(cma_detect_accounts)"`; `echo "$det" | grep -q "prov-xiaomi"`; assert_eq 1 $?

For the "no secret leaked" assertion, extend the existing grep to include `dummy-xiaomi`:
`grep -rq "dummy-acme\|dummy-beta\|dummy-mistral\|dummy-xiaomi" "$PDIR" "$ALIAS_FILE"`.
For the idempotency re-run, no extra work needed (re-sync already proven; the count
assertion uses acme but xiaomi follows the same path).

### Do NOT
- Touch Section 1 (account-detection) — it already covers the prov- prefix generally.
  But you MAY add one line creating a `prov-xiaomi` marker dir at the top of Section 1
  if it cleanly strengthens the existing regression — only if it does not disturb the
  existing acct1/acct2/prov-deepseek/prov-groq setup. If unsure, skip and note it.
- Add zsh smoke-test changes (Section 4 covers the native path via acme generically).
- Modify any file other than `scripts/tests/test_providers.sh`.

## Global constraints
- Hermetic: everything in the sandbox, dummy values only, never touch real ~/.claude*.
- No secrets. No real key values.
- macOS-portable bash (no GNU-only constructs). The existing file already handles this.
- Preserve all existing assertions and their order.

## Validation you MUST run and paste into your report
1. `bash scripts/tests/run-all.sh providers` — MUST be all-pass. Paste the full summary
   (the `==== SUMMARY ====` block + per-file PASS/FAIL + the "X/Y test files passed" line).
2. Count the new `it "…"` assertions you added (should be ~9 across both sections) and
   confirm the total assertion count in the providers test went up accordingly.

## Commit
`test(providers): hermetic resolver+sync coverage for Xiaomi MiMo`
Stage ONLY `scripts/tests/test_providers.sh`. End commit message with:
Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>

## Report
Write your full report to `/Volumes/T7/Projects/claude_tookit/.claude/plans/task-2-report.md`
(sections: Changes [which assertions/fixtures added], Validation [paste the full test
summary], Commit [hash]). Return ONLY: status word, commit hash, one-line summary,
and a one-line note on how many new assertions were added.
