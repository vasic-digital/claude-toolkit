# Prometheus `/metrics` Endpoint — Read-Only Source Research

**Repo:** `/Volumes/T7/Projects/claude_tookit/submodules/LLMsVerifier/llm-verifier`
**Module:** `digital.vasic.llmsverifier` (`go 1.25.3`)
**Date:** 2026-06-16
**Scope:** READ-ONLY analysis. No edits, no git ops. Goal: determine exactly how to add a working `GET /api/metrics` (and/or `/metrics`) Prometheus endpoint to `api/server.go`.

---

## TL;DR / Answer

- **Is `github.com/prometheus/client_golang` available?** **NO.** It is not in `go.mod` and not in `go.sum` (0 hits). `promhttp` / `prometheus.NewRegistry` / `MustRegister` appear nowhere in the codebase.
- **But you do NOT need it.** The repo already ships a **zero-dependency, hand-rolled Prometheus *text-format* exporter** — `monitoring.PrometheusExporter` in `monitoring/prometheus.go` — which is a plain `http.Handler` (`func (pe *PrometheusExporter) ServeHTTP(w, r)`) emitting valid `text/plain; version=0.0.4` output via `fmt.Fprintf`. Wiring this into `api/server.go` adds **no new go.mod dependency** and is the smallest, mandate-compliant (no-`go get`/no-network) change.
- **Exact change:** add the `monitoring` import and one (or two) `mux.HandleFunc` lines in **both** `Router()` and `Start()` of `api/server.go`. See "Ready-to-apply snippet" below. The only open question is wiring the `*monitoring.PrometheusExporter`'s dependencies (it needs a `MetricsCollector`, `AlertManager`, `MetricsTracker`) — two implementation options are given.

---

## 1. Dependency status

`client_golang` is **NOT** a dependency.

```
$ grep -nE 'prometheus' go.mod        # → (no output)
$ grep -nE 'prometheus' go.sum        # → (no output)
$ grep -c 'client_golang' go.sum      # → 0
```

Adding the official client (`github.com/prometheus/client_golang/prometheus/promhttp`) would require `go get` (network) + a `go.mod`/`go.sum` change. Per the repo's hard-stop constraints (no network-dependent build steps assumed), **prefer the existing in-repo exporter** which needs no new module.

If the official library IS desired later, the import + handler are given in §4(B).

---

## 2. Router structure — `api/server.go`

The server uses the stdlib `net/http` `ServeMux` with `mux.HandleFunc` per route. The mux variable name is **`mux`**. There are **TWO** identical registration blocks that must be kept in sync — one in `Router()` (used by tests) and one in `Start()` (used at runtime).

`api/server.go` current imports (lines 5-10):

```go
import (
	"net/http"

	"digital.vasic.llmsverifier/config"
	"digital.vasic.llmsverifier/database"
)
```

`Router()` registration block (lines 28-39):

```go
func (s *Server) Router() http.Handler {
	mux := http.NewServeMux()

	// Register API endpoints
	mux.HandleFunc("/api/health", s.HealthHandler)
	mux.HandleFunc("/api/models", s.ListModelsHandler)
	mux.HandleFunc("/api/models/", s.GetModelHandler)
	mux.HandleFunc("/api/models/{id}/verify", s.VerifyModelHandler)
	mux.HandleFunc("/api/providers", s.ProvidersHandler)

	return mux
}
```

`Start()` registration block (lines 43-49) — same routes, separate mux:

```go
func (s *Server) Start(port string) error {
	mux := http.NewServeMux()

	mux.HandleFunc("/api/health", s.HealthHandler)
	mux.HandleFunc("/api/models", s.ListModelsHandler)
	mux.HandleFunc("/api/models/", s.GetModelHandler)
	mux.HandleFunc("/api/models/{id}/verify", s.VerifyModelHandler)
	mux.HandleFunc("/api/providers", s.ProvidersHandler)
	...
}
```

The `Server` struct (lines 13-17) holds `config *config.Config`, `database *database.Database`, `server *http.Server`. It does NOT currently hold a metrics exporter — adding one is the cleanest way to wire dependencies (see §4(A) Option 2).

---

## 3. Existing metrics / registry code

