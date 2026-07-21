#!/usr/bin/env bash
# suite-lock.sh — serialize test-suite runs so two of them can never overlap.
#
# WHY: a forensic investigation caught run-proof.sh (PID 170365) executing
# concurrently with run-all.sh (PID 581986) while a third agent added a test
# file mid-run. A repo that mutates while its own tests execute cannot produce
# reproducible results — that is what made a set of deterministic tests look
# "flaky". Serializing suite runs removes that entire class of false signal.
#
# PUBLIC API
#   cma_suite_lock_acquire NAME   acquire (or legitimately inherit) the lock and
#                                 install EXIT/INT/TERM release traps
#   cma_suite_lock_release        release iff THIS process is the holder
#   cma_suite_lock_path           echo the lock path in use
#
# RE-ENTRANCY (the deadlock run-proof.sh would otherwise hit)
#   run-proof.sh invokes run-all.sh as a child, and BOTH are documented
#   standalone entry points, so both must lock. A child therefore INHERITS the
#   parent's lock via CMA_SUITE_LOCK_OWNER/CMA_SUITE_LOCK_PATH instead of
#   blocking on it. Inheritance is verified, never trusted: the env var must
#   name the same lock path, the named PID must still be alive, AND that PID
#   must be the one physically recorded inside the lock. A forged or stale
#   env var therefore cannot silently disable locking.
#
# CONTENTION POLICY: bounded wait, then fail.
#   A competing run is usually transient (another agent's suite finishing), so
#   a bounded wait lets runs queue up instead of forcing a manual re-run. It
#   never hangs: after CMA_SUITE_LOCK_WAIT seconds (default 600) it gives up
#   with exit 75 (EX_TEMPFAIL). Set CMA_SUITE_LOCK_WAIT=0 for fail-fast.
#
# BACKENDS
#   flock(1) when present (kernel-backed; a crashed holder is released
#   automatically). Otherwise — macOS ships without flock and this toolkit
#   targets macOS too — an atomic mkdir(2) lock with race-safe stale breaking:
#   the stale directory is claimed by rename(2), which exactly one contender
#   can win, so two processes can never both "recover" the same stale lock.
#
# KNOBS
#   CMA_SUITE_LOCK_WAIT         seconds to wait on contention (default 600)
#   CMA_SUITE_LOCK_DIR          directory holding the lock (default: the repo's
#                               git dir, else $TMPDIR) — never the tracked tree
#   CMA_SUITE_LOCK_NO_FLOCK=1   force the portable fallback (used by the tests
#                               to exercise the macOS path on Linux)
#   CMA_SUITE_LOCK_STALE_GRACE  seconds a pid-less lock dir may exist before it
#                               is treated as stale (default 5)

CMA_SUITE_LOCK_WAIT="${CMA_SUITE_LOCK_WAIT:-600}"
CMA_SUITE_LOCK_STALE_GRACE="${CMA_SUITE_LOCK_STALE_GRACE:-5}"

_cma_lock_held=0
_cma_lock_mode=""
_cma_lock_path=""

# Where the lock lives. Never inside the tracked tree: a lock file under
# scripts/ would show up in `git status` and could be committed by accident.
# The git dir is ideal (repo-scoped, writable, already ignored); $TMPDIR is
# the fallback, keyed by repo path so two checkouts get two locks.
_cma_lock_home() {
  if [ -n "${CMA_SUITE_LOCK_DIR:-}" ]; then
    printf '%s\n' "$CMA_SUITE_LOCK_DIR"
    return 0
  fi
  local here gd
  here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  if gd="$(git -C "$here" rev-parse --absolute-git-dir 2>/dev/null)" && [ -d "$gd" ]; then
    printf '%s\n' "$gd"
    return 0
  fi
  printf '%s\n' "${TMPDIR:-/tmp}"
}

# A stable per-repo key, so a $TMPDIR fallback lock does not collide across
# checkouts. Portable: `tr` only, no GNU-only sed/awk constructs.
_cma_lock_key() {
  local root
  root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." 2>/dev/null && pwd)" || root="unknown"
  printf '%s\n' "$root" | tr -c 'A-Za-z0-9' '-' | tr -s '-'
}

cma_suite_lock_path() { printf '%s\n' "$_cma_lock_path"; }

_cma_lock_sleep() { sleep 0.2 2>/dev/null || sleep 1; }

_cma_lock_now() { date '+%s'; }

