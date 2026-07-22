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
	"math"
	"os"
	"os/exec"
	"path/filepath"
	"strconv"
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

// findToonScript mirrors Python find_toon_script() for the shared candidates
// (script/exe dir, then the user share dir) but is INTENTIONALLY WIDER by two
// extra walk-up candidates — a deliberate, investigated (§11.4.124) divergence
// from byte-parity, not an oversight:
//
// Python's find_toon_script() anchors on os.path.dirname(os.path.abspath(__file__))
// — the location of the toon_encode.py SOURCE FILE, which is always
// scripts/ in this repo and never moves. The Go port has no equivalent stable
// anchor: os.Executable() returns wherever the OPERATOR chose to `go build -o`
// the binary, which is arbitrary. In the realistic in-place build layout for
// this module (`cd scripts/toon && go build .`, producing scripts/toon/toon_encode),
// the binary's OWN directory is scripts/toon/ — sibling-only resolution
// (exeDir/toon.mjs) would look for scripts/toon/toon.mjs, which does not
// exist; the real file is one level up at scripts/toon.mjs. Without the first
// walk-up candidate, that entirely realistic build would silently ALWAYS take
// the fallback encoder even though toon.mjs is genuinely available — a
// functional regression with no Python parity benefit, since Python's
// resolution has no analogue for "where the interpreter binary happens to
// live" (it always runs the .py file in place).
//
// Caveat (documented per the review, not silently accepted): because this
// candidate set is a strict SUPERSET of Python's, the two wrappers CAN select
// a different toon.mjs than each other under an unset CMA_TOON_SCRIPT if a
// decoy toon.mjs exists at ../toon.mjs or ../../toon.mjs relative to wherever
// the Go binary was built — a layout Python's finder never even considers.
// This is narrow (requires an operator-placed decoy file at a specific
// relative path) and is pinned down by TestFindToonScriptWalkUp in
// encode_test.go so it cannot silently widen further.
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
			// scripts/toon/bin/ still finds the repo's scripts/toon.mjs. See
			// the function doc comment above — deliberate, non-Python-parity.
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

// isFloatLiteral reports whether a JSON number literal parses as a Python
// float (it has a fraction and/or exponent part) rather than a Python int.
// Mirrors the json.loads number grammar: int / int frac / int exp / int frac
// exp, where frac starts with '.' and exp starts with 'e'/'E'.
func isFloatLiteral(lit string) bool {
	return strings.ContainsAny(lit, ".eE")
}

// pyIntString replicates Python's str(int(<JSON int literal>)) — the literal
// digit string is already canonical (json.Decoder rejects leading zeros)
// except for "-0", where Python's arbitrary-precision int normalizes the sign
// away (int("-0") == 0, str(0) == "0").
func pyIntString(lit string) string {
	if lit == "-0" {
		return "0"
	}
	return lit
}

// pyFloatDigits returns the shortest round-trip decimal digit string for
// |f| (no sign, no decimal point, no trailing zero — e.g. "15" for 1.5,
// "1" for 1e20, "0" for 0.0) plus decpt, the power-of-ten exponent such that
// the value equals 0.<digits> * 10^decpt. This is the same "shortest string
// that round-trips" contract CPython's dtoa (mode 0) and Go's strconv
// (shortest 'e' formatting) both implement, so the digit sequences agree —
// only the fixed-vs-scientific display convention (formatPyFloat) differs
// and is replicated separately below.
func pyFloatDigits(f float64) (digits string, decpt int) {
	f = math.Abs(f)
	s := strconv.FormatFloat(f, 'e', -1, 64) // e.g. "1.5e+20", "1e+00"
	eIdx := strings.IndexByte(s, 'e')
	mantissa := strings.Replace(s[:eIdx], ".", "", 1)
	exp, err := strconv.Atoi(s[eIdx+1:])
	if err != nil {
		// Unreachable for a well-formed 'e'-format string from strconv itself.
		exp = 0
	}
	return mantissa, exp + 1
}

