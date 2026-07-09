# kcp-observability

Prometheus alerts, recording rules, and a Grafana dashboard for a **kcp.io control plane** on
Stakater Cloud (OpenShift UWM + grafana-operator). Covers the shards (apiservers), the
front-proxy edge, etcd, workspace/logical-cluster lifecycle, the APIExport/APIBinding surface,
the kcp controllers, the cache server, and pod footprint.

> **Status: bootstrapping.** The roadmap is drafted; rules and the dashboard are **not built
> yet** — they are being pinned against a real `/metrics` scrape from a live kcp control plane so
> nothing references a metric that doesn't exist. See below.

## Read these first

- [`docs/roadmap.md`](docs/roadmap.md) — the capability areas and user stories (design intent),
  each with SLI/SLO/SLA, alert, and dashboard. **Review target.**
- [`tests/METRICS-CAPTURE.md`](tests/METRICS-CAPTURE.md) — how to capture the real per-component
  `/metrics` scrape into `tests/fixtures/`. **This is the current blocking step.**

## The discipline (same as crossplane-observability)

No rule or panel references a metric unless it is either **captured** from a real cluster
(`tests/fixtures/`) or **documented upstream with a citation**. An offline gate
(`tests/validate.sh`, added once building starts) enforces it. kcp metric *names and labels* are
confirmed from the live dump, not assumed — assumed labels were the #1 bug source last time.

## Conventions

Archetype B (full observability). Grafana block, per-component `ServiceMonitor`/`PodMonitor`
(default off), one `PrometheusRule` per alert file under `templates/prometheus/rules/`, gated by
its own `enabled` value. See the repo-root `CLAUDE.md` for the shared conventions.
