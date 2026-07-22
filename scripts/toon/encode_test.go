// encode_test.go — parity proof for the Go port of scripts/toon_encode.py.
//
// Anti-bluff design (§11.4.5 / §11.4.50 / §11.4.107): the golden vectors are NOT
// hand-written. For every input in testdata/inputs.json the test executes the
// REAL Python wrapper (scripts/toon_encode.py) to produce the golden output, and
// the REAL compiled Go binary to produce the candidate output, then asserts the
// two are byte-identical (stdout) with matching exit codes — in BOTH the primary
// Node path and the degraded fallback path. If Python/Node/toon.mjs are absent
// the parity tests SKIP with a reason (§11.4.3 topology skip), never fake-pass.
package main

import (
	"bytes"
	"encoding/json"
	"errors"
	"fmt"
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
	"strings"
	"testing"
)

type vectors struct {
	Valid   []string `json:"valid"`
	Invalid []string `json:"invalid"`
}

func loadVectors(t *testing.T) vectors {
	t.Helper()
	raw, err := os.ReadFile(filepath.Join("testdata", "inputs.json"))
	if err != nil {
		t.Fatalf("read inputs.json: %v", err)
	}
	var v vectors
	if err := json.Unmarshal(raw, &v); err != nil {
		t.Fatalf("parse inputs.json: %v", err)
	}
	return v
}

// repoRoot walks up from the module dir (scripts/toon) to the repo root that
// holds scripts/toon_encode.py.
func repoRoot(t *testing.T) string {
	t.Helper()
	root, err := filepath.Abs(filepath.Join("..", ".."))
	if err != nil {
		t.Fatalf("resolve repo root: %v", err)
	}
	if _, err := os.Stat(filepath.Join(root, "scripts", "toon_encode.py")); err != nil {
		t.Fatalf("scripts/toon_encode.py not found under %s: %v", root, err)
	}
	return root
}

// buildBinary compiles the Go CLI into dir and returns its path.
func buildBinary(t *testing.T, dir string) string {
	t.Helper()
	bin := filepath.Join(dir, "toon_encode")
	cmd := exec.Command("go", "build", "-o", bin, ".")
	var stderr bytes.Buffer
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("go build failed: %v\n%s", err, stderr.String())
	}
	return bin
}

type result struct {
	stdout string
	exit   int
}

// runProc feeds stdin to bin (with args) under env and captures stdout + exit.
func runProc(t *testing.T, bin string, args []string, stdin string, env []string) result {
	t.Helper()
	cmd := exec.Command(bin, args...)
	cmd.Stdin = strings.NewReader(stdin)
	cmd.Env = env
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	err := cmd.Run()
	exit := 0
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			exit = ee.ExitCode()
		} else {
			t.Fatalf("run %s: %v", bin, err)
		}
	}
	return result{stdout: stdout.String(), exit: exit}
}

func haveCmd(name string) bool {
	_, err := exec.LookPath(name)
	return err == nil
}

// envWith returns a copy of the current environment with the given key set (or
// removed when val == "").
func envWith(base []string, key, val string) []string {
	out := make([]string, 0, len(base)+1)
	prefix := key + "="
	for _, e := range base {
		if strings.HasPrefix(e, prefix) {
			continue
		}
		out = append(out, e)
	}
	if val != "" {
		out = append(out, prefix+val)
	}
	return out
}

