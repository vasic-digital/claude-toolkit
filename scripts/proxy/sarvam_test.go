// sarvam_test.go — mirrors scripts/tests/test_sarvam_proxy.sh (the behavior
// spec for sarvam_proxy.py's flatten_content / fix_request) against the Go port.
package main

import (
	"encoding/json"
	"testing"
)

// sarvamStr is a tiny helper for asserting a value equals an expected string.
func sarvamStr(t *testing.T, got interface{}, want, msg string) {
	t.Helper()
	s, ok := got.(string)
	if !ok {
		t.Fatalf("%s: not a string: %T (%v)", msg, got, got)
	}
	if s != want {
		t.Fatalf("%s: got %q want %q", msg, s, want)
	}
}

// sarvamBlock builds a {"type":"text","text":...} content block.
func sarvamBlock(text string) map[string]interface{} {
	return map[string]interface{}{"type": "text", "text": text}
}

// TestSarvamFlattenJoinsTextBlocks mirrors: "flatten_content joins text blocks
// into one string" — two text blocks joined with newline.
func TestSarvamFlattenJoinsTextBlocks(t *testing.T) {
	c := []interface{}{sarvamBlock("You are helpful."), sarvamBlock("Be brief.")}
	sarvamStr(t, sarvamFlattenContent(c), "You are helpful.\nBe brief.",
		"two text blocks joined with newline")
}

// TestSarvamFlattenLeavesStrings mirrors: "flatten_content leaves plain strings
// untouched".
func TestSarvamFlattenLeavesStrings(t *testing.T) {
	sarvamStr(t, sarvamFlattenContent("already a string"), "already a string",
		"string content passes through")
}

// TestSarvamFlattenDropsEmptyAndNonText covers the join filter (`if p`) and the
// non-text drop in flatten_content.
func TestSarvamFlattenDropsEmptyAndNonText(t *testing.T) {
	c := []interface{}{
		sarvamBlock(""), // empty text -> dropped
		map[string]interface{}{"type": "image", "url": "x"}, // non-text -> dropped
		sarvamBlock("hi"),                      // kept
		map[string]interface{}{"type": "text"}, // missing text -> "" -> dropped
	}
	sarvamStr(t, sarvamFlattenContent(c), "hi", "empty/non-text/missing-text blocks dropped")
}

// TestSarvamFixFlattensAllRoles mirrors: "fix_request flattens content arrays
// for ALL roles (system AND user)".
func TestSarvamFixFlattensAllRoles(t *testing.T) {
	b := map[string]interface{}{"messages": []interface{}{
		map[string]interface{}{"role": "system", "content": []interface{}{
			sarvamBlock("sys one"), sarvamBlock("sys two")}},
		map[string]interface{}{"role": "user", "content": []interface{}{
			sarvamBlock("usr one")}},
	}}
	r := sarvamFix(b)
	msgs := r["messages"].([]interface{})
	sarvamStr(t, msgs[0].(map[string]interface{})["content"], "sys one\nsys two", "system flattened")
	sarvamStr(t, msgs[1].(map[string]interface{})["content"], "usr one", "user flattened")
}

// TestSarvamFixNoOp mirrors: "fix_request is a no-op when no system content
// array is present" — already-valid string bodies pass through unchanged.
func TestSarvamFixNoOp(t *testing.T) {
	b := map[string]interface{}{
		"messages": []interface{}{
			map[string]interface{}{"role": "system", "content": "plain"},
			map[string]interface{}{"role": "user", "content": "hi"},
		},
		"model": "m",
	}
	r := sarvamFix(b)
	msgs := r["messages"].([]interface{})
	sarvamStr(t, msgs[0].(map[string]interface{})["content"], "plain", "system string untouched")
	sarvamStr(t, msgs[1].(map[string]interface{})["content"], "hi", "user string untouched")
	sarvamStr(t, r["model"], "m", "model untouched")
	if _, present := r["max_tokens"]; present {
		t.Fatalf("max_tokens should stay absent, got %v", r["max_tokens"])
	}
}

// TestSarvamFixClampsMaxTokens mirrors: "fix_request clamps max_tokens above the
// tier ceiling (4096) but keeps smaller values" — 64000 -> 4096; 2048 kept;
// absent stays absent. Exercised through the default env-derived ceiling.
func TestSarvamFixClampsMaxTokens(t *testing.T) {
	a := sarvamFix(map[string]interface{}{"max_tokens": 64000, "messages": []interface{}{}})
	if got := a["max_tokens"]; got != sarvamDefaultMaxOutputTokens {
		t.Fatalf("64000 should clamp to %d, got %v", sarvamDefaultMaxOutputTokens, got)
	}
	b := sarvamFix(map[string]interface{}{"max_tokens": 2048, "messages": []interface{}{}})
	if got := b["max_tokens"]; got != 2048 {
		t.Fatalf("2048 should be kept, got %v", got)
	}
	c := sarvamFix(map[string]interface{}{"messages": []interface{}{}})
	if _, present := c["max_tokens"]; present {
		t.Fatalf("absent max_tokens should stay absent, got %v", c["max_tokens"])
	}
}

// TestSarvamFixClampFloatAndBoundary confirms JSON-decoded floats clamp (real
// requests decode numbers to float64) and that an exact-ceiling value is kept
// (python uses `mt > MAX`, strict).
func TestSarvamFixClampFloatAndBoundary(t *testing.T) {
	// Simulate a real decoded request body (numbers -> float64).
	var body map[string]interface{}
	if err := json.Unmarshal([]byte(`{"max_tokens":64000,"messages":[]}`), &body); err != nil {
		t.Fatalf("unmarshal: %v", err)
	}
	r := sarvamFix(body)
	if got := r["max_tokens"]; got != sarvamDefaultMaxOutputTokens {
		t.Fatalf("float 64000 should clamp to %d, got %v", sarvamDefaultMaxOutputTokens, got)
	}
	// Boundary: exactly the ceiling is not > ceiling, so it is kept as-is.
	eq := sarvamFix(map[string]interface{}{"max_tokens": sarvamDefaultMaxOutputTokens, "messages": []interface{}{}})
	if got := eq["max_tokens"]; got != sarvamDefaultMaxOutputTokens {
		t.Fatalf("ceiling value should be kept, got %v", got)
	}
	// Non-numeric max_tokens (string) is not a number -> left untouched.
	s := sarvamFix(map[string]interface{}{"max_tokens": "64000", "messages": []interface{}{}})
	sarvamStr(t, s["max_tokens"], "64000", "string max_tokens left untouched")
}

// TestSarvamReadMaxOutputTokens covers the env-knob parse: default, valid
// override, and unparseable fallback — matching sarvam_proxy.py's guarded int().
func TestSarvamReadMaxOutputTokens(t *testing.T) {
	t.Setenv("SARVAM_MAX_OUTPUT_TOKENS", "")
	if got := sarvamReadMaxOutputTokens(); got != sarvamDefaultMaxOutputTokens {
		t.Fatalf("empty -> default %d, got %d", sarvamDefaultMaxOutputTokens, got)
	}
	t.Setenv("SARVAM_MAX_OUTPUT_TOKENS", "8192")
	if got := sarvamReadMaxOutputTokens(); got != 8192 {
		t.Fatalf("valid override -> 8192, got %d", got)
	}
	t.Setenv("SARVAM_MAX_OUTPUT_TOKENS", "not-a-number")
	if got := sarvamReadMaxOutputTokens(); got != sarvamDefaultMaxOutputTokens {
		t.Fatalf("unparseable -> default %d, got %d", sarvamDefaultMaxOutputTokens, got)
	}
}
