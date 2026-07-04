# Provider Verification Overhaul — Implementation Plan (Phase 1: toolkit-side)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Persist per-provider verification status, split `list` into `list`/`list-all`/`list-faulty`, gate alias launch on status, add an install-time + session-time sync hook, and root-cause the config-overwrite prompt — all with hermetic test coverage.

**Architecture:** A single status cache (`$(cma_providers_dir)/status.json`, provider-id → record) becomes the source of truth for "is this alias usable." `cmd_sync` writes it; the three list subcommands read it; the `cma_run_provider` activation gate reads it at launch. The session-sync hook re-writes aliases from cache (no network) on shell start, with a TTL-triggered background full sync. The config-overwrite prompt is investigated (systematic-debugging) before any change, since per-alias `settings.json` is already owned (`lib.sh:716`).

**Tech Stack:** POSIX-leaning bash (targets Linux + macOS bash 4+), `jq` for JSON, Python 3 for the existing scoring engine, the hermetic sandbox test harness under `scripts/tests/`.

**Decomposition note:** This is Phase 1 of the decomposed programme (spec §1). Phase 2 (separate plan) adds the LLMsVerifier `semantic-code-visibility` Go command + the live superpowers-TUI test + the semantic layer wiring in `model_verify.py` — they need a Go-submodule deep-dive and a live host. Phase 3 (separate plan) covers docs + the cross-repo release. This plan ships independently: after it, `list`/`list-all`/`list-faulty` + the activation gate + the session hook all work and are tested, even though the semantic/superpowers layers land in Phase 2.

## Global Constraints

- Target Linux + macOS; bash 4+ (macOS ships 3.2 — `install.sh` re-execs into a newer bash; test the same way).
- POSIX-leaning: no GNU-only `awk` 3-arg `match()`, no `mktemp --suffix`; use `mktemp "${TMPDIR:-/tmp}/x.XXXXXX"`.
- `lib.sh` guards must use literal `()` not `\(\)` (BRE empty-group bug) — grep/sed patterns with empty alternation `(\"| )` are correct as literals.
- API keys via environment (`CMA_PROBE_KEY`), never argv; bearer tokens via process-substituted `--config <(printf ...)` fd.
- No secrets in the status cache, env files, or alias file. `status.json` holds only provider id, status, model id, timestamp, failing-layer — never keys.
- Every destructive replacement uses `backup_and_remove` / `.preunify.<timestamp>` rename; nothing is `rm`'d without a backup.
- Verification statuses are exactly: `verified` (all layers), `unverified` (existence passed, later layer failed), `failed` (existence failed), `pending` (not yet verified). No other values.
- Hermetic tests use `make_sandbox` (mktemp `$HOME`, `CLAUDE_BIN=/usr/bin/true`), never touch real `~/.claude*`, no network, no keys.
- No fixes without root cause (§11.4.102); no silent removal of existing components (§11.4.122); investigate dead/existing code before changing (§11.4.124).
- Every state-advancing commit updates `docs/CONTINUATION.md` + `.remember/remember.md` (§11.4.131).
- Existing `claude1..N` accounts + existing provider aliases keep working unchanged.

---

## File Structure

- `scripts/lib.sh` — add `cma_status_cache`, `cma_status_write`, `cma_status_read`, `cma_status_all` helpers (status cache I/O) near the provider helpers (after `cma_providers_dir`, line 725). Add the activation-gate check into the `cma_run_provider` heredoc body (the block written at `lib.sh:475`).
- `scripts/claude-providers.sh` — `cmd_sync` persists status (after the `vstatus` computation, ~line 214); split `cmd_list` (223-243) into `cmd_list`/`cmd_list_all`/`cmd_list_faulty`; add `--refresh-aliases` + `--quiet` flags; extend dispatch (426).
- `scripts/install.sh` — add the session-sync hook install (new step after step 4b, ~line 136) + an install-time `claude-providers sync` (soft).
- `scripts/tests/test_providers.sh` — new hermetic cases: `test_status_cache`, `test_list_split`, `test_activation_gate`, `test_session_sync_hook`.
- `docs/investigations/2026-07-04-config-overwrite-prompt.md` — the systematic-debugging root-cause record for the overwrite prompt (Task 7).

---

### Task 1: Status cache helpers in lib.sh

**Files:**
- Modify: `scripts/lib.sh` (add after `cma_providers_dir`, line 725)
- Test: `scripts/tests/test_providers.sh` (new `test_status_cache`)

