// poe_test.go — behavior parity tests for the Poe request transform (poe.go).
//
// These mirror scripts/tests/test_poe_proxy.sh (the 8-assertion behavior spec)
// case-for-case, plus the $ref-resolution and cache_control-strip behavior the
// python fix_request also performs. All helpers are poe*-prefixed.
package main

import (
	"os"
	"reflect"
	"strconv"
	"strings"
	"testing"
)

// poeFunc builds a {"type":"function","function":{...}} tool object.
func poeFunc(fn map[string]interface{}) map[string]interface{} {
	return map[string]interface{}{"type": "function", "function": fn}
}

// poeName pulls a capped/fixed tool's function name (for cap assertions).
func poeName(tool interface{}) string { return poeToolName(tool) }

//  1. fix_tools/cap_tools/fix_request present — in Go this is a compile-time
//     guarantee; exercise all three so the symbols are referenced by name.
func TestPoeSymbolsPresent(t *testing.T) {
	_ = poeFixTools([]interface{}{})
	_, _ = poeCapTools([]interface{}{}, 200)
	_ = poeFix(map[string]interface{}{})
}

// 2. fix_tools injects a default parameters object when a tool omits it.
func TestPoeFixToolsInjectsDefaultParameters(t *testing.T) {
	tools := []interface{}{poeFunc(map[string]interface{}{"name": "ping", "description": "p"})}
	got := poeFixTools(tools).([]interface{})
	params := got[0].(map[string]interface{})["function"].(map[string]interface{})["parameters"]
	want := map[string]interface{}{"type": "object", "properties": map[string]interface{}{}}
	if !reflect.DeepEqual(params, want) {
		t.Fatalf("missing parameters not filled: got %#v want %#v", params, want)
	}
}

// 3. fix_tools adds properties to a bare {"type":"object"} parameters.
func TestPoeFixToolsBareObjectGainsProperties(t *testing.T) {
	tools := []interface{}{poeFunc(map[string]interface{}{
		"name": "noop", "description": "zero-arg tool",
		"parameters": map[string]interface{}{"type": "object"},
	})}
	got := poeFixTools(tools).([]interface{})
	params := got[0].(map[string]interface{})["function"].(map[string]interface{})["parameters"]
	want := map[string]interface{}{"type": "object", "properties": map[string]interface{}{}}
	if !reflect.DeepEqual(params, want) {
		t.Fatalf("bare object schema did not gain properties:{}: got %#v", params)
	}
}

// 4. fix_tools preserves existing properties and fills missing type.
func TestPoeFixToolsKeepsPropertiesFillsType(t *testing.T) {
	tools := []interface{}{poeFunc(map[string]interface{}{
		"name": "calc", "description": "d",
		"parameters": map[string]interface{}{
			"properties": map[string]interface{}{"e": map[string]interface{}{"type": "string"}},
		},
	})}
	got := poeFixTools(tools).([]interface{})
	params := got[0].(map[string]interface{})["function"].(map[string]interface{})["parameters"].(map[string]interface{})
	if params["type"] != "object" {
		t.Fatalf("type not defaulted to object: got %#v", params["type"])
	}
	wantProps := map[string]interface{}{"e": map[string]interface{}{"type": "string"}}
	if !reflect.DeepEqual(params["properties"], wantProps) {
		t.Fatalf("existing properties not preserved: got %#v", params["properties"])
	}
}

// 5. cap_tools is a no-op when tool count is within the limit.
func TestPoeCapToolsNoOpUnderLimit(t *testing.T) {
	var tools []interface{}
	for i := 0; i < 50; i++ {
		tools = append(tools, poeFunc(map[string]interface{}{
			"name":       "t" + strconv.Itoa(i),
			"parameters": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}},
		}))
	}
	capped, dropped := poeCapTools(tools, 200)
	if len(capped.([]interface{})) != 50 || dropped != 0 {
		t.Fatalf("50 tools <= 200 should be unchanged: got len=%d dropped=%d", len(capped.([]interface{})), dropped)
	}
}

// 6. cap_tools caps to the limit and preserves ALL built-in (non-mcp) tools.
func TestPoeCapToolsKeepsAllBuiltins(t *testing.T) {
	var tools []interface{}
	for i := 0; i < 30; i++ {
		tools = append(tools, poeFunc(map[string]interface{}{
			"name":       "b" + strconv.Itoa(i),
			"parameters": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}},
		}))
	}
	for i := 0; i < 400; i++ {
		tools = append(tools, poeFunc(map[string]interface{}{
			"name":       "mcp__srv__t" + strconv.Itoa(i),
			"parameters": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}},
		}))
	}
	capped, dropped := poeCapTools(tools, 100)
	list := capped.([]interface{})
	keptBuiltin := 0
	for _, tl := range list {
		if !strings.HasPrefix(poeName(tl), "mcp__") {
			keptBuiltin++
		}
	}
	// 430 tools, cap 100 -> keep 100 (all 30 builtin + 70 mcp), drop 330.
	if len(list) != 100 || dropped != 330 || keptBuiltin != 30 {
		t.Fatalf("cap 100 over 430: got len=%d dropped=%d keptBuiltin=%d want 100 330 30",
			len(list), dropped, keptBuiltin)
	}
}

