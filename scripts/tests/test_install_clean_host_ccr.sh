#!/usr/bin/env bash
# test_install_clean_host_ccr.sh — CLEAN-HOST install acceptance: the installer
# must never report success over a product whose router is missing or is the
# npm doppelganger.
#
# THE RELEASE-TESTING GAP THIS CLOSES
# -----------------------------------
# Field failure (2026-07-22, operator host, v1.25.4): the operator ran
# install.sh on a DIFFERENT host, reloaded aliases, and `opencode` died with
#   "resolved ccr (/home/<user>/.local/bin/ccr) is not the bundled
#    claude-code-router ... Fix the install, remove the shadowing ccr, or
#    (re)build the bundled Go router: claude-ccr-build"
# install.sh had printed "[done] installed". Operator verdict: "unacceptable
# low quality of work and the testing of delivered release".
#
# Nothing in the suite could have caught it. Every pre-existing ccr test
# (test_ccr_build / test_ccr_conformance / test_ccr_path_shadowing) exercises
# RUNTIME resolution against an ALREADY-CORRECT install. Not one of them ran
# the INSTALL acceptance path on a host where the bundled router is absent, so
# the "warn and print [done] anyway" behaviour was invisible to the release
# gate. This file is that missing acceptance test.
#
# WHY NO CONTAINER
# ----------------
# A clean host here means: a pristine $HOME with no bundled router installed,
# plus a shadowing npm `ccr` earlier on PATH. Both are fully reproducible with
# a sandbox HOME + a stub PATH entry, so this stays hermetic, offline, and
# runs everywhere the rest of the suite does. (§11.4.161 would mandate ROOTLESS
# podman if a container were needed; it is not — a container would only add a
# runtime dependency without adding a single assertion.)
#
# WHAT IS ASSERTED (behavioural — these EXECUTE the real gate, they do not grep
# our own source, §11.4.201)
#   A. doppelganger-only  -> verify FAILS, names the npm router as the cause
#   B. shadow + bundled   -> verify PASSES  (no false positive: PATH shadowing
#                            is NOT fatal since cma_run_provider resolves the
#                            stable path first — refusing here would be a
#                            §11.4.201(1) FAIL-bluff)
#   C. no ccr at all      -> verify FAILS
#   D. CONTROL NEEDLE     -> proves the OLD fingerprint could not discriminate,
#                            so a regression back to it fails this file
#   E. wiring             -> install.sh actually calls the gate and exits
#                            non-zero on a recorded failure
#   F. B1 (review 2026-07-22): claude-ccr-build on a NO-Go host must probe the
#      ARTIFACT — a working bundled ccr keeps install green (exit 0 + honest
#      staleness note); a broken/absent/doppelganger ccr still fails hard
#   G. I1+M2: verify's --help probe stays BOUNDED on hosts WITHOUT coreutils
#      timeout(1), and a wedged binary is reported AS a hang, never as
#      "not a router"
#   H. M1: a dangling symlink at the stable install path is diagnosed as
#      ITSELF ("not executable"), not misreported via the PATH fallback
set -uo pipefail
TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TESTS_DIR/.." && pwd)"
source "$TESTS_DIR/lib/assert.sh"
source "$TESTS_DIR/lib/sandbox.sh"
make_sandbox
set +e

VERIFY="$SCRIPTS_DIR/claude-install-verify.sh"

# --- stub builders -----------------------------------------------------------
# These reproduce the two binaries' REAL --help surfaces. Both were captured
# from the live binaries on 2026-07-22 (see the control needle in test D):
# the npm router prints start/ui/serve/stop and NO `restart`; the bundled Go
# router prints `ccr restart` as well. `restart` is what applies an edited
# config.json, which is why a router without it cannot serve a provider launch.

make_npm_ccr() {  # $1 = path
  sandbox_stub "$1" <<'STUB'
#!/usr/bin/env bash
# stub of npm @musistudio/claude-code-router — NOTE: no `restart`
cat <<'H'
Usage:
  ccr start [--host <host>] [--port <port>] [--open|--no-open]
  ccr ui [--host <host>] [--port <port>] [--open|--no-open]
  ccr serve [--host <host>] [--port <port>] [--open|--no-open]
  ccr stop
  ccr <profile-name-or-id> [cli|app] [-- <agent args>]
H
STUB
}

make_bundled_ccr() {  # $1 = path
  sandbox_stub "$1" <<'STUB'
#!/usr/bin/env bash
# stub of the BUNDLED Go claude-code-router
cat <<'H'
ccr - Claude Code Router

Usage:
  ccr start [--host <host>] [--port <port>] [--open|--no-open]
  ccr ui    [--host <host>] [--port <port>] [--open|--no-open]
  ccr serve [--host <host>] [--port <port>] [--open|--no-open]
  ccr stop
  ccr restart [--host <host>] [--port <port>]
  ccr <profile-name-or-id> [cli|app] [-- <agent args>]
H
STUB
}

