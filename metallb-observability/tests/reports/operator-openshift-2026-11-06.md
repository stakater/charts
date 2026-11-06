# metallb-observability — real-cluster comparison, OpenShift MetalLB operator, 2026-11-06

**Scope:** the release-gate handover from `e2e/README.md` — re-run `METRICS-CAPTURE.md`
**read-only** against a production OpenShift cluster running the **MetalLB operator**,
diff the scrape surface against the kind lab, fold the deltas into the chart defaults,
then validate the chart against the cluster without installing anything.

**Target (generic descriptor — this repo is public):** OpenShift **4.22.13**, bare metal,
3 schedulable nodes; MetalLB operator CSV **4.22.0** in `metallb-operator`, **FRR-K8s
mode** with the `frr-k8s` DaemonSet in `openshift-frr-k8s`; one BGP peer, no BFD, no L2;
20 `LoadBalancer` Services. Only `get`/`list`, `port-forward` and Thanos queries were
used; the install check was a `--dry-run=server` (admission only, nothing persisted).

**Verdict: gate cleared.** The operator layout differs from upstream in every way the
handover note predicted (labels, ports, proxies, operator-created monitors) plus one it
did not (FRR-K8s in a separate namespace). All of it is now the chart's default; the
chart renders, admits, and every alert expression and dashboard query returns the
expected result against live data. One alert would fire for real today.

## 1. Scrape-surface diff (kind lab → operator)

| Surface | Upstream (kind, 2026-11-01) | OpenShift operator (2026-11-06) | Folded into |
| --- | --- | --- | --- |
| Who scrapes | nothing — chart PodMonitors required | operator `ServiceMonitor`s (`controller-monitor`, `speaker-monitor`, `frr-k8s-monitor`) in `openshift.io/cluster-monitoring=true` namespaces → **platform** Prometheus | `metallb.operatorManagedMonitors: true`; PodMonitors stay off; `up` alerts render anyway |
| Job labels | chart-pinned `metallb-{controller,speaker,frr-k8s}` | `controller-monitor-service`, `speaker-monitor-service`, `frr-k8s-monitor-service` | `metallb.*.job` defaults; rules, watchdog and dashboard use them |
| Pod labels | `app.kubernetes.io/name` + `/component` | `app: metallb` + `component: controller\|speaker`; `app: frr-k8s` + `component: frr-k8s` | `metallb.*.selector` defaults |
| Controller / speaker port | `monitoring` **7472** plain HTTP | `monitoring` **29150** plain HTTP + kube-rbac-proxy `metricshttps` 9120 | none needed — same port *name* |
| FRR-K8s proxies | 9140 + 9141, **both** named `metricshttps` | `metricshttps` 9140 + **`frrmetricshttps`** 9141 (two containers) | `frrK8sPodMonitor.ports` list |
| FRR-K8s namespace | same as MetalLB | **`openshift-frr-k8s`** (owned by `Network/cluster`, not the MetalLB CR) | `metallb.frrk8s.namespace` → PodMonitor `namespaceSelector`; dashboard `frr_namespace` variable |
| Rule evaluation | kube-prometheus-stack | platform Prometheus (`ruleNamespaceSelector: cluster-monitoring=true`, `ruleSelector: {}`); UWM excludes these namespaces | README: install into the MetalLB namespace |
| kube-state-metrics | not asserted | `kube_daemonset_status_*` for both DaemonSets and `kube_deployment_status_replicas_available` for the controller visible in the same Prometheus | roadmap `[ksm]` tag verified |
| Operator alerts | n/a | **none** — no `PrometheusRule` shipped, no MetalLB alert of any kind on the cluster | the gap this chart fills |

Metric **families and label shapes are identical** on both layouts (allowlist grew only by
controller-runtime/certwatcher housekeeping families from the frr-k8s controller). Two
families are **[absent]** on the operator cluster by configuration, not by version:
`frrk8s_bfd_*` (no `BFDProfile`) and `metallb_layer2_*` (no `L2Advertisement`). The kind
capture remains the proof for those. One behavioural difference: in BGP mode **every**
speaker registers `metallb_speaker_announced` for every IP (11–12 series per speaker);
the lazy announcer-only behaviour is the L2 case.

Captures: `fixtures/operator/` (scrubbed: nodes, IPs, tenant Service names, cluster name).
The kube-rbac-proxy ports were also scraped with a bearer token and returned
byte-identical bodies to the raw ports.

## 2. Chart changes made from the diff

