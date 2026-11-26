# netbird-observability — handover & deploy guide

One-page orientation for the team member taking this to production. Read this, then
`README.md` (install/config tables) and `docs/roadmap.md` (the why behind every alert).

## What it is

A Helm chart of Prometheus alerts (13) + a fleet Grafana dashboard for self-hosted
NetBird instances (management, signal, relay) on OpenShift UWM. Fleet model: **one
NetBird instance per customer/organization namespace, this chart installed once per
instance namespace** (UWM tenancy forces it; the roadmap's "deployment model" section
explains). It ships a self-contained test harness whose central rule: **no metric is
referenced unless captured from a real NetBird v0.75.0 (`tests/fixtures/`) or documented
upstream with a citation** (`tests/metrics-allowlist.documented.txt`).

## Status (2026-10-31)

- Branch `feat/netbird-observability` (6 commits, pushed). **PR not yet opened.**
- Offline gate `./tests/validate.sh` → green (lint/render, job-coherence, promtool
  check + 20 unit test cases, metric-reality gate, dashboard guards, strict kubeconform).
- kind e2e → green (`tests/reports/e2e-kind-2026-10-31.md`): two real NetBird instances;
  TargetDown ×3 components, MetricsAbsent, a real relay crashloop (PodRestarting) and a
  real 32Mi OOM-kill (PodOOM) each fire, deliver to Alertmanager, and resolve — with the
  healthy instance asserted quiet every time.
- **Not deployed to any cluster yet.** Dashboard screenshots: `docs/images/`.

## Deploy — step by step

### 1. Publish the chart

1. Open the PR from `feat/netbird-observability`. Repo rules: **one chart per PR**;
   merge with **Rebase and Merge** (plain Merge breaks the pipeline); no label = patch
   bump. First release of a new chart → publishes `0.0.1`.
2. Confirm it actually published: the `Pushed: ghcr.io/stakater/charts/netbird-observability:X.Y.Z`
   line in the push job (or the `netbird-observability-X.Y.Z` git tag). **Pin that
   version everywhere — never the `version:` in `Chart.yaml`** (it is overwritten by the
   pipeline and never published as-is).

### 2. Canary: one instance namespace on one cluster

