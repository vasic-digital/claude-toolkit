#!/usr/bin/env bash
# test_session.sh — hermetic tests for claude-session.sh.
#
# Covers:
#   1. name   – snake_case conversion from dir basename
#   2. id     – stable, valid, unique UUID per project root
#   3. color  – palette membership and determinism
#   4. flags (first-run) – outputs --session-id + --name when no session file exists
#   5. flags (resume)    – outputs --resume when the session .jsonl is present
#   6. trust  – flags writes hasTrustDialogAccepted=true into <config_dir>/.claude.json
#   7. git-root – subdir shares the same session as the repo root
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"

# shellcheck source=lib/assert.sh
source "$TESTS_DIR/lib/assert.sh"
# shellcheck source=lib/sandbox.sh
source "$TESTS_DIR/lib/sandbox.sh"

make_sandbox
# shellcheck source=../lib.sh
source "$SCRIPTS_DIR/lib.sh"
# lib.sh sets -e; tests assert on failures deliberately, so relax it.
set +e

SESSION_SH="$SCRIPTS_DIR/claude-session.sh"

# ── helper: run the session script from a specific directory ──────────────
# All invocations that need $PWD-sensitive behaviour (flags, id without path,
# name without path) should use this helper so the script sees the right $PWD.
run_session_from() {
  local dir="$1"; shift
  (cd "$dir" && bash "$SESSION_SH" "$@")
}

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 1. name – snake_case conversion
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "name: 'My_Cool-Project' → 'my_cool_project'"
proj_name1="$SANDBOX_HOME/My_Cool-Project"
mkdir -p "$proj_name1"
out1="$(bash "$SESSION_SH" name "$proj_name1")"
assert_eq "my_cool_project" "$out1" "mixed-case with dash → snake_case"

it "name: 'Android 15' → 'android_15'"
proj_name2="$SANDBOX_HOME/Android 15"
mkdir -p "$proj_name2"
out2="$(bash "$SESSION_SH" name "$proj_name2")"
assert_eq "android_15" "$out2" "space in name → underscore"

it "name: 'claude_toolkit' → 'claude_toolkit'"
proj_name3="$SANDBOX_HOME/claude_toolkit"
mkdir -p "$proj_name3"
out3="$(bash "$SESSION_SH" name "$proj_name3")"
assert_eq "claude_toolkit" "$out3" "already snake_case passes through unchanged"

it "name: no leading, trailing, or double underscores in output"
proj_name4="$SANDBOX_HOME/__Weird--Name__"
mkdir -p "$proj_name4"
out4="$(bash "$SESSION_SH" name "$proj_name4")"
cond=1; [[ "$out4" != _* && "$out4" != *_ && "$out4" != *__* ]] && cond=0
assert_eq 0 "$cond" "no leading/trailing/double underscores (got: '$out4')"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 2. id – stable UUID
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

uuid_re='^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'

it "id: returns a valid RFC-4122-shaped UUID"
proj_id="$SANDBOX_HOME/id_test_proj"
mkdir -p "$proj_id"
sid="$(bash "$SESSION_SH" id "$proj_id")"
cond=1; [[ "$sid" =~ $uuid_re ]] && cond=0
assert_eq 0 "$cond" "UUID shape valid (got: $sid)"

it "id: stable — two calls to the same directory give identical output"
sid1="$(bash "$SESSION_SH" id "$proj_id")"
sid2="$(bash "$SESSION_SH" id "$proj_id")"
assert_eq "$sid1" "$sid2" "id is deterministic across calls"

it "id: different project directories produce different UUIDs"
proj_alpha="$SANDBOX_HOME/proj_alpha"
proj_beta="$SANDBOX_HOME/proj_beta"
mkdir -p "$proj_alpha" "$proj_beta"
sid_a="$(bash "$SESSION_SH" id "$proj_alpha")"
sid_b="$(bash "$SESSION_SH" id "$proj_beta")"
cond=1; [[ "$sid_a" != "$sid_b" ]] && cond=0
assert_eq 0 "$cond" "alpha ($sid_a) ≠ beta ($sid_b)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 3. color – palette membership and determinism
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

