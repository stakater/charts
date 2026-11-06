# metallb-observability

A Helm chart for **MetalLB** observability on **OpenShift**, built for the **MetalLB
operator** layout and usable with upstream MetalLB. Built docs-first: every alert and
panel traces to a story in [`docs/roadmap.md`](docs/roadmap.md), and every metric it
references was **captured live** — from the OpenShift MetalLB operator (4.22, FRR-K8s
mode) and from upstream v0.15.3 — provenance in
[`tests/fixtures/README.md`](tests/fixtures/README.md).

It ships three kinds of resource:

| Resource | Purpose |
| --- | --- |
| `PrometheusRule` (×12) | Alerts on address-pool capacity, BGP/BFD session health, configuration health, component availability, and a blindness watchdog. One rule per file under `templates/prometheus/rules/`. |
| `GrafanaDashboard` | Pools, sessions, announcements, L2 activity and config health, applied via grafana-operator. Gated on `grafana.dashboard.enabled`. |
| `PodMonitor` (×3, **off by default**) | For **upstream** MetalLB only, where nothing else scrapes it: controller and speaker on the plain-HTTP `monitoring` port; FRR-K8s via its kube-rbac-proxy TLS ports (bearer token + optional shipped RBAC). The OpenShift operator ships its own `ServiceMonitor`s — leave these off there. |

## Prerequisites

### 1. Something scrapes MetalLB

**OpenShift MetalLB operator (default):** nothing to do. The operator creates
`ServiceMonitor`s for the controller, the speakers and FRR-K8s in namespaces labelled
`openshift.io/cluster-monitoring=true`, and the **platform** Prometheus scrapes them
under the jobs `controller-monitor-service`, `speaker-monitor-service` and
`frr-k8s-monitor-service`. The chart's rules and dashboard target those jobs
(`metallb.*.job`) and its `up`-based alerts render because
`metallb.operatorManagedMonitors: true`.

**Upstream MetalLB (helm chart):** set `metallb.operatorManagedMonitors: false`, the
upstream pod selectors and your own job names, and enable the three PodMonitors — see
`tests/e2e/values-e2e.yaml`, the upstream profile.

### 2. MetalLB in FRR-K8s mode

The BGP/BFD alerts target the **`frrk8s_*` metric family**, which FRR-K8s mode exports
(the upstream default and what the OpenShift MetalLB operator deploys — on OpenShift the
`frr-k8s` DaemonSet runs in its own `openshift-frr-k8s` namespace, `metallb.frrk8s.namespace`).
On a native-BGP-mode install the `metallb_bgp_*` family exists instead and the session
alerts stay silent — check the mode before relying on them.

### 3. Install into the MetalLB namespace

Install into MetalLB's namespace (`metallb-operator` on OpenShift operator installs):
`global.namespace` or the release namespace. On the operator that namespace carries
`openshift.io/cluster-monitoring=true`, so the **platform** Prometheus evaluates the
`PrometheusRule`s (it has every MetalLB series; UWM explicitly excludes such
namespaces). The Grafana dashboard goes wherever `grafana.namespace` points (defaults to
the same namespace; `allowCrossNamespaceImport` is on).

### 4. FRR-K8s metrics auth (chart PodMonitor only)

FRR-K8s binds its raw metrics to localhost; the chart's PodMonitor scrapes the
kube-rbac-proxy TLS ports and authenticates with a token whose ServiceAccount must be
allowed `get /metrics`. The chart ships that ServiceAccount + token Secret +
ClusterRole/Binding (`frrK8sPodMonitor.metricsReader.create: true`); disable it if the
scraping Prometheus is already authorized. Not needed when the operator scrapes.

## Configuration