# A PATH whose FIRST entry holds the npm doppelganger — exactly the operator's
# host layout, where nvm's bin dir precedes ~/.local/bin.
SHADOW_DIR="$HOME/.fake-nvm/bin"
mkdir -p "$SHADOW_DIR"
make_npm_ccr "$SHADOW_DIR/ccr"
# PATH is CLOSED, not prepended-to. Inheriting the developer's $PATH let the
# real nvm ccr (/home/<dev>/.nvm/.../bin/ccr) leak into the "no ccr anywhere"
# case, so that test measured the host instead of the sandbox and reported a
# doppelganger we never installed. A clean-host test whose PATH is not itself
# clean is not measuring a clean host (§11.4.201 — the path IS the instrument).
export PATH="$SHADOW_DIR:$HOME/.local/bin:/usr/bin:/bin"

# ============================================================================
it "A. clean host + npm ccr shadow, NO bundled router -> install self-verify FAILS"
# The operator's exact starting state.
rm -f "$HOME/.local/bin/ccr"
outA="$(CMA_CCR_BIN='' bash "$VERIFY" 2>&1)"; rcA=$?
assert_eq "1" "$rcA" "verify must exit 1 when the only ccr is the npm doppelganger"
case "$outA" in
  *"bundled Go claude-code-router"*|*"no router found"*)
    _pass "verify named the router problem" ;;
  *) _fail "verify did not name the router problem. Got: $outA" ;;
esac
case "$outA" in
  *"claude-ccr-build"*) _pass "verify gave the actionable fix (claude-ccr-build)" ;;
  *) _fail "verify FAILED without telling the operator how to fix it. Got: $outA" ;;
esac

# ============================================================================
it "B. bundled router installed, npm ccr STILL shadowing on PATH -> verify PASSES"
# Guards against over-correction: PATH shadowing alone must NOT fail the
# install, because cma_run_provider resolves \$HOME/.local/bin/ccr first.
# A failure here would be a false-positive refusal of a working product.
make_bundled_ccr "$HOME/.local/bin/ccr"
outB="$(CMA_CCR_BIN='' bash "$VERIFY" 2>&1)"; rcB=$?
assert_eq "0" "$rcB" "verify must PASS when the bundled router is installed, shadow or not"
case "$outB" in
  *"bundled Go router verified"*) _pass "verify confirmed the bundled router" ;;
  *) _fail "verify passed but never confirmed the bundled router. Got: $outB" ;;
esac
# And it must have resolved the STABLE path, not the shadowing PATH entry.
case "$outB" in
  *"$HOME/.local/bin/ccr"*) _pass "verify resolved the stable install path" ;;
  *) _fail "verify did not resolve \$HOME/.local/bin/ccr. Got: $outB" ;;
esac

# ============================================================================
it "C. no ccr anywhere -> verify FAILS"
rm -f "$HOME/.local/bin/ccr" "$SHADOW_DIR/ccr"
outC="$(CMA_CCR_BIN='' bash "$VERIFY" 2>&1)"; rcC=$?
assert_eq "1" "$rcC" "verify must exit 1 when no ccr exists at all"
case "$outC" in
  *"no router found"*) _pass "verify reported the absent router" ;;
  *) _fail "verify did not report the absent router. Got: $outC" ;;
esac
make_npm_ccr "$SHADOW_DIR/ccr"   # restore for later tests

# ============================================================================
it "D. CONTROL NEEDLE: the OLD fingerprint cannot discriminate; the new one can"
# This is the instrument-validation step (§11.4.201(7)(b)). If someone reverts
# the gate to the "ccr start"/"ccr serve" fingerprint, test A silently starts
# passing the doppelganger — so we prove HERE, against the same stubs, that
# the old tokens match BOTH binaries and only `ccr restart` separates them.
make_bundled_ccr "$HOME/.local/bin/ccr"
npm_help="$("$SHADOW_DIR/ccr" --help 2>&1)"
bun_help="$("$HOME/.local/bin/ccr" --help 2>&1)"

n_start=$(printf '%s' "$npm_help" | grep -c 'ccr start')
b_start=$(printf '%s' "$bun_help" | grep -c 'ccr start')
if (( n_start > 0 && b_start > 0 )); then
  _pass "'ccr start' matches BOTH (npm=$n_start bundled=$b_start) — old gate was blind, as diagnosed"
else
  _fail "control needle broken: 'ccr start' no longer matches both (npm=$n_start bundled=$b_start); the stubs no longer model the real binaries"
fi