palette_re='^(red|blue|green|yellow|purple|orange|pink|cyan)$'

it "color: each label maps to a known palette color"
for _label in claude1 claude2 work personal xiaomi; do
  _col="$(bash "$SESSION_SH" color "$_label")"
  cond=1; [[ "$_col" =~ $palette_re ]] && cond=0
  assert_eq 0 "$cond" "label '$_label' → '$_col' is in palette"
done

it "color: same label always maps to the same color (deterministic)"
col_a="$(bash "$SESSION_SH" color "myalias")"
col_b="$(bash "$SESSION_SH" color "myalias")"
assert_eq "$col_a" "$col_b" "color stable for 'myalias'"

it "color: empty label does not error and returns a palette color"
col_empty="$(bash "$SESSION_SH" color "" 2>/dev/null)"
cond=1; [[ "$col_empty" =~ $palette_re ]] && cond=0
assert_eq 0 "$cond" "empty label → '$col_empty' (in palette)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 4. flags – first-run (no session file present)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "flags first-run: output contains '--session-id' and '--name', not '--resume'"
proj_fr="$SANDBOX_HOME/first_run_proj"
cfg_fr="$SANDBOX_HOME/cfg_first_run"
mkdir -p "$proj_fr" "$cfg_fr"
flags_fr="$(run_session_from "$proj_fr" flags "$cfg_fr")"
cond=1; [[ "$flags_fr" == *"--session-id"* ]] && cond=0
assert_eq 0 "$cond" "first-run output contains --session-id"
cond=1; [[ "$flags_fr" == *"--name"* ]] && cond=0
assert_eq 0 "$cond" "first-run output contains --name"
cond=1; [[ "$flags_fr" != *"--resume"* ]] && cond=0
assert_eq 0 "$cond" "first-run output does NOT contain --resume"

it "flags first-run: --name matches the snake_case of the project dir basename"
expected_snake="first_run_proj"
cond=1; [[ "$flags_fr" == *"--name $expected_snake"* ]] && cond=0
assert_eq 0 "$cond" "flags --name is '$expected_snake' (got: $flags_fr)"

it "flags first-run: --session-id is a valid UUID"
# Extract the word immediately following --session-id.
sid_fr="$(printf '%s' "$flags_fr" | sed -E 's/.*--session-id ([^ ]+).*/\1/')"
cond=1; [[ "$sid_fr" =~ $uuid_re ]] && cond=0
assert_eq 0 "$cond" "flags --session-id is a valid UUID (got: $sid_fr)"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 5. flags – resume (session .jsonl already exists)
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "flags resume: when session .jsonl exists, output is '--resume <uuid> --name <snake>'"
proj_res="$SANDBOX_HOME/resume_proj"
cfg_res="$SANDBOX_HOME/cfg_resume"
mkdir -p "$proj_res" "$cfg_res"

# The UUID and slug must match what the script itself would compute when run
# from inside $proj_res.  Use the same invocations so path canonicalisation
# (pwd -P) is handled identically on both sides. Slug uses the PER-CHAR rule
# (s/[^A-Za-z0-9]/-/g) — claude's real on-disk slug does NOT collapse runs.
res_sid="$(run_session_from "$proj_res" id)"
res_root="$(cd "$proj_res" && pwd -P)"
res_slug="$(printf '%s' "$res_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
res_name="$(run_session_from "$proj_res" name)"

sess_dir="$cfg_res/projects/$res_slug"
mkdir -p "$sess_dir"
printf '{"type":"user","content":"hello"}\n' > "$sess_dir/$res_sid.jsonl"

flags_res="$(run_session_from "$proj_res" flags "$cfg_res")"
# Resume now ALSO carries --name: re-passing the name on --resume is what lets an
# existing UNNAMED session finally get named (proven live on claude 2.1.195:
# `claude --resume <id> --name <x>` sets custom-title <NONE> -> <x>).
assert_eq "--resume $res_sid --name $res_name" "$flags_res" "resume output is '--resume <uuid> --name <snake>'"