// TestParityNodeMode proves byte-identical output between the real Python
// wrapper and the real Go binary when both drive the same toon.mjs via Node.
func TestParityNodeMode(t *testing.T) {
	root := repoRoot(t)
	pyScript := filepath.Join(root, "scripts", "toon_encode.py")
	toonMjs := filepath.Join(root, "scripts", "toon.mjs")
	if !haveCmd("python3") {
		t.Skip("SKIP: python3 not installed")
	}
	if !haveCmd("node") {
		t.Skip("SKIP: node not installed")
	}
	if _, err := os.Stat(toonMjs); err != nil {
		t.Skip("SKIP: scripts/toon.mjs not present")
	}
	// Confirm the @toon-format/toon package is actually installed (mirrors
	// test_toon.sh's dependency probe) — otherwise Python itself falls back and
	// this would not be a Node-mode test.
	probe := exec.Command("node", toonMjs, "encode", "{}")
	if err := probe.Run(); err != nil {
		t.Skip("SKIP: @toon-format/toon package not installed (node probe failed)")
	}

	binDir := t.TempDir()
	bin := buildBinary(t, binDir)
	v := loadVectors(t)

	pyEnv := os.Environ()
	goEnv := envWith(os.Environ(), "CMA_TOON_SCRIPT", toonMjs)

	for _, in := range v.Valid {
		py := runProc(t, "python3", []string{pyScript}, in, pyEnv)
		go_ := runProc(t, bin, nil, in, goEnv)
		if py.exit != 0 {
			t.Errorf("python non-zero exit on valid input %q (exit=%d)", in, py.exit)
			continue
		}
		if py.stdout != go_.stdout || py.exit != go_.exit {
			t.Errorf("NODE-MODE MISMATCH\ninput:  %q\npython: exit=%d %q\ngo:     exit=%d %q",
				in, py.exit, py.stdout, go_.exit, go_.stdout)
		}
	}

	for _, in := range v.Invalid {
		py := runProc(t, "python3", []string{pyScript}, in, pyEnv)
		go_ := runProc(t, bin, nil, in, goEnv)
		if py.exit == 0 || go_.exit == 0 {
			t.Errorf("INVALID-INPUT exit parity broken\ninput: %q\npython exit=%d\ngo exit=%d",
				in, py.exit, go_.exit)
		}
		if py.stdout != "" || go_.stdout != "" {
			t.Errorf("INVALID-INPUT emitted stdout\ninput: %q\npython=%q go=%q",
				in, py.stdout, go_.stdout)
		}
	}
}

// TestParityFallbackMode proves byte-identical output between the real Python
// wrapper and the real Go binary when both are forced onto the YAML-like
// fallback path (toon.mjs unreachable). Both run from an isolated directory with
// no sibling toon.mjs and an isolated HOME (no user-share toon.mjs).
func TestParityFallbackMode(t *testing.T) {
	root := repoRoot(t)
	pyScriptSrc := filepath.Join(root, "scripts", "toon_encode.py")
	if !haveCmd("python3") {
		t.Skip("SKIP: python3 not installed")
	}

	isoHome := t.TempDir()

	// Python fallback: a copy of the wrapper with no sibling toon.mjs.
	pyDir := t.TempDir()
	pyScript := filepath.Join(pyDir, "toon_encode.py")
	src, err := os.ReadFile(pyScriptSrc)
	if err != nil {
		t.Fatalf("read python source: %v", err)
	}
	if err := os.WriteFile(pyScript, src, 0o644); err != nil {
		t.Fatalf("copy python source: %v", err)
	}

	// Go fallback: binary built into an isolated dir (no toon.mjs up the tree).
	binDir := t.TempDir()
	bin := buildBinary(t, binDir)

	base := os.Environ()
	fallbackEnv := envWith(envWith(base, "HOME", isoHome), "CMA_TOON_SCRIPT", "")
	v := loadVectors(t)

	// Sanity: prove Python really took the fallback path (its Node-mode output
	// for {"a":[{"k":1}]} is "a[1]{k}:", the fallback output is "a:\n  [1]{k}:\n  1").
	probe := runProc(t, "python3", []string{pyScript}, `{"a":[{"k":1}]}`, fallbackEnv)
	if strings.Contains(probe.stdout, "a[1]{k}:") {
		t.Fatalf("fallback isolation failed: python still reached toon.mjs (got %q)", probe.stdout)
	}
	// Symmetric Go-side probe: prove the Go binary ALSO really took the
	// fallback path in this environment, not a stray reachable toon.mjs.
	goProbe := runProc(t, bin, nil, `{"a":[{"k":1}]}`, fallbackEnv)
	if strings.Contains(goProbe.stdout, "a[1]{k}:") {
		t.Fatalf("fallback isolation failed: go binary still reached toon.mjs (got %q)", goProbe.stdout)
	}

	for _, in := range v.Valid {
		py := runProc(t, "python3", []string{pyScript}, in, fallbackEnv)
		go_ := runProc(t, bin, nil, in, fallbackEnv)
		if py.exit != 0 {
			t.Errorf("python non-zero exit on valid input %q (exit=%d)", in, py.exit)
			continue
		}
		if py.stdout != go_.stdout || py.exit != go_.exit {
			t.Errorf("FALLBACK-MODE MISMATCH\ninput:  %q\npython: exit=%d %q\ngo:     exit=%d %q",
				in, py.exit, py.stdout, go_.exit, go_.stdout)
		}
	}

	for _, in := range v.Invalid {
		py := runProc(t, "python3", []string{pyScript}, in, fallbackEnv)
		go_ := runProc(t, bin, nil, in, fallbackEnv)
		if py.exit == 0 || go_.exit == 0 {
			t.Errorf("FALLBACK INVALID-INPUT exit parity broken\ninput: %q\npython exit=%d go exit=%d",
				in, py.exit, go_.exit)
		}
	}
}

