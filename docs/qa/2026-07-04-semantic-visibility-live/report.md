# Evidence: `semantic-code-visibility` — real end-to-end LLM run

**Date:** 2026-07-04
**Standard:** §11.4.69 (real physical evidence) / §11.4.3 (honest SKIP with reason)
**Rule:** every claim below is pasted real command output. No code was modified — the
binary was built from already-committed source, run against real providers, and this
file records what actually happened.

- **Command source:** `submodules/LLMsVerifier/llm-verifier/cmd/semantic-code-visibility/main.go`
  (already implemented + committed).
- **Toolkit fixture:** `scripts/providers/fixture/code-visibility.md`
- **Toolkit prompt:** `scripts/providers/fixture/prompt-template.txt`
- **Toolkit rubric:** `scripts/providers/rubric/code-visibility-rubric.json`
- **Sentinel:** `ZETA-9-ORANGE-7f3a` (unguessable — only reproducible if the model
  actually received and read the fixture).
- Only the toolkit's own non-secret fixture was sent to any provider. No real repo
  file was transmitted. No API key value was ever printed or passed as a literal —
  keys were passed by env-var NAME via `--api-key-env`.

---

## Step 1 — Build (to a cache path, not the module root)

```
$ cd submodules/LLMsVerifier/llm-verifier && GOFLAGS=-mod=mod go build -o /tmp/scv-bin ./cmd/semantic-code-visibility/ 2>&1; echo EXIT=$?
EXIT=0
```

```
$ go version
go version go1.26.2-X:nodwarf5 linux/amd64
$ ls -la /tmp/scv-bin
-rwxr-xr-x 1 milosvasic milosvasic 9253148 Jul  4 22:04 /tmp/scv-bin
```

**Build result: PASS.** Binary produced at `/tmp/scv-bin` (9.25 MB). No artifact left in
the module root.

### URL construction (verified in source, main.go:352)

```go
url := strings.TrimRight(baseURL, "/") + "/v1/chat/completions"
```

The binary appends `/v1/chat/completions` to `--base-url`. This dictates the exact
base-url passed per provider (see below) so the effective path is correct — e.g. Groq's
real chat path is `/openai/v1/chat/completions`, so the base must be `.../openai` (not
`.../openai/v1`, which would double the `/v1`).

---

## Step 2 — Provider keys present in `~/api_keys.sh` (NAMES only, no values)

`~/api_keys.sh` EXISTS. Sourced in a subshell; only variable NAMES that are set and
non-empty are reported (lengths shown as a non-secret sanity signal, never the value):

```
SET_NONEMPTY: DEEPSEEK_API_KEY   (len=35)
SET_NONEMPTY: GROQ_API_KEY       (len=56)
SET_NONEMPTY: MISTRAL_API_KEY    (len=32)
SET_NONEMPTY: OPENROUTER_API_KEY (len=73)
SET_NONEMPTY: FIREWORKS_API_KEY  (len=25)
SET_NONEMPTY: GEMINI_API_KEY     (len=39)
SET_NONEMPTY: CEREBRAS_API_KEY   (len=52)
SET_NONEMPTY: HYPERBOLIC_API_KEY (len=73)
```

**Two providers chosen** (each with a key AND a known OpenAI-compatible chat endpoint),
capped at 2 live requests total, round-1 only (no judge flags), token-frugal:

1. **DeepSeek** — base `https://api.deepseek.com`, model `deepseek-chat`, key `DEEPSEEK_API_KEY`
2. **Groq** — base `https://api.groq.com/openai`, model `llama-3.3-70b-versatile`, key `GROQ_API_KEY`

---

## Step 3 — Live round-1 runs (real endpoints)

### Provider 1 — DeepSeek

Exact command (key passed by env-var NAME, never value):

```
$ source ~/api_keys.sh
$ /tmp/scv-bin --base-url https://api.deepseek.com --model deepseek-chat \
    --api-key-env DEEPSEEK_API_KEY \
    --fixture scripts/providers/fixture/code-visibility.md \
    --prompt scripts/providers/fixture/prompt-template.txt \
    --sentinel ZETA-9-ORANGE-7f3a --format json
```

Real output:

```json
{
  "round1_sentinel": {
    "pass": false,
    "observed": "",
    "reason": "non-200 status 402: {\"error\":{\"message\":\"Insufficient Balance\",\"type\":\"unknown_error\",\"param\":null,\"code\":\"invalid_request_error\"}}"
  },
  "round2_judge": {
    "pass": null,
    "score": null,
    "skipped": true
  },
  "overall_pass": false
}
EXIT=1
```

