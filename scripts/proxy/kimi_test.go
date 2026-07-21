package main

import (
	"encoding/json"
	"reflect"
	"testing"
)

// kimiParse unmarshals a JSON object literal into map[string]interface{} so the
// fixtures mirror real proxy input (numbers decode as float64, etc.).
func kimiParse(t *testing.T, s string) map[string]interface{} {
	t.Helper()
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(s), &m); err != nil {
		t.Fatalf("bad fixture json: %v", err)
	}
	return m
}

// kimiRef digs schema["properties"][prop]["$ref"] out of a normalized schema.
func kimiRef(t *testing.T, schema map[string]interface{}, prop string) interface{} {
	t.Helper()
	props, ok := schema["properties"].(map[string]interface{})
	if !ok {
		t.Fatalf("properties missing/not object: %#v", schema["properties"])
	}
	node, ok := props[prop].(map[string]interface{})
	if !ok {
		t.Fatalf("property %q missing/not object", prop)
	}
	return node["$ref"]
}

// test_kimi.sh: foreign $ref (#/definitions/X) rewritten + definitions hoisted.
func TestKimiForeignRefRewrittenAndDefinitionsHoisted(t *testing.T) {
	s := kimiParse(t, `{"type":"object",
		"properties":{"orderBy":{"$ref":"#/definitions/orderBy"}},
		"definitions":{"orderBy":{"type":"string","enum":["asc","desc"]}}}`)
	r := kimiNormalizeSchema(s)

	if got := kimiRef(t, r, "orderBy"); got != "#/$defs/orderBy" {
		t.Fatalf("ref = %v, want #/$defs/orderBy", got)
	}
	if _, present := r["definitions"]; present {
		t.Fatalf("definitions was not hoisted away")
	}
	want := map[string]interface{}{
		"orderBy": map[string]interface{}{"type": "string", "enum": []interface{}{"asc", "desc"}},
	}
	if !reflect.DeepEqual(r["$defs"], want) {
		t.Fatalf("$defs = %#v, want %#v", r["$defs"], want)
	}
	// Non-mutation: the input still carries its original "definitions" block.
	if _, present := s["definitions"]; !present {
		t.Fatalf("input schema was mutated (definitions removed)")
	}
}

// test_kimi.sh: valid #/$defs/ refs are kept as-is.
func TestKimiValidDefsRefKept(t *testing.T) {
	s := kimiParse(t, `{"type":"object",
		"properties":{"x":{"$ref":"#/$defs/T"}},
		"$defs":{"T":{"type":"string"}}}`)
	r := kimiNormalizeSchema(s)
	if got := kimiRef(t, r, "x"); got != "#/$defs/T" {
		t.Fatalf("valid ref altered: %v", got)
	}
	want := map[string]interface{}{"T": map[string]interface{}{"type": "string"}}
	if !reflect.DeepEqual(r["$defs"], want) {
		t.Fatalf("$defs = %#v, want %#v", r["$defs"], want)
	}
}

// test_kimi.sh: bare-name ref rewritten when the name is defined.
func TestKimiBareNameRefRewritten(t *testing.T) {
	s := kimiParse(t, `{"type":"object",
		"properties":{"x":{"$ref":"orderBy"}},
		"definitions":{"orderBy":{"type":"string"}}}`)
	r := kimiNormalizeSchema(s)
	if got := kimiRef(t, r, "x"); got != "#/$defs/orderBy" {
		t.Fatalf("bare ref not mapped by last segment: %v", got)
	}
}

// A foreign $ref whose name is NOT defined is left untouched (python: only
// rewrites `if name in defs`).
func TestKimiForeignRefUndefinedNameKept(t *testing.T) {
	s := kimiParse(t, `{"type":"object",
		"properties":{"x":{"$ref":"#/definitions/missing"}},
		"definitions":{"orderBy":{"type":"string"}}}`)
	r := kimiNormalizeSchema(s)
	if got := kimiRef(t, r, "x"); got != "#/definitions/missing" {
		t.Fatalf("undefined-name ref should be kept: %v", got)
	}
}