// runViaFile writes jsonStr to a fresh file inside dir and returns the
// --file invocation args (no stdin needed).
func runViaFile(t *testing.T, dir, jsonStr string, n int) []string {
	t.Helper()
	path := filepath.Join(dir, fmt.Sprintf("input_%d.json", n))
	if err := os.WriteFile(path, []byte(jsonStr), 0o644); err != nil {
		t.Fatalf("write input file: %v", err)
	}
	return []string{"--file", path}
}

// TestParityInputPathsFallback closes the review finding that only the stdin
// path was parity-tested: it proves byte-identical output between the real
// Python wrapper and the real Go binary via the --file flag AND the
// positional-argument form, in the fallback (no-toon.mjs) mode — the mode
// where the review's real python3-vs-Go run found the number-formatting
// divergence (e.g. {"n":1.50} diverged specifically over --file too).
func TestParityInputPathsFallback(t *testing.T) {
	root := repoRoot(t)
	pyScriptSrc := filepath.Join(root, "scripts", "toon_encode.py")
	if !haveCmd("python3") {
		t.Skip("SKIP: python3 not installed")
	}

	isoHome := t.TempDir()
	pyDir := t.TempDir()
	pyScript := filepath.Join(pyDir, "toon_encode.py")
	src, err := os.ReadFile(pyScriptSrc)
	if err != nil {
		t.Fatalf("read python source: %v", err)
	}
	if err := os.WriteFile(pyScript, src, 0o644); err != nil {
		t.Fatalf("copy python source: %v", err)
	}

	binDir := t.TempDir()
	bin := buildBinary(t, binDir)
	fallbackEnv := envWith(envWith(os.Environ(), "HOME", isoHome), "CMA_TOON_SCRIPT", "")
	v := loadVectors(t)
	fileDir := t.TempDir()

	for i, in := range v.Valid {
		// --file path.
		fileArgs := runViaFile(t, fileDir, in, i)
		py := runProc(t, "python3", append([]string{pyScript}, fileArgs...), "", fallbackEnv)
		go_ := runProc(t, bin, fileArgs, "", fallbackEnv)
		if py.exit != 0 {
			t.Errorf("python non-zero exit on valid --file input %q (exit=%d)", in, py.exit)
		} else if py.stdout != go_.stdout || py.exit != go_.exit {
			t.Errorf("FALLBACK --file MISMATCH\ninput:  %q\npython: exit=%d %q\ngo:     exit=%d %q",
				in, py.exit, py.stdout, go_.exit, go_.stdout)
		}

		// Positional-argument path (skip empty string: argparse treats a
		// positional "" identically to "not given", which is stdin — not
		// a distinct positional-arg case worth asserting here).
		if in == "" {
			continue
		}
		py = runProc(t, "python3", []string{pyScript, in}, "", fallbackEnv)
		go_ = runProc(t, bin, []string{in}, "", fallbackEnv)
		if py.exit != 0 {
			t.Errorf("python non-zero exit on valid positional input %q (exit=%d)", in, py.exit)
		} else if py.stdout != go_.stdout || py.exit != go_.exit {
			t.Errorf("FALLBACK positional-arg MISMATCH\ninput:  %q\npython: exit=%d %q\ngo:     exit=%d %q",
				in, py.exit, py.stdout, go_.exit, go_.stdout)
		}
	}
}

