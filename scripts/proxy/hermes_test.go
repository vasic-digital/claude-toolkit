package main

import (
	"encoding/json"
	"strings"
	"testing"
)

func argsOf(t *testing.T, tc toolCall) map[string]interface{} {
	t.Helper()
	var m map[string]interface{}
	if err := json.Unmarshal([]byte(tc.args), &m); err != nil {
		t.Fatalf("args not JSON: %q (%v)", tc.args, err)
	}
	return m
}

// The live-captured leak: preamble + a single string param.
func TestParse_LiveCapturedLeak(t *testing.T) {
	leaked := "I'll read the README first.\n\n" +
		"<function=Read>\n<parameter=file_path>\nREADME.md\n</parameter>\n</function>\n</tool_call>"
	pt := map[string]map[string]string{"Read": {"file_path": "string"}}
	pre, calls, ok := parseHermesToolCalls(leaked, pt)
	if !ok || len(calls) != 1 {
		t.Fatalf("expected 1 call, got ok=%v n=%d", ok, len(calls))
	}
	if calls[0].name != "Read" {
		t.Fatalf("name = %q", calls[0].name)
	}
	if a := argsOf(t, calls[0]); a["file_path"] != "README.md" {
		t.Fatalf("args = %v", a)
	}
	if !strings.HasPrefix(pre, "I'll read") || strings.Contains(pre, "<function=") {
		t.Fatalf("preamble = %q", pre)
	}
}

func TestParse_SkillLeak(t *testing.T) {
	s := "Let me start.\n<function=Skill>\n<parameter=skill>\nsuperpowers:using-superpowers\n</parameter>\n</function>\n</tool_call>"
	_, calls, ok := parseHermesToolCalls(s, map[string]map[string]string{"Skill": {"skill": "string"}})
	if !ok || calls[0].name != "Skill" {
		t.Fatalf("skill leak not parsed: ok=%v", ok)
	}
	if a := argsOf(t, calls[0]); a["skill"] != "superpowers:using-superpowers" {
		t.Fatalf("args = %v", a)
	}
}

// REGRESSION (review 2026-07-22): a value containing </function> must NOT
// truncate/drop the arg — the python parser dropped `content` entirely here.
func TestParse_ValueContainsCloseFunctionTag(t *testing.T) {
	s := "I'll write it.\n<function=Write>\n" +
		"<parameter=file_path>\nx.py\n</parameter>\n" +
		"<parameter=content>\nprint(\"</function>\")\n</parameter>\n" +
		"</function>\n</tool_call>"
	pt := map[string]map[string]string{"Write": {"file_path": "string", "content": "string"}}
	_, calls, ok := parseHermesToolCalls(s, pt)
	if !ok || len(calls) != 1 {
		t.Fatalf("expected 1 call, got ok=%v n=%d", ok, len(calls))
	}
	a := argsOf(t, calls[0])
	if a["file_path"] != "x.py" {
		t.Fatalf("file_path = %v", a["file_path"])
	}
	if a["content"] != `print("</function>")` {
		t.Fatalf("content dropped/truncated: %q", a["content"])
	}
}

// REGRESSION: a value containing </parameter> must be preserved (last-close wins).
func TestParse_ValueContainsCloseParameterTag(t *testing.T) {
	s := "<function=Write>\n<parameter=content>\ntext </parameter> more\n</parameter>\n</function>\n</tool_call>"
	_, calls, ok := parseHermesToolCalls(s, map[string]map[string]string{"Write": {"content": "string"}})
	if !ok {
		t.Fatalf("not parsed")
	}
	if a := argsOf(t, calls[0]); a["content"] != "text </parameter> more" {
		t.Fatalf("content = %q", a["content"])
	}
}

// An unbalanced opening <function= inside a value trips the guard -> passthrough.
func TestParse_UnbalancedOpeningTagInValue_Passthrough(t *testing.T) {
	s := "<function=Write>\n<parameter=content>\nsee <function=Foo> here\n</parameter>\n</function>\n</tool_call>"
	if _, _, ok := parseHermesToolCalls(s, nil); ok {
		t.Fatalf("expected passthrough on unbalanced opening tag")
	}
}

func TestParse_NoFalsePositives(t *testing.T) {
	if _, _, ok := parseHermesToolCalls("A normal answer, no tools.", nil); ok {
		t.Fatalf("false positive on plain prose")
	}
	if _, _, ok := parseHermesToolCalls("Discussing the <function= token in text.", nil); ok {
		t.Fatalf("false positive on unterminated tag")
	}
}

