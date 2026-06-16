# Observability wiring — verification + honest gaps

Read-only verification of the prometheus/grafana chain against the live nezha
stack. Captured, no bluff.

## Results

| Check | Result |
|-------|--------|
| prometheus + llm-verifier on same podman network | **YES** — both on `llmsverifier_default` (service DNS resolves) |
| prometheus self-scrape | **up** |
| grafana API health | `database: ok` (v13.0.2) |
| **llm-verifier `/metrics`** | **404 — GAP** |
| prometheus `llm-verifier` target | **down** (`server returned HTTP status 404`) |
| node/postgres/redis exporter targets | down (exporters not deployed — optional, intentionally omitted) |

## Honest gaps (not fixed — feature/scope limitations, surfaced not buried)

1. **App exposes no Prometheus metrics endpoint.** `api/server.go` registers
   only `/api/health`, `/api/models`, `/api/models/`, `/api/models/{id}/verify`,
   `/api/providers` — there is **no `/metrics` route**. `PROMETHEUS_ENABLED=true`
   does not produce an HTTP metrics endpoint in this build. So prometheus cannot
   scrape the app (target down, 404). Fixing this is an **upstream app feature
   addition** (implement a `/metrics` handler), out of scope for the deployment;
   the network wiring is correct and ready the moment the app exposes metrics.
2. **Exporter sidecars not deployed.** node/postgres/redis exporters are absent
   by design (the overlay deploys the core data + observability tier only). The
   prometheus.yml scrape jobs for them are therefore down; they activate if the
   exporters are added later.

The application health (`/api/health`), data tier, and grafana are fully
functional; the only observability gap is app-level metric *scraping*, which
depends on an upstream feature.