| Key | Default | Description |
| --- | --- | --- |
| `metallb.operatorManagedMonitors` | `true` | The operator's ServiceMonitors already scrape MetalLB: render the `up`-based alerts without the chart's PodMonitors. Set `false` for upstream MetalLB. |
| `metallb.controller.selector` / `.speaker.selector` / `.frrk8s.selector` | operator labels (`app` + `component`) | Pod labels the chart PodMonitors select. Upstream uses `app.kubernetes.io/name` + `app.kubernetes.io/component`. |
| `metallb.controller.job` / `.speaker.job` / `.frrk8s.job` | `*-monitor-service` (operator) | The `job` label of each component's series; rules and dashboard reference it, and the chart PodMonitors pin it. |
| `metallb.frrk8s.namespace` | `openshift-frr-k8s` | Namespace of the FRR-K8s DaemonSet (empty = the chart's namespace, as upstream). |
| `prometheus.monitors.controllerPodMonitor.enabled` | `false` | Scrape the controller (upstream only). |
| `prometheus.monitors.speakerPodMonitor.enabled` | `false` | Scrape every speaker (upstream only). |
| `prometheus.monitors.frrK8sPodMonitor.enabled` | `false` | Scrape FRR-K8s (upstream only). |
| `prometheus.monitors.frrK8sPodMonitor.ports` | `[metricshttps, frrmetricshttps]` | kube-rbac-proxy port names to scrape (operator names; upstream names both `metricshttps`). |
| `prometheus.monitors.frrK8sPodMonitor.metricsReader.create` | `true` | Ship the token + RBAC the TLS scrape needs. |
| `prometheus.rules.labels` | `{}` | Extra labels on every `PrometheusRule` (Alertmanager routing / `ruleSelector`). |
| `prometheus.rules.metallb.<alert>.*` | see `values.yaml` | Per-alert `enabled` / `for` / `severity` / thresholds. |
| `grafana.dashboard.enabled` | `true` | Create the `GrafanaDashboard` CR. |

### Alerts

| Alert | Severity | Condition |
| --- | --- | --- |
| `MetalLBAddressPoolExhausted` | critical | a pool's in-use ≥ total (new Services hang `<pending>`) |
| `MetalLBAddressPoolNearExhaustion` | warning | pool utilization > 90% (default) |
| `MetalLBBGPSessionDown` | critical | `frrk8s_bgp_session_up == 0` |
| `MetalLBBGPSessionFlapping` | warning | > 3 session state changes in 30m (defaults) |
| `MetalLBBFDSessionDown` | warning | `frrk8s_bfd_session_up == 0` (silent without BFD) |
| `MetalLBConfigNotLoaded` | critical | a pod has never loaded a config |
| `MetalLBConfigStale` | warning | the latest config failed; an old one is live |
| `MetalLBK8sClientErrors` | warning | config update errors in the last 10m |
| `MetalLBControllerDown` | critical | controller scrape failing **or absent** |
| `MetalLBSpeakerDown` | warning | a speaker target failing its scrape |
| `MetalLBFRRK8sDown` | warning | an FRR-K8s metrics endpoint failing (BGP/BFD alerts blind) |
| `MetalLBMetricsAbsent` | warning | watchdog: speaker / frr-k8s series vanished entirely |

The `up`-based alerts render while something scrapes the component: the operator's
monitors (`metallb.operatorManagedMonitors: true`) or the matching chart PodMonitor.
Without a scrape there is nothing to alert on.

## Dashboard

Enabled with `grafana.dashboard.enabled=true`. Defaults to the `prometheus` data source;
a `namespace` variable (MetalLB) and a `frr_namespace` variable (FRR-K8s, a separate
namespace on OpenShift) scope every query. The availability tiles use `metallb.*.job`.

| Panel | Query basis | Value / purpose |
| --- | --- | --- |
| **Controller / Speakers up** | `up{job=<metallb.*.job>}` | Scrape-health tiles; pairs with the Down alerts. |
| **BGP / BFD sessions down** | `frrk8s_{bgp,bfd}_session_up == 0` | Top-of-glass reachability state. |
| **Pools at capacity / Stale-config pods** | allocator + `config_stale_bool` | The two silent failure modes, visible. |
| **Pool utilization** | `in_use / total` per pool | Bar gauge with the 80/90% thresholds the alerts use. |
| **Addresses in use vs pool size** | allocator series | Trend toward exhaustion, per pool. |
| **BGP session state** | `frrk8s_bgp_session_up` | Per node → peer state over time. |
| **Prefixes per session** | announced/received totals | What each session actually advertises. |
| **BGP message rates** | updates/opens/notifications | Flap signature (pairs with the flapping alert). |
| **BFD state / events** | `frrk8s_bfd_*` | Fast-failover health and churn. |
| **Current announcements** | `metallb_speaker_announced` | Table: service → IP → announcing node → protocol. First incident question answered. |
| **L2 ARP/NDP activity** | `metallb_layer2_*` | Request/response/gratuitous rates per L2 IP. |
| **Config updates vs errors / loaded–stale** | `*_k8s_client_*` | Reconcile health per pod. |

## Testing

```bash
./tests/validate.sh      # offline gate: lint, render, promtool check+test (every alert
                         # fires & resolves on synthetic series), metric-reality gate
                         # against captured fixtures, dashboard JSON/PromQL, kubeconform
./tests/e2e/up.sh        # kind + FRR peer (BGP+BFD) + MetalLB (FRR-K8s) + sample services
./tests/e2e/capture.sh   # re-capture /metrics fixtures from the lab
./tests/e2e/down.sh      # teardown
```

```bash
# Tilt against a cluster (deploys into metallb-operator):
tilt up
tilt down -f Tiltfile-delete
```

Validation history lives in `tests/reports/`: the kind alert e2e (every alert fired and
resolved) and the read-only comparison against an OpenShift cluster running the MetalLB
operator (scrape surface diffed, every alert and panel query evaluated live, server
dry-run install).