// TestParityInputPathsNodeMode is TestParityInputPathsFallback's Node-mode
// counterpart: proves --file and positional-argument parity when both
// wrappers drive the real toon.mjs via node.
func TestParityInputPathsNodeMode(t *testing.T) {
	root := repoRoot(t)
	pyScript := filepath.Join(root, "scripts", "toon_encode.py")
	toonMjs := filepath.Join(root, "scripts", "toon.mjs")
	if !haveCmd("python3") {
		t.Skip("SKIP: python3 not installed")
	}
	if !haveCmd("node") {
		t.Skip("SKIP: node not installed")
	}
	if _, err := os.Stat(toonMjs); err != nil {
		t.Skip("SKIP: scripts/toon.mjs not present")
	}
	probe := exec.Command("node", toonMjs, "encode", "{}")
	if err := probe.Run(); err != nil {
		t.Skip("SKIP: @toon-format/toon package not installed (node probe failed)")
	}

	binDir := t.TempDir()
	bin := buildBinary(t, binDir)
	v := loadVectors(t)
	fileDir := t.TempDir()

	pyEnv := os.Environ()
	goEnv := envWith(os.Environ(), "CMA_TOON_SCRIPT", toonMjs)

	for i, in := range v.Valid {
		fileArgs := runViaFile(t, fileDir, in, i)
		py := runProc(t, "python3", append([]string{pyScript}, fileArgs...), "", pyEnv)
		go_ := runProc(t, bin, fileArgs, "", goEnv)
		if py.exit != 0 {
			t.Errorf("python non-zero exit on valid --file input %q (exit=%d)", in, py.exit)
		} else if py.stdout != go_.stdout || py.exit != go_.exit {
			t.Errorf("NODE-MODE --file MISMATCH\ninput:  %q\npython: exit=%d %q\ngo:     exit=%d %q",
				in, py.exit, py.stdout, go_.exit, go_.stdout)
		}

		if in == "" {
			continue
		}
		py = runProc(t, "python3", []string{pyScript, in}, "", pyEnv)
		go_ = runProc(t, bin, []string{in}, "", goEnv)
		if py.exit != 0 {
			t.Errorf("python non-zero exit on valid positional input %q (exit=%d)", in, py.exit)
		} else if py.stdout != go_.stdout || py.exit != go_.exit {
			t.Errorf("NODE-MODE positional-arg MISMATCH\ninput:  %q\npython: exit=%d %q\ngo:     exit=%d %q",
				in, py.exit, py.stdout, go_.exit, go_.stdout)
		}
	}
}

