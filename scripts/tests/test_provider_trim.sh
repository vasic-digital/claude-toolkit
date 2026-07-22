#!/usr/bin/env bash
# test_provider_trim.sh — CMA_PROVIDER_TRIM='bare' makes a provider launch
# minimal: `--bare` prepended and NO auto `--resume` injection (fresh session).
#
# Field failure (2026-07-22, helixagent): a local-model provider serving a
# 229,376-token window received 332k-462k-token requests and refused every
# session with HTTP 400. Two stacked injections caused it: the shared
# plugin/MCP/skill roster (~110k tokens of fixed surface) and the wrapper's
# `--resume <existing-session>` auto-injection dragging the synced session
# history (~330k tokens) into every launch. A direct `claude --bare -p hi`
# request measures 4,891 BYTES — the client is fine; the injections are the
# weight. Local-model providers therefore need a TRIM mode: the whole point
# of `claude` mode's single big slot is one session that actually fits.
#
# Contract under test (per-provider, opt-in via the provider env file):
#   CMA_PROVIDER_TRIM='bare' =>
#     (a) `--bare` is prepended to conversation launches;
#     (b) the `--resume <existing-id>` auto-injection is SKIPPED (fresh
#         session each launch — history stays out);
#     (c) an EXPLICIT user session selector (--session-id/--resume/...) is
#         passed through verbatim (user choice wins) — still with `--bare`;
#     (d) non-conversation subcommands (mcp, doctor, ...) get NOTHING added.
#   Unset => behavior is UNCHANGED (auto-resume still injected, no --bare).
#
# This EXECUTES the real generated wrapper against stubbed ccr/claude-session
# (it does not grep lib.sh), so a regression that drops trim fails here.
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
set +e

# --- two verified router-transport providers: one trimmed, one not ----------
pdir="$(cma_providers_dir)"; mkdir -p "$pdir"
cma_provider_write_env trimrtr TESTKEY router "http://127.0.0.1:9/v1" testmodel testmodel \
  "$SANDBOX_HOME/.claude-prov-trimrtr" 200000 8192 trimrtr
cma_status_write trimrtr verified testmodel ""
printf "CMA_PROVIDER_TRIM='bare'\n" >> "$pdir/trimrtr.env"

cma_provider_write_env plainrtr TESTKEY router "http://127.0.0.1:9/v1" testmodel testmodel \
  "$SANDBOX_HOME/.claude-prov-plainrtr" 200000 8192 plainrtr
cma_status_write plainrtr verified testmodel ""

export TESTKEY="dummy-key-present"
mkdir -p "$SANDBOX_HOME/.claude-code-router"
printf '{}\n' > "$SANDBOX_HOME/.claude-code-router/config.json"

# --- generate the alias file (embeds cma_run_provider with trim support) ----
ALIAS_FILE="$SANDBOX_HOME/.local/share/claude-multi-account/aliases.sh"
mkdir -p "$(dirname "$ALIAS_FILE")" "$SANDBOX_HOME/.local/bin"
CMA_RC_FILES=("$SANDBOX_HOME/.unused-rc")
cma_ensure_alias_file >/dev/null 2>&1

ccrlog="$SANDBOX_HOME/ccr.argv"

# --- stubs: a CURRENT ccr that records the FULL launch argv per invocation --
sandbox_stub "$SANDBOX_HOME/.local/bin/ccr" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$ccrlog"
case "\$1" in
  --help)  printf 'Usage:\n  ccr start [...]\n  ccr serve [...]\n  ccr stop\n  ccr restart [...]\n'; exit 0 ;;
  restart) echo "ccr started (pid 1)"; exit 0 ;;
  *) exit 0 ;;
esac
STUB
# claude-session: an existing session ALWAYS exists, so the auto-resume
# injection fires whenever the wrapper allows it — the discriminator for (b).
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-session" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  flags)       echo "" ;;
  existing-id) echo "11111111-2222-3333-4444-555555555555" ;;
esac
exit 0
STUB
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-sync-state" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
export PATH="$SANDBOX_HOME/.local/bin:$PATH"

# shellcheck source=/dev/null
source "$ALIAS_FILE"
it "HYGIENE: cma_run_provider under test comes from the sandbox alias file"
assert_fn_from cma_run_provider "$ALIAS_FILE" "wrapper loaded from the sandbox, not the host"
export CLAUDE_BIN=/usr/bin/true