There is **no Prometheus client-library registry** (`prometheus.NewRegistry` / `MustRegister` not found). But there is substantial existing metrics surface, none of it in `api/`:

- **`monitoring/prometheus.go`** — `PrometheusExporter` with `ServeHTTP(w, r)` that writes valid Prometheus text format using only `fmt.Fprintf` (stdlib). Sets `Content-Type: text/plain; version=0.0.4`. Emits counters/gauges for brotli tests, cache hit rate, active verifications, success rate. **This is the reusable handler.**
- `monitoring/health.go:606` — a Gin route `router.GET("/metrics", ...)` (Gin, different router than `api/`).
- `enhanced/analytics/api.go:408,474` — `ExportMetrics` handler on `mux.HandleFunc("/metrics", pe.ExportMetrics)` producing Prometheus format from an analytics summary (another self-contained, dependency-free exporter).
- `events/websocket_server.go:130` — `mux.HandleFunc("/metrics", server.handleMetrics)`.
- `config/production_config.go:127,353` — config struct `ProductionPrometheusConfig` and a default scrape `Path: "/metrics"` (config only; no handler).
- `enhanced/enterprise/api.go:212` — `/api/enterprise/metrics` (auth/rbac gated).
- `pkg/cliagents/generator.go:595` — emits a prometheus MCP server config entry (unrelated).

So the `api.Server` mux is the only public REST router that lacks a metrics route; the building block to fill that gap already exists in `monitoring/`.

---

## 4. Ready-to-apply code

### (A) RECOMMENDED — reuse the in-repo exporter (NO new dependency)

`monitoring.PrometheusExporter` already satisfies `http.Handler` (it has `ServeHTTP`), so it can be passed straight to `mux.Handle`. It is constructed via:

```go
func NewPrometheusExporter(metricsCollector *MetricsCollector, alertManager *AlertManager, metricsTracker *MetricsTracker) *PrometheusExporter
```

**Import to add** to `api/server.go`:

```go
"digital.vasic.llmsverifier/monitoring"
```

**Option 1 — exporter stored on the Server (cleanest; survives both Router() and Start()).**
Add a field to `Server` and set it in `NewServer` (caller supplies the collector/alertManager/tracker it already builds), then in BOTH `Router()` and `Start()` add:

```go
// Prometheus metrics (text exposition format; no external deps)
if s.metricsExporter != nil {
	mux.Handle("/api/metrics", s.metricsExporter) // GET /api/metrics
	mux.Handle("/metrics", s.metricsExporter)     // optional alias for default scrape path
}
```

(Field: `metricsExporter *monitoring.PrometheusExporter` on the `Server` struct; assign in `NewServer`.)

**Option 2 — construct inline** (acceptable if the three monitoring deps are reachable at wiring time):

```go
exp := monitoring.NewPrometheusExporter(metricsCollector, alertManager, metricsTracker)
mux.Handle("/api/metrics", exp)
mux.Handle("/metrics", exp)
```

Note: use `mux.Handle` (not `HandleFunc`) because `PrometheusExporter` is already an `http.Handler`. If you prefer `HandleFunc` symmetry with the surrounding lines, use `mux.HandleFunc("/api/metrics", exp.ServeHTTP)`.

**Minimal 1-line essence (the load-bearing addition), in each of the two blocks:**

```go
mux.Handle("/api/metrics", s.metricsExporter)
```

### (B) ALTERNATIVE — official `client_golang` (requires `go get`, NETWORK)

Only if you want the standard registry/default Go runtime metrics. This is NOT currently buildable offline — it needs:

```
go get github.com/prometheus/client_golang/prometheus/promhttp
```

Then in `api/server.go`:

```go
import (
	// ...existing...
	"github.com/prometheus/client_golang/prometheus/promhttp"
)
```

and in BOTH `Router()` and `Start()`:

```go
mux.Handle("/api/metrics", promhttp.Handler()) // serves the default registry
```

`promhttp.Handler()` returns an `http.Handler` over `prometheus.DefaultRegisterer`/`DefaultGatherer`, so any package that does `prometheus.MustRegister(...)` is exposed automatically. Cost: a new go.mod/go.sum dependency + transitive deps (`client_model`, `common`, `procfs`).

---

## Recommendation

