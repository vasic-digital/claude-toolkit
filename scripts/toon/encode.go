// encode.go — core TOON-encoding logic for the Go port of scripts/toon_encode.py.
//
// This is a byte-faithful re-implementation of the Python wrapper's behaviour:
//
//  1. Locate toon.mjs (env override → executable dir → ~/.local/share).
//  2. If found, shell out to `node <toon.mjs> encode <json>` (the primary,
//     authoritative path — the @toon-format/toon library is the real encoder).
//  3. Otherwise, degrade to a YAML-like fallback encoder that replicates the
//     Python fallback_encode() output character-for-character.
//
// Order preservation is load-bearing: Python's json.loads/json.dumps preserve
// object key insertion order, and TOON declares object fields in that order, so
// the Go port parses JSON into an insertion-ordered structure rather than a Go
// map (which would sort keys and diverge).
//
// Cross-reference: scripts/toon_encode.py (the Python original this replaces),
// scripts/toon.mjs (the Node encoder both wrappers shell out to).
package main

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// orderedMap is a JSON object that preserves key insertion order, mirroring a
// Python 3.7+ dict. Duplicate keys follow Python semantics: last value wins,
// first-seen position is kept.
type orderedMap struct {
	keys []string
	vals map[string]any
}

func newOrderedMap() *orderedMap {
	return &orderedMap{vals: map[string]any{}}
}

func (m *orderedMap) set(k string, v any) {
	if _, ok := m.vals[k]; !ok {
		m.keys = append(m.keys, k)
	}
	m.vals[k] = v
}

// parseOrdered decodes a single JSON value from src, preserving object key
// order and numeric literals (json.Number). It rejects trailing non-whitespace
// content, matching Python's json.loads (which raises on trailing garbage).
func parseOrdered(src []byte) (any, error) {
	dec := json.NewDecoder(bytes.NewReader(src))
	dec.UseNumber()
	v, err := decodeValue(dec)
	if err != nil {
		return nil, err
	}
	// Ensure only whitespace follows the value (json.loads-equivalent: it
	// tolerates surrounding whitespace but rejects any trailing content).
	for _, c := range src[dec.InputOffset():] {
		if c != ' ' && c != '\t' && c != '\n' && c != '\r' {
			return nil, fmt.Errorf("extra data after JSON value")
		}
	}
	return v, nil
}

func decodeValue(dec *json.Decoder) (any, error) {
	t, err := dec.Token()
	if err != nil {
		return nil, err
	}
	switch tok := t.(type) {
	case json.Delim:
		switch tok {
		case '{':
			m := newOrderedMap()
			for dec.More() {
				keyTok, err := dec.Token()
				if err != nil {
					return nil, err
				}
				key, ok := keyTok.(string)
				if !ok {
					return nil, fmt.Errorf("object key is not a string")
				}
				val, err := decodeValue(dec)
				if err != nil {
					return nil, err
				}
				m.set(key, val)
			}
			if _, err := dec.Token(); err != nil { // consume '}'
				return nil, err
			}
			return m, nil
		case '[':
			arr := []any{}
			for dec.More() {
				val, err := decodeValue(dec)
				if err != nil {
					return nil, err
				}
				arr = append(arr, val)
			}
			if _, err := dec.Token(); err != nil { // consume ']'
				return nil, err
			}
			return arr, nil
		default:
			return nil, fmt.Errorf("unexpected delimiter %q", tok)
		}
	default:
		// string, bool, nil, or json.Number
		return t, nil
	}
}

// findToonScript mirrors Python find_toon_script(): the first existing candidate
// wins. CMA_TOON_SCRIPT is an explicit override placed at the front — when
// unset, the default search order matches the Python wrapper (script dir, then
// the user share dir). Here "script dir" is the executable's directory.
func findToonScript() string {
	var candidates []string
	if env := os.Getenv("CMA_TOON_SCRIPT"); env != "" {
		candidates = append(candidates, env)
	}
	if exe, err := os.Executable(); err == nil {
		exeDir := filepath.Dir(exe)
		candidates = append(candidates,
			filepath.Join(exeDir, "toon.mjs"),
			// Convenience walk-up so a binary built under scripts/toon/ or
			// scripts/toon/bin/ still finds the repo's scripts/toon.mjs.
			filepath.Join(exeDir, "..", "toon.mjs"),
			filepath.Join(exeDir, "..", "..", "toon.mjs"),
		)
	}
	if home, err := os.UserHomeDir(); err == nil {
		candidates = append(candidates,
			filepath.Join(home, ".local/share/claude-multi-account", "toon.mjs"))
	}
	for _, p := range candidates {
		if st, err := os.Stat(p); err == nil && !st.IsDir() {
			return p
		}
	}
	return ""
}

