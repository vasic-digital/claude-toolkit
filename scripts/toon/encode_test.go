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
	"os"
	"os/exec"
	"path/filepath"
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
