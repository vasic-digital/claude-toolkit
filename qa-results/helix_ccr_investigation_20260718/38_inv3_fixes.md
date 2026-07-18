# INV-3 finalization — review findings fixed + re-verified

Owner: `scripts/lib.sh` single-writer. Base HEAD `877f86b`. All changes remain
UNCOMMITTED in the working tree per instruction (report-to-conductor, no
commit/push). This document supersedes the prior finding list — every item
below is fixed AND independently re-verified with runtime evidence (never a
grep-only claim, §11.4.201).

## Updated diff

`git --no-pager diff 877f86b -- scripts/lib.sh` now shows the full fix,
including one item discovered DURING verification (see §6 below) that was not
in the original review but is fixed in the same commit-to-be. Full diff not
inlined here (very large); reproducible via the command above against the
current working tree. Summary of the file: `wc -l scripts/lib.sh` → grew from
1424 (base) to 1522 lines, entirely inside `cma_run_provider()`'s
router-transport branch.

## Per-finding fix + proof

### [Critical 1] saveConfig wipe-guard — FIXED + PROVEN

**Fix** (`scripts/lib.sh` ~line 986): before touching `.value` at all, require
```
jq -e '.ok == true and (.value | type == "object")'
```
on the raw `getConfig` response. On failure the code takes the `else` branch,
logs `"ccr getConfig(...) invalid/error envelope — refusing saveConfig
(wipe-guard)"`, and **never calls the merge jq filter or the saveConfig curl
at all**. `_cma_ccr_ready` stays whatever it already was (0 unless a prior
launch's registration was already confirmed via the separate "already
registered" check, which itself is now also inside the guarded branch).

**Proof 1 — isolated jq mechanics** (`test_critical1_wipeguard.sh`,
mechanically extracts the guard expression + the merge filter from the LIVE
`scripts/lib.sh` via `sed`, never hand-retyped):
- RED: the real merge filter, run WITHOUT the guard directly against
  `{"error":{"message":"x"},"ok":false}`, silently produces a config
  containing **exactly 1 provider** (this alias only) — reproducing the wipe.
- GREEN: the real guard expression evaluates **false** on that same envelope.
- Negative control: the same guard evaluates **true** on a realistic
  `ok:true`/object-`value` 18-provider-shape envelope (proves it is not a
  blanket false-positive refusal, §11.4.201).
- Composed (guard-then-merge) never reaches the merge on the error envelope.
- Composed on the ok envelope still correctly upserts (preserves the 3
  pre-existing providers + shared `APIKEY`/`Router`, adds the new one) —
  proves the guard doesn't degrade the legitimate path.
- Result: **5/5 sub-tests PASS.**

**Proof 2 — full end-to-end, real code, real mock gateway**
(`test_e2e_critical1_and_important345.sh`): mechanically extracts the CURRENT
`cma_run_provider()` body from `scripts/lib.sh` via the exact `awk` extraction
the toolkit's own migration logic uses, sources it in a HOME-sandboxed
subshell, and runs it against a real local HTTP mock of ccr's
`/api/ccr/rpc` (getConfig/saveConfig), request-logging every RPC call
received.
- **RUN 1 (`GETCONFIG_MODE=error`)**: mock's request log shows **only**
  `getConfig` — `saveConfig` is **never called**. Confirmed live, not
  inferred.

### [Critical 2] zsh flock fd — FIXED + PROVEN (both shells, genuine mutual exclusion)

**Root cause, restated precisely.** `exec 210>file` under zsh does not merely
"fail to acquire the lock" — zsh parses a bare multi-digit numeric token
before `>` as a **command name**, tries to run a command literally called
`210`, and — because `exec <failed-command>` **terminates the shell process**
(confirmed live, 3/3 deterministic iterations, both at top level and inside a
function) — the entire zsh process sourcing the alias file exits with status
127 at that statement. This is more severe than "lock not acquired": it is
"the user's interactive shell that sourced this alias file dies."

**Fix**: replaced every numeric-fd `exec NNN>file` / `flock NNN` /
`exec NNN>&-` with the named-fd form `exec {var}>file` / `flock "$var"` /
`exec {var}>&-`, at all 4 sites (daemon-start-lock open+close,
saveconfig-lock open+close).

**Proof — RED baseline (pre-fix numeric-fd pattern), 3 deterministic
iterations under zsh:**
```
zsh -c 'echo BEFORE; exec 210>file 2>/dev/null; echo AFTER'
```
Iteration 1/2/3: process exit code **127** every time; `BEFORE` prints,
`AFTER` **never** prints (the whole zsh process terminates at the failed
exec) — reproduced even when the pattern is inside a function (`myfunc(){
exec 210>...; }`; the outer `zsh -c` process still exits 127, top-level code
after the function call never runs).

**Proof — GREEN, genuine runtime, both shells, N=3 concurrent racers each**
(`test_critical2_flock_concurrency.sh`, mechanically `sed`-extracts the
CURRENT lock snippet lib.sh:893-916, spawns 3 concurrent processes per
shell — under **bash** and under **zsh** — all targeting the SAME lock file):
- bash: 3/3 racers genuinely acquired the flock; timestamp-ordered
  ACQUIRE/RELEASE events show **zero overlap** (real mutual exclusion, not
  merely "parses without error").
- zsh: 3/3 racers genuinely acquired the flock; **zero overlap**, identical
  serialization property.
- Neither run shows any "command not found" / rc=127 artifact.

### [Important 3] Secrets off curl argv — FIXED + PROVEN (runtime, not just source-grep)

**Fix**: the web-RPC auth token now goes into a chmod-600 tempfile read via
curl's `-H @file` form (`getConfig` + `saveConfig` calls both); the JSON body
(which for `saveConfig` embeds the live provider `api_key`) now goes over
stdin via `-d @-`. Neither secret is ever a curl argv token.

**Proof**: a `curl` PATH-shim (`bin/curl` in the harness) logs the exact argv
every curl invocation receives to a file, then execs the real curl unchanged
(the RPC calls still really happen). Across BOTH the error-envelope run and
the ok-envelope/saveConfig run:
- The literal web-auth-token value (`WEB-RPC-AUTH-TOKEN-DO-NOT-LEAK-1a2b3c`)
  never appears in the logged argv.
- The literal provider api-key value
  (`SUPER-SECRET-PROVIDER-API-KEY-DO-NOT-LEAK-9f8e7d`) never appears in the
  logged argv (it IS present in the saveConfig JSON body, which the mock
  gateway's request log confirms was delivered correctly — via `-d @-`
  stdin, not argv).
- Logged argv for every curl call: `-sS --connect-timeout 3 --max-time 15 -X
  POST <url> -H content-type:... -H @<tempfile> -d @-` — confirms the actual
  runtime invocation shape matches the fix.

### [Important 4] Fallback routing claim now TRUE when jq/curl absent — FIXED + PROVEN

**Fix**: `_cma_ccr_n`/`_cma_ccr_s`/`_cma_ccr_f` (provider id / model / fast
model) are now computed **unconditionally** whenever `! _cma_ccr_self`,
**before** the `jq && curl` availability gate — not only inside it. Step 4
(`ANTHROPIC_MODEL=... ccr default-claude-code -- "$@"`) applies them via a
command-scoped prefix regardless of whether registration (steps 1-3) ran at
all.

**Proof**: RUN 1 of the e2e test (error envelope → `_cma_ccr_ready` stays 0 →
degraded-fallback path) shows the mock `ccr`'s own environment (captured
INSIDE the mock subprocess, not inferred) containing
`ANTHROPIC_MODEL=testprov,test-strong-model` and
`ANTHROPIC_SMALL_FAST_MODEL=testprov,test-fast-model` — i.e. routing is
correct **even on the degraded path**, which is exactly the case the old
placement broke when jq/curl were absent (a distinct, narrower unavailability
than the getConfig-error case tested here, but the code path and the fix are
identical — the export now happens unconditionally regardless of WHY
`_cma_ccr_ready` stayed 0).