// $defs AND definitions are merged into one $defs; definitions wins on clash.
func TestKimiDefsAndDefinitionsMerged(t *testing.T) {
	s := kimiParse(t, `{"type":"object","properties":{},
		"$defs":{"A":{"type":"string"},"C":{"type":"number"}},
		"definitions":{"B":{"type":"boolean"},"C":{"type":"integer"}}}`)
	r := kimiNormalizeSchema(s)
	defs, ok := r["$defs"].(map[string]interface{})
	if !ok {
		t.Fatalf("$defs missing/not object")
	}
	want := map[string]interface{}{
		"A": map[string]interface{}{"type": "string"},
		"B": map[string]interface{}{"type": "boolean"},
		// definitions merged second => its C wins.
		"C": map[string]interface{}{"type": "integer"},
	}
	if !reflect.DeepEqual(defs, want) {
		t.Fatalf("merged $defs = %#v, want %#v", defs, want)
	}
	if _, present := r["definitions"]; present {
		t.Fatalf("definitions not hoisted")
	}
}

// test_kimi.sh: missing/null parameters become a valid empty object schema.
func TestKimiNullParametersBecomeEmptyObject(t *testing.T) {
	want := map[string]interface{}{"type": "object", "properties": map[string]interface{}{}}
	if got := kimiNormalizeSchema(nil); !reflect.DeepEqual(got, want) {
		t.Fatalf("nil -> %#v, want %#v", got, want)
	}
	// Non-object inputs (string, number, list) collapse the same way.
	if got := kimiNormalizeSchema("nope"); !reflect.DeepEqual(got, want) {
		t.Fatalf("string -> %#v, want %#v", got, want)
	}
	if got := kimiNormalizeSchema([]interface{}{1, 2}); !reflect.DeepEqual(got, want) {
		t.Fatalf("list -> %#v, want %#v", got, want)
	}
}

// type/properties are guaranteed even when absent, and a non-object properties
// is replaced; an existing object properties is preserved.
func TestKimiTypeAndPropertiesGuaranteed(t *testing.T) {
	// No type, no properties.
	r := kimiNormalizeSchema(kimiParse(t, `{"description":"d"}`))
	if r["type"] != "object" {
		t.Fatalf("type not defaulted: %v", r["type"])
	}
	if _, ok := r["properties"].(map[string]interface{}); !ok {
		t.Fatalf("properties not guaranteed: %#v", r["properties"])
	}
	if r["description"] != "d" {
		t.Fatalf("sibling key lost: %v", r["description"])
	}

	// properties present but not an object -> replaced with {}.
	r2 := kimiNormalizeSchema(kimiParse(t, `{"type":"object","properties":["bad"]}`))
	if p, ok := r2["properties"].(map[string]interface{}); !ok || len(p) != 0 {
		t.Fatalf("non-object properties not replaced: %#v", r2["properties"])
	}

	// existing "type" is preserved (only defaulted when the key is absent).
	r3 := kimiNormalizeSchema(kimiParse(t, `{"type":"array","properties":{}}`))
	if r3["type"] != "array" {
		t.Fatalf("existing type overwritten: %v", r3["type"])
	}
}

// test_kimi.sh: fix_request fixes tools AND strips cache_control end to end.
func TestKimiFixRequestToolsAndCacheControl(t *testing.T) {
	b := kimiParse(t, `{
		"messages":[{"role":"user","content":"hi","cache_control":{"type":"ephemeral"}}],
		"tools":[{"type":"function","function":{"name":"t","description":"d",
			"parameters":{"type":"object",
				"properties":{"x":{"$ref":"#/definitions/T"}},
				"definitions":{"T":{"type":"string"}}}}}]}`)
	r := kimiFix(b)

	msgs := r["messages"].([]interface{})
	msg0 := msgs[0].(map[string]interface{})
	if _, present := msg0["cache_control"]; present {
		t.Fatalf("cache_control not stripped")
	}
	if msg0["content"] != "hi" || msg0["role"] != "user" {
		t.Fatalf("message content mangled: %#v", msg0)
	}

	tool0 := r["tools"].([]interface{})[0].(map[string]interface{})
	params := tool0["function"].(map[string]interface{})["parameters"].(map[string]interface{})
	if got := kimiRef(t, params, "x"); got != "#/$defs/T" {
		t.Fatalf("tool ref not normalized: %v", got)
	}
	if _, present := params["definitions"]; present {
		t.Fatalf("definitions not hoisted in tool params")
	}
}

