# Fixture provenance

Two captures, two layouts. Both are real `/metrics` scrapes; the allowlist is their union
(`../generate-allowlist.sh`).

| Set | Where | What it proves |
| --- | --- | --- |
| `./*-metrics.txt` | kind lab, **2026-11-01** (`../e2e/up.sh` + `capture.sh`) | the **upstream** layout: helm-chart MetalLB 0.15.3, FRR-K8s mode, BGP **and** L2, **BFD on** — the only capture of the lazy L2/BFD families |
| `./operator/*-metrics.txt` | a production **OpenShift** cluster running the **MetalLB operator**, **2026-11-06**, read-only (`../METRICS-CAPTURE.md`) | the **operator** layout the chart defaults to: pod labels, kube-rbac-proxy ports, operator-created ServiceMonitors, platform-Prometheus job labels |

The operator fixtures are **scrubbed** (this repo is public): node names → `node-{a,b,c}`,
service IPs → `203.0.113.0/24`, the BGP peer → `192.0.2.1`, tenant Services →
`tenant-N/lb-N`, the pool → `public-bgp`. Metric names, label **keys** and label shapes are
verbatim.

---

## Capture 2 — OpenShift MetalLB operator (2026-11-06)

### Build captured

| What | Value |
| --- | --- |
| OpenShift | 4.22.13 (bare metal, 3 schedulable nodes = 3 speakers) |
| MetalLB operator | CSV `metallb-operator.v4.22.0`, namespace `metallb-operator`; controller + speaker image `registry.redhat.io/openshift4/metallb-rhel9` |
| Backend mode | **FRR-K8s** — `frr-k8s` DaemonSet in its **own namespace `openshift-frr-k8s`**, owned by the cluster `Network` operator (not by the MetalLB CR) |
| rbac proxy | `ose-kube-rbac-proxy-rhel9` in front of **every** metrics port (controller, speaker, both frr-k8s sidecars) |
| Peering | one `BGPPeer` (AS 65001, no BFD profile), one `BGPAdvertisement`, two `IPAddressPool`s (a public BGP pool of 14 IPs and a private /24); **no `L2Advertisement`, no `BFDProfile`** |
| Exercised | 20 `LoadBalancer` Services live, 13/14 public-pool IPs allocated, all BGP sessions Established |

### Files and what exports what

| Fixture | Pod / port | Families |
| --- | --- | --- |
| `operator/controller-metrics.txt` | controller `:29150` (`monitoring`, plain HTTP, pod network) | identical family set to upstream: `metallb_allocator_{,ipv4_,ipv6_}addresses{,_in_use}_total{pool}`, `metallb_k8s_client_*` |
| `operator/speaker-metrics.txt` | union of all 3 speakers `:29150` (`monitoring`, plain HTTP, hostNetwork) | `metallb_k8s_client_*`, `metallb_speaker_announced{ip,node,protocol="bgp",service="<ns>/<name>"}` on **every** speaker (BGP: all nodes announce every IP); **no `metallb_layer2_*`** (no L2 advertisement configured — [absent], not a version difference) |
| `operator/frr-k8s-controller-metrics.txt` | frr-k8s `:7572` (127.0.0.1-bound, hostNetwork) | `frrk8s_k8s_client_*` |
| `operator/frr-k8s-frr-metrics.txt` | frr-k8s `:7573` (127.0.0.1-bound, hostNetwork) | `frrk8s_bgp_*{peer="<IP>",vrf="default"}` — same label shape as upstream (no port in `peer`); **no `frrk8s_bfd_*`** (no BFD profile — [absent]) |

The kube-rbac-proxy ports (`9120` controller/speaker, `9140`/`9141` frr-k8s) were scraped
too, with a bearer token over TLS; they return byte-identical bodies to the raw ports, so
only the raw captures are committed.

### Scrape-surface facts (what changed the chart's defaults)

1. **The operator already scrapes everything.** Both namespaces carry
   `openshift.io/cluster-monitoring: "true"`, and the operator ships headless metrics
   Services + `ServiceMonitor`s: `controller-monitor` / `speaker-monitor` (owned by the
   `MetalLB` CR) and `frr-k8s-monitor` (owned by `Network/cluster`, **two** endpoints:
   `metricshttps` 9140 + `frrmetricshttps` 9141). All are HTTPS with the Prometheus SA
   token and the service-CA client cert. The **platform** Prometheus
   (`openshift-monitoring/k8s`) scrapes them — not UWM, which explicitly excludes
   `cluster-monitoring` namespaces.