- `values.yaml`: operator defaults (`metallb.operatorManagedMonitors`, selectors, jobs,
  `frrk8s.namespace`, `frrK8sPodMonitor.ports`); `job` moved from the PodMonitor blocks
  to `metallb.<component>.job` (it is the series identity, whoever scrapes).
- `up`-based rules (`controller-down`, `speaker-down`, `frr-k8s-down`, watchdog
  `metrics-absent`): render when the operator scrapes **or** the chart PodMonitor is on.
- `frr-k8s-podmonitor.yaml`: `namespaceSelector` + one endpoint per proxy port name.
- Dashboard: availability tiles substitute `metallb.*.job` at render time; new
  `frr_namespace` variable scopes every `frrk8s_*` panel.
- `tests/e2e/values-e2e.yaml` is now the **upstream profile** (kind lab unchanged);
  unit tests use the operator job names; Tilt namespace `metallb-operator`.
- Docs: `fixtures/README.md` (capture 2 provenance), `METRICS-CAPTURE.md`,
  `docs/roadmap.md` (structural facts, tags, gate), `README.md`, `e2e/README.md`.

## 3. Validation against the cluster (read-only)

### 3a. Offline gate — `tests/validate.sh`

`helm lint` + render (defaults and everything-enabled), `promtool check` (13 rules),
`promtool test` (every alert fires and resolves on synthetic series), allowlist in sync
with both fixture sets, metric-reality gate 23/24 captured + `up` documented, dashboard
JSON + 28 panel queries parse, kubeconform 20/20 objects valid. **All passed.**

### 3b. Server dry-run install — `helm template … -n metallb-operator | oc apply --dry-run=server`

12 `PrometheusRule` + 1 `GrafanaDashboard` (operator defaults render **no** PodMonitors
and no RBAC) — **all 13 admitted** by the live API server and its admission webhooks.
The Grafana instance on the cluster carries `app: grafana` and a datasource named
`prometheus` (thanos-querier), matching the chart's defaults.

### 3c. Every alert expression, evaluated live (`for` ignored)

| Alert | Live result | Expected on a healthy cluster |
| --- | --- | --- |
| `MetalLBAddressPoolExhausted` | 0 series | quiet ✅ |
| `MetalLBAddressPoolNearExhaustion` | **1 series — public BGP pool at 13/14 = 92.9 %** | **fires** ✅ — real signal (the pool-full incident class that motivated the chart; see §4) |
| `MetalLBBGPSessionDown` | 0 (3 sessions, all up) | quiet ✅ |
| `MetalLBBGPSessionFlapping` | 0 | quiet ✅ |
| `MetalLBBFDSessionDown` | 0 (family absent — no BFD) | quiet ✅ |
| `MetalLBConfigNotLoaded` / `MetalLBConfigStale` | 0 / 0 (7 pods loaded, none stale) | quiet ✅ |
| `MetalLBK8sClientErrors` | 0 | quiet ✅ |
| `MetalLBControllerDown` | 0 (`up`=1, absent clause false) | quiet ✅ |
| `MetalLBSpeakerDown` | 0 (3 targets up) | quiet ✅ |
| `MetalLBFRRK8sDown` | 0 (6 targets up: 2 per pod) | quiet ✅ |
| `MetalLBMetricsAbsent{target=speaker\|frr-k8s}` | 0 / 0 | quiet ✅ |

### 3d. Every dashboard query, evaluated live (variables substituted)

Controller 1, Speakers up 3, BGP sessions down 0, BFD down 0, Pools at capacity 0,
Stale-config pods 0; Pool utilization 2 pools (92.9 % / 2.4 %); BGP state 3 node→peer
series, prefixes 12/11/11 announced, 0 received; announcements table 34 rows; config
loaded/stale 7 pods; message/update rates present. BFD and L2 panels empty (families
absent by configuration). **Every panel returns the expected data.**

## 4. Observation for the operators of that cluster (not a chart issue)

At capture time the public BGP pool had **one free IP**. The next `LoadBalancer` Service
against it will sit `<pending>` — exactly the silent failure class behind the incidents
that motivated this chart. Installing the chart would page `warning` immediately.

## 5. Not done / caveats

- No failure scenarios were induced on the shared cluster (per the procedure); the
  fire-and-resolve proof remains the kind e2e (`e2e-kind-2026-11-01.md`).
- The chart was **not installed**; the Grafana import and Alertmanager routing are
  validated by the server dry-run and the existing-dashboard conventions only.
- Alert thresholds are still the roadmap placeholders pending 2–4 weeks of baseline.