// TestFindToonScriptWalkUp closes a §11.4.6 accuracy gap: the doc comment on
// findToonScript (encode.go) claims its two INTENTIONAL, non-Python-parity
// walk-up candidates (../toon.mjs and ../../toon.mjs relative to the running
// executable's directory) are "pinned down by TestFindToonScriptWalkUp ... so
// it cannot silently widen further" — this IS that test. Before this change
// no such test existed (grep-confirmed: the name appeared only inside that
// comment) and the comment's citation was false.
//
// It drives the REAL compiled toon_encode binary end-to-end — proving the
// whole resolve-then-shell-out pipeline, not merely the unexported resolver
// called in isolation — built into the two realistic in-place layouts the
// doc comment itself names (scripts/toon/ and scripts/toon/bin/), with a
// decoy toon.mjs seeded one and two levels up from the binary's own
// directory. Real node / @toon-format/toon is not required: the "node" the
// binary shells out to is a fake stand-in, prepended onto PATH, that simply
// echoes back the exact script path it was invoked with — turning the
// binary's own stdout into a direct, unambiguous witness of which candidate
// findToonScript() selected, with zero need to reach into the package's
// unexported state.
func TestFindToonScriptWalkUp(t *testing.T) {
	// fakeNode reports the script path it is told to run instead of actually
	// encoding anything, so a candidate SELECTION is observable without any
	// real Node.js / @toon-format/toon dependency (this test must run even
	// where neither is installed).
	fakeBinDir := t.TempDir()
	fakeNode := filepath.Join(fakeBinDir, "node")
	if err := os.WriteFile(fakeNode, []byte("#!/bin/sh\necho \"SELECTED:$1\"\n"), 0o755); err != nil {
		t.Fatalf("write fake node stand-in: %v", err)
	}
	pathWithFakeNode := fakeBinDir + string(os.PathListSeparator) + os.Getenv("PATH")

	// isolatedEnv strips CMA_TOON_SCRIPT (the highest-priority candidate,
	// which must NOT be in play here) and points HOME at an empty temp dir
	// (so the ~/.local/share/claude-multi-account fallback candidate never
	// resolves either) — isolating the two walk-up candidates as the ONLY
	// ones left standing.
	isolatedEnv := func(t *testing.T, path string) []string {
		t.Helper()
		isoHome := t.TempDir()
		base := envWith(os.Environ(), "HOME", isoHome)
		base = envWith(base, "CMA_TOON_SCRIPT", "")
		return envWith(base, "PATH", path)
	}

	buildAt := func(t *testing.T, exeDir string) string {
		t.Helper()
		if err := os.MkdirAll(exeDir, 0o755); err != nil {
			t.Fatalf("mkdir %s: %v", exeDir, err)
		}
		return buildBinary(t, exeDir)
	}

	writeDecoy := func(t *testing.T, path string) {
		t.Helper()
		if err := os.WriteFile(path, []byte("// decoy toon.mjs — never actually executed\n"), 0o644); err != nil {
			t.Fatalf("write decoy %s: %v", path, err)
		}
	}

	// mustEvalSymlinks resolves a path to its canonical form so path identity
	// is compared by the physical file on disk, never by raw string form —
	// os.Executable() inside the child may report a symlink-resolved
	// (canonicalized) form of a directory under t.TempDir() that differs
	// character-for-character from the string this test built, even though
	// both name the exact same file (§11.4.201: the path is part of the
	// instrument — compare what the two sides actually mean, not their
	// incidental spelling).
	mustEvalSymlinks := func(t *testing.T, p string) string {
		t.Helper()
		r, err := filepath.EvalSymlinks(p)
		if err != nil {
			t.Fatalf("EvalSymlinks(%q): %v", p, err)
		}
		return r
	}

	t.Run("two_level_walkup_only", func(t *testing.T) {
		// Realistic layout #2 from the doc comment: binary built under
		// scripts/toon/bin/, so exeDir/../../toon.mjs is scripts/toon.mjs.
		root := t.TempDir()
		exeDir := filepath.Join(root, "scripts", "toon", "bin")
		bin := buildAt(t, exeDir)
		decoy := filepath.Join(exeDir, "..", "..", "toon.mjs") // == root/scripts/toon.mjs
		writeDecoy(t, decoy)

		got := runProc(t, bin, nil, `{}`, isolatedEnv(t, pathWithFakeNode))
		if got.exit != 0 {
			t.Fatalf("exit=%d stdout=%q", got.exit, got.stdout)
		}
		line := strings.TrimSuffix(got.stdout, "\n")
		if !strings.HasPrefix(line, "SELECTED:") {
			t.Fatalf("two-level walk-up candidate not reached: stdout=%q", got.stdout)
		}
		gotPath := strings.TrimPrefix(line, "SELECTED:")
		if mustEvalSymlinks(t, gotPath) != mustEvalSymlinks(t, decoy) {
			t.Fatalf("resolved script %q does not refer to the seeded two-level decoy %q", gotPath, decoy)
		}
	})

	t.Run("one_level_walkup_wins_over_two_level", func(t *testing.T) {
		// Realistic layout #1 from the doc comment: binary built directly
		// under scripts/toon/, so exeDir/../toon.mjs is scripts/toon.mjs.
		// BOTH the one-level and two-level candidates are seeded here to
		// prove candidate ORDER — sibling, then one-up, then two-up — not
		// merely that "some" walk-up candidate resolves.
		root := t.TempDir()
		exeDir := filepath.Join(root, "scripts", "toon")
		bin := buildAt(t, exeDir)
		oneUp := filepath.Join(exeDir, "..", "toon.mjs")       // == root/scripts/toon.mjs
		twoUp := filepath.Join(exeDir, "..", "..", "toon.mjs") // == root/toon.mjs
		writeDecoy(t, oneUp)
		writeDecoy(t, twoUp)

		got := runProc(t, bin, nil, `{}`, isolatedEnv(t, pathWithFakeNode))
		if got.exit != 0 {
			t.Fatalf("exit=%d stdout=%q", got.exit, got.stdout)
		}
		line := strings.TrimSuffix(got.stdout, "\n")
		if !strings.HasPrefix(line, "SELECTED:") {
			t.Fatalf("one-level walk-up candidate not reached: stdout=%q", got.stdout)
		}
		gotPath := strings.TrimPrefix(line, "SELECTED:")
		if mustEvalSymlinks(t, gotPath) != mustEvalSymlinks(t, oneUp) {
			t.Fatalf("one-up did not win: resolved script %q, want %q (two-up %q)", gotPath, oneUp, twoUp)
		}
	})

	t.Run("no_decoy_falls_through_to_fallback", func(t *testing.T) {
		// Negative control (§11.4.201 control-needle discipline): with
		// NEITHER walk-up candidate present, findToonScript() must return ""
		// and the binary must take the ordinary fallback path — never
		// fabricate a hit. Proves the two positive cases above are genuinely
		// conditioned on the seeded decoy files, not an artifact of the
		// fake-node harness always reporting a match.
		root := t.TempDir()
		exeDir := filepath.Join(root, "scripts", "toon", "bin")
		bin := buildAt(t, exeDir)

		in := `{"a":1}`
		data, err := parseOrdered([]byte(in))
		if err != nil {
			t.Fatalf("parseOrdered(%q): %v", in, err)
		}
		want := fallbackEncode(data, 0) + "\n"

		got := runProc(t, bin, nil, in, isolatedEnv(t, pathWithFakeNode))
		if got.exit != 0 || got.stdout != want {
			t.Fatalf("no-decoy case did not fall through to the fallback encoder\n got: exit=%d stdout=%q\nwant: exit=0 stdout=%q",
				got.exit, got.stdout, want)
		}
		if strings.Contains(got.stdout, "SELECTED:") {
			t.Fatalf("no-decoy case unexpectedly reached the fake node stand-in: %q", got.stdout)
		}
	})
}