Use **(A) Option 1**: store a `*monitoring.PrometheusExporter` on `Server`, and register `mux.Handle("/api/metrics", s.metricsExporter)` (plus optional `/metrics` alias) in both `Router()` and `Start()`. Zero new dependencies, no `go get`, reuses tested in-repo exposition logic, and keeps the two mux blocks in sync. Per repo Definition-of-Done, follow with a real run: `curl -s localhost:8080/api/metrics` should return `text/plain; version=0.0.4` Prometheus output (brotli_*, verification_* series).

---

## EVIDENCE (real command output)

### go.mod / go.sum prometheus scan
```
$ grep -nE 'prometheus' go.mod        # (no output)
$ grep -nE 'prometheus' go.sum        # (no output)
$ grep -c 'client_golang' go.sum
0
```

### Module header
```
$ grep -nE '^module|^go ' go.mod
1:module digital.vasic.llmsverifier
3:go 1.25.3
```

### Router registrations in api/server.go
```
$ grep -nE 'HandleFunc|http.NewServeMux' api/server.go
29:	mux := http.NewServeMux()
32:	mux.HandleFunc("/api/health", s.HealthHandler)
33:	mux.HandleFunc("/api/models", s.ListModelsHandler)
34:	mux.HandleFunc("/api/models/", s.GetModelHandler)
35:	mux.HandleFunc("/api/models/{id}/verify", s.VerifyModelHandler)
36:	mux.HandleFunc("/api/providers", s.ProvidersHandler)
43:	mux := http.NewServeMux()
45:	mux.HandleFunc("/api/health", s.HealthHandler)
46:	mux.HandleFunc("/api/models", s.ListModelsHandler)
47:	mux.HandleFunc("/api/models/", s.GetModelHandler)
48:	mux.HandleFunc("/api/models/{id}/verify", s.VerifyModelHandler)
49:	mux.HandleFunc("/api/providers", s.ProvidersHandler)
```

### Module-wide prometheus / promhttp / metrics scan (excludes _test.go)
```
$ grep -rnE 'promhttp|prometheus|/metrics' --include='*.go' . | grep -v _test.go
config/production_config.go:127:	Prometheus ProductionPrometheusConfig `yaml:"prometheus"`
config/production_config.go:353:				Path:      "/metrics",
enhanced/analytics/api.go:44:// RecordMetric handles POST /api/analytics/metrics
enhanced/analytics/api.go:267:	mux.HandleFunc("/api/analytics/metrics", h.RecordMetric)
enhanced/analytics/api.go:408:// ExportMetrics handles GET /metrics (Prometheus format)
enhanced/analytics/api.go:418:	prometheusText := pe.convertToPrometheusFormat(summary)
enhanced/analytics/api.go:421:	w.Write([]byte(prometheusText))
enhanced/analytics/api.go:474:	mux.HandleFunc("/metrics", pe.ExportMetrics)
enhanced/enterprise/api.go:212:	mux.HandleFunc("/api/enterprise/metrics", api.withMiddleware(api.handleMetrics, "auth", "rbac"))
enhanced/enterprise/api.go:810:	case strings.HasPrefix(path, "/api/enterprise/metrics"):
events/websocket_server.go:130:	mux.HandleFunc("/metrics", server.handleMetrics)
monitoring/health.go:606:	router.GET("/metrics", func(c *gin.Context) {
monitoring/prometheus.go:27:// ServeHTTP serves Prometheus metrics at /metrics endpoint
pkg/cliagents/generator.go:595:		{Name: "prometheus", Type: "remote", URL: "http://" + host + ":9923/sse"},
```

### monitoring/prometheus.go — reusable handler signature
```
package monitoring  (imports: fmt, net/http, sync, time — NO external deps)

type PrometheusExporter struct { metricsCollector *MetricsCollector; alertManager *AlertManager; metricsTracker *MetricsTracker; mu sync.RWMutex }

func NewPrometheusExporter(metricsCollector *MetricsCollector, alertManager *AlertManager, metricsTracker *MetricsTracker) *PrometheusExporter

// line 28:
func (pe *PrometheusExporter) ServeHTTP(w http.ResponseWriter, r *http.Request)
//   sets w.Header().Set("Content-Type", "text/plain; version=0.0.4")
//   writes brotli_*, verification_active_count, verification_success_rate via fmt.Fprintf
```