// encodeToon replicates Python encode_toon(): shell out to node when toon.mjs is
// available, otherwise use the fallback encoder.
func encodeToon(data any) string {
	script := findToonScript()
	if script == "" {
		return fallbackEncode(data, 0)
	}
	jsonStr := serializeJSON(data)
	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()
	cmd := exec.CommandContext(ctx, "node", script, "encode", jsonStr)
	var stdout bytes.Buffer
	cmd.Stdout = &stdout
	if err := cmd.Run(); err != nil {
		return fallbackEncode(data, 0)
	}
	return strings.TrimSpace(stdout.String())
}

// serializeJSON emits order-preserving JSON for handoff to node. Exact number
// and string formatting is irrelevant here because node re-parses the string;
// only structure and key order need to survive.
func serializeJSON(v any) string {
	var b strings.Builder
	writeJSON(&b, v)
	return b.String()
}

func writeJSON(b *strings.Builder, v any) {
	switch val := v.(type) {
	case nil:
		b.WriteString("null")
	case bool:
		if val {
			b.WriteString("true")
		} else {
			b.WriteString("false")
		}
	case json.Number:
		b.WriteString(val.String())
	case string:
		enc, _ := json.Marshal(val)
		b.Write(enc)
	case []any:
		b.WriteByte('[')
		for i, el := range val {
			if i > 0 {
				b.WriteByte(',')
			}
			writeJSON(b, el)
		}
		b.WriteByte(']')
	case *orderedMap:
		b.WriteByte('{')
		for i, k := range val.keys {
			if i > 0 {
				b.WriteByte(',')
			}
			enc, _ := json.Marshal(k)
			b.Write(enc)
			b.WriteByte(':')
			writeJSON(b, val.vals[k])
		}
		b.WriteByte('}')
	default:
		enc, _ := json.Marshal(val)
		b.Write(enc)
	}
}

// fallbackEncode replicates Python fallback_encode() byte-for-byte, including
// its indentation quirk (only the first line of a nested block is indented) and
// its depth guard (beyond 64 levels, emit compact JSON).
func fallbackEncode(data any, depth int) string {
	if depth > 64 {
		return jsonDumps(data)
	}
	switch val := data.(type) {
	case []any:
		if len(val) > 0 && allDicts(val) {
			keys := val[0].(*orderedMap).keys
			lines := []string{fmt.Sprintf("[%d]{%s}:", len(val), strings.Join(keys, ","))}
			for _, item := range val {
				m := item.(*orderedMap)
				cells := make([]string, len(keys))
				for i, k := range keys {
					if v, ok := m.vals[k]; ok {
						cells[i] = pyStr(v)
					} else {
						cells[i] = "" // item.get(k, "")
					}
				}
				lines = append(lines, "  "+strings.Join(cells, ","))
			}
			return strings.Join(lines, "\n")
		}
		lines := []string{fmt.Sprintf("[%d]:", len(val))}
		for _, item := range val {
			if s, ok := item.(string); ok {
				lines = append(lines, "  - "+s)
			} else {
				lines = append(lines, "  - "+jsonDumps(item))
			}
		}
		return strings.Join(lines, "\n")
	case *orderedMap:
		var lines []string
		for _, k := range val.keys {
			v := val.vals[k]
			if isContainer(v) {
				lines = append(lines, k+":")
				lines = append(lines, "  "+fallbackEncode(v, depth+1))
			} else if s, ok := v.(string); ok {
				lines = append(lines, k+": "+s)
			} else {
				lines = append(lines, k+": "+jsonDumps(v))
			}
		}
		return strings.Join(lines, "\n")
	default:
		return pyStr(data)
	}
}

func allDicts(arr []any) bool {
	for _, el := range arr {
		if _, ok := el.(*orderedMap); !ok {
			return false
		}
	}
	return true
}

func isContainer(v any) bool {
	switch v.(type) {
	case *orderedMap, []any:
		return true
	}
	return false
}

// pyStr replicates Python str() for the value types produced by JSON decoding.
func pyStr(v any) string {
	switch val := v.(type) {
	case string:
		return val
	case json.Number:
		return val.String()
	case bool:
		if val {
			return "True"
		}
		return "False"
	case nil:
		return "None"
	case []any:
		return pyRepr(val)
	case *orderedMap:
		return pyRepr(val)
	default:
		return fmt.Sprintf("%v", val)
	}
}