// cache_control is stripped at EVERY nesting level, and lists are recursed.
func TestKimiStripCacheControlNested(t *testing.T) {
	in := kimiParse(t, `{"a":{"cache_control":1,"b":2},
		"list":[{"cache_control":9,"keep":true},"plain"],
		"cache_control":{"top":1}}`)
	out := kimiStripCacheControl(in).(map[string]interface{})
	if _, present := out["cache_control"]; present {
		t.Fatalf("top-level cache_control kept")
	}
	a := out["a"].(map[string]interface{})
	if _, present := a["cache_control"]; present || a["b"] != float64(2) {
		t.Fatalf("nested strip failed: %#v", a)
	}
	item0 := out["list"].([]interface{})[0].(map[string]interface{})
	if _, present := item0["cache_control"]; present || item0["keep"] != true {
		t.Fatalf("list-nested strip failed: %#v", item0)
	}
}

// fix_tools: non-list tools returned unchanged; empty list unchanged; non-object
// entries dropped; a tool without a "function" object is passed through as a copy.
func TestKimiFixToolsEdgeCases(t *testing.T) {
	// Non-list passthrough.
	if got := kimiFixTools("not-a-list"); got != "not-a-list" {
		t.Fatalf("non-list not passed through: %v", got)
	}
	// Empty list passthrough.
	empty := []interface{}{}
	if got := kimiFixTools(empty).([]interface{}); len(got) != 0 {
		t.Fatalf("empty list altered")
	}
	// Non-object entries dropped; function-less tool kept.
	in := []interface{}{
		"junk",
		map[string]interface{}{"type": "function"}, // no function object
		map[string]interface{}{"type": "function", "function": map[string]interface{}{
			"name": "f", "parameters": map[string]interface{}{"properties": map[string]interface{}{}},
		}},
	}
	out := kimiFixTools(in).([]interface{})
	if len(out) != 2 {
		t.Fatalf("expected 2 kept tools (junk dropped), got %d", len(out))
	}
	// The function-carrying tool got its parameters normalized (type defaulted).
	fn := out[1].(map[string]interface{})["function"].(map[string]interface{})
	params := fn["parameters"].(map[string]interface{})
	if params["type"] != "object" {
		t.Fatalf("parameters.type not defaulted: %v", params["type"])
	}
}

// kimiLastSegment matches python ref.rstrip("/").split("/")[-1].
func TestKimiLastSegment(t *testing.T) {
	cases := map[string]string{
		"#/definitions/orderBy": "orderBy",
		"orderBy":               "orderBy",
		"a/b/":                  "b",
		"#/$defs/T":             "T",
		"":                      "",
		"///":                   "",
	}
	for in, want := range cases {
		if got := kimiLastSegment(in); got != want {
			t.Fatalf("kimiLastSegment(%q) = %q, want %q", in, got, want)
		}
	}
}

// kimiFix registers itself under the "kimi" family key, and providerKey resolves
// the alias ids the launch wrapper uses (kimi-for-coding, kimi-k3, ...).
func TestKimiRegisteredUnderFamilyKey(t *testing.T) {
	if reqTransforms["kimi"] == nil {
		t.Fatal("kimi request transform not registered")
	}
	for _, id := range []string{"kimi", "kimi-for-coding", "kimi-k3", "kimi-k2p7", "kimi-for-coding-highspeed"} {
		if providerKey(id) != "kimi" {
			t.Fatalf("providerKey(%q) = %q, want kimi", id, providerKey(id))
		}
	}
}
