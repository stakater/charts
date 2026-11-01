# metallb-observability

A Helm chart for **MetalLB** observability, integrated with **OpenShift user-workload
monitoring (UWM)**. Built docs-first: every alert and panel traces to a story in
[`docs/roadmap.md`](docs/roadmap.md), and every metric it references was **captured live**
(MetalLB v0.15.3, **FRR-K8s mode** — provenance in
[`tests/fixtures/README.md`](tests/fixtures/README.md)).

It ships three kinds of resource into the MetalLB namespace:

| Resource | Purpose |
| --- | --- |
| `PodMonitor` (×3) | Controller and speaker on plain-HTTP `monitoring:7472`; FRR-K8s via its kube-rbac-proxy TLS ports (`metricshttps` 9140/9141, bearer token + optional shipped RBAC). No metrics Services exist in MetalLB installs, hence PodMonitors. |
| `PrometheusRule` (×12) | Alerts on address-pool capacity, BGP/BFD session health, configuration health, component availability, and a blindness watchdog. One rule per file under `templates/prometheus/rules/`. |
| `GrafanaDashboard` | Pools, sessions, announcements, L2 activity and config health, applied via grafana-operator. Gated on `grafana.dashboard.enabled`. |

## Prerequisites

### 1. OpenShift user-workload monitoring enabled

```yaml
# openshift-monitoring/cluster-monitoring-config configmap
data:
  config.yaml: |
    enableUserWorkload: true
```

UWM evaluates these `PrometheusRule`s in `thanos-ruler-user-workload`.

### 2. MetalLB in FRR-K8s mode

The BGP/BFD alerts target the **`frrk8s_*` metric family**, which FRR-K8s mode exports
(the upstream default and what recent OpenShift MetalLB operators deploy). On a
native-BGP-mode install the `metallb_bgp_*` family exists instead and the session alerts
stay silent — check the mode before relying on them.

### 3. Install into the MetalLB namespace

The monitors select MetalLB's pods by label, so the chart must land in MetalLB's
namespace (`metallb-system` on operator installs): `global.namespace` or the release
namespace. Pod label selectors default to the upstream chart's labels
(`app.kubernetes.io/name` + `app.kubernetes.io/component`); verify them on an operator
install and override `metallb.*.selector` if they differ.

### 4. FRR-K8s metrics auth

FRR-K8s binds its raw metrics to localhost; the chart scrapes the kube-rbac-proxy TLS
ports and authenticates with a token whose ServiceAccount must be allowed
`get /metrics`. The chart ships that ServiceAccount + token Secret + ClusterRole/Binding
(`frrK8sPodMonitor.metricsReader.create: true`); disable it if the scraping Prometheus
is already authorized.

## Configuration

| Key | Default | Description |
| --- | --- | --- |
| `metallb.controller.selector` | upstream labels | Pod labels of the controller Deployment. |
| `metallb.speaker.selector` | upstream labels | Pod labels of the speaker DaemonSet. |
| `metallb.frrk8s.selector` | upstream labels | Pod labels of the FRR-K8s DaemonSet. |
| `prometheus.monitors.controllerPodMonitor.enabled` | `false` | Scrape the controller. |
| `prometheus.monitors.speakerPodMonitor.enabled` | `false` | Scrape every speaker. |
| `prometheus.monitors.frrK8sPodMonitor.enabled` | `false` | Scrape FRR-K8s (BGP/BFD source). |
| `prometheus.monitors.<m>.job` | `metallb-*` | Pinned job label; rules and dashboard reference it — change together. |
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
| `MetalLBControllerDown` | critical | controller scrape failing **or absent** (needs its monitor) |
| `MetalLBSpeakerDown` | warning | a speaker target failing its scrape (needs its monitor) |
| `MetalLBFRRK8sDown` | warning | an FRR-K8s metrics endpoint failing (BGP/BFD alerts blind) |
| `MetalLBMetricsAbsent` | warning | watchdog: speaker / frr-k8s series vanished entirely |

The `up`-based alerts render only while their PodMonitor is enabled — without the scrape
there is nothing to alert on.

## Dashboard

Enabled with `grafana.dashboard.enabled=true`. Defaults to the `prometheus` data source;
a `namespace` variable scopes every query.

| Panel | Query basis | Value / purpose |
| --- | --- | --- |
| **Controller / Speakers up** | `up{job="metallb-*"}` | Scrape-health tiles; pairs with the Down alerts. |
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
# Tilt against a cluster (deploys into metallb-system):
tilt up
tilt down -f Tiltfile-delete
```

> **Before release:** re-run the capture read-only against a cluster running the MetalLB
> **operator** and diff the scrape surface (pod labels, rbac-proxy ports, operator-created
> monitors) against `tests/fixtures/README.md` — then adjust `metallb.*.selector` /
> monitor defaults if the operator's layout differs. See `tests/e2e/README.md`.