**DeepSeek verdict: FAIL — but NOT a visibility failure and NOT a test bug.** The request
reached the real DeepSeek endpoint and authenticated (a 402 billing error, not a 401
auth error, proves the key was accepted). It returned HTTP 402 "Insufficient Balance" —
the account has no credit, so no completion could be produced. This is an account/billing
precondition, external to the command under test. Inconclusive for visibility on this
provider (the model never got to respond). The tool itself behaved correctly: it surfaced
the upstream error verbatim and reported `overall_pass: false` with a truthful reason.

### Provider 2 — Groq

Exact command (key passed by env-var NAME, never value):

```
$ source ~/api_keys.sh
$ /tmp/scv-bin --base-url https://api.groq.com/openai --model llama-3.3-70b-versatile \
    --api-key-env GROQ_API_KEY \
    --fixture scripts/providers/fixture/code-visibility.md \
    --prompt scripts/providers/fixture/prompt-template.txt \
    --sentinel ZETA-9-ORANGE-7f3a --format json
```

Real output:

```json
{
  "round1_sentinel": {
    "pass": true,
    "observed": "ZETA-9-ORANGE-7f3a\n\nThe file contains two classes and one function. \n\n1. The cla"
  },
  "round2_judge": {
    "pass": null,
    "score": null,
    "skipped": true
  },
  "overall_pass": true
}
EXIT=0
```

**Groq verdict: PASS.** `round1_sentinel.pass: true`, `overall_pass: true`, exit 0. The
model reproduced the unguessable sentinel `ZETA-9-ORANGE-7f3a` verbatim at the start of
its reply and even began describing the fixture ("two classes and one function"). Because
the sentinel is a random token present only inside the toolkit fixture, this is direct
physical proof the model genuinely received and read the fixture content that the command
sent — i.e. the code-visibility path works end-to-end against a real provider.

---

## Step 4 — Per-provider verdicts

| Provider | Endpoint (effective) | Model | Verdict | Observed / reason |
|---|---|---|---|---|
| DeepSeek | `https://api.deepseek.com/v1/chat/completions` | `deepseek-chat` | **FAIL (billing, inconclusive)** | HTTP 402 "Insufficient Balance" — auth accepted, no account credit; not a visibility or test defect |
| Groq | `https://api.groq.com/openai/v1/chat/completions` | `llama-3.3-70b-versatile` | **PASS** | Sentinel `ZETA-9-ORANGE-7f3a` reproduced verbatim; `overall_pass: true`, exit 0 |

---

## Verdict

**The end-to-end `semantic-code-visibility` capability is PROVEN.** A real LLM provider
(Groq) received the toolkit fixture through the built-from-source binary and returned the
unguessable sentinel, confirming the model actually read the code the command showed it
(`overall_pass: true`, exit 0). The DeepSeek attempt did not disprove anything — it failed
upstream on account balance (HTTP 402) before the model could respond, which is an
external billing precondition, not a defect in the command. No key value was ever printed
or passed literally; no real repo file was sent; live requests were capped at 2.

## Independent re-verification (orchestrator, §11.4.9 / §11.4.69)

The orchestrator re-ran the Groq call itself (not trusting the subagent's capture) —
one token-frugal request, key passed by env-var NAME only:

```
$ /tmp/scv-bin --base-url https://api.groq.com/openai --model llama-3.3-70b-versatile \
    --api-key-env GROQ_API_KEY --fixture scripts/providers/fixture/code-visibility.md \
    --prompt scripts/providers/fixture/prompt-template.txt --sentinel ZETA-9-ORANGE-7f3a --format json
{
  "round1_sentinel": {
    "pass": true,
    "observed": "ZETA-9-ORANGE-7f3a\n\nThe code in the file consists of two classes and one functio"
  },
  "round2_judge": { "pass": null, "score": null, "skipped": true },
  "overall_pass": true
}
EXIT=0
```

Reproduced verbatim: `overall_pass: true`, exit 0, the unguessable sentinel returned AND
the model described the fixture ("two classes and one function"). The capability is proven
by two independent runs. This empirically confirms the load-bearing premise: a real
non-Anthropic model receives and reads the code shown to it through the OpenAI-compatible
alias path.