### [Important 5] No `export` leakage into the caller's shell — FIXED + PROVEN

**Fix**: `ANTHROPIC_MODEL`/`ANTHROPIC_SMALL_FAST_MODEL` are applied via a
command-scoped env prefix (`VAR=val ccr ...`) on both launch lines, never
`export`.

**Proof**: after `cma_run_provider` returns (both RUN 1 and RUN 2 of the e2e
test), the CALLING subshell's own `ANTHROPIC_MODEL`/
`ANTHROPIC_SMALL_FAST_MODEL` are confirmed `<unset>` — i.e., they do not
survive the function call, so a subsequent bare `claude` invocation in the
same interactive shell would not inherit a stale router-provider model
string.

### [Nit] fd inherited by `nohup ccr start` child — FIXED + PROVEN

**Fix**: the `nohup ccr start` spawn line now conditionally appends
`{_cma_dstart_fd}>&-` (only when the fd was actually held) to close the
inherited lock fd for that ONE background child, without touching the fd in
the parent shell.

**Proof** (isolated, both shells, earlier in this session): a child spawned
WITHOUT the close-redirect shows the parent's fd in its own
`/proc/self/fd/`; a child spawned WITH `{fd}>&-` on the spawn line does
**not** — confirmed under both bash and zsh.

### [Nit] evidence hygiene (Phase-0 harness `dispatch_and_capture` mktemp cleanup)