// TestNaNInfinityDocumentedDivergence GATES a known, deliberately-NOT-CLOSED
// divergence (§11.4.6 honest documentation, not silence): Python's json
// module accepts the non-standard bare literals NaN/Infinity/-Infinity
// (json.loads's default parse_constant) and exits 0; Go's encoding/json
// implements strict JSON grammar and rejects them, exiting 1. Closing this
// gap would require a bespoke JSON tokenizer accepting these three bare
// identifiers ONLY in value position (encoding/json's Decoder has no such
// extension point, and a naive text-substitution pre-pass would be unsafe —
// it cannot tell a bare NaN token from the literal text "NaN" inside a JSON
// string without re-implementing the tokenizer regardless). Accepted-lossy
// per the review's own instruction; this test exists so a future change to
// EITHER side's behaviour on this exact input set is caught, never silent.
func TestNaNInfinityDocumentedDivergence(t *testing.T) {
	root := repoRoot(t)
	pyScriptSrc := filepath.Join(root, "scripts", "toon_encode.py")
	if !haveCmd("python3") {
		t.Skip("SKIP: python3 not installed")
	}
	isoHome := t.TempDir()
	pyDir := t.TempDir()
	pyScript := filepath.Join(pyDir, "toon_encode.py")
	src, err := os.ReadFile(pyScriptSrc)
	if err != nil {
		t.Fatalf("read python source: %v", err)
	}
	if err := os.WriteFile(pyScript, src, 0o644); err != nil {
		t.Fatalf("copy python source: %v", err)
	}
	binDir := t.TempDir()
	bin := buildBinary(t, binDir)
	fallbackEnv := envWith(envWith(os.Environ(), "HOME", isoHome), "CMA_TOON_SCRIPT", "")

	cases := []struct {
		in         string
		pyWant     string
		pyWantExit int
	}{
		{`{"n":NaN}`, "n: NaN\n", 0},
		{`{"n":Infinity}`, "n: Infinity\n", 0},
		{`{"n":-Infinity}`, "n: -Infinity\n", 0},
		{`NaN`, "nan\n", 0},
		{`Infinity`, "inf\n", 0},
		{`-Infinity`, "-inf\n", 0},
	}
	for _, c := range cases {
		py := runProc(t, "python3", []string{pyScript}, c.in, fallbackEnv)
		if py.exit != c.pyWantExit || py.stdout != c.pyWant {
			t.Errorf("python behaviour on %q changed — update this documented divergence: exit=%d stdout=%q (want exit=%d stdout=%q)",
				c.in, py.exit, py.stdout, c.pyWantExit, c.pyWant)
		}
		go_ := runProc(t, bin, nil, c.in, fallbackEnv)
		if go_.exit == 0 {
			t.Errorf("go now ACCEPTS %q (exit 0, stdout=%q) — the NaN/Infinity gap is closed, update this test to assert parity instead of documenting divergence",
				c.in, go_.stdout)
		}
	}
}