n_restart=$(printf '%s' "$npm_help" | grep -c 'ccr restart')
b_restart=$(printf '%s' "$bun_help" | grep -c 'ccr restart')
assert_eq "0" "$n_restart" "npm router must NOT advertise 'ccr restart'"
if (( b_restart > 0 )); then
  _pass "'ccr restart' matches only the bundled router — the discriminator sees"
else
  _fail "bundled stub lost 'ccr restart'; the discriminator would be a false-negative"
fi

# ============================================================================
it "E. install.sh WIRES the gate: it calls verify and fails loudly, never [done]-over-broken"
# Structural, and deliberately so: running the whole installer here would drag
# in npm install / provider sync / doc export. The BEHAVIOUR of the gate is
# already proven by A-D above; what remains to prove is that install.sh
# actually consults it and that its success banner is reachable only after.
inst="$SCRIPTS_DIR/install.sh"
assert_file_contains "$inst" "claude-install-verify.sh" \
  "install.sh must invoke the post-install self-verify"
assert_file_contains "$inst" "CMA_INSTALL_FAILURES" \
  "install.sh must record build failures instead of only warning"
# The [done] banner must come AFTER the failure gate, never before it.
done_line="$(grep -n '\[done\] claude-multi-account installed' "$inst" | head -1 | cut -d: -f1)"
gate_line="$(grep -n 'CMA_INSTALL_FAILURES\[@\]} > 0' "$inst" | head -1 | cut -d: -f1)"
if [[ -n "$done_line" && -n "$gate_line" ]] && (( gate_line < done_line )); then
  _pass "the failure gate (line $gate_line) precedes the [done] banner (line $done_line)"
else
  _fail "[done] banner is not gated by the failure check (gate=$gate_line done=$done_line)"
fi
# And the ccr build must no longer be a bare warn-and-continue.
if grep -q 'cma_warn "bundled claude-code-router (Go) not built' "$inst"; then
  _fail "install.sh still only WARNS when the bundled router fails to build (the original defect)"
else
  _pass "the warn-and-continue on a failed router build is gone"
fi

