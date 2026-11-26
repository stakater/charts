# mto-observability

Observability for the **Multi Tenant Operator (MTO)**: Prometheus monitors +
`PrometheusRule` alerts + a Grafana dashboard, integrated with OpenShift
user-workload monitoring (UWM) and the grafana-operator.

> **Status: 🔨 Tier 2 built, unreleased.** The chart now ships PodMonitors + scraper
> RBAC for all four MTO operators and the generic operator-health alert set below,
> all behind a green [`tests/validate.sh`](tests/validate.sh). **Release stays gated**
> on (1) a live metrics capture re-verifying the scrape surface
> ([`tests/METRICS-CAPTURE.md`](tests/METRICS-CAPTURE.md)) and (2) the remaining
> roadmap decisions. Tier 1 (finops cost-pipeline alerts,
> [`docs/finops-alerts.md`](docs/finops-alerts.md)) additionally waits on operator
> releases carrying the state gauges. Scope is the **MTO suite of four operators** —
> tenant-operator, finops-operator (priority: silent cost-collection failure),
> hibernation-operator, template-operator-v2. MTO Console/Gateway are out of scope.

## Alerts (Tier 2 — rendered per enabled operator)

For each of the four operators (`<Op>` = TenantOperator / FinopsOperator /
HibernationOperator / TemplateOperator):

| Alert | Severity | Fires when |
| --- | --- | --- |
| `MTO<Op>Down` | critical | `up == 0` or the job is absent for 5m (needs `prometheus.monitors.podMonitors.enabled`) |
| `MTO<Op>ReconcileErrors` | warning | a controller's reconcile error ratio > 10% over 15m |
| `MTO<Op>WorkqueueBacklog` | warning | a workqueue holds > 50 items for 15m |
| `MTO<Op>WebhookErrors` | warning | an admission webhook returns 5xx for 10m |
| `MTO<Op>WebhookLatencyHigh` | warning | webhook p99 latency > 1s for 10m |

Thresholds are placeholders until a live baseline; every one is a value under
`prometheus.rules.mto.*`. Monitors default **off**; enabling them also creates the
scraper ServiceAccount/token bound to a `GET /metrics` ClusterRole (every operator
serves authenticated HTTPS metrics).

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