# Read the PID physically recorded in the lock (flock: the file; mkdir: pid
# file inside the dir). Empty when unknown.
_cma_lock_recorded_pid() {
  local p=""
  if [ "$_cma_lock_mode" = "mkdir" ]; then
    p="$(head -1 "$_cma_lock_path/pid" 2>/dev/null)"
  else
    p="$(head -1 "$_cma_lock_path" 2>/dev/null)"
  fi
  printf '%s\n' "$p" | tr -d '[:space:]'
}

# Honour an inherited lock only when every claim checks out.
_cma_lock_inherited() {
  local owner="${CMA_SUITE_LOCK_OWNER:-}" claimed="${CMA_SUITE_LOCK_PATH:-}" recorded
  [ -n "$owner" ] || return 1
  case "$owner" in ''|*[!0-9]*) return 1 ;; esac      # must be a plain PID
  [ "$claimed" = "$_cma_lock_path" ] || return 1      # must be OUR lock
  kill -0 "$owner" 2>/dev/null || return 1            # owner must still exist
  recorded="$(_cma_lock_recorded_pid)"
  [ "$recorded" = "$owner" ] || return 1              # and actually hold it
  return 0
}

_cma_lock_giveup() {
  local holder="$1"
  printf '\033[31m[LOCK] giving up after %ss — another test-suite run (PID %s) still holds %s\033[0m\n' \
    "$CMA_SUITE_LOCK_WAIT" "${holder:-unknown}" "$_cma_lock_path" >&2
  printf '[LOCK] concurrent suite runs are refused on purpose: a repo that mutates\n' >&2
  printf '[LOCK] while its own tests execute cannot produce reproducible results.\n' >&2
  exit 75
}

_cma_lock_announce() {
  local holder="$1"
  printf '\033[33m[LOCK] another test-suite run is in progress (PID %s, lock %s) — waiting up to %ss\033[0m\n' \
    "${holder:-unknown}" "$_cma_lock_path" "$CMA_SUITE_LOCK_WAIT" >&2
}

# --- flock backend -----------------------------------------------------------
# The lock file is opened in APPEND mode on purpose: `exec 9>file` truncates at
# open, which would erase a live holder's PID record before we even contend.
_cma_lock_acquire_flock() {
  local holder
  exec 9>>"$_cma_lock_path" || return 1
  if ! flock -n 9; then
    holder="$(_cma_lock_recorded_pid)"
    _cma_lock_announce "$holder"
    if [ "$CMA_SUITE_LOCK_WAIT" -le 0 ] 2>/dev/null || ! flock -w "$CMA_SUITE_LOCK_WAIT" 9; then
      exec 9>&-
      _cma_lock_giveup "$holder"
    fi
    printf '\033[32m[LOCK] acquired — previous run finished\033[0m\n' >&2
  fi
  # Safe to truncate by path now: we hold the lock and the file is never
  # unlinked, so this is the same inode we hold.
  printf '%s\n' "$$" > "$_cma_lock_path"
  return 0
}

# --- portable mkdir backend (macOS / no flock) -------------------------------
# _cma_lock_break_stale OBSERVED_PID — discard a lock whose owner is gone.
#
# Claiming happens via rename(2): exactly one contender can win a given path,
# so two processes can never both "recover" the same stale lock. But winning
# the rename is not enough. Between deciding "PID N is dead" and performing the
# swap, another contender can break the lock and acquire it for real — and this
# rename would then throw away a LIVE holder's lock, leaving two suites running.
# So the swap is verified: if what we took is not the dead lock we judged, we
# put it back instead of deleting it. That is the difference between a correct
# stale break and a best-effort one.
_cma_lock_break_stale() {
  local observed="${1:-}" stash="${_cma_lock_path}.stale.$$" got
  rm -rf "$stash" 2>/dev/null
  # Losing the rename is fine — another contender got there first; just retry.
  mv "$_cma_lock_path" "$stash" 2>/dev/null || return 0
  got="$(head -1 "$stash/pid" 2>/dev/null | tr -d '[:space:]')"
  if [ "$got" = "$observed" ]; then
    rm -rf "$stash" 2>/dev/null          # confirmed: same dead owner, discard
    return 0
  fi
  # Not the lock we judged stale. Restore it rather than dropping someone's
  # live lock — unless the path was re-taken meanwhile, in which case the
  # current holder is authoritative and the stash is the stale one.
  if [ -e "$_cma_lock_path" ] || ! mv "$stash" "$_cma_lock_path" 2>/dev/null; then
    rm -rf "$stash" 2>/dev/null
  fi
  return 0
}