launch_argv() {  # last recorded `default-claude-code` launch line
  grep 'default-claude-code' "$ccrlog" | tail -1
}

# ── (a)+(b): trimmed provider — bare, fresh session ──
: > "$ccrlog"
( set +eu; cma_run_provider trimrtr -p hi >/dev/null 2>&1 )
argv="$(launch_argv)"

it "TRIM (a): a trimmed provider's conversation launch carries --bare"
case "$argv" in *"--bare"*) ok=0 ;; *) ok=1 ;; esac
assert_eq 0 "$ok" "--bare present in: $argv"

it "TRIM (b): a trimmed provider gets NO --resume auto-injection (fresh session)"
case "$argv" in *"--resume"*) ok=1 ;; *) ok=0 ;; esac
assert_eq 0 "$ok" "no auto --resume in: $argv"

# ── (c): explicit user session selector stays verbatim, still bare ──
: > "$ccrlog"
( set +eu; cma_run_provider trimrtr --session-id aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee -p hi >/dev/null 2>&1 )
argv="$(launch_argv)"

it "TRIM (c): an explicit --session-id passes through verbatim"
case "$argv" in *"--session-id aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"*) ok=0 ;; *) ok=1 ;; esac
assert_eq 0 "$ok" "user selector kept in: $argv"

it "TRIM (c): the explicit-selector launch is still bare"
case "$argv" in *"--bare"*) ok=0 ;; *) ok=1 ;; esac
assert_eq 0 "$ok" "--bare present in: $argv"

# ── (d): non-conversation subcommands get nothing added ──
: > "$ccrlog"
( set +eu; cma_run_provider trimrtr doctor >/dev/null 2>&1 )
argv="$(launch_argv)"

it "TRIM (d): a non-conversation subcommand (doctor) gets neither --bare nor --resume"
case "$argv" in *"--bare"*|*"--resume"*) ok=1 ;; *) ok=0 ;; esac
assert_eq 0 "$ok" "no trim/resume flags in: $argv"

# ── regression: an UNTRIMMED provider keeps today's behavior exactly ──
: > "$ccrlog"
( set +eu; cma_run_provider plainrtr -p hi >/dev/null 2>&1 )
argv="$(launch_argv)"

it "REGRESSION: an untrimmed provider still gets the --resume auto-injection"
case "$argv" in *"--resume 11111111-2222-3333-4444-555555555555"*) ok=0 ;; *) ok=1 ;; esac
assert_eq 0 "$ok" "auto --resume preserved in: $argv"

it "REGRESSION: an untrimmed provider is NOT bare"
case "$argv" in *"--bare"*) ok=1 ;; *) ok=0 ;; esac
assert_eq 0 "$ok" "no --bare in: $argv"

# ── (e): zero-args INTERACTIVE launch — the flags store injects there too ──
# The REAL `claude-session flags` emits e.g. "--resume <id> --name <proj>"
# (field evidence 2026-07-22: the helixagent profile returned exactly that),
# so the interactive path drags the session history in through a DIFFERENT
# seam than the conversation-args branch. Trim must cover both.
sandbox_stub "$SANDBOX_HOME/.local/bin/claude-session" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  flags)       echo "--resume 99999999-8888-7777-6666-555555555555 --name sbx" ;;
  existing-id) echo "11111111-2222-3333-4444-555555555555" ;;
esac
exit 0
STUB

: > "$ccrlog"
( set +eu; cma_run_provider trimrtr >/dev/null 2>&1 )
argv="$(launch_argv)"

it "TRIM (e): an interactive (zero-args) trimmed launch is bare"
case "$argv" in *"--bare"*) ok=0 ;; *) ok=1 ;; esac
assert_eq 0 "$ok" "--bare present in: $argv"

it "TRIM (e): an interactive trimmed launch gets NO flags-store --resume (fresh session)"
case "$argv" in *"--resume"*) ok=1 ;; *) ok=0 ;; esac
assert_eq 0 "$ok" "no stored --resume in: $argv"

: > "$ccrlog"
( set +eu; cma_run_provider plainrtr >/dev/null 2>&1 )
argv="$(launch_argv)"

it "REGRESSION: an untrimmed interactive launch still applies the stored session flags"
case "$argv" in *"--resume 99999999-8888-7777-6666-555555555555"*) ok=0 ;; *) ok=1 ;; esac
assert_eq 0 "$ok" "stored flags preserved in: $argv"

summary
