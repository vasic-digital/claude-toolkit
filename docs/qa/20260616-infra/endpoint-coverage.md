# LLMsVerifier — Endpoint Coverage Probe

- **Target:** `http://127.0.0.1:8080` on `nezha.local` (reached via `ssh milosvasic@nezha.local 'curl ...'`)
- **Date:** 2026-06-16 (UTC ~14:08)
- **Mode:** READ-ONLY discovery (GET/HEAD/POST probes only; no podman/write/restart ops)
- **Discovery pressure:** §11.4.118
- **Known real routes:** `/api/health`, `/api/models`, `/api/models/{id}`, `/api/models/{id}/verify`, `/api/providers`

All HTTP codes, bodies, and headers below are from real captured `curl -i` responses
pasted verbatim in the EVIDENCE appendix. Every row is cross-referenced to an
appendix entry by `[E#]`.

## Probe Matrix

| # | Endpoint | Method | HTTP Code | Body Excerpt | Verdict |
|---|----------|--------|-----------|--------------|---------|
| 1 | `/api/health` | GET | 200 | `{"database":"connected","database_status":"ok","status":"healthy","timestamp":1781618910}` | OK — healthy, DB connected `[E1]` |
| 2 | `/api/models` | GET | 200 | `{"count":0,"models":[]}` | OK — empty inventory (count 0) `[E2]` |
| 3 | `/api/providers` | GET | 200 | `{"count":0,"providers":[]}` | OK — empty inventory (count 0) `[E3]` |
| 4 | `/api/models/nonexistent` | GET | 400 | `Invalid model ID` | OK — input validated; rejects malformed ID before lookup `[E4]` |
| 5 | `/api/health` | POST | 405 | `Method not allowed` | OK — method routing enforced (GET-only) `[E5]` |
| 6 | `/nope` | GET | 404 | `404 page not found` | OK — clean 404 for unknown route `[E6]` |
| 7 | `/api/models/../../etc/passwd` | GET | 404 | `404 page not found` | OK — path normalized to `/etc/passwd` → 404, no traversal `[E7]` |
| 8 | `/api/models/nonexistent/verify` | POST | 400 | `Invalid model ID` | OK — verify validates ID first; no leakage `[E8]` |
| 9 | `/api/models/nonexistent/verify` | GET | 400 | `Invalid model ID` | ANOMALY (minor) — ID validation precedes method check; expected 405 `[E9]` |
| 10 | `/api/health` | HEAD | 405 | (no body) | ANOMALY (minor) — HEAD on a GET route returns 405, not 200 `[E10]` |
| 11 | `/api/models/..%2f..%2fetc%2fpasswd` | GET (`--path-as-is`) | 400 | `Invalid model ID` | OK — encoded traversal treated as opaque ID, rejected `[E11]` |
| 12 | `/` | GET | 404 | `404 page not found` | OK — no root handler (API-only service) `[E12]` |

## Summary

- **Probes executed:** 12
- **OK (expected/safe behavior):** 10
- **Anomalies:** 2 (both LOW severity / cosmetic)

### Anomaly details

1. **Row 9 — GET on `/api/models/{id}/verify` returns 400, not 405.**
   The handler validates the model ID (`Invalid model ID`) before it checks the
   HTTP method. A GET to a POST-only verify route therefore yields `400 Bad
   Request` instead of the RFC-preferred `405 Method Not Allowed`. Low severity:
   no information leak, request is still rejected — only the status taxonomy is
   imprecise. (Note: for a *valid* model ID, method-check order may differ; not
   testable here since the model inventory is empty.)

2. **Row 10 — HEAD `/api/health` returns 405, not 200.**
   The health route is registered GET-only, so HEAD (which clients/monitors often
   use for cheap liveness checks) is rejected with `405`. Low severity, but worth
   noting for any uptime monitor configured to HEAD the health endpoint — it must
   use GET.

### Health assessment

The service is **UP and healthy**. `/api/health` reports `status: healthy` with
`database: connected` / `database_status: ok`. All three real GET endpoints
(`/api/health`, `/api/models`, `/api/providers`) return `200` with valid JSON.
The models and providers inventories are both empty (`count: 0`) — consistent
with a freshly deployed / unconfigured instance, not a fault.

Security/robustness posture is solid:

- Unknown routes and root return a clean `404 page not found` (no stack traces,
  no framework banners).
- Both path-traversal attempts (dot-segment and percent-encoded) are safely
  contained — normalized to a 404 or rejected as an `Invalid model ID`; no file
  contents leaked.
- `X-Content-Type-Options: nosniff` is present on all error responses.
- Input validation rejects malformed model IDs with a generic `400` and no
  internal detail.
- No `Server` header advertising the runtime was observed in any response.

The only findings are two minor HTTP-status-code taxonomy quirks (rows 9 and 10),
neither of which is a security or availability concern. **Overall verdict: PASS —
service is live, healthy, and behaves safely under negative/discovery probing.**

---

## EVIDENCE Appendix (raw captured `curl -i` responses)

### [E1] GET /api/health
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -i http://127.0.0.1:8080/api/health'
HTTP/1.1 200 OK
Content-Type: application/json
Date: Tue, 16 Jun 2026 14:08:30 GMT
Content-Length: 90

{"database":"connected","database_status":"ok","status":"healthy","timestamp":1781618910}
```

### [E2] GET /api/models
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -i http://127.0.0.1:8080/api/models'
HTTP/1.1 200 OK
Content-Type: application/json
Date: Tue, 16 Jun 2026 14:08:35 GMT
Content-Length: 24

{"count":0,"models":[]}
```

### [E3] GET /api/providers
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -i http://127.0.0.1:8080/api/providers'
HTTP/1.1 200 OK
Content-Type: application/json
Date: Tue, 16 Jun 2026 14:08:36 GMT
Content-Length: 27

{"count":0,"providers":[]}
```

### [E4] GET /api/models/nonexistent
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -i http://127.0.0.1:8080/api/models/nonexistent'
HTTP/1.1 400 Bad Request
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Tue, 16 Jun 2026 14:08:37 GMT
Content-Length: 17

Invalid model ID
```

### [E5] POST /api/health (wrong method)
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -i -X POST http://127.0.0.1:8080/api/health'
HTTP/1.1 405 Method Not Allowed
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Tue, 16 Jun 2026 14:08:38 GMT
Content-Length: 19

Method not allowed
```

### [E6] GET /nope (unknown route)
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -i http://127.0.0.1:8080/nope'
HTTP/1.1 404 Not Found
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Tue, 16 Jun 2026 14:08:39 GMT
Content-Length: 19

404 page not found
```

### [E7] GET /api/models/../../etc/passwd (dot-segment traversal, client-normalized)
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -i "http://127.0.0.1:8080/api/models/../../etc/passwd"'
HTTP/1.1 404 Not Found
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Tue, 16 Jun 2026 14:08:40 GMT
Content-Length: 19

404 page not found
```

### [E8] POST /api/models/nonexistent/verify
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -i -X POST http://127.0.0.1:8080/api/models/nonexistent/verify'
HTTP/1.1 400 Bad Request
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Tue, 16 Jun 2026 14:08:47 GMT
Content-Length: 17

Invalid model ID
```

### [E9] GET /api/models/nonexistent/verify (wrong method — validation precedes method check)
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -i http://127.0.0.1:8080/api/models/nonexistent/verify'
HTTP/1.1 400 Bad Request
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Tue, 16 Jun 2026 14:08:47 GMT
Content-Length: 17

Invalid model ID
```

### [E10] HEAD /api/health
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -I http://127.0.0.1:8080/api/health'
HTTP/1.1 405 Method Not Allowed
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Tue, 16 Jun 2026 14:08:48 GMT
Content-Length: 19
```

### [E11] GET /api/models/..%2f..%2fetc%2fpasswd (percent-encoded traversal, --path-as-is)
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -i --path-as-is "http://127.0.0.1:8080/api/models/..%2f..%2fetc%2fpasswd"'
HTTP/1.1 400 Bad Request
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Tue, 16 Jun 2026 14:08:49 GMT
Content-Length: 17

Invalid model ID
```

### [E12] GET / (root)
```
$ ssh milosvasic@nezha.local 'curl -s -m5 -i http://127.0.0.1:8080/'
HTTP/1.1 404 Not Found
Content-Type: text/plain; charset=utf-8
X-Content-Type-Options: nosniff
Date: Tue, 16 Jun 2026 14:08:50 GMT
Content-Length: 19

404 page not found
```
