# Fixture provenance

Captured **2026-11-01** from the disposable kind lab in `../e2e/` (`up.sh` + `capture.sh`),
NOT yet from a production cluster — comparing this surface against a real cluster running
the MetalLB **operator** is a committed follow-up (see "Handover" in `../e2e/README.md`).

## Build captured

| What | Value |
| --- | --- |
| Kubernetes | kind, `kindest/node:v1.33.4`, 1 cp + 2 workers (metallb ≤0.15 CRDs are rejected by k8s ≥1.34 — ASN fields say `format: int32` with a uint32 `maximum`; fixed upstream in 0.16) |
| MetalLB | helm chart **0.15.3** (`quay.io/metallb/{controller,speaker}:v0.15.3`), **FRR-K8s mode** (`frrk8s.enabled=true`) |
| FRR-K8s | `quay.io/metallb/frr-k8s:v0.0.21`, FRR `quay.io/frrouting/frr:10.4.1` |
| rbac proxy | `quay.io/brancz/kube-rbac-proxy:v0.18.2` (lab override — the subchart's pinned `gcr.io/kubebuilder/kube-rbac-proxy:v0.12.0` was deleted from gcr.io) |
| Peering | external FRR 9.1 container, AS 64512 ↔ 64513, dynamic neighbors, **BFD on**, 3 sessions Established |
| Exercised | `bgp-pool` + `l2-pool`, one LoadBalancer Service on each, HTTP traffic through the peer to both IPs |

## Files and what exports what

| Fixture | Pod / port | Families |
| --- | --- | --- |
| `controller-metrics.txt` | controller `:7472` (`monitoring`, plain HTTP, pod network) | `metallb_allocator_addresses{,_in_use}_total{pool}` **plus undocumented `metallb_allocator_ipv{4,6}_*` variants**, `metallb_k8s_client_*` |
| `speaker-metrics.txt` | **union of all 3 speakers** `:7472` (`monitoring`, plain HTTP, hostNetwork — binds the **node IP**, not localhost) | `metallb_k8s_client_*`; **lazily registered, announcer-only**: `metallb_speaker_announced{ip,node,protocol,service}` (protocol `bgp`\|`layer2`), `metallb_layer2_{requests_received,responses_sent,gratuitous_sent}{ip}` |
| `frr-k8s-controller-metrics.txt` | frr-k8s `:7572` (bound to **127.0.0.1**, hostNetwork) | `frrk8s_k8s_client_*` only |
| `frr-k8s-frr-metrics.txt` | frr-k8s `:7573` (bound to **127.0.0.1**, hostNetwork) | `frrk8s_bgp_*`, `frrk8s_bfd_*` — labels `{peer="<IP>",vrf="default"}` (**no port in `peer`**) |

## Scrape-surface facts (decide the chart's monitors)

1. **No metrics Services exist** (only the two webhook Services) and **no operator-created
   ServiceMonitors/PodMonitors** → the chart must ship **PodMonitors**.
2. Controller + speaker metrics are plain HTTP on container port `monitoring` (7472); a
   PodMonitor scraping the pod IP works for both (the speaker answers on its node IP =
   its hostNetwork pod IP).
3. frr-k8s raw ports 7572/7573 are **localhost-only**; the only scrapeable surface is the
   two **kube-rbac-proxy TLS ports** `metricshttps` **9140** (controller metrics) and
   **9141** (frr metrics) — scraping needs bearer-token auth + TLS (self-signed unless
   `prometheus.metricsTLSSecret`), and the Prometheus SA needs the `/metrics` RBAC the
   subchart's `prometheus.rbacPrometheus=true` would create.
4. BGP/BFD series exist **per frr-k8s pod per peer**; `frrk8s_bgp_announced_prefixes_total`
   is 0 on a node that currently announces nothing (per-node value, not cluster total).
5. The lazily-registered speaker families (`metallb_speaker_announced`, `metallb_layer2_*`)
   appear **only on the speaker currently announcing** a service — a single-pod scrape can
   miss them entirely, and `absent()`-style logic on them is unsafe.

Regenerate the allowlist after any re-capture: `../generate-allowlist.sh`.