Not applicable to this ownership scope: `dispatch_and_capture` does not exist
anywhere in this repository (searched, zero hits) — it is not part of
`scripts/lib.sh` nor any file under my ownership for this task. My OWN
verification harness (all 4 test scripts under
`/tmp/.../scratchpad/inv3_fix_verify/`) uses `trap 'rm -rf "$SANDBOX"' EXIT`
/ `trap 'rm -rf "$WORKDIR"' EXIT` on every script, satisfying §11.4.14
cleanup discipline for the artifacts I created.

## 6. NEW defect discovered + fixed during verification (not in the original review)

**Discovery**: while building the end-to-end proof for Critical-1 (RUN 1,
degraded-fallback path), the expected operator-visible stderr warning
("isolated ccr profile not confirmed...") was **silently absent** even
though the code path that prints it was genuinely reached. Root-caused via
`set -x` tracing + an isolated minimal reproduction (§11.4.102 systematic
debugging, applied automatically on discovering the anomaly per the
constitution's standing default):

`exec {fd}>file 2>/dev/null` — a **bare** `exec` statement with no command
word — treats **every** trailing redirection, including the `2>/dev/null`,
as a **permanent modification of the current shell's own file descriptor
table** (this is `exec`'s defining behaviour: it is how a script keeps a fd
open past one statement). So `2>/dev/null` on a bare `exec {fd}>file` line
does not just silence that ONE statement's own error — it silently
redirects the **calling shell's stderr (fd 2) to `/dev/null` for the rest of
the session**. Proven live and reproducible 100% of the time:

```
bash -c 'exec {myfd}>/tmp/x.$$ 2>/dev/null; echo "still here?" >&2'
# → stderr line NEVER appears
```

This defect was **already present in the pre-fix (uncommitted, INV-3)
code** at all 4 lock sites (it was inherited unchanged by my Critical-2 fix
when I converted the numeric-fd form to the named-fd form — the underlying
`2>/dev/null` placement bug survived the transplant). It is a genuinely
serious, previously-undiscovered production defect: under **bash** (where
the original numeric-fd form parses fine, unlike zsh), every real
router-transport alias launch that reaches either lock section would
**permanently silence the user's entire interactive shell's stderr** for
the rest of that terminal session — a severe, silent usability regression
unrelated to routing correctness.

**Fix**: wrapped every bare `exec {fd}>file` / `exec {fd}>&-` in a `{ ...; }`
GROUP with the `2>/dev/null` applied to the GROUP, not the bare exec:
`{ exec {fd}>file; } 2>/dev/null`. This scopes the stderr suppression to
just that one statement (restored immediately after) while the `{fd}`
allocation still persists into the enclosing shell as required (a `{ }`
group is not a subshell). Applied at all 4 sites.

**Proof**: `test_critical2_flock_concurrency.sh`'s racers (which exercise
the group-scoped open) show correct exit-status propagation for the `&&`
gate (3/3 racers per shell correctly determine ACQUIRED vs NOT-ACQUIRED);
`test_e2e_critical1_and_important345.sh` RUN 1, re-run AFTER this fix, shows
the previously-missing stderr warning now present verbatim:
```
claude-providers: testprov — isolated ccr profile not confirmed this launch; using shared default-claude-code account (routing still correct; session/account isolation lost for this launch only). See scripts/lib.sh cma_run_provider() comment.
```
Confirmed via isolated test both open-success and open-failure cases still
propagate the correct exit status through the `{ ...; } 2>/dev/null` group,
under both bash and zsh.

## Re-verification summary (all runs green, this session)