2. **Job labels** are the Service names (the monitors' `jobLabel` points at a label the
   Services don't carry, so Prometheus falls back to the Service name):
   `controller-monitor-service`, `speaker-monitor-service`, `frr-k8s-monitor-service`
   (the latter for both frr-k8s endpoints; `container` / `endpoint` tell them apart).
   Every series also carries `container="kube-rbac-proxy[-frr]"`, `endpoint`, `service`.
   → the chart's rules and dashboard default to these jobs; its PodMonitors stay off.
3. **Pod labels** are `app: metallb` + `component: controller|speaker` and
   `app: frr-k8s` + `component: frr-k8s` — not the upstream `app.kubernetes.io/*` pair.
4. **Ports**: controller + speaker expose `monitoring` on **29150** (upstream 7472 — the
   port *name* is the same, so the PodMonitors still match) plus `metricshttps` 9120 on
   the proxy. frr-k8s: raw 7572/7573 bound to 127.0.0.1, proxies **`metricshttps` 9140**
   and **`frrmetricshttps` 9141** — two different port names (upstream names both
   `metricshttps`), hence the PodMonitor's `ports` list.
5. **FRR-K8s lives in another namespace** than MetalLB. A chart PodMonitor needs a
   `namespaceSelector` (only the platform Prometheus honours cross-namespace selection),
   and the dashboard needs a separate `frr_namespace` variable.
6. **kube-state-metrics** `kube_daemonset_status_{desired_number_scheduled,number_ready}`
   for both DaemonSets and `kube_deployment_status_replicas_available` for the controller
   are visible in the same Prometheus — the `[ksm]` assumption in the roadmap holds.
7. The operator ships **no `PrometheusRule`s** and the cluster had **no MetalLB alerts** of
   any kind — the gap this chart fills. At capture time the public pool stood at 13/14
   (92.9%), i.e. `MetalLBAddressPoolNearExhaustion` would have fired (the exact
   pool-full incident class that motivated the chart).

---

## Capture 1 — upstream kind lab (2026-11-01)

### Build captured

| What | Value |
| --- | --- |
| Kubernetes | kind, `kindest/node:v1.33.4`, 1 cp + 2 workers (metallb ≤0.15 CRDs are rejected by k8s ≥1.34 — ASN fields say `format: int32` with a uint32 `maximum`; fixed upstream in 0.16) |
| MetalLB | helm chart **0.15.3** (`quay.io/metallb/{controller,speaker}:v0.15.3`), **FRR-K8s mode** (`frrk8s.enabled=true`) |
| FRR-K8s | `quay.io/metallb/frr-k8s:v0.0.21`, FRR `quay.io/frrouting/frr:10.4.1` |
| rbac proxy | `quay.io/brancz/kube-rbac-proxy:v0.18.2` (lab override — the subchart's pinned `gcr.io/kubebuilder/kube-rbac-proxy:v0.12.0` was deleted from gcr.io) |
| Peering | external FRR 9.1 container, AS 64512 ↔ 64513, dynamic neighbors, **BFD on**, 3 sessions Established |
| Exercised | `bgp-pool` + `l2-pool`, one LoadBalancer Service on each, HTTP traffic through the peer to both IPs |

### Files and what exports what

| Fixture | Pod / port | Families |
| --- | --- | --- |
| `controller-metrics.txt` | controller `:7472` (`monitoring`, plain HTTP, pod network) | `metallb_allocator_addresses{,_in_use}_total{pool}` **plus undocumented `metallb_allocator_ipv{4,6}_*` variants**, `metallb_k8s_client_*` |
| `speaker-metrics.txt` | **union of all 3 speakers** `:7472` (`monitoring`, plain HTTP, hostNetwork — binds the **node IP**, not localhost) | `metallb_k8s_client_*`; **lazily registered, announcer-only**: `metallb_speaker_announced{ip,node,protocol,service}` (protocol `bgp`\|`layer2`), `metallb_layer2_{requests_received,responses_sent,gratuitous_sent}{ip}` |
| `frr-k8s-controller-metrics.txt` | frr-k8s `:7572` (bound to **127.0.0.1**, hostNetwork) | `frrk8s_k8s_client_*` only |
| `frr-k8s-frr-metrics.txt` | frr-k8s `:7573` (bound to **127.0.0.1**, hostNetwork) | `frrk8s_bgp_*`, `frrk8s_bfd_*` — labels `{peer="<IP>",vrf="default"}` (**no port in `peer`**) |

### Scrape-surface facts (upstream layout — the `tests/e2e/values-e2e.yaml` profile)

1. **No metrics Services exist** (only the two webhook Services) and **no operator-created
   ServiceMonitors/PodMonitors** → the chart's **PodMonitors** are the only scrape.
2. Controller + speaker metrics are plain HTTP on container port `monitoring` (7472); a
   PodMonitor scraping the pod IP works for both (the speaker answers on its node IP =
   its hostNetwork pod IP).
3. frr-k8s raw ports 7572/7573 are **localhost-only**; the only scrapeable surface is the
   two **kube-rbac-proxy TLS ports**, **both** named `metricshttps` (9140 controller
   metrics, 9141 frr metrics) — scraping needs bearer-token auth + TLS (self-signed unless
   `prometheus.metricsTLSSecret`), and the Prometheus SA needs the `/metrics` RBAC the
   subchart's `prometheus.rbacPrometheus=true` would create.
4. BGP/BFD series exist **per frr-k8s pod per peer**; `frrk8s_bgp_announced_prefixes_total`
   is 0 on a node that currently announces nothing (per-node value, not cluster total).
5. The lazily-registered speaker families (`metallb_speaker_announced`, `metallb_layer2_*`)
   appear **only on the speaker currently announcing** a service — a single-pod scrape can
   miss them entirely, and `absent()`-style logic on them is unsafe.

Regenerate the allowlist after any re-capture: `../generate-allowlist.sh`.