// 7. cap_tools default limit is 200 when POE_MAX_TOOLS is unset.
func TestPoeCapToolsDefaultLimit200(t *testing.T) {
	old, had := os.LookupEnv("POE_MAX_TOOLS")
	os.Unsetenv("POE_MAX_TOOLS")
	defer func() {
		if had {
			os.Setenv("POE_MAX_TOOLS", old)
		}
	}()
	if poeMaxTools() != 200 {
		t.Fatalf("default POE_MAX_TOOLS should be 200, got %d", poeMaxTools())
	}
	var tools []interface{}
	for i := 0; i < 417; i++ {
		tools = append(tools, poeFunc(map[string]interface{}{
			"name":       "mcp__s__" + strconv.Itoa(i),
			"parameters": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}},
		}))
	}
	capped, dropped := poeCapTools(tools, poeMaxTools())
	if len(capped.([]interface{})) != 200 || dropped != 217 {
		t.Fatalf("417 -> default cap 200: got len=%d dropped=%d want 200 217",
			len(capped.([]interface{})), dropped)
	}
}

// 8. fix_request applies BOTH the parameters fix and the tool cap end to end.
func TestPoeFixRequestEndToEnd(t *testing.T) {
	t.Setenv("POE_MAX_TOOLS", "200")
	tools := []interface{}{poeFunc(map[string]interface{}{"name": "builtin_no_params"})}
	for i := 0; i < 417; i++ {
		tools = append(tools, poeFunc(map[string]interface{}{
			"name":       "mcp__s__" + strconv.Itoa(i),
			"parameters": map[string]interface{}{"type": "object", "properties": map[string]interface{}{}},
		}))
	}
	body := map[string]interface{}{"model": "claude-sonnet-4.6", "tools": tools}
	out := poeFix(body)
	list := out["tools"].([]interface{})
	first := list[0].(map[string]interface{})["function"].(map[string]interface{})
	if _, ok := first["parameters"]; !ok {
		t.Fatalf("param-less built-in was not fixed: %#v", first)
	}
	if len(list) != 200 {
		t.Fatalf("418 tools should cap to 200, got %d", len(list))
	}
	if first["name"] != "builtin_no_params" {
		t.Fatalf("built-in tool was not kept first: got %#v", first["name"])
	}
}

// Extra: $ref/$defs resolution — part of fix_tools. A property referencing a
// #/$defs entry is replaced by that entry and $defs is removed.
func TestPoeFixToolsResolvesRefs(t *testing.T) {
	tools := []interface{}{poeFunc(map[string]interface{}{
		"name": "t",
		"parameters": map[string]interface{}{
			"type": "object",
			"properties": map[string]interface{}{
				"x": map[string]interface{}{"$ref": "#/$defs/Foo"},
			},
			"$defs": map[string]interface{}{
				"Foo": map[string]interface{}{"type": "string", "enum": []interface{}{"a", "b"}},
			},
		},
	})}
	got := poeFixTools(tools).([]interface{})
	params := got[0].(map[string]interface{})["function"].(map[string]interface{})["parameters"].(map[string]interface{})
	if _, present := params["$defs"]; present {
		t.Fatalf("$defs was not removed after resolution: %#v", params)
	}
	props := params["properties"].(map[string]interface{})
	wantX := map[string]interface{}{"type": "string", "enum": []interface{}{"a", "b"}}
	if !reflect.DeepEqual(props["x"], wantX) {
		t.Fatalf("$ref not resolved: got %#v want %#v", props["x"], wantX)
	}
}

// Extra: an unresolvable $ref (name absent from $defs) is left untouched.
func TestPoeResolveRefsUnresolvableLeftAsIs(t *testing.T) {
	obj := map[string]interface{}{"$ref": "#/$defs/Missing"}
	got := poeResolveRefs(obj, map[string]interface{}{}, 0)
	if !reflect.DeepEqual(got, obj) {
		t.Fatalf("unresolvable $ref should pass through: got %#v", got)
	}
}

// Extra: fix_request strips cache_control from messages (recursively).
func TestPoeFixStripsCacheControl(t *testing.T) {
	body := map[string]interface{}{
		"messages": []interface{}{
			map[string]interface{}{
				"role": "user",
				"content": []interface{}{
					map[string]interface{}{
						"type":          "text",
						"text":          "hi",
						"cache_control": map[string]interface{}{"type": "ephemeral"},
					},
				},
				"cache_control": map[string]interface{}{"type": "ephemeral"},
			},
		},
	}
	out := poeFix(body)
	msgs := out["messages"].([]interface{})
	msg0 := msgs[0].(map[string]interface{})
	if _, ok := msg0["cache_control"]; ok {
		t.Fatalf("cache_control not stripped from message: %#v", msg0)
	}
	block := msg0["content"].([]interface{})[0].(map[string]interface{})
	if _, ok := block["cache_control"]; ok {
		t.Fatalf("cache_control not stripped from content block: %#v", block)
	}
	if block["text"] != "hi" {
		t.Fatalf("non-cache_control fields must survive: %#v", block)
	}
}