// TestPyFloatRepr proves formatPyFloat matches CPython's repr(float) across a
// broad, deterministic sweep of float64 values — structured edge cases
// (every decpt boundary the fixed/scientific switch depends on, subnormals,
// DBL_MAX, signed zero) plus a large fixed-seed pseudo-random bit-pattern
// sample. Values cross to Python via IEEE-754 hex-float literals
// (float.fromhex), an encoding independent of the decimal formatter under
// test, so the oracle itself cannot be fooled by a shared formatting bug
// (§11.4.201 control-needle discipline applied to this test's own bridge).
// SKIPs (never fake-passes) when python3 is unavailable.
func TestPyFloatRepr(t *testing.T) {
	if !haveCmd("python3") {
		t.Skip("SKIP: python3 not installed")
	}

	values := pyFloatReprSweepValues()

	var script strings.Builder
	script.WriteString("import sys\n")
	script.WriteString("for line in sys.stdin:\n")
	script.WriteString("    line = line.strip()\n")
	script.WriteString("    if not line:\n        continue\n")
	script.WriteString("    print(repr(float.fromhex(line)))\n")

	var hexLines strings.Builder
	for _, f := range values {
		hexLines.WriteString(strconv.FormatFloat(f, 'x', -1, 64))
		hexLines.WriteByte('\n')
	}

	cmd := exec.Command("python3", "-c", script.String())
	cmd.Stdin = strings.NewReader(hexLines.String())
	var stdout, stderr bytes.Buffer
	cmd.Stdout = &stdout
	cmd.Stderr = &stderr
	if err := cmd.Run(); err != nil {
		t.Fatalf("python3 repr sweep failed: %v\nstderr: %s", err, stderr.String())
	}

	pyLines := strings.Split(strings.TrimRight(stdout.String(), "\n"), "\n")
	if len(pyLines) != len(values) {
		t.Fatalf("python3 produced %d lines for %d inputs", len(pyLines), len(values))
	}

	mismatches := 0
	for i, f := range values {
		got := formatPyFloat(f)
		want := pyLines[i]
		if got != want {
			mismatches++
			if mismatches <= 20 {
				t.Errorf("formatPyFloat(%s) = %q, python repr = %q", strconv.FormatFloat(f, 'x', -1, 64), got, want)
			}
		}
	}
	if mismatches > 20 {
		t.Errorf("... and %d more mismatches (%d/%d total)", mismatches-20, mismatches, len(values))
	}
}