// formatPyFloat replicates CPython's repr(float) / json.dumps(float) digit
// formatting for a FINITE value (callers handle Inf/NaN/sign separately).
// CPython's format_float_short (Python/pystrtod.c, mode 'r') switches to
// scientific notation exactly when decpt > 16 or decpt <= -4; the exponent is
// always signed with a minimum of two digits. Verified against real `python3
// -c "print(repr(x))"` output across the finite range (subnormals through
// DBL_MAX, both notations, both signs) — see encode_test.go TestPyFloatRepr.
func formatPyFloat(f float64) string {
	digits, decpt := pyFloatDigits(f)
	var out string
	switch {
	case decpt > 16 || decpt <= -4:
		mantissa := digits[:1]
		if len(digits) > 1 {
			mantissa += "." + digits[1:]
		}
		e := decpt - 1
		sign := "+"
		if e < 0 {
			sign = "-"
			e = -e
		}
		out = fmt.Sprintf("%se%s%02d", mantissa, sign, e)
	case decpt <= 0:
		out = "0." + strings.Repeat("0", -decpt) + digits
	case decpt >= len(digits):
		out = digits + strings.Repeat("0", decpt-len(digits)) + ".0"
	default:
		out = digits[:decpt] + "." + digits[decpt:]
	}
	if math.Signbit(f) {
		out = "-" + out
	}
	return out
}

// pyFloatStr replicates Python str(float)/repr(float) (identical in Python 3)
// for a parsed json.Number float value, including the non-finite cases as
// str() renders them: lowercase "inf"/"-inf"/"nan".
func pyFloatStr(f float64) string {
	switch {
	case math.IsNaN(f):
		return "nan"
	case math.IsInf(f, 1):
		return "inf"
	case math.IsInf(f, -1):
		return "-inf"
	default:
		return formatPyFloat(f)
	}
}

// pyFloatJSON replicates Python json.dumps(float): identical digit formatting
// to pyFloatStr for finite values, but capitalized non-finite spellings
// ("Infinity"/"-Infinity"/"NaN") — Python's json.dumps allow_nan default.
func pyFloatJSON(f float64) string {
	switch {
	case math.IsNaN(f):
		return "NaN"
	case math.IsInf(f, 1):
		return "Infinity"
	case math.IsInf(f, -1):
		return "-Infinity"
	default:
		return formatPyFloat(f)
	}
}

// pyNumberStr renders a decoded json.Number the way Python's str()/repr()
// would render the equivalent int-or-float value: an int-literal token keeps
// its (sign-normalized) digit string exactly, a float-literal token is
// re-parsed to float64 and formatted via CPython's shortest-repr algorithm —
// closing the divergence where the Go fallback previously echoed the raw
// JSON literal (e.g. "1.50", "1e10") instead of Python's canonicalized
// re-serialization of the parsed float ("1.5", "10000000000.0").
func pyNumberStr(n json.Number) string {
	lit := n.String()
	if !isFloatLiteral(lit) {
		return pyIntString(lit)
	}
	f, _ := strconv.ParseFloat(lit, 64) // ErrRange still yields the correctly
	return pyFloatStr(f)                // saturated ±Inf/±0 value, matching Python.
}

// pyNumberJSON is pyNumberStr's json.dumps-style counterpart (see pyFloatJSON
// for the only difference: non-finite capitalization).
func pyNumberJSON(n json.Number) string {
	lit := n.String()
	if !isFloatLiteral(lit) {
		return pyIntString(lit)
	}
	f, _ := strconv.ParseFloat(lit, 64)
	return pyFloatJSON(f)
}

// pyStr replicates Python str() for the value types produced by JSON decoding.
func pyStr(v any) string {
	switch val := v.(type) {
	case string:
		return val
	case json.Number:
		return pyNumberStr(val)
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
		return pyNumberJSON(val)
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
		return pyNumberStr(val) // repr(int)==str(int), repr(float)==str(float)
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