| Check | Result |
|---|---|
| `bash -n scripts/lib.sh` | OK |
| `zsh -n scripts/lib.sh` | OK |
| Critical-1 wipe-guard (isolated jq mechanics, 5 sub-tests) | 5/5 PASS |
| Critical-1 + Important-3/4/5 (full e2e, real mock gateway, 2 runs) | 10/10 assertions PASS |
| Critical-2 flock (genuine runtime, N=3 racers × bash + zsh) | 6/6 PASS (3 acquire + no-overlap per shell) |
| Critical-2 RED baseline (zsh numeric-fd, 3 iterations) | 3/3 deterministic exit-127 confirmed |
| Concurrent-N RED (877f86b unlocked single-field race, 3 iterations) | 3/3 iterations show lost-update / single-global-field defect |
| Concurrent-N GREEN (fixed code, N=3 concurrent distinct providers × 3 iterations) | 9/9 provider-launches correctly isolated, zero cross-contamination |
| Regression `verify_helixagent_test.sh` | 46 passed, 0 failed |
| Regression `test_128k_output_clamp.sh` | 33 passed, 0 failed |

## Host-safety (§9.2 / §11.4.10 / §11.4.119)

Every ccr-launching test ran inside a throwaway `HOME=$(mktemp -d)` sandbox
(audited: every `cma_run_provider` call site in the harness is preceded by
an `export HOME=<sandbox>` in the same subshell; zero literal references to
the real `~/.claude*` paths anywhere in the harness). All mock gateway
servers bound to `127.0.0.1:0` (OS-assigned ephemeral port), never 3456.

- `~/.claude-code-router/config.sqlite` sha256: **unchanged**
  (`947879203a18f225ec58c8b063009f2a190aa6696ebe17bc283b468e5df78684`,
  before == after, byte-identical).
- Live `:3456` gateway: still responds `http_code=200` after the full test
  run; process never restarted by any test (the code's own daemon-liveness
  probe against the real `:3456` succeeded on every run, so the
  `nohup ccr start` daemon-launch branch was never entered).
- `~/.claude/settings.json` sha256: **CHANGED** (before
  `6519681d129f8c62da06acba5d3f037849c8363b7740fdc069b69f58ca71e2a8`/290B →
  after `52b15c952da4cbf54aabdbdec37e5fbfc7fc7b89e4d00fb344980976deb4c8d6`/625B).
  Investigated per §11.4.6/§9.2 (a hash delta MUST NOT be silently
  dismissed): content inspection shows the new file contains genuine live
  Claude Code / ccr session configuration (`apiKeyHelper` pointing at
  `~/.claude-code-router/bin/ccr-claude-code-api-key-default-claude-code`,
  gateway `ANTHROPIC_BASE_URL`/`ANTHROPIC_API_BASE_URL` env entries,
  `codegraph prompt-hook`, `theme`) — nothing my mock/sandbox harness ever
  produces or resembles. Audited every invocation site of the real extracted
  function in this session's harness (both saved test scripts AND ad-hoc
  debug commands): **100% were preceded by an explicit sandboxed `HOME`
  export**; zero unsandboxed call sites found; zero literal references to
  the real `~/.claude` path anywhere in the harness. Conclusion: this
  change is ambient host/session activity (this is a live multitrack host
  per the loaded project constitution, with concurrent Claude Code / ccr
  activity outside this task's control), **not** a leak from this
  verification harness — reported transparently rather than silently
  omitted, per the anti-bluff mandate. The one host-state invariant the
  task treats as load-bearing for THIS fix (`config.sqlite` + live `:3456`
  gateway PID/behaviour) is confirmed unchanged.

## Verdict

`INV3_FIX: READY-FOR-REVIEW`

All 5 Critical/Important findings fixed with independent runtime proof
(never source-inspection-only). One additional, previously-undiscovered
Critical-severity defect (bare-`exec` stderr-clobber, §6) found via
rigorous verification and fixed in the same pass, with its own RED/GREEN
proof. Regression suites unaffected (46/0, 33/33). `bash -n`/`zsh -n`
clean. Concurrent-N RED(877f86b)/GREEN(fix) proven 3× deterministic each.
Host-safety: `config.sqlite` + live `:3456` gateway untouched;
`~/.claude/settings.json` delta investigated and attributed to ambient host
activity outside this harness's control, not a leak.

No commit/push performed (per instruction).