# ============================================================================
# F/G/H simulate hosts MISSING tools (go / timeout). `command -v` consults PATH
# only, so a closed PATH over a symlink farm that lacks those tools IS such a
# host, hermetically (§11.4.201 — the path is part of the instrument). The farm
# mirrors /usr/bin + /bin rather than a hand-picked allowlist so the scripts
# keep every tool they legitimately need; only the deliberately-removed ones
# differ. `ccr` is also excluded so no host-installed router leaks in (the same
# closed-PATH lesson the header of this file records).
make_tool_farm() {  # $1 = farm dir; $2.. = command names to EXCLUDE
  local out="$1"; shift
  mkdir -p "$out"
  local d ex
  for d in /usr/bin /bin; do
    [ -d "$d" ] || continue
    # Bulk-link; duplicate basenames across the two dirs (usrmerge hosts) and
    # unlinkable oddities are ignored — first link wins.
    ln -s "$d"/* "$out"/ 2>/dev/null || true
  done
  for ex in "$@"; do rm -f "$out/$ex"; done
}
FARM="$HOME/.toolfarm-bin"
make_tool_farm "$FARM" go gofmt timeout gtimeout ccr
CCR_BUILD="$SCRIPTS_DIR/claude-ccr-build.sh"

# ============================================================================
it "F1. CONTROL NEEDLE: no Go + NO usable ccr -> claude-ccr-build still fails loudly"
# Proves two things at once: (a) the farm PATH is sufficient for the script to
# REACH its Go gate — the needle for F2/F3, §11.4.201(7)(b): without it, a
# blind instrument (script dying earlier for a missing tool) and a real Go-gate
# refusal would be indistinguishable; (b) the second half of the B1 acceptance:
# a genuinely-broken/absent artifact without Go remains a HARD failure.
rm -f "$HOME/.local/bin/ccr"
outF1="$(env PATH="$FARM" bash "$CCR_BUILD" 2>&1)"; rcF1=$?
assert_eq "1" "$rcF1" "ccr-build must exit 1: no Go AND no usable artifact"
case "$outF1" in
  *"Go toolchain not found"*) _pass "the Go gate was reached and refused (farm PATH proven sufficient)" ;;
  *) _fail "script never reached the Go gate under the farm PATH — instrument blind" "$outF1" ;;
esac

# ============================================================================
it "F2. B1: working bundled ccr + NO Go -> claude-ccr-build exits 0 with an honest staleness note"
# THE B1 finding (review 2026-07-22, live-proven): a routine 'git pull &&
# install.sh' upgrade on a host whose Go had been removed turned a WORKING
# install into [FAILED] exit 1 — a §11.4.201(1) false-positive refusal. The
# readiness gate must assert the ARTIFACT is usable (probe it), not that a
# build PREREQUISITE (Go) is present. install.sh step 2b records a failure
# ONLY on a non-zero exit here (wiring proven by test E), so exit 0 here is
# exactly what keeps that upgrade green end-to-end.
make_bundled_ccr "$HOME/.local/bin/ccr"
outF2="$(env PATH="$FARM" bash "$CCR_BUILD" 2>&1)"; rcF2=$?
assert_eq "0" "$rcF2" "ccr-build must exit 0: the existing bundled router is USABLE without Go"
case "$outF2" in
  *"verified usable"*) _pass "the existing artifact was probed and confirmed usable" ;;
  *) _fail "no usability confirmation in the output" "$outF2" ;;
esac
case "$outF2" in
  *STALE*|*stale*) _pass "the staleness consequence (no rebuild without Go) is stated honestly" ;;
  *) _fail "exit 0 without the staleness warning would overclaim" "$outF2" ;;
esac

# ============================================================================
it "F3. no Go + npm doppelganger at the install path -> still a hard failure"
# Guards against an over-permissive B1 fix: '-x exists' alone must NOT short-
# circuit — the resident artifact must pass the 'ccr restart' discriminator,
# otherwise the doppelganger would ride the new exit-0 path straight past the
# very gate built to catch it.
make_npm_ccr "$HOME/.local/bin/ccr"
outF3="$(env PATH="$FARM" bash "$CCR_BUILD" 2>&1)"; rcF3=$?
assert_eq "1" "$rcF3" "ccr-build must exit 1: the resident ccr is the npm doppelganger"
case "$outF3" in
  *"verified usable"*) _fail "the doppelganger was accepted as usable — discriminator bypassed" "$outF3" ;;
  *"Go toolchain not found"*) _pass "fell through to the loud Go-gate failure" ;;
  *) _fail "unexpected outcome" "$outF3" ;;
esac

# ============================================================================
it "G. I1+M2: wedged ccr + host WITHOUT timeout(1) -> verify stays BOUNDED and names the hang"
# I1: the probe was proven bounded only through coreutils `timeout`; the
# fallback branch (macOS without coreutils) ran the binary UNBOUNDED, so a
# wedged router hung the install forever — contradicting the header's
# "without ever hanging". The farm PATH has NO timeout/gtimeout and the stub
# never answers --help: verify must still complete, and (M2) must report the
# WEDGE as the cause — distinctly from "not a router".
sandbox_stub "$HOME/.local/bin/ccr" <<'STUB'
#!/usr/bin/env bash
# wedged router: never answers --help
exec sleep 600
STUB
# Outer guard so the RED state (pre-fix unbounded probe) cannot hang the suite;
# after the fix the run finishes in ~CMA_VERIFY_PROBE_BUDGET seconds.
_outer=()
command -v timeout >/dev/null 2>&1 && _outer=(timeout 60)
outG="$(${_outer[@]+"${_outer[@]}"} env PATH="$FARM" CMA_CCR_BIN='' CMA_VERIFY_PROBE_BUDGET=3 bash "$VERIFY" 2>&1)"; rcG=$?
if (( rcG == 124 )); then
  _fail "verify HUNG past the 60s outer guard — the probe is still unbounded without timeout(1)"
else
  _pass "verify completed on a timeout-less host (rc=$rcG)"
fi
assert_eq "1" "$rcG" "verify must FAIL (exit 1) on a wedged router"
case "$outG" in
  *"did not answer --help"*) _pass "the hang was reported distinctly (M2)" ;;
  *) _fail "wedged binary not reported as a hang" "$outG" ;;
esac
case "$outG" in
  *"not a claude-code-router at all"*) _fail "wedge misclassified as 'not a router' (the M2 conflation)" "$outG" ;;
  *) _pass "no misclassification as 'not a router'" ;;
esac

# ============================================================================
it "H. M1: DANGLING symlink at the stable install path -> named 'not executable' diagnostic"
# The 'exists but is not executable' branch was UNREACHABLE: a dangling
# symlink fell through to the PATH fallback and surfaced as 'no router found'
# (or as whatever unrelated ccr PATH happened to hold), hiding the actually-
# broken artifact. A stable path that EXISTS but cannot run must be diagnosed
# AS ITSELF.
rm -f "$HOME/.local/bin/ccr"
ln -s "$HOME/.local/bin/no-such-target" "$HOME/.local/bin/ccr"
outH="$(env PATH="$FARM" CMA_CCR_BIN='' bash "$VERIFY" 2>&1)"; rcH=$?
assert_eq "1" "$rcH" "verify must exit 1 on a dangling ccr symlink"
case "$outH" in
  *"not executable"*) _pass "the dangling symlink was diagnosed as itself (reachable branch)" ;;
  *) _fail "dangling symlink not diagnosed distinctly" "$outH" ;;
esac
rm -f "$HOME/.local/bin/ccr"

summary