// pyFloatReprSweepValues returns the deterministic value set TestPyFloatRepr
// checks: every decpt-threshold boundary case, the finite float64 extremes,
// and a fixed-seed pseudo-random bit-pattern sample (xorshift64, no math/rand
// dependency needed) spanning the full exponent range.
func pyFloatReprSweepValues() []float64 {
	values := []float64{
		0.0, math.Copysign(0, -1),
		1.0, -1.0, 9.9, 1.5, 100.0,
		1e15, 1e16, 1e17, // decpt 16/17/18 boundary (>16 switches to sci)
		1e-3, 1e-4, 1e-5, 1e-6, // decpt -3/-4 boundary (<=-4 switches to sci)
		9999999999999998.0, 1234567890123456.0, 12345678901234567.0,
		math.MaxFloat64, -math.MaxFloat64,
		4.9406564584124654e-324, // smallest positive subnormal (5e-324 rounds up)
		math.SmallestNonzeroFloat64,
		2.2250738585072014e-308, // smallest positive normal
	}
	// Structured exponent × mantissa sweep, matching the manual review that
	// found the original divergence.
	for _, exp := range []int{-320, -100, -20, -16, -15, -6, -5, -4, -3, 0, 3, 10, 15, 16, 17, 20, 100, 300} {
		for _, mant := range []float64{1, 1.5, 9.99999, 1.23456789012345, -1, -1.5} {
			v := mant * math.Pow(10, float64(exp))
			if !math.IsInf(v, 0) && !math.IsNaN(v) {
				values = append(values, v)
			}
		}
	}
	// Fixed-seed xorshift64 bit-pattern sample across the full float64 space,
	// filtered to finite values.
	var state uint64 = 0x2545F4914F6CDD1D
	for i := 0; i < 4000; i++ {
		state ^= state << 13
		state ^= state >> 7
		state ^= state << 17
		f := math.Float64frombits(state)
		if !math.IsNaN(f) && !math.IsInf(f, 0) {
			values = append(values, f)
		}
	}
	return values
}

// TestCLIContract is a hermetic (no external dependency) guard on the CLI
// contract: invalid JSON exits non-zero, --compact is a no-op, and stdin is the
// default input source. It complements the live-Python parity tests above and
// runs even where Python/Node are unavailable.
func TestCLIContract(t *testing.T) {
	// Invalid JSON → exit 1.
	if code := run([]string{}, strings.NewReader("not json"), &bytes.Buffer{}, &bytes.Buffer{}); code != 1 {
		t.Errorf("invalid JSON: want exit 1, got %d", code)
	}
	// Help → exit 0.
	if code := run([]string{"-h"}, strings.NewReader(""), &bytes.Buffer{}, &bytes.Buffer{}); code != 0 {
		t.Errorf("help: want exit 0, got %d", code)
	}
	// --compact accepted, valid stdin JSON → exit 0 with a trailing newline.
	var out bytes.Buffer
	if code := run([]string{"--compact"}, strings.NewReader(`{"x":1}`), &out, &bytes.Buffer{}); code != 0 {
		t.Errorf("valid stdin: want exit 0, got %d", code)
	}
	if !strings.HasSuffix(out.String(), "\n") {
		t.Errorf("output must end with a trailing newline, got %q", out.String())
	}
}