**Interfaces:**
- Consumes: `cma_providers_dir` (existing, `lib.sh:725`), `jq`.
- Produces:
  - `cma_status_cache()` → prints the status-cache path (`$(cma_providers_dir)/status.json`).
  - `cma_status_write <id> <status> <model> <failing_layer>` → upserts one record; `failing_layer` empty for `verified`. Writes ISO-8601 UTC `checked_at`. Creates `{}` if absent. Atomic via mktemp+mv.
  - `cma_status_read <id>` → prints the status word (`verified`/`unverified`/`failed`/`pending`) for `<id>`, or `pending` if absent.
  - `cma_status_all` → prints `id<TAB>status<TAB>model<TAB>checked_at<TAB>failing_layer` one line per record (empty output if no cache).

- [ ] **Step 1: Write the failing test**

Add to `scripts/tests/test_providers.sh` (before `summary`):

```bash
test_status_cache() {
  make_sandbox
  source "$LIB_DIR/lib.sh"; set +e

  # Unknown id reads as pending.
  assert_eq "$(cma_status_read nope)" "pending" "unknown id -> pending"

  # Write + read back.
  cma_status_write deepseek verified deepseek-chat ""
  assert_eq "$(cma_status_read deepseek)" "verified" "wrote verified"

  # Overwrite same id (idempotent upsert, no dup).
  cma_status_write deepseek unverified deepseek-chat semantic
  assert_eq "$(cma_status_read deepseek)" "unverified" "upsert overwrote"
  assert_eq "$(cma_status_cache | xargs -I{} jq '.deepseek|length' {})" "4" "one record, 4 fields"

  # Second provider, then cma_status_all lists both.
  cma_status_write groq failed llama-3 existence
  assert_eq "$(cma_status_all | wc -l | tr -d ' ')" "2" "two records listed"
  assert_contains "$(cma_status_all)" "groq	failed	llama-3" "groq row present"

  # No secret is ever written.
  assert_not_contains "$(cat "$(cma_status_cache)")" "sk-" "no key material in cache"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 status_cache`
Expected: FAIL — `cma_status_cache: command not found` (helpers not defined yet).

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/lib.sh` immediately after `cma_providers_dir() { ... }` (line 725):

```bash
# --- verification status cache ---------------------------------------------
# Single source of truth for "is this provider alias usable". Holds ONLY
# non-secret metadata: provider id -> {status, model, checked_at, failing_layer}.
# status is one of: verified | unverified | failed | pending.
cma_status_cache() { echo "$(cma_providers_dir)/status.json"; }

# cma_status_write <id> <status> <model> <failing_layer>
# Upserts one record. failing_layer is "" for verified/pending. Atomic.
cma_status_write() {
  local id="$1" status="$2" model="${3:-}" layer="${4:-}"
  cma_require jq
  local f; f="$(cma_status_cache)"; mkdir -p "$(dirname "$f")"
  [[ -s "$f" ]] || printf '{}\n' > "$f"
  # checked_at: portable UTC ISO-8601 (GNU + BSD date both accept -u +fmt).
  local now; now="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  if jq --arg id "$id" --arg s "$status" --arg m "$model" \
        --arg l "$layer" --arg t "$now" \
        '.[$id] = {status:$s, model:$m, checked_at:$t, failing_layer:$l}' \
        "$f" > "$tmp" 2>/dev/null; then
    mv "$tmp" "$f"
  else
    rm -f "$tmp"; cma_warn "could not update status cache $f"
  fi
}

# cma_status_read <id> -> status word (pending if absent/unreadable).
cma_status_read() {
  local id="$1" f; f="$(cma_status_cache)"
  [[ -s "$f" ]] || { echo pending; return 0; }
  local s; s="$(jq -r --arg id "$id" '.[$id].status // "pending"' "$f" 2>/dev/null)"
  [[ -n "$s" && "$s" != "null" ]] && echo "$s" || echo pending
}