it "flags resume: output carries --name (renames legacy unnamed sessions), no --session-id"
cond=1; [[ "$flags_res" != *"--session-id"* ]] && cond=0
assert_eq 0 "$cond" "resume output has no --session-id"
cond=1; [[ "$flags_res" == *"--name $res_name"* ]] && cond=0
assert_eq 0 "$cond" "resume output carries --name $res_name"

# Regression for the per-char slug fix: a project path with CONSECUTIVE
# non-alnum chars (e.g. a hidden '/.cfg/' segment) must still resolve to claude's
# real slug so an existing session is RESUMED, not re-created. The old collapsing
# slug (s/…+/-/g) produced a single '-' here and false-negatived the lookup.
it "flags resume: consecutive separators in the path still resume (per-char slug)"
proj_cs="$SANDBOX_HOME/.cfg/cs_proj"
cfg_cs="$SANDBOX_HOME/cfg_cs"
mkdir -p "$proj_cs" "$cfg_cs"
cs_sid="$(run_session_from "$proj_cs" id)"
cs_root="$(cd "$proj_cs" && pwd -P)"
cs_slug="$(printf '%s' "$cs_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
mkdir -p "$cfg_cs/projects/$cs_slug"
printf '{"type":"user","content":"hi"}\n' > "$cfg_cs/projects/$cs_slug/$cs_sid.jsonl"
flags_cs="$(run_session_from "$proj_cs" flags "$cfg_cs")"
cond=1; [[ "$flags_cs" == "--resume $cs_sid"* ]] && cond=0
assert_eq 0 "$cond" "path with '/.' resumes (not re-creates); got: $flags_cs"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 6. trust – flags writes hasTrustDialogAccepted=true into .claude.json
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "trust: .claude.json gains hasTrustDialogAccepted=true after a flags call"
proj_trust="$SANDBOX_HOME/trust_proj"
cfg_trust="$SANDBOX_HOME/cfg_trust"
mkdir -p "$proj_trust" "$cfg_trust"
run_session_from "$proj_trust" flags "$cfg_trust" > /dev/null 2>&1

trust_file="$cfg_trust/.claude.json"
assert_file "$trust_file" ".claude.json was created by flags"

# The project key stored by the script is cma_project_root($PWD) = pwd -P.
trust_root="$(cd "$proj_trust" && pwd -P)"
assert_jq "$trust_file" \
  ".projects[\"$trust_root\"].hasTrustDialogAccepted" \
  "true" \
  "hasTrustDialogAccepted is true for $trust_root"

it "trust: repeated flags calls are idempotent (file stays valid JSON)"
run_session_from "$proj_trust" flags "$cfg_trust" > /dev/null 2>&1
run_session_from "$proj_trust" flags "$cfg_trust" > /dev/null 2>&1
# jq must still be able to parse the file after multiple writes.
trust_val="$(jq -r ".projects[\"$trust_root\"].hasTrustDialogAccepted" "$trust_file" 2>/dev/null || echo '<jq-error>')"
assert_eq "true" "$trust_val" "trust flag still true after repeated flags calls"

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 7. git-root – subdir shares the same session as the repo root
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "git-root: id and name from a deep subdir match those from the repo root"
if ! command -v git >/dev/null 2>&1; then
  _pass "git not available on this host — skipping git-root test"
else
  git_repo="$SANDBOX_HOME/git_root_test"
  mkdir -p "$git_repo"
  # Suppress "hints" noise; we only need git to recognise the directory.
  git -C "$git_repo" init -q 2>/dev/null || git -C "$git_repo" init 2>/dev/null

  subdir="$git_repo/src/deep/nested"
  mkdir -p "$subdir"

  id_from_root="$(run_session_from "$git_repo" id)"
  id_from_sub="$(run_session_from "$subdir"   id)"
  assert_eq "$id_from_root" "$id_from_sub" \
    "id is identical from repo root and deep subdir"

  name_from_root="$(run_session_from "$git_repo" name)"
  name_from_sub="$(run_session_from "$subdir"   name)"
  assert_eq "$name_from_root" "$name_from_sub" \
    "name is identical from repo root and deep subdir"