func TestCoerce_BySchema(t *testing.T) {
	s := "<function=F>\n<parameter=n>\n42\n</parameter>\n<parameter=b>\ntrue\n</parameter>\n<parameter=s>\n123\n</parameter>\n</function>\n</tool_call>"
	pt := map[string]map[string]string{"F": {"n": "integer", "b": "boolean", "s": "string"}}
	_, calls, ok := parseHermesToolCalls(s, pt)
	if !ok {
		t.Fatal("not parsed")
	}
	a := argsOf(t, calls[0])
	if n, isF := a["n"].(float64); !isF || n != 42 { // JSON numbers decode as float64
		t.Fatalf("n = %v (%T)", a["n"], a["n"])
	}
	if a["b"] != true {
		t.Fatalf("b = %v", a["b"])
	}
	if a["s"] != "123" {
		t.Fatalf("string over-coerced: %v (%T)", a["s"], a["s"])
	}
}

func TestParse_TwoParallelCalls(t *testing.T) {
	s := "<function=A>\n<parameter=x>\n1\n</parameter>\n</function>\n" +
		"<function=B>\n<parameter=y>\nhi\n</parameter>\n</function>\n</tool_call>"
	_, calls, ok := parseHermesToolCalls(s, map[string]map[string]string{"A": {"x": "integer"}, "B": {"y": "string"}})
	if !ok || len(calls) != 2 || calls[0].name != "A" || calls[1].name != "B" {
		t.Fatalf("parallel calls: ok=%v n=%d", ok, len(calls))
	}
}

func TestTransformNonStream_RewritesLeak(t *testing.T) {
	resp := []byte(`{"choices":[{"message":{"content":"pre.\n<function=Read>\n<parameter=file_path>\nR.md\n</parameter>\n</function>\n</tool_call>","tool_calls":null},"finish_reason":"stop"}]}`)
	out, changed := transformNonStream(resp, map[string]map[string]string{"Read": {"file_path": "string"}})
	if !changed {
		t.Fatal("expected rewrite")
	}
	var o map[string]interface{}
	if err := json.Unmarshal(out, &o); err != nil {
		t.Fatalf("output not JSON: %v", err)
	}
	c0 := o["choices"].([]interface{})[0].(map[string]interface{})
	if c0["finish_reason"] != "tool_calls" {
		t.Fatalf("finish_reason = %v", c0["finish_reason"])
	}
	msg := c0["message"].(map[string]interface{})
	if tc, ok := msg["tool_calls"].([]interface{}); !ok || len(tc) != 1 {
		t.Fatalf("tool_calls missing")
	}
	if cs, _ := msg["content"].(string); strings.Contains(cs, "<function=") {
		t.Fatalf("hermes left in content: %q", cs)
	}
}

func TestTransformNonStream_PassthroughAlreadyStructured(t *testing.T) {
	resp := []byte(`{"choices":[{"message":{"content":"","tool_calls":[{"id":"x"}]},"finish_reason":"tool_calls"}]}`)
	if _, changed := transformNonStream(resp, nil); changed {
		t.Fatal("mangled an already-structured response")
	}
}

func TestTransformNonStream_PassthroughPlainText(t *testing.T) {
	resp := []byte(`{"choices":[{"message":{"content":"just an answer"},"finish_reason":"stop"}]}`)
	if _, changed := transformNonStream(resp, nil); changed {
		t.Fatal("rewrote a plain-text response")
	}
}

func TestTransformStream_RewritesLeak(t *testing.T) {
	leaked := "pre.\n<function=Read>\n<parameter=file_path>\nR.md\n</parameter>\n</function>\n</tool_call>"
	enc, _ := json.Marshal(leaked)
	sse := `data: {"id":"c1","model":"m","choices":[{"index":0,"delta":{"content":` + string(enc) + `}}]}` + "\n\ndata: [DONE]\n\n"
	out, changed := transformStream(sse, map[string]map[string]string{"Read": {"file_path": "string"}})
	if !changed {
		t.Fatal("expected stream rewrite")
	}
	s := string(out)
	if !strings.Contains(s, `"tool_calls"`) || !strings.Contains(s, `"tool_calls"`) {
		t.Fatal("missing tool_calls delta")
	}
	if !strings.Contains(s, `"finish_reason":"tool_calls"`) {
		t.Fatalf("missing finish_reason: %s", s)
	}
	if !strings.HasSuffix(strings.TrimSpace(s), "[DONE]") {
		t.Fatal("not DONE-terminated")
	}
}

func TestTransformStream_PassthroughAlreadyStructured(t *testing.T) {
	sse := `data: {"choices":[{"delta":{"tool_calls":[{"index":0,"id":"z"}]}}]}` + "\n\ndata: [DONE]\n\n"
	if _, changed := transformStream(sse, nil); changed {
		t.Fatal("rewrote an already-structured stream")
	}
}

func TestUpstreamRoot(t *testing.T) {
	if got := upstreamRoot("http://127.0.0.1:18434/v1"); got != "http://127.0.0.1:18434" {
		t.Fatalf("/v1 not stripped: %q", got)
	}
	if got := upstreamRoot("http://127.0.0.1:18434"); got != "http://127.0.0.1:18434" {
		t.Fatalf("bare root altered: %q", got)
	}
}