Pick a non-production mesh first (a dev/platform mesh, not a customer's). In that
namespace:

```bash
helm install netbird-observability oci://ghcr.io/stakater/charts/netbird-observability \
  --version <published X.Y.Z> -n <mesh-namespace> \
  --set prometheus.monitors.management.enabled=true \
  --set prometheus.monitors.signal.enabled=true \
  --set prometheus.monitors.relay.enabled=true
```

Notes:
- Monitors default **off**; the three `--set`s opt in. A mesh that runs no relay of its
  own (shared platform relay): leave `relay.enabled=false` — its watchdogs disarm with it.
- `grafana.dashboard.enabled` defaults **true**: fine on the first install; every further
  install on the same cluster adds `--set grafana.dashboard.enabled=false` (the dashboard
  is fleet-wide via its `$namespace` variable — one copy per cluster).
- Grafana defaults assume the platform conventions: instance selector `{app: grafana}`,
  datasource **named** `prometheus`. Different cluster → override the COMPLETE
  `grafana.instanceSelector` (map-merge trap — see values.yaml) and the datasource name.

### 3. Verify (15 minutes, in order)

1. **Scrape:** `up{job=~"netbird-(management|signal|relay)-metrics", namespace="<ns>"}`
   returns 3 series = 1 (console → Observe → Metrics, or thanos-querier).
2. **Rules loaded:** `oc -n <ns> get prometheusrule` shows the 13 rules; the console's
   Alerting page lists the `NetBird*` alerts as inactive.
3. **Dashboard:** "NetBird Fleet Observability" appears in Grafana (folder "NetBird
   Observability"); the status matrix shows the namespace with all components `up`;
   management panels fill as API traffic occurs (signal/relay panels stay "No data"
   until real peers — lazily registered metrics, expected).
4. **Fire one alert for real** (canary namespace only): point the management metrics
   Service at a dead port, watch `NetBirdTargetDown{namespace="<ns>", target="management"}`
   fire (~6–7 min at defaults: 5m `for` + scrape/eval), then restore:
   ```bash
   oc -n <ns> patch svc netbird-management-metrics --type json \
     -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9999}]'
   # after it fires:
   oc -n <ns> patch svc netbird-management-metrics --type json \
     -p '[{"op":"replace","path":"/spec/ports/0/targetPort","value":9090}]'
   ```
5. **Delivery — the known gap (roadmap Story 5.1):** the alert firing in
   Prometheus/Alertmanager does **not** mean a human was paged. Receiver wiring on
   hosting clusters is an open platform decision; until it lands, treat alerting as
   visible-in-console only. When it lands, re-run step 4 and confirm the page arrives —
   delivery is verified by a received notification, never by config review.

### 4. Fleet rollout

- **Blocked on the team's Decision 1** (roadmap Story 5.2): who installs per mesh —
  recommendation is the mesh composition installs it transactionally with each mesh,
  plus a cluster-scoped coverage watchdog. Until decided, per-mesh installs are manual:
  repeat step 2 per namespace with `grafana.dashboard.enabled=false`.
- `prometheus.rules.labels` is the hook for Alertmanager routing labels if the platform
  routes on anything beyond `severity` — set it identically on every install.

### 5. After 2–4 weeks of baseline

Calibrate: every latency/ratio threshold in `values.yaml` is a documented placeholder
(`docs/roadmap.md`, calibration note). Calibration = values change on the installs, not
a chart release. While at it, capture `/metrics` from a live instance **with real
peers** and graduate documented-tier metrics to captured (`tests/fixtures/CAPTURE.md`,
refresh procedure).

## How to work on it (the discipline — don't skip)

- `./tests/validate.sh` must stay green on every change; it runs offline
  (promtool/kubeconform via Docker if not on PATH).
- **Every rule change needs a `tests/unit/rules.test.yaml` case.** Never weaken a gate.
- **Never reference a metric you haven't verified** — captured fixture or documented
  with citation; `tests/check_metrics.py` enforces it.
- e2e before any release that touches rules/monitors:
  `tests/e2e/up.sh && tests/e2e/scenarios.sh && tests/e2e/down.sh` (kind + Docker,
  ~30 min; writes a dated report into `tests/reports/` — commit it).
- Labels are the #1 bug class here. Already caught: prometheus-operator renames
  NetBird's HTTP `endpoint` label to `exported_endpoint` on-cluster; signal metrics are
  unprefixed (job-scope everything); KSM's OOM reason label latches (the PodOOM alert's
  restart-guard exists for that). Confirm new labels against the e2e rig, not the docs.

## Key design decisions (the "why", so you don't undo them)

- **Fixed metrics-Service names** (`netbird-<component>-metrics`) = fleet-stable `job`
  labels, so one dashboard and one rule set cover every instance regardless of release
  names. One instance per namespace is assumed.
- **Per-instance install, not central**: UWM ServiceMonitors can't cross namespaces and
  ThanosRuler enforces the rule's namespace label. Per-instance also makes every alert
  carry the customer's namespace — the routing dimension on-call needs.
- **Lazy metrics never alert on absence** — a healthy idle signal exports no app metrics
  at all. Only `up` and the watchdog pair reason about absence.
- **Postgres and TLS are other charts' mechanisms** (`cloudnative-pg-observability`,
  `cert-manager-observability`); `NetBirdManagementStoreSlow` is deliberately only the
  NetBird-side symptom pointer.
- Roadmap Stories 5.4–5.6 (registered-peers exporter, bootstrap convergence, SLO rollup)
  are Draft — written down, not approved. Don't build them without a decision.
