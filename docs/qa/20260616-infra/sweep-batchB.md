# LLM Provider Verification Sweep — Batch B

- **Date:** 2026-06-16
- **Host:** nezha.local (verification executed there; keys never left the host)
- **Verifier image:** `localhost/llm-verifier-mv:nezha` (built ~2h before sweep)
- **Method (per provider, 2-step):**
  1. Read-only `curl <base>/models` (or chat probe where `/models` is unavailable) with `Bearer ${KEYVAR}` from `~/helix-system/llmsverifier/.env` to discover/confirm a real chat model id.
  2. `podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha --provider <P> --model <id> --verbose`
- **Constraints honored:** no builds, no git, no touching deployed `llmsverifier_*` containers; only the ephemeral `--rm` verifier container + read-only curl.

## Results

| Provider  | Model              | Status   | CanSeeCode | Score | Error (HTTP) |
|-----------|--------------------|----------|------------|-------|--------------|
| codestral | codestral-latest   | verified | true       | 0.98  | —            |
| chutes    | Qwen/Qwen3-32B-TEE | error    | false      | 0.00  | HTTP 402 — account balance $0.0 (quota exceeded) |
| upstage   | solar-pro2         | error    | false      | 0.00  | HTTP 403 — blocked at AWS ELB edge (key never reaches API) |

## Honest verdicts

- **codestral — PASS (working).** Real chat model `codestral-latest` confirmed via a live 200 chat completion, then verified by the harness with Status `verified`, Can See Code `true`, Score `0.98`. Key valid, provider fully reachable. Note: codestral has no `/v1/models` listing route (returns 404 "no Route matched"); the model id was confirmed directly through `/v1/chat/completions`.

- **chutes — FAIL (billing-blocked, NOT dead).** Key is valid and the model id is genuine (`Qwen/Qwen3-32B-TEE` appears in the live `/v1/models` list). Verification fails with **HTTP 402**; direct curl returns the explicit message `Quota exceeded and account balance is $0.0`. Provider and credentials are healthy — the account is simply unfunded. Fundable to recover.

- **upstage — FAIL (edge-blocked / unreachable from nezha).** Every request (with auth, without auth, `/models`, `/solar/chat/completions`, `/chat/completions`) returns an identical **HTTP 403** served by `server: awselb/2.0` as raw nginx-style HTML — not a JSON API auth error. The response is byte-identical with and without the Bearer token, which means the block happens at the AWS load balancer **before** the request reaches the Upstage API or any auth check. The key itself has the correct `up_…` Upstage format. Most likely cause: geo/IP filtering of nezha's egress IP (or WAF). Could not discover or exercise any model id. Distinct from chutes: this is a network/edge reachability failure, not a credential or billing problem.

---

## EVIDENCE APPENDIX (real captured output)

### Pre-flight: image + keys present on nezha
```
$ ssh nezha.local 'podman images | grep llm-verifier-mv'
localhost/llm-verifier-mv                     nezha               3c453651e273  2 hours ago     31.8 MB

$ grep -E '^(UPSTAGE|CHUTES|CODESTRAL)_API_KEY=' ~/helix-system/llmsverifier/.env | sed 's/=.\+/=<set>/'
CODESTRAL_API_KEY=<set>
UPSTAGE_API_KEY=<set>
CHUTES_API_KEY=<set>
```

### codestral — model discovery
`/v1/models` has no route; confirmed model directly via chat:
```
$ curl -s https://codestral.mistral.ai/v1/models -H "Authorization: Bearer ${CODESTRAL_API_KEY}" -w "\nHTTP:%{http_code}\n"
{"message":"no Route matched with those values","request_id":"5b3daf6a06381e79c4c7c87502afca2f"}
HTTP:404

$ curl -s https://codestral.mistral.ai/v1/chat/completions -H "Authorization: Bearer ${CODESTRAL_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"codestral-latest","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' -w "\nHTTP:%{http_code}\n"
{"id":"a619f3b7b8f547e091ac410e62d4371d","created":1781631464,"model":"codestral-latest",
 "usage":{"prompt_tokens":4,"total_tokens":9,"completion_tokens":5,...},
 "object":"chat.completion","choices":[{"index":0,"finish_reason":"length",
 "message":{"role":"assistant","tool_calls":null,"content":"Hello! 😊"}}]}
HTTP:200
```

