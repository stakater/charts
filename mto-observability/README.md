# mto-observability

Observability for the **Multi Tenant Operator (MTO)**: Prometheus monitors +
`PrometheusRule` alerts + a Grafana dashboard, integrated with OpenShift
user-workload monitoring (UWM) and the grafana-operator.

> **Status: 📝 bootstrap.** The chart ships **no monitors, rules or dashboard yet**.
> The story set is drafted in [`docs/roadmap.md`](docs/roadmap.md) and is gated on
> (1) a live metrics capture from a real MTO cluster
> ([`tests/METRICS-CAPTURE.md`](tests/METRICS-CAPTURE.md)) and (2) per-story human
> approval. Scope is the **MTO suite of four operators** — tenant-operator,
> finops-operator (priority: silent cost-collection failure), hibernation-operator,
> template-operator-v2 — covering their controllers and admission webhooks. MTO
> Console/Gateway are separate systems and out of scope.

## Prerequisites (planned surface)

- OpenShift with **user-workload monitoring** enabled
- **grafana-operator** (dashboards as `GrafanaDashboard` CRs)
- MTO ≥ 1.10 with its metrics endpoint enabled (`--metrics-bind-address`, on by
  default in OperatorHub installs) — the endpoint is authenticated HTTPS, so the
  scraper must hold a token bound to MTO's `metrics-reader` ClusterRole

## Development

```bash
helm template . -f values-local.yaml   # render check
./tests/validate.sh                    # full offline gate (meaningful once stories are built)
tilt up                                # live dev against the cluster in ../tilt-settings.json
tilt down -f Tiltfile-delete
```

Configuration tables, the alert table and the dashboard panel list are added here as
stories move to ✅ Done.