fi

# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
# 8. apply-color – inject the per-alias agent-color into the session jsonl
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

it "apply-color: writes the alias colour into a session that has none (set -e regression)"
ac_proj="$SANDBOX_HOME/ac_proj"; ac_cfg="$SANDBOX_HOME/ac_cfg"
mkdir -p "$ac_proj"
ac_sid="$(run_session_from "$ac_proj" id)"
ac_root="$(cd "$ac_proj" && pwd -P)"; ac_slug="$(printf '%s' "$ac_root" | sed -E 's/[^A-Za-z0-9]/-/g')"
ac_sf="$ac_cfg/projects/$ac_slug/$ac_sid.jsonl"
mkdir -p "$(dirname "$ac_sf")"
printf '{"type":"user","content":"hi"}\n' > "$ac_sf"   # session with NO agent-color record
ac_color="$(run_session_from "$ac_proj" color alias_one)"
run_session_from "$ac_proj" apply-color "$ac_cfg" alias_one
ac_got="$(grep '"type":"agent-color"' "$ac_sf" 2>/dev/null | tail -1 | sed -E 's/.*"agentColor":"([^"]*)".*/\1/')"
assert_eq "$ac_color" "$ac_got" "agent-color for alias_one written (=$ac_color)"

it "apply-color: idempotent — same alias does not append a duplicate"
ac_b="$(grep -c '"type":"agent-color"' "$ac_sf")"
run_session_from "$ac_proj" apply-color "$ac_cfg" alias_one
ac_a="$(grep -c '"type":"agent-color"' "$ac_sf")"
assert_eq "$ac_b" "$ac_a" "no duplicate agent-color on re-apply"

it "apply-color: switching alias re-colours the session"
ac_color2="$(run_session_from "$ac_proj" color alias_two)"
run_session_from "$ac_proj" apply-color "$ac_cfg" alias_two
ac_got2="$(grep '"type":"agent-color"' "$ac_sf" 2>/dev/null | tail -1 | sed -E 's/.*"agentColor":"([^"]*)".*/\1/')"
assert_eq "$ac_color2" "$ac_got2" "session colour follows the current alias (=$ac_color2)"

it "apply-color: no-op (exit 0) when the session file does not exist yet"
ac_empty="$SANDBOX_HOME/ac_empty"; mkdir -p "$ac_empty"
run_session_from "$ac_empty" apply-color "$ac_cfg" alias_one; rc=$?
assert_eq 0 "$rc" "apply-color returns 0 when no session file exists"

# --- hint: EXECUTE it (cma_run calls `claude-session hint` on every bare launch;
# previously this path was only string-matched in the wrapper body, never run) --
it "hint: EXECUTES cleanly and writes the project + colour to stderr only"
hint_proj="$SANDBOX_HOME/Hint_Demo"; mkdir -p "$hint_proj"
hint_out="$(run_session_from "$hint_proj" hint claude2 2>/dev/null)"            # stdout only
hint_err="$(run_session_from "$hint_proj" hint claude2 2>&1 1>/dev/null)"; hint_rc=$?
assert_eq 0 "$hint_rc" "hint exits 0 (no set -e abort)"
assert_eq "" "$hint_out" "hint writes nothing to stdout (must not pollute the launch)"
printf '%s\n' "$hint_err" | grep -q 'hint_demo';   assert_eq 0 $? "hint stderr names the snake_case project"
printf '%s\n' "$hint_err" | grep -q 'alias color:'; assert_eq 0 $? "hint stderr states the alias colour"

it "hint: EXECUTES with an empty label (edge case) without aborting"
run_session_from "$hint_proj" hint >/dev/null 2>&1; assert_eq 0 $? "hint with no label exits 0"

summary