### codestral — verifier run
```
$ podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha \
    --provider codestral --model codestral-latest --verbose
→ verifying requested id directly against the provider API
✅ Verification completed in 4.968921797s
Status: verified
Can See Code: true
Verification Score: 0.98
```

### chutes — model discovery (live /models, first entries)
```
$ curl -s https://llm.chutes.ai/v1/models -H "Authorization: Bearer ${CHUTES_API_KEY}" -w "\nHTTP:%{http_code}\n"
{"object":"list","data":[
  {"id":"Qwen/Qwen3-32B-TEE","root":"Qwen/Qwen3-32B-FP8", ... "context_length":40960,
   "supported_features":["json_mode","tools","structured_outputs","reasoning"], ...},
  {"id":"google/gemma-4-31B-turbo-TEE", ...},
  {"id":"zai-org/GLM-5.1-TEE", ...},
  {"id":"moonshotai/Kimi-K2.6-TEE", ...}, ...]}
HTTP:200
```

### chutes — verifier run
```
$ podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha \
    --provider chutes --model "Qwen/Qwen3-32B-TEE" --verbose
✅ Verification completed in 1.699261683s
Status: error
Can See Code: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with status 402 (avg response time: 1699ms) (response length: 0)
```

### chutes — direct curl confirming the 402 is an unfunded account (not a model/key fault)
```
$ curl -s https://llm.chutes.ai/v1/chat/completions -H "Authorization: Bearer ${CHUTES_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"Qwen/Qwen3-32B-TEE","messages":[{"role":"user","content":"hi"}],"max_tokens":5}' -w "\nHTTP:%{http_code}\n"
{"detail":{"message":"Quota exceeded and account balance is $0.0, please pay with fiat or send tao to 5HSnNYmThbTVp2N6vhuHMpRCmagVEHpKPBP9kDEsG2qAgCCo"}}
HTTP:402
```

### upstage — model discovery / reachability (all 403 from AWS ELB, identical with & without auth)
```
$ curl -s -i https://api.upstage.ai/v1/solar/chat/completions -H "Authorization: Bearer ${UPSTAGE_API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"solar-pro2","messages":[{"role":"user","content":"hi"}],"max_tokens":5}'
HTTP/2 403
server: awselb/2.0
date: Tue, 16 Jun 2026 17:38:08 GMT
content-type: text/html
content-length: 118
<html><head><title>403 Forbidden</title></head><body><center><h1>403 Forbidden</h1></center></body></html>

# Same 403 WITHOUT the Authorization header -> block is pre-auth, at the edge:
$ curl -s -i https://api.upstage.ai/v1/solar/chat/completions -H "Content-Type: application/json" \
    -d '{"model":"solar-pro2","messages":[{"role":"user","content":"hi"}]}'
HTTP/2 403
server: awselb/2.0
...
<html><head><title>403 Forbidden</title></head>...

# Key has correct Upstage format:
$ echo "${UPSTAGE_API_KEY}" | sed -E 's/(.{6}).*(.{3})/\1...\2/'
up_SMK...hCu

# /v1/models and /v1/solar/models also return the same edge 403.
```

### upstage — verifier run
```
$ podman run --rm --env-file ~/helix-system/llmsverifier/.env llm-verifier-mv:nezha \
    --provider upstage --model solar-pro2 --verbose
✅ Verification completed in 423.388508ms
Status: error
Can See Code: false
Verification Score: 0.00
Error: Meaningful response verification failed: API request failed: API request failed with status 403 (avg response time: 423ms) (response length: 0)
```
