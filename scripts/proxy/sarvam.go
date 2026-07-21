// sarvam.go — Sarvam API request compatibility transform (Go port of sarvam_proxy.py).
//
// Sarvam's chat endpoint is OpenAI-strict about message shapes: a message whose
// `content` is an ARRAY of content blocks is rejected with
// `400 body.messages.N.<role>.content : Input should be a valid string`
// (reproduced live for BOTH system and user roles). Claude Code (via
// claude-code-router) emits content blocks everywhere, so every real launch
// 400s while simple string probes pass. This transform flattens any message
// whose `content` is a list into a single joined string (text blocks
// concatenated with "\n"; empty text and non-text blocks dropped), which is the
// shape strict providers accept. Everything else passes through unchanged.
//
// It also clamps `max_tokens` down to the subscription-tier ceiling (starter:
// 4096, override via SARVAM_MAX_OUTPUT_TOKENS) because Claude Code's 64000
// default is rejected outright ("max_tokens (64000) exceeds the maximum allowed
// ... (starter): 4096" — reproduced live).
//
// Request-only: Sarvam responses are standard OpenAI JSON and pass through
// untouched (no registerResponse).
package main

import (
	"encoding/json"
	"os"
	"strconv"
	"strings"
)

// init registers the request transform so cma-proxy discovers and applies it.
func init() { registerRequest("sarvam", sarvamFix) }

// sarvamDefaultMaxOutputTokens is the starter-tier max_tokens ceiling; Claude
// Code's 64000 default 400s against it. Mirrors sarvam_proxy.py's fallback 4096.
const sarvamDefaultMaxOutputTokens = 4096

// sarvamMaxOutputTokens mirrors the python module-load read of
// SARVAM_MAX_OUTPUT_TOKENS (default 4096; any unparseable value falls back to
// 4096). Evaluated once at package init, as the python reads it once at import.
var sarvamMaxOutputTokens = sarvamReadMaxOutputTokens()

// sarvamReadMaxOutputTokens reads SARVAM_MAX_OUTPUT_TOKENS as an integer,
// falling back to sarvamDefaultMaxOutputTokens when unset or unparseable —
// matching python's `int(os.environ.get(...))` guarded by TypeError/ValueError.
func sarvamReadMaxOutputTokens() int {
	v := strings.TrimSpace(os.Getenv("SARVAM_MAX_OUTPUT_TOKENS"))
	if v == "" {
		return sarvamDefaultMaxOutputTokens
	}
	n, err := strconv.Atoi(v)
	if err != nil {
		return sarvamDefaultMaxOutputTokens
	}
	return n
}

// sarvamFlattenContent flattens a content-block list into a single string.
// Returns the input unchanged when it is not a list (a plain string passes
// through untouched). Text blocks are concatenated with "\n"; empty text and
// non-text blocks are dropped. Mirrors sarvam_proxy.py:flatten_content, where
// `"\n".join(p for p in parts if p)` drops the empty parts.
func sarvamFlattenContent(content interface{}) interface{} {
	list, ok := content.([]interface{})
	if !ok {
		return content
	}
	var parts []string
	for _, block := range list {
		bm, ok := block.(map[string]interface{})
		if !ok {
			continue
		}
		if t, _ := bm["type"].(string); t != "text" {
			continue
		}
		if text, _ := bm["text"].(string); text != "" {
			parts = append(parts, text)
		}
	}
	return strings.Join(parts, "\n")
}

// sarvamAsNumber reports the numeric value of an int/float max_tokens, matching
// python's `isinstance(mt, (int, float))`. JSON numbers decode to float64;
// direct int construction (tests) is also accepted. Strings/bools/nil/other
// types are not numbers and are left alone.
func sarvamAsNumber(v interface{}) (float64, bool) {
	switch n := v.(type) {
	case float64:
		return n, true
	case float32:
		return float64(n), true
	case int:
		return float64(n), true
	case int64:
		return float64(n), true
	case json.Number:
		f, err := n.Float64()
		return f, err == nil
	default:
		return 0, false
	}
}

// sarvamFix flattens every message whose `content` is a content-block array to a
// joined string (Sarvam 400s on array content for system AND user), then clamps
// `max_tokens` above the tier ceiling down to it. Returns the (in-place mutated)
// body. Mirrors sarvam_proxy.py:fix_request. Request-only.
func sarvamFix(body map[string]interface{}) map[string]interface{} {
	if messages, ok := body["messages"].([]interface{}); ok {
		for _, m := range messages {
			msg, ok := m.(map[string]interface{})
			if !ok {
				continue
			}
			if _, isList := msg["content"].([]interface{}); isList {
				msg["content"] = sarvamFlattenContent(msg["content"])
			}
		}
	}
	// Clamp max_tokens to the subscription-tier ceiling — Claude Code's 64000
	// default is rejected outright by the tier check.
	if mt, ok := sarvamAsNumber(body["max_tokens"]); ok && mt > float64(sarvamMaxOutputTokens) {
		body["max_tokens"] = sarvamMaxOutputTokens
	}
	return body
}