# cma_status_all -> id<TAB>status<TAB>model<TAB>checked_at<TAB>failing_layer per record.
cma_status_all() {
  local f; f="$(cma_status_cache)"
  [[ -s "$f" ]] || return 0
  jq -r 'to_entries[] | [.key, .value.status, (.value.model // ""),
         (.value.checked_at // ""), (.value.failing_layer // "")] | @tsv' \
     "$f" 2>/dev/null || true
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 status_cache`
Expected: PASS (all `test_status_cache` assertions green).

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh scripts/tests/test_providers.sh
git commit -m "feat(providers): status cache helpers (single source of truth for alias usability)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 2: `cmd_sync` persists verification status

**Files:**
- Modify: `scripts/claude-providers.sh` (`cmd_sync`, lines 187-216)
- Test: `scripts/tests/test_providers.sh` (extend the existing sync test to assert status persisted)

**Interfaces:**
- Consumes: `cma_status_write` (Task 1), `vstatus` local computed at `claude-providers.sh:188-203`.
- Produces: after every sync, `$(cma_status_cache)` has one record per resolved provider with its `vstatus` and, on failure, the failing layer (`existence` for the `failed` path).

- [ ] **Step 1: Write the failing test**

Add to `scripts/tests/test_providers.sh`:

```bash
test_sync_persists_status() {
  make_sandbox
  # Fake a resolved provider + a verifier that reports 'unverified' (no network).
  make_provider_env deepseek deepseek-chat   # helper: writes a minimal *.env + status-less state
  # Run sync with --no-verify so vstatus defaults to unverified deterministically.
  run_providers sync --no-verify --offline >/dev/null 2>&1
  source "$LIB_DIR/lib.sh"; set +e
  assert_eq "$(cma_status_read deepseek)" "unverified" "sync persisted unverified"
}
```

(If `make_provider_env`/`run_providers` helpers do not yet exist in the test file, add them next to the existing `make_account`/`run_unify` helpers: `run_providers() { bash "$LIB_DIR/claude-providers.sh" "$@"; }` and a `make_provider_env` that seeds `providers/key-aliases.json` + a stub catalog so `cmd_sync` resolves one provider offline.)

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 sync_persists`
Expected: FAIL — `cma_status_read` returns `pending` (sync does not write status yet).

- [ ] **Step 3: Write minimal implementation**

In `scripts/claude-providers.sh`, inside `cmd_sync`, replace the failed-branch + success-tail (lines 205-215) so each path records status:

```bash
    if [[ "$vstatus" == "failed" ]]; then
      cma_warn "provider '$pid' FAILED verification — alias NOT activated"
      cma_status_write "$pid" failed "$model" existence
      n_disabled=$((n_disabled+1))
      continue
    fi

    cma_link_shared_items "$cdir"
    cma_provider_write_env "$pid" "$keyvar" "$transport" "$base" "$model" "$fast" "$cdir" "$ctx_limit" "$max_out"
    cma_provider_write_alias "$alias" "$pid"
    # Persist status: verified|unverified. A non-"verified" here means existence
    # passed but a later layer (semantic/superpowers, Phase 2) has not confirmed;
    # the failing_layer is recorded so list-faulty + the gate can explain it.
    if [[ "$vstatus" == "verified" ]]; then
      cma_status_write "$pid" verified "$model" ""
    else
      cma_status_write "$pid" "$vstatus" "$model" semantic
    fi
    cma_log "provider '$pid' -> alias '$alias' [$transport] model=$model ($vstatus)"
    n_created=$((n_created+1))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 sync_persists`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-providers.sh scripts/tests/test_providers.sh
git commit -m "feat(providers): cmd_sync persists per-provider verification status

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 3: Split `list` into `list` / `list-all` / `list-faulty`

**Files:**
- Modify: `scripts/claude-providers.sh` (`cmd_list` 223-243; dispatch 426-429; usage 55-81)
- Test: `scripts/tests/test_providers.sh` (`test_list_split`)

**Interfaces:**
- Consumes: `cma_status_read` (Task 1), the per-`*.env` loop already in `cmd_list`.
- Produces:
  - `cmd_list` prints only providers whose `cma_status_read` is `verified`.
  - `cmd_list_all` prints every provider (the current behaviour) with a STATUS column.
  - `cmd_list_faulty` prints only `failed`/`unverified`/`pending` providers with STATUS + failing-layer.
  - A shared `_list_rows <filter>` helper emits rows so the three commands share one code path (DRY).

- [ ] **Step 1: Write the failing test**

```bash
test_list_split() {
  make_sandbox
  source "$LIB_DIR/lib.sh"; set +e
  # Three providers at three statuses, each with an env file + alias.
  for p in good bad meh; do make_provider_env "$p" "${p}-model"; done
  cma_status_write good verified good-model ""
  cma_status_write bad failed bad-model existence
  cma_status_write meh unverified meh-model semantic

  assert_contains   "$(run_providers list)"        "good" "list shows verified"
  assert_not_contains "$(run_providers list)"      "bad"  "list hides failed"
  assert_not_contains "$(run_providers list)"      "meh"  "list hides unverified"

  assert_contains   "$(run_providers list-all)"    "good" "list-all shows all (good)"
  assert_contains   "$(run_providers list-all)"    "bad"  "list-all shows all (bad)"
  assert_contains   "$(run_providers list-all)"    "meh"  "list-all shows all (meh)"

  assert_not_contains "$(run_providers list-faulty)" "good" "list-faulty hides verified"
  assert_contains   "$(run_providers list-faulty)"  "bad"  "list-faulty shows failed"
  assert_contains   "$(run_providers list-faulty)"  "meh"  "list-faulty shows unverified"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 list_split`
Expected: FAIL — `list-all`/`list-faulty` are unknown subcommands (dispatch rejects them).

- [ ] **Step 3: Write minimal implementation**

Replace `cmd_list` (223-243) with a shared row emitter + three thin commands:

```bash
# --- subcommand: list family ------------------------------------------------
# _list_rows <filter>  filter: verified | faulty | all
_list_rows() {
  local filter="$1" pdir; pdir="$(cma_providers_dir)"
  if [[ ! -d "$pdir" ]] || ! compgen -G "$pdir/*.env" >/dev/null; then
    echo "No provider aliases installed. Run: claude-providers sync"
    return 0
  fi
  printf '%-14s %-16s %-10s %-12s %-22s\n' ALIAS PROVIDER STATUS LAYER STRONG_MODEL
  local f
  for f in "$pdir"/*.env; do
    local id status layer keep=0
    # shellcheck disable=SC1090
    id="$( ( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_ID" ) )"
    status="$(cma_status_read "$id")"
    case "$filter" in
      verified) [[ "$status" == "verified" ]] && keep=1 ;;
      faulty)   [[ "$status" != "verified" ]] && keep=1 ;;
      all)      keep=1 ;;
    esac
    (( keep )) || continue
    layer="$(cma_status_all | awk -F'\t' -v i="$id" '$1==i{print $5}')"
    # shellcheck disable=SC1090
    ( set -a; . "$f"; set +a
      alias="$(grep -E "cma_run_provider $CMA_PROVIDER_ID(\"| )" "$ALIAS_FILE" 2>/dev/null | sed -E 's/^alias ([^=]+)=.*/\1/' | head -1)" || alias=""
      printf '%-14s %-16s %-10s %-12s %-22s\n' \
        "${alias:-?}" "$CMA_PROVIDER_ID" "$status" "${layer:--}" "$CMA_PROVIDER_MODEL" )
  done
}
cmd_list()        { _list_rows verified; }
cmd_list_all()    { _list_rows all; }
cmd_list_faulty() { _list_rows faulty; }
```

Extend the dispatch `case` (line 427):

```bash
  sync|list|list-all|list-faulty|show|remove|add) SUBCMD="$1"; shift ;;
```

and the dispatch tail that calls `cmd_$SUBCMD` — map the hyphens: add near the dispatch,

```bash
case "$SUBCMD" in
  list-all)    cmd_list_all "${POSITIONAL[@]}" ;;
  list-faulty) cmd_list_faulty "${POSITIONAL[@]}" ;;
  *)           "cmd_$SUBCMD" "${POSITIONAL[@]}" ;;
esac
```

(Adapt to the file's existing dispatch shape — if it already does `cmd_$SUBCMD`, the hyphenated names need the explicit `case` above because `cmd_list-all` is not a valid function name.)

Update `usage()` (55-81) to document `list` (verified only), `list-all`, `list-faulty`.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 list_split`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-providers.sh scripts/tests/test_providers.sh
git commit -m "feat(providers): list shows only verified; add list-all + list-faulty

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 4: Activation gate in `cma_run_provider`

**Files:**
- Modify: `scripts/lib.sh` (the `cma_run_provider` heredoc body written at `lib.sh:475-641`; add a gate right after the env-file existence check at line 479-482, and bump the migration marker so existing alias files get the new body)
- Test: `scripts/tests/test_providers.sh` (`test_activation_gate`)

**Interfaces:**
- Consumes: the status cache file directly (the alias-file body is self-contained — it has NO `cma_*` helpers, so it reads `status.json` with `jq` inline, exactly as it already reads `$envf`).
- Produces: `cma_run_provider <id>` refuses to launch (`return 3`, prints actionable message) when status is `unverified`/`failed`/`pending`, unless `CMA_PROVIDER_FORCE=1` (set by an `--force` first arg) is present. `verified` launches normally.

- [ ] **Step 1: Write the failing test**

```bash
test_activation_gate() {
  make_sandbox
  source "$LIB_DIR/lib.sh"; set +e
  export CLAUDE_BIN=/usr/bin/true
  cma_ensure_alias_file            # writes the cma_run_provider body
  make_provider_env deepseek deepseek-chat

  # failed -> refuse, non-zero, actionable message, CLAUDE_BIN not run.
  cma_status_write deepseek failed deepseek-chat existence
  out="$( set +e; ( source "$ALIAS_FILE"; cma_run_provider deepseek ) 2>&1 )"
  rc=$?
  assert_neq "$rc" "0" "failed alias refuses to launch"
  assert_contains "$out" "claude-providers verify deepseek" "message tells user to verify"

  # verified -> launches (CLAUDE_BIN=/usr/bin/true exits 0).
  cma_status_write deepseek verified deepseek-chat ""
  ( source "$ALIAS_FILE"; cma_run_provider deepseek ) >/dev/null 2>&1
  assert_eq "$?" "0" "verified alias launches"

  # --force overrides a failed status.
  cma_status_write deepseek failed deepseek-chat existence
  ( source "$ALIAS_FILE"; cma_run_provider --force deepseek ) >/dev/null 2>&1
  assert_eq "$?" "0" "--force overrides gate"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 activation_gate`
Expected: FAIL — a `failed` alias currently launches (rc 0), no gate.

- [ ] **Step 3: Write minimal implementation**

In `scripts/lib.sh`, inside the `cma_run_provider() { ... }` heredoc (the `cat >> "$ALIAS_FILE" <<'EOF'` block starting line 473), add the gate right after the `source "$envf"` line (currently line 484) — it needs `$CMA_PROVIDER_ID` which `$envf` defines:

```bash
  # --force as the first arg bypasses the activation gate (operator override).
  local _cma_force=0
  if [[ "$id" == "--force" ]]; then _cma_force=1; id="$1"; shift 2>/dev/null || true
    envf="$pdir/$id.env"
    [[ -f "$envf" ]] || { printf 'claude-providers: unknown provider %s\n' "$id" >&2; return 1; }
    # shellcheck disable=SC1090
    source "$envf"
  fi
  # Activation gate: only 'verified' aliases launch Claude Code. A non-verified
  # alias returns a clear message instead of bringing up a broken session.
  if (( ! _cma_force )); then
    local _cma_sf="$pdir/status.json" _cma_st="pending"
    if command -v jq >/dev/null 2>&1 && [[ -s "$_cma_sf" ]]; then
      _cma_st="$(jq -r --arg i "$CMA_PROVIDER_ID" '.[$i].status // "pending"' "$_cma_sf" 2>/dev/null)"
      [[ -n "$_cma_st" && "$_cma_st" != "null" ]] || _cma_st="pending"
    fi
    if [[ "$_cma_st" != "verified" ]]; then
      printf 'claude-providers: alias %s is %s — not launching.\n' "$CMA_PROVIDER_ID" "$_cma_st" >&2
      printf '  Run: claude-providers verify %s\n' "$CMA_PROVIDER_ID" >&2
      printf '  Override (operator): %s --force %s\n' "cma_run_provider" "$CMA_PROVIDER_ID" >&2
      return 3
    fi
  fi
```

Because `cma_run_provider` parses `$1` as `id` at the top (line 476), the `--force` handling must sit before the first `source "$envf"`; adjust the top of the function so the initial `local id="$1"; shift` is followed immediately by the `--force` re-parse, then the existing env-file check. Bump the migration marker comment in `cma_ensure_alias_file` (the `cma_log "migrated outdated cma_run_provider ..."` string at `lib.sh:469`) to include `+activation-gate` so existing installs regenerate the body.

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 activation_gate`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh scripts/tests/test_providers.sh
git commit -m "feat(providers): activation gate — only verified aliases launch Claude Code

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 5: `--refresh-aliases` + `--quiet` flags for the session hook

**Files:**
- Modify: `scripts/claude-providers.sh` (arg parsing 431-445; a new `cmd_refresh_aliases` that re-writes alias functions from `*.env` with no network)
- Test: `scripts/tests/test_providers.sh` (`test_refresh_aliases`)

**Interfaces:**
- Consumes: the per-`*.env` loop, `cma_provider_write_alias` (`lib.sh:878`).
- Produces: `claude-providers list --refresh-aliases --quiet` re-writes every provider alias line in `$ALIAS_FILE` from the cached env files, prints nothing on success (`--quiet`), makes NO network call, and is idempotent (re-running yields the same `$ALIAS_FILE`).

- [ ] **Step 1: Write the failing test**

```bash
test_refresh_aliases() {
  make_sandbox
  source "$LIB_DIR/lib.sh"; set +e
  make_provider_env deepseek deepseek-chat
  # Corrupt the alias line, then refresh should restore it, no network.
  cma_remove_alias dseek 2>/dev/null || true
  run_providers list --refresh-aliases --quiet >/dev/null 2>&1
  assert_contains "$(cat "$ALIAS_FILE")" "cma_run_provider deepseek" "alias restored from cache"
  # Idempotent: capture, re-run, compare.
  before="$(cat "$ALIAS_FILE")"
  run_providers list --refresh-aliases --quiet >/dev/null 2>&1
  assert_eq "$(cat "$ALIAS_FILE")" "$before" "refresh is idempotent"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 refresh_aliases`
Expected: FAIL — `--refresh-aliases` is an unknown flag (lands in POSITIONAL, does nothing).

- [ ] **Step 3: Write minimal implementation**

Add flags to the arg-parse loop (after line 441):

```bash
    --refresh-aliases) REFRESH_ALIASES=1; shift ;;
    --quiet) QUIET=1; shift ;;
```

Declare `REFRESH_ALIASES=0 QUIET=0` beside the other flag defaults (line 52). Add a refresh path that runs before normal dispatch when the flag is set:

```bash
if (( REFRESH_ALIASES )); then
  pdir="$(cma_providers_dir)"
  if [[ -d "$pdir" ]] && compgen -G "$pdir/*.env" >/dev/null; then
    for f in "$pdir"/*.env; do
      id="$( ( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_ID" ) )"
      alias="$( ( set -a; . "$f"; set +a; printf '%s' "$CMA_PROVIDER_ALIAS" ) )"
      # Fall back to the provider id as the alias name if no CMA_PROVIDER_ALIAS.
      [[ -n "$alias" ]] || alias="$id"
      cma_provider_write_alias "$alias" "$id" 2>/dev/null || true
    done
  fi
  (( QUIET )) || cma_log "refreshed provider aliases from cache (no network)"
  exit 0
fi
```

(If `*.env` files do not currently store `CMA_PROVIDER_ALIAS`, add it to `cma_provider_write_env` in `lib.sh:856` — one extra `CMA_PROVIDER_ALIAS=$(_cma_q "$alias")` line and an `alias` parameter — so refresh knows the alias name without scanning `$ALIAS_FILE`. This is a small additive change; keep the existing positional args and append `alias` as a new trailing arg with an empty default.)

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 refresh_aliases`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/claude-providers.sh scripts/lib.sh scripts/tests/test_providers.sh
git commit -m "feat(providers): --refresh-aliases + --quiet (no-network alias rewrite for the session hook)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 6: install.sh session-sync hook + install-time sync

**Files:**
- Modify: `scripts/install.sh` (new step after 4b, ~line 136)
- Modify: `scripts/lib.sh` (a `cma_install_session_hook` helper that writes the marker-bracketed function into `$ALIAS_FILE`)
- Test: `scripts/tests/test_providers.sh` (`test_session_sync_hook`)

**Interfaces:**
- Consumes: `cma_ensure_alias_file`, `$ALIAS_FILE`, `CMA_PROVIDERS_SYNC_TTL` (default 86400).
- Produces:
  - `cma_install_session_hook` writes a `cma_providers_session_refresh` function + a call to it into `$ALIAS_FILE`, bracketed by `# cma-providers-session-refresh BEGIN/END`, replacing any prior block atomically (idempotent).
  - The installed function: calls `claude-providers list --quiet --refresh-aliases` (no network); if `status.json` is older than `CMA_PROVIDERS_SYNC_TTL`, launches `claude-providers sync` detached (`nohup ... &` + `disown`, §11.4.89) and does not block the shell.
  - `install.sh` calls `cma_install_session_hook` and then runs `claude-providers sync` once (soft — non-fatal if it fails).

- [ ] **Step 1: Write the failing test**

```bash
test_session_sync_hook() {
  make_sandbox
  source "$LIB_DIR/lib.sh"; set +e
  cma_ensure_alias_file
  cma_install_session_hook
  # Marker pair present exactly once.
  assert_eq "$(grep -c 'cma-providers-session-refresh BEGIN' "$ALIAS_FILE")" "1" "one BEGIN marker"
  # Idempotent: re-install, still exactly one.
  cma_install_session_hook
  assert_eq "$(grep -c 'cma-providers-session-refresh BEGIN' "$ALIAS_FILE")" "1" "still one after re-install"
  # The function calls list --refresh-aliases (no network verb like 'sync' inline).
  assert_contains "$(cat "$ALIAS_FILE")" "list --quiet --refresh-aliases" "hook uses no-network refresh"
  # Sourcing the alias file defines + runs the hook without error and with no network.
  ( source "$ALIAS_FILE" ) >/dev/null 2>&1
  assert_eq "$?" "0" "sourcing alias file (hook fires) succeeds offline"
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 session_sync_hook`
Expected: FAIL — `cma_install_session_hook: command not found`.

- [ ] **Step 3: Write minimal implementation**

Add to `scripts/lib.sh` (near the other alias-file helpers, after `cma_provider_write_alias`, ~line 894):

```bash
# Install (idempotently) the session-refresh hook into $ALIAS_FILE. The hook
# re-writes provider aliases from cache on shell start (no network) and, when
# the status cache is older than CMA_PROVIDERS_SYNC_TTL, kicks a detached full
# sync (§11.4.89 background). Bracketed by markers so re-install replaces it.
cma_install_session_hook() {
  cma_ensure_alias_file
  local begin='# cma-providers-session-refresh BEGIN'
  local end='# cma-providers-session-refresh END'
  local tmp; tmp="$(mktemp "${TMPDIR:-/tmp}/cma.XXXXXX")"
  # Drop any existing block (BEGIN..END inclusive), then append the fresh one.
  awk -v b="$begin" -v e="$end" '
    $0==b{skip=1} !skip{print} $0==e{skip=0}' "$ALIAS_FILE" > "$tmp"
  {
    printf '%s\n' "$begin"
    cat <<'HOOK'
cma_providers_session_refresh() {
  command -v claude-providers >/dev/null 2>&1 || return 0
  # No-network: re-write alias functions from the cached env files.
  claude-providers list --quiet --refresh-aliases >/dev/null 2>&1 || true
  # TTL-triggered background full sync (detached; never blocks the shell).
  local ttl="${CMA_PROVIDERS_SYNC_TTL:-86400}"
  local sf="$HOME/.local/share/claude-multi-account/providers/status.json"
  if [[ -f "$sf" ]]; then
    local age now mtime
    now="$(date +%s)"
    mtime="$(date -r "$sf" +%s 2>/dev/null || stat -c %Y "$sf" 2>/dev/null || echo "$now")"
    age=$(( now - mtime ))
    if (( age > ttl )); then
      ( nohup claude-providers sync >/dev/null 2>&1 & disown ) 2>/dev/null || true
    fi
  fi
}
cma_providers_session_refresh
HOOK
    printf '%s\n' "$end"
  } >> "$tmp"
  mv "$tmp" "$ALIAS_FILE"
}
```

In `scripts/install.sh`, after step 4b (line 136), before step 5:

```bash
# 4c. Install the provider session-sync hook + run an install-time sync (soft).
cma_install_session_hook
if command -v claude-providers >/dev/null 2>&1 || [[ -x "$LIB_DIR/claude-providers.sh" ]]; then
  cma_log "running claude-providers sync (install-time; soft)"
  ( "$LIB_DIR/claude-providers.sh" sync ) || cma_warn "provider sync skipped (no keys/network?)"
fi
```

- [ ] **Step 4: Run test to verify it passes**

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 session_sync_hook`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add scripts/lib.sh scripts/install.sh scripts/tests/test_providers.sh
git commit -m "feat(providers): install-time + session-time sync hook (cache refresh + TTL background sync)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

### Task 7: Root-cause the config-overwrite prompt (systematic-debugging — investigate, then fix ONLY if a real cause is found)

**Files:**
- Create: `docs/investigations/2026-07-04-config-overwrite-prompt.md` (root-cause record)
- Modify (ONLY if the investigation finds a real cause): the specific file the investigation identifies
- Test: `scripts/tests/test_providers.sh` (a regression test ONLY if a fix lands)

**Interfaces:**
- Consumes: `cma_link_shared_items` (`lib.sh:730`), `cma_own_settings_seed` (`lib.sh:762`), the `cma_run_provider` launch path.
- Produces: a written root-cause record. If (and only if) a real prompt trigger is found, a minimal fix + a regression test proving the prompt no longer fires on a fresh provider dir.

**Note:** `settings.json` is ALREADY per-alias-owned (`lib.sh:716` comment), and `.claude.json` is NOT in `CMA_SHARED_ITEMS`, so the spec's assumed cause (shared-settings symlink) is already handled by commit `c6fe153`. This task is investigation-first per §11.4.102 — do NOT implement the pre-supposed fix blind.

- [ ] **Step 1: Reproduce**

Run a provider alias against a fresh config dir and capture the exact prompt:

```bash
# In a sandbox (never touch real ~/.claude*):
CLAUDE_BIN="$(command -v claude || echo /usr/bin/true)"
# Create a provider dir via the real path, launch non-interactively, capture stderr/stdout.
```

Record verbatim: the exact prompt text, which file it names, and the code path (Claude Code trust dialog? onboarding? a toolkit write?). Determine whether it originates in Claude Code itself (trust dialog for a new `CLAUDE_CONFIG_DIR`) or in the toolkit.

- [ ] **Step 2: Trace to source**

If the prompt is Claude Code's trust dialog for a new config dir: the fix is to pre-seed the trust acceptance in the per-dir `.claude.json` (the `c6fe153` "sticky trust" mechanism — verify it covers provider dirs). If it is a toolkit write colliding with an existing file: identify the exact `cp`/`ln`/`>` that overwrites without a backup. Write the finding into `docs/investigations/2026-07-04-config-overwrite-prompt.md` with the captured evidence.

- [ ] **Step 3: Decide + (conditionally) fix**

- If the investigation shows the prompt is ALREADY eliminated by `c6fe153` for provider dirs → record "no fix needed; verified fixed by c6fe153" with the captured clean-launch evidence. No code change.
- If a real remaining trigger is found → implement the minimal fix at its source, add a regression test that launches a fresh provider dir and asserts the prompt does not fire (via a stub `CLAUDE_BIN` that fails if it reads from a prompt fd, or by asserting the trust flag is pre-seeded).

- [ ] **Step 4: Verify**

Run the reproduction again on a clean provider dir; confirm no prompt (or the honest "already fixed" evidence). If a regression test was added:

Run: `bash scripts/tests/run-all.sh providers 2>&1 | grep -A2 overwrite`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add docs/investigations/2026-07-04-config-overwrite-prompt.md scripts/ 2>/dev/null
git commit -m "fix(providers): root-cause config-overwrite prompt (investigation + $OUTCOME)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

(Replace `$OUTCOME` with "verified already fixed by c6fe153" or "seed sticky trust for provider dirs".)

---

### Task 8: Full suite green + CONTINUATION/remember sync

**Files:**
- Modify: `docs/CONTINUATION.md`, `.remember/remember.md`
- Test: the whole suite

- [ ] **Step 1: Run the full hermetic suite**

Run: `bash scripts/tests/run-all.sh`
Expected: all green, including the new `test_status_cache`, `test_sync_persists_status`, `test_list_split`, `test_activation_gate`, `test_refresh_aliases`, `test_session_sync_hook`, and (if added) the overwrite regression.

- [ ] **Step 2: Update the handoff docs**

Update `docs/CONTINUATION.md` §1 phase to "Phase 1 (toolkit-side verification) implemented; Phase 2 (Go semantic-code-visibility + live superpowers-TUI) next" and bump the HEAD line. Rewrite `.remember/remember.md` to the post-Phase-1 state.

- [ ] **Step 3: Commit**

```bash
git add docs/CONTINUATION.md
git commit -m "docs: Phase 1 provider-verification toolkit-side complete; CONTINUATION synced (§11.4.131)

Co-Authored-By: Claude Opus 4.8 <noreply@anthropic.com>"
```

---

## Self-Review

**Spec coverage (Phase 1 scope):**
- Spec §5.1 list/list-all/list-faulty → Task 3. ✅
- Spec §5.2 activation gate → Task 4. ✅
- Spec §4.5 extended VERIFIED_CACHE (status subset) → Tasks 1-2 (status.json; the per-layer semantic/superpowers detail lands in Phase 2). ✅ (Phase-1 subset)
- Spec §5.3 install.sh session-sync hook + `--refresh-aliases` → Tasks 5-6. ✅
- Spec §6 per-alias config / overwrite prompt → Task 7 (investigation-first, since already partly fixed). ✅
- Spec §3 semantic layer, §4.4 superpowers-TUI, §4.6 xAI, §7.3 live tier, §8 docs/release → **Phase 2 / Phase 3 (separate plans)** — explicitly out of this plan's scope per the decomposition note. Documented, not dropped.

**Placeholder scan:** No TBD/TODO/"add error handling" — every code step carries complete code. Task 7 is intentionally investigation-first (not a placeholder — it is the §11.4.102 discipline; its code is conditional on the captured root cause, which is the correct plan shape for a debugging task).

**Type consistency:** `cma_status_write`/`cma_status_read`/`cma_status_all`/`cma_status_cache` names used identically across Tasks 1-6. Status vocabulary (`verified`/`unverified`/`failed`/`pending`) consistent throughout. `status.json` path (`$(cma_providers_dir)/status.json`) identical in the helper (Task 1), the gate inline read (Task 4), and the hook TTL check (Task 6).

**Known adaptation points flagged inline:** the dispatch hyphen-name handling (Task 3), the optional `CMA_PROVIDER_ALIAS` env-file field (Task 5), and the `make_provider_env`/`run_providers` test helpers (Task 2) are called out where the implementer must reconcile with the file's existing shape.
