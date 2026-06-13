# crossplane-observability

A Helm chart for **Crossplane** observability on **Stakater Cloud**, integrated with
**OpenShift user-workload monitoring (UWM)** and the **grafana-operator**. It is the
implementation of the [Crossplane Observability Roadmap](docs/roadmap.md) — every alert,
recording rule, and dashboard row below maps to a numbered user story in that document.

It ships into the Crossplane namespace:

| Resource | Count | Purpose |
| --- | --- | --- |
| `ServiceMonitor` (core) | 1 | Scrapes Crossplane core `/metrics` (controller-runtime, workqueue, circuit-breaker, function pipeline). |
| `PodMonitor` (providers) | 1 | Scrapes provider pods — `crossplane_managed_resource_*` (ready/synced/TTR/drift) + `upjet_*`. |
| `PrometheusRule` (recording) | 1 | SLO recording rules — pre-computed SLIs incl. the headline composite (Story 1.3). |
| `PrometheusRule` (alerts) | up to 18 | One alert (or closely-paired alert set) per file under `templates/prometheus/rules/<area>/`. |
| `GrafanaDashboard` | 1 | Consolidated dashboard, one row per capability area. Gated on `grafana.dashboard.enabled`. |

> **Roadmap status.** Every numeric threshold here is a **placeholder**. The roadmap
> requires 2–4 weeks of real baseline before committing SLA numbers, segmented per tier and
> per resource class. Treat the shipped defaults as starting points, not contracts.

## Phasing

| Phase | What you get | Default | Stories |
| --- | --- | --- | --- |
| **Phase 1 — Now (Crossplane 2.1.3)** | ~75% coverage, everything customer-facing | **enabled** | 1.1, 1.2, 1.3, 2.1–2.5, 3.1, 6.1*, 7.1, 7.2 |
| **Phase 2 — confirm-on-build (2.2/2.3, often 2.1.x)** | Function-pipeline visibility + multi-tenant thrashing protection | **disabled** | 4.2, 5.1, 5.2 |
| **Needs exporter** | Claim/XRD/Composition inventory layer | **disabled** | 4.1 |

\* Story 6.1 is Phase 1 but **Upjet-providers only** — gated on `upjet.enabled`.

Phase 2 and exporter-dependent rules are present but **off by default**. "Phase 2" is
*confirm-on-build*, not strictly post-upgrade: `function_run_*` and `circuit_breaker_*` are
already emitted on some Crossplane **2.1.x** builds (confirmed in deploy validation). Confirm
with `tests/fetch-cluster-metrics.sh` / `verify-fetched.py`, then enable. ⚠️ Before enabling
`FunctionErrorRate`, note the error filter is `result_severity="Fatal"` (the real label — there
is no `result="error"`); confirm it matches your build.

## Prerequisites

### 1. OpenShift user-workload monitoring enabled

```yaml
# openshift-monitoring/cluster-monitoring-config configmap
data:
  config.yaml: |
    enableUserWorkload: true
```

UWM evaluates these `PrometheusRule`s in `thanos-ruler-user-workload`.

### 2. Crossplane metrics exposed

- **Core:** start core with `--set metrics.enabled=true` (Helm) so `/metrics` is served.
- **Providers:** expose a metrics port on each provider via its `DeploymentRuntimeConfig`.
  Every crossplane-runtime provider emits `crossplane_managed_resource_*` natively
  (ready/synced/TTR/drift) — no external exporter is needed for leaf-MR health.

Then turn on the scrapers (both default to `false`):

```yaml
prometheus:
  monitors:
    coreServiceMonitor: { enabled: true }
    providerPodMonitor: { enabled: true }
```

> **If your cluster already scrapes Crossplane** (e.g. Stakater Cloud ships its own `crossplane-core`
> ServiceMonitor + `crossplane-providers-and-functions` PodMonitor), leave the chart's
> monitors **disabled** and just point the rules at the existing jobs — see below.

### Cluster-specific wiring (don't assume the defaults fit)

The defaults target a generic upstream Crossplane install. On Stakater Cloud/OpenShift you typically
override:

| Value | Default | Stakater Cloud / typical override |
| --- | --- | --- |
| `crossplane.core.job` | `crossplane` | `crossplane-metrics` |
| `crossplane.providers.job` | `crossplane-providers` | `crossplane-system/crossplane-providers-and-functions` |
| `crossplane.core.serviceMonitorSelector` | `{name:crossplane, component:metrics}` | match your metrics Service labels (only if you enable the chart's monitor) |
| `crossplane.providers.selector` | `pkg.crossplane.io/revision: Exists` | match your provider pods (only if you enable the chart's monitor) |
| `grafana.instanceSelector` | `{app: grafana}` | your instance's labels, e.g. `{dashboards: crossplane}` |

The `job` values are the important ones — **the alert/recording expressions filter on them**,
so if they don't match what your Prometheus assigns, rules evaluate to empty. Find them with
`count by (job)({__name__=~"crossplane_managed_resource_.+"})`.

**Grafana gotchas (grafana-operator):** to change `grafana.instanceSelector` you must also null
the default key, because Helm deep-merges maps — e.g. `--set grafana.instanceSelector.app=null
--set grafana.instanceSelector.dashboards=crossplane`. And `spec.instanceSelector` is
**immutable**: changing it requires deleting and recreating the `GrafanaDashboard`.

A ready-to-edit override file for this layout (job labels, Grafana, and wiring the
`ksm-crossplane` inventory exporter for Story 4.1) is in
[docs/values-stakater-cloud-example.yaml](docs/values-stakater-cloud-example.yaml).

### Inventory rules on OpenShift UWM (Story 4.1) — important

OpenShift **user-workload monitoring enforces namespace scoping**: it injects
`namespace="<the PrometheusRule's namespace>"` into every user-workload rule expression. The
control-plane and managed-resource rules are fine — those metrics originate from the
Crossplane-namespace scrape, so the enforced label matches. **The inventory/composite rules
are not:** the exporter emits one series per XR carrying the *tenant* namespace
(`ws-*`, `hypershift-*`, …), so a rule deployed in `crossplane-system` matches nothing and
`CompositeNotReady`/`CompositeNotSynced` fire **0 — silently**. **0 firing ≠ all healthy.**

What works and what doesn't under UWM:

- ✅ **Dashboard composite panels** — Grafana queries thanos-querier directly (not
  namespace-enforced), so they see all tenant namespaces.
- ❌ **Composite recording rule + alerts** as a user-workload PrometheusRule in the Crossplane
  namespace — namespace-enforced to nothing.

### Two alerting paths — and why

Because of the constraint above, this chart uses **two alerting mechanisms on purpose**:

- **Prometheus `PrometheusRule`s (UWM)** for everything whose metric originates in the
  Crossplane namespace — control plane, providers, managed resources, footprint. These fit
  UWM's per-namespace model and are Prometheus-native (with recording rules + unit tests).
- **Grafana-managed alerts** for the **cross-tenant composite/inventory** signals (Story 4.1),
  whose series carry tenant namespaces. Grafana queries `thanos-querier` (not
  namespace-enforced), so it's the only *supported* way to alert across tenants — the OpenShift
  **platform** stack is not an option (Red Hat reserves it and resets user objects).

**This does not break your pipeline:** Grafana-managed alerts **forward to your existing
Prometheus Alertmanager** (via an Alertmanager contact point, or Alertmanager-as-data-source
with forwarding). Same Alertmanager, same routing, same Slack/PagerDuty receivers and silences
— only the *evaluation engine* differs (Grafana instead of thanos-ruler).

The full rationale is in **[docs/alerting-architecture.md](docs/alerting-architecture.md)**.
The recording-rule/alert expressions themselves are correct (proven in `tests/unit/`); the MR
and control-plane stories are unaffected.

### 3. Verify your build before enabling Phase 2 (roadmap Decision 2)

`curl` the core pod `/metrics` and grep:

- `function_run_` → Stories 5.1 / 5.2 available now vs strictly post-upgrade
- `circuit_breaker_` → Story 4.2 available now vs post-upgrade
- `crossplane_managed_resource_` on each provider pod → confirms 1.1–1.3, 3.1 are live

## Deploying — who does what

### When the deploy agent runs (automatable)

1. Render + offline-validate the branch: `./tests/validate.sh` must print `ALL VALIDATION PASSED`.
2. Install with the cluster's values (start from
   [docs/values-stakater-cloud-example.yaml](docs/values-stakater-cloud-example.yaml)):
   set `crossplane.core.job` / `crossplane.providers.job`, `grafana.namespace` /
   `instanceSelector` (with `--set grafana.instanceSelector.app=null` to defeat Helm
   deep-merge), and the inventory block if used.
3. Pick the **composite alerting path** (Story 4.1) — they're mutually exclusive, don't enable both:
   - **OpenShift UWM (the usual case):** `grafana.compositeAlerts.enabled=true` +
     `grafana.compositeAlerts.datasourceUid=<thanos datasource UID>`, and **leave the
     PrometheusRule composite alerts off** (`prometheus.rules.fleet.compositeNotReady.enabled=false`,
     `…compositeNotSynced.enabled=false`).
   - **Non-UWM / per-tenant-namespace:** the reverse — PrometheusRule composite alerts on,
     `grafana.compositeAlerts.enabled=false`.
4. Run the deploy-validation brief
   ([tests/DEPLOY-VALIDATION.md](tests/DEPLOY-VALIDATION.md)) and return the report. Confirm the
   things we changed: MRNotReady count is small (not hundreds), the composite panel populates,
   and composite alerts fire only for genuinely-degraded XRs.

### What the SRE must do for production (one-time, human)

These need cluster/Grafana context an agent can't safely guess:

1. **Enable UWM** (`enableUserWorkload: true`) and confirm Crossplane core + providers are
   scraped (the chart's own monitors stay disabled if the cluster already scrapes them).
2. **Find the datasource UID** of the Prometheus/Thanos datasource in *your* Grafana that can
   read across namespaces (Grafana → Connections → Data sources → the thanos-querier /
   cluster-monitoring one → the `uid` in its URL/JSON). Put it in
   `grafana.compositeAlerts.datasourceUid`. Without it the chart refuses to render the alerts.
3. **Wire Grafana → Alertmanager** so the composite alerts reach your existing on-call:
   add an **Alertmanager contact point** (or Alertmanager data source + forwarding) in Grafana
   pointing at your Prometheus Alertmanager, and route the `rulesgroup=crossplane` alerts to it.
   See [docs/alerting-architecture.md](docs/alerting-architecture.md). *(Until this is done the
   alerts evaluate in Grafana but won't notify anywhere.)*
4. **Confirm the inventory exporter** (`crossplane.inventory.{conditionMetricPattern,job}`) by
   scraping it (`tests/fetch-cluster-metrics.sh`) before trusting Story 4.1.
5. **Calibrate thresholds** over 2–4 weeks of baseline before treating any SLA number as real.

## Configuration

| Key | Default | Description |
| --- | --- | --- |
| `global.namespace` | release ns | Namespace the monitoring objects are created in (must be where Crossplane runs). |
| `crossplane.core.name` | `crossplane` | Crossplane core release/fullname (core ServiceMonitor selector). |
| `crossplane.core.job` | `crossplane` | `job` label core metrics land under (used in alert/recording expressions). |
| `crossplane.providers.selector` | `pkg.crossplane.io/revision: Exists` | Label selector matching provider pods (PodMonitor). |
| `crossplane.providers.job` | `crossplane-providers` | `job` label provider metrics land under. |
| `crossplane.inventory.enabled` | `false` | Enable Claim/inventory rules (needs an exporter — see [example](docs/resource-state-metrics-example.yaml)). |
| `crossplane.inventory.conditionMetricPattern` | `kube_customresource_crossplane_xr_.+_condition` | Regex (PromQL `__name__=~`) matching the exporter's one-hot condition metrics across **all** XR kinds (Story 4.1). |
| `upjet.enabled` | `false` | Upjet providers present — enables Story 6.1 and the more-accurate Upjet TTR (Story 1.2). |
| `grafana.folder` | `Crossplane Observability` | Grafana folder for the dashboard. |
| `grafana.dashboard.enabled` | `true` | Create the GrafanaDashboard. |
| `grafana.compositeAlerts.enabled` | `false` | Story 4.1 composite alerts as **Grafana-managed** rules (use on UWM instead of the PrometheusRule composite alerts). |
| `grafana.compositeAlerts.datasourceUid` | `""` | **Required when enabled** — UID of the cross-namespace Prometheus/Thanos datasource in Grafana. |
| `grafana.namespace` | release ns | Namespace to create the GrafanaDashboard in. |
| `prometheus.monitors.coreServiceMonitor.enabled` | `false` | Scrape Crossplane core. |
| `prometheus.monitors.providerPodMonitor.enabled` | `false` | Scrape provider pods. |
| `prometheus.recordingRules.enabled` | `true` | Emit the SLO recording rules. |
| `prometheus.rules.labels` | `{}` | Extra labels added to every `PrometheusRule`. |
| `prometheus.rules.<area>.<alert>.enabled` | varies | Toggle an individual alert (Phase 1 on, Phase 2 / 4.1 off). |
| `prometheus.rules.<area>.<alert>.{for,severity,threshold…}` | varies | Per-alert tuning — see `values.yaml`. |

## Alerts

One alert per file, grouped by roadmap capability area under
`templates/prometheus/rules/<area>/`. **SLA** marks the few stories that back a customer
promise; the rest are internal SLIs/SLOs that exist to protect them.

| Story | Alert | Area / file | Condition | SLA? | Phase |
| --- | --- | --- | --- | --- | --- |
| 1.1 | `MRNotReady` | resource-health | `crossplane_managed_resource_ready == 0` (15m) | ✅ | 1 |
| 1.1 | `MRNotReadyCritical` | resource-health | same, sustained (1h) | ✅ | 1 |
| 1.2 | `TTRDegraded` | resource-health | p95 time-to-readiness > SLO (Upjet TTR when `upjet.enabled`) | ✅ | 1 |
| 1.3 | `ClaimTreeNotReady` | resource-health | `crossplane:claim_tree_ttr_seconds:p95` > SLO | ✅ **headline** | 1 |
| 2.1 | `ReconcileErrorRateHigh` | control-plane | `crossplane:reconcile_errors:ratio` > 1% | ❌ | 1 |
| 2.2 | `ReconcileLatencyHigh` | control-plane | `crossplane:reconcile_time_seconds:p99` > SLO | ❌ | 1 |
| 2.3 | `WorkqueueDepthGrowing` | control-plane | `workqueue_depth` sustained over threshold | ❌ | 1 |
| 2.4 | `APIServiceUnavailable` | control-plane | `aggregator_unavailable_apiservice{name=~".*crossplane.*"} == 1` | ✅ | 1 |
| 2.5 | `DetectionLagHigh` | control-plane | p95 create→first-reconcile > SLO | ❌ | 1 |
| 3.1 | `DriftDetected` | drift | `crossplane_managed_resource_drift_seconds` > threshold | ❌ | 1 |
| 4.1 | `CompositeNotReady` | fleet | XR condition `{type=Ready,status=True} == 0` *(needs inventory exporter)* | →1.1 | needs exporter |
| 4.1 | `CompositeNotSynced` | fleet | XR condition `{type=Synced,status=True} == 0` *(needs inventory exporter)* | →1.1 | needs exporter |
| 4.2 | `CircuitBreakerDropRatioHigh` | fleet | > 20% events dropped (5m) | ✅ (indirect) | 2 |
| 4.2 | `CircuitBreakerFrequentOpens` | fleet | > 6 opens/hr (15m) | ✅ (indirect) | 2 |
| 5.1 | `FunctionLatencyHigh` | functions | function p95 exec > SLO | ❌ | 2 |
| 5.1 | `FunctionErrorRate` | functions | function error ratio > 0.5% | ❌ | 2 |
| 5.2 | `FunctionCacheErrorRate` | functions | cache hit ratio < 90% | ❌ | 2 |
| 6.1 | `CloudAPIThrottling` | cloud | reconcile delay > poll interval *(Upjet only)* | ❌ never | 1 (Upjet) |
| 7.1 | `ProviderPodRestarting` | footprint | restarts over window > threshold | →2.4 | 1 |
| 7.1 | `ProviderPodOOM` | footprint | `last_terminated_reason == OOMKilled` | →2.4 | 1 |
| 7.2 | `ProviderPodCPUThrottled` | footprint | CFS throttled fraction > 1% | ❌ | 1 |

### Recording rules (SLOs)

Emitted as one `PrometheusRule` (`role: recording-rules`) when
`prometheus.recordingRules.enabled`:

| Record | SLI |
| --- | --- |
| `crossplane:managed_resource_ready:ratio` | Story 1.1 — MR ready ratio per namespace+kind |
| `crossplane:managed_resource_ready:ratio:fleet` | Story 1.1 — fleet-wide ready ratio |
| `crossplane:managed_resource_ttr_seconds:p95` | Story 1.2 — p95 time-to-readiness per kind |
| `crossplane:claim_tree_ttr_seconds:p95` | Story 1.3 — headline composite (add claim layer once 4.1 lands) |
| `crossplane:reconcile_errors:ratio` | Story 2.1 — reconcile error ratio per controller |
| `crossplane:reconcile_time_seconds:p99` | Story 2.2 — p99 reconcile duration per controller |

## Dashboard

Enabled with `grafana.dashboard.enabled=true`. One row per capability area, with
`$datasource`, `$namespace`, and `$kind` template variables. Phase 2 and Upjet rows are
**collapsed by default** and render empty until their metrics exist — they "light up" the
moment you upgrade / enable Upjet, with no dashboard rework.

| Row | Stories | Key panels |
| --- | --- | --- |
| Overview / SLO | 1.1, 1.3, 2.4 | Fleet ready ratio · Claim-tree p95 TTR · API up · MRs not ready |
| Resource Health | 1.1, 1.2 | Not-ready/not-synced table · TTR p50/p95/p99 |
| Control Plane | 2.1–2.5 | Reconcile rate+errors · latency · workqueue · detection lag |
| Correctness & Drift | 3.1 | Time-out-of-sync by kind |
| Fleet & Multi-tenancy | 4.1, 4.2 | Ready ratio by GVK · **Composite (XR) ready ratio by kind** *(raw cross-namespace query, works on UWM)* · circuit-breaker drop/opens *(4.2 = Phase 2)* |
| Composition / Functions *(Phase 2)* | 5.1, 5.2 | Function p95 · error ratio · cache hit ratio |
| Cloud Interaction *(Upjet only)* | 6.1 | Reconcile delay vs poll interval |
| Resource Footprint | 7.1, 7.2 | Provider restarts · memory · CPU-throttled % |

The dashboard JSON lives in [files/crossplane_grafana_dashboard.json](files/crossplane_grafana_dashboard.json)
and is inlined via `.Files.Get` (so Grafana `$variables` need no Helm escaping).

For a panel-by-panel rationale — what each panel shows, why an SRE cares, and **what you'd be
blind to without it** — see [docs/dashboard-panels.md](docs/dashboard-panels.md).

## Metric verification status

Every metric the rules reference has a **provenance** — it is either captured from a real
Crossplane or documented in the upstream metrics reference. The harness (`tests/`) enforces
this; nothing is assumed. Against the pinned capture (**Crossplane 2.3.1 +
provider-kubernetes v1.2.1**):

- ✅ **Captured in real fixtures** (we scraped them): `controller_runtime_*` (2.1, 2.2),
  `workqueue_*` (2.3), and the `crossplane_managed_resource_*` family —
  `exists` / `ready` / `synced` (Story 1.1) and `first_time_to_{readiness,reconcile}_seconds_*`
  (1.2, 1.3, 2.5).
- 📖 **Documented upstream, not emitted by the pinned rig** — listed with citations in
  [tests/metrics-allowlist.documented.txt](tests/metrics-allowlist.documented.txt):
  - `crossplane_managed_resource_drift_seconds` (3.1) — needs an actual drift to occur.
  - `function_run_*`, `circuit_breaker_*` (5.x, 4.2) — core metrics that register only when a
    composition Function / realtime composition runs.
  - `upjet_resource_*` (1.2 Upjet path, 6.1) — need an Upjet provider.
  - `aggregator_unavailable_apiservice`, `container_*`, `kube_pod_container_*` — standard
    apiserver / cAdvisor / kube-state-metrics metrics (present on a real UWM cluster).
  - The Story 4.1 inventory metric (`kube_customresource_crossplane_xr_xproject_condition`)
    is now **captured** from a real `ksm-crossplane` exporter (in fixtures), not documented —
    it's a one-hot composite/XR condition metric. The rules ship disabled until you point
    `crossplane.inventory.*` at your exporter; see
    [docs/resource-state-metrics-example.yaml](docs/resource-state-metrics-example.yaml).

These names are confirmed against the [Crossplane metrics reference](https://docs.crossplane.io/latest/guides/metrics/).
One name that was genuinely invented (`upjet_resource_poll_interval_seconds`) was found and
removed, and `CloudAPIThrottling` rewritten to use a configurable threshold. See
[tests/README.md](tests/README.md) for how to graduate a documented metric to captured.

Also tune to your environment: the **`job` labels** (`crossplane.core.job` /
`crossplane.providers.job`) must match what your ServiceMonitor/PodMonitor produces, and the
**pod-name regexes** (`pod=~"provider.*"`) / provider **pod selector** assume default provider
naming.

## Local Testing

Full validation — lint, render, `promtool check`/`test`, the metric-reality gate against
real captured fixtures, and dashboard checks — runs offline with one command:

```bash
./tests/validate.sh
```

See [tests/README.md](tests/README.md) for the strategy (and how metric names are verified
against a pinned, ephemeral Crossplane rather than assumed). Manual rendering:

```bash
# Phase 1 (defaults):
helm template . -f values.yaml
# Everything, to render Phase 2 + Upjet + exporter rules:
helm template . \
  --set prometheus.monitors.coreServiceMonitor.enabled=true \
  --set prometheus.monitors.providerPodMonitor.enabled=true \
  --set upjet.enabled=true \
  --set prometheus.rules.functions.functionLatencyHigh.enabled=true
# Install against a cluster:
helm install crossplane-observability . -n <crossplane-namespace>
helm delete  crossplane-observability  -n <crossplane-namespace>
```

See [docs/roadmap.md](docs/roadmap.md) for the full story-by-story rationale, SLI/SLO/SLA
definitions, and open decisions (exporter choice for Story 4.1, build verification).