// jsonDumps replicates Python json.dumps() with default separators (", ", ": ")
// and ensure_ascii=True.
func jsonDumps(v any) string {
	switch val := v.(type) {
	case nil:
		return "null"
	case bool:
		if val {
			return "true"
		}
		return "false"
	case json.Number:
		return val.String()
	case string:
		return pyJSONString(val)
	case []any:
		parts := make([]string, len(val))
		for i, el := range val {
			parts[i] = jsonDumps(el)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case *orderedMap:
		parts := make([]string, len(val.keys))
		for i, k := range val.keys {
			parts[i] = pyJSONString(k) + ": " + jsonDumps(val.vals[k])
		}
		return "{" + strings.Join(parts, ", ") + "}"
	default:
		return fmt.Sprintf("%v", val)
	}
}

// pyJSONString replicates Python json.dumps() string escaping with
// ensure_ascii=True: double-quoted, with \" \\ \n \r \t \b \f short escapes,
// \uXXXX for control chars and every non-ASCII rune.
func pyJSONString(s string) string {
	var b strings.Builder
	b.WriteByte('"')
	for _, r := range s {
		switch r {
		case '"':
			b.WriteString(`\"`)
		case '\\':
			b.WriteString(`\\`)
		case '\n':
			b.WriteString(`\n`)
		case '\r':
			b.WriteString(`\r`)
		case '\t':
			b.WriteString(`\t`)
		case '\b':
			b.WriteString(`\b`)
		case '\f':
			b.WriteString(`\f`)
		default:
			if r < 0x20 || r > 0x7e {
				writeUEscape(&b, r)
			} else {
				b.WriteRune(r)
			}
		}
	}
	b.WriteByte('"')
	return b.String()
}

// writeUEscape emits Python's \uXXXX escaping, including surrogate pairs for
// runes beyond the BMP (matching json.dumps ensure_ascii behaviour).
func writeUEscape(b *strings.Builder, r rune) {
	if r > 0xffff {
		r -= 0x10000
		hi := 0xd800 + (r >> 10)
		lo := 0xdc00 + (r & 0x3ff)
		fmt.Fprintf(b, `\u%04x\u%04x`, hi, lo)
		return
	}
	fmt.Fprintf(b, `\u%04x`, r)
}

// pyRepr replicates Python repr() for the value types reachable from str() of a
// container (used when a nested container appears inside a tabular row). Covers
// the realistic space: strings (with Python's single/double quote selection),
// numbers, bool, None, and nested lists/dicts of those.
func pyRepr(v any) string {
	switch val := v.(type) {
	case string:
		return pyReprString(val)
	case json.Number:
		return val.String()
	case bool:
		if val {
			return "True"
		}
		return "False"
	case nil:
		return "None"
	case []any:
		parts := make([]string, len(val))
		for i, el := range val {
			parts[i] = pyRepr(el)
		}
		return "[" + strings.Join(parts, ", ") + "]"
	case *orderedMap:
		parts := make([]string, len(val.keys))
		for i, k := range val.keys {
			parts[i] = pyReprString(k) + ": " + pyRepr(val.vals[k])
		}
		return "{" + strings.Join(parts, ", ") + "}"
	default:
		return fmt.Sprintf("%v", val)
	}
}

// pyReprString replicates CPython's string repr quote selection: single quotes
// by default, switching to double quotes when the string contains a single
// quote but no double quote. Control characters escape as \xNN; printable
// (including non-ASCII printable) characters are kept literally, as CPython does.
func pyReprString(s string) string {
	quote := byte('\'')
	if strings.Contains(s, "'") && !strings.Contains(s, "\"") {
		quote = '"'
	}
	var b strings.Builder
	b.WriteByte(quote)
	for _, r := range s {
		switch {
		case r == rune(quote):
			b.WriteByte('\\')
			b.WriteRune(r)
		case r == '\\':
			b.WriteString(`\\`)
		case r == '\n':
			b.WriteString(`\n`)
		case r == '\r':
			b.WriteString(`\r`)
		case r == '\t':
			b.WriteString(`\t`)
		case r < 0x20 || r == 0x7f:
			fmt.Fprintf(&b, `\x%02x`, r)
		default:
			b.WriteRune(r)
		}
	}
	b.WriteByte(quote)
	return b.String()
}