_cma_lock_acquire_mkdir() {
  local deadline holder announced=0 empty_since=""
  deadline=$(( $(_cma_lock_now) + CMA_SUITE_LOCK_WAIT ))
  while :; do
    if mkdir "$_cma_lock_path" 2>/dev/null; then
      printf '%s\n' "$$" > "$_cma_lock_path/pid"
      # Confirm we still own what we just took. If a contender was mid stale
      # break it could have swapped the directory out from under us; the PID
      # recorded here is the tiebreaker, and losing it means going back to the
      # queue rather than running a second suite alongside the winner.
      if [ "$(_cma_lock_recorded_pid)" != "$$" ]; then
        continue
      fi
      if [ "$announced" -eq 1 ]; then
        printf '\033[32m[LOCK] acquired — previous run finished\033[0m\n' >&2
      fi
      return 0
    fi

    holder="$(_cma_lock_recorded_pid)"
    if [ -z "$holder" ]; then
      # mkdir won but the pid write has not landed yet — or the winner died in
      # between. Give it a grace window before declaring the lock stale.
      if [ -z "$empty_since" ]; then empty_since="$(_cma_lock_now)"; fi
      if [ "$(( $(_cma_lock_now) - empty_since ))" -ge "$CMA_SUITE_LOCK_STALE_GRACE" ]; then
        _cma_lock_break_stale ""
        empty_since=""
        continue
      fi
    else
      empty_since=""
      if ! kill -0 "$holder" 2>/dev/null; then
        # Crashed run: its PID is gone, so the lock must not wedge the suite.
        _cma_lock_break_stale "$holder"
        continue
      fi
    fi

    if [ "$announced" -eq 0 ]; then
      _cma_lock_announce "$holder"
      announced=1
    fi
    if [ "$(_cma_lock_now)" -ge "$deadline" ]; then
      _cma_lock_giveup "$holder"
    fi
    _cma_lock_sleep
  done
}

# --- public ------------------------------------------------------------------
# Work out which backend and which path this run would use, WITHOUT acquiring
# anything. Split out from acquire so callers (notably the tests) can ask
# "where is the lock?" without taking it — probing by acquiring would release
# a live holder's lock as a side effect.
cma_suite_lock_resolve() {
  local name="${1:-suite}" home
  home="$(_cma_lock_home)"
  mkdir -p "$home" 2>/dev/null
  if command -v flock >/dev/null 2>&1 && [ -z "${CMA_SUITE_LOCK_NO_FLOCK:-}" ]; then
    _cma_lock_mode="flock"
    _cma_lock_path="$home/cma-$name$(_cma_lock_key).lock"
  else
    _cma_lock_mode="mkdir"
    _cma_lock_path="$home/cma-$name$(_cma_lock_key).lockdir"
  fi
}

cma_suite_lock_acquire() {
  local name="${1:-suite}"
  cma_suite_lock_resolve "$name"

  if _cma_lock_inherited; then
    # Nested run inside an already-locked process tree (run-proof.sh ->
    # run-all.sh). Do not re-acquire, do not release on exit.
    _cma_lock_held=0
    return 0
  fi

  if [ "$_cma_lock_mode" = "flock" ]; then
    _cma_lock_acquire_flock
  else
    _cma_lock_acquire_mkdir
  fi

  _cma_lock_held=1
  export CMA_SUITE_LOCK_OWNER="$$"
  export CMA_SUITE_LOCK_PATH="$_cma_lock_path"
  # Release on every exit path: normal, error, and Ctrl-C.
  trap 'cma_suite_lock_release' EXIT
  trap 'cma_suite_lock_release; exit 130' INT
  trap 'cma_suite_lock_release; exit 143' TERM
  return 0
}

cma_suite_lock_release() {
  [ "$_cma_lock_held" -eq 1 ] || return 0
  _cma_lock_held=0
  if [ "$_cma_lock_mode" = "mkdir" ]; then
    # Only remove a lock we still own — after a stale break the directory may
    # belong to someone else.
    if [ "$(_cma_lock_recorded_pid)" = "$$" ]; then
      rm -rf "$_cma_lock_path" 2>/dev/null
    fi
  else
    # Clear the PID record, then drop the lock. The file itself is deliberately
    # NOT unlinked: unlinking a flock target races a contender who already
    # opened the old inode.
    : > "$_cma_lock_path" 2>/dev/null
    flock -u 9 2>/dev/null
    exec 9>&- 2>/dev/null
  fi
  unset CMA_SUITE_LOCK_OWNER CMA_SUITE_LOCK_PATH
  return 0
}
