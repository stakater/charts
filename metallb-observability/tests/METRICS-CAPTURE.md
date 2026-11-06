# Capturing live MetalLB metrics → `tests/fixtures/`

The roadmap (`../docs/roadmap.md`) may only be revised and approved against a **live
capture** from a cluster running MetalLB. This documents the procedure and the provenance
to record. Everything is **read-only**.

## Status

**Captured twice** (provenance in `fixtures/README.md`): 2026-11-01 from the kind lab
(`e2e/up.sh` + `e2e/capture.sh`, upstream layout) and **2026-11-06 read-only from a
production OpenShift cluster running the MetalLB operator** (`fixtures/operator/`,
report `reports/operator-openshift-2026-11-06.md`). The operator layout is the chart's
default; the deltas are folded into `values.yaml`.

On the operator the raw ports are `29150` (controller/speaker) and `7572`/`7573`
(frr-k8s, 127.0.0.1-bound but reachable by `port-forward` because the pods are
hostNetwork); every port is also fronted by a kube-rbac-proxy (`9120`, `9140`, `9141`)
that accepts any token allowed `get /metrics`. Scrub the captures before committing —
this repo is public (node names, service IPs, tenant Service names, cluster name in the
ingress Service).

## What to find out first (shapes the whole chart)

Record the answers in `fixtures/README.md`:

1. **Backend mode** — native BGP speaker, deprecated FRR sidecar, or FRR-K8s?
   (`kubectl -n <metallb-ns> get pods -o name`: an `frr-k8s-*` DaemonSet means FRR-K8s;
   an `frr` container inside the speaker pod means the deprecated sidecar.)
   This decides the metric family: `metallb_bgp_*` vs `frrk8s_*`.
2. **MetalLB / operator version** — operator CSV or image tags.
3. **Scrape surface** — which containers/ports serve `/metrics`
   (`kubectl -n <ns> get pods -o jsonpath` over container ports; upstream default is
   `7472` named `monitoring`); whether a kube-rbac-proxy sidecar fronts them (TLS +
   bearer token); whether the operator already created ServiceMonitors/PodMonitors
   (`kubectl -n <ns> get servicemonitors,podmonitors`).
4. **L2 or BGP (or both)** in actual use — `kubectl -n <ns> get ipaddresspools,
   l2advertisements,bgpadvertisements,bgppeers`.

## Capture

One fixture file per component, raw exposition format:

```bash
NS=<metallb-namespace>

# controller
kubectl -n "$NS" port-forward deploy/controller 7472:7472 &
curl -s http://localhost:7472/metrics > fixtures/controller-metrics.txt

# one speaker pod (host network — port-forward the pod)
kubectl -n "$NS" port-forward pod/<speaker-pod> 7472:7472 &
curl -s http://localhost:7472/metrics > fixtures/speaker-metrics.txt

# FRR-K8s mode only: one frr-k8s pod (discover the metrics port from the pod spec)
kubectl -n "$NS" port-forward pod/<frr-k8s-pod> <port>:<port> &
curl -s http://localhost:<port>/metrics > fixtures/frr-k8s-metrics.txt
```

If kube-rbac-proxy fronts the ports, scrape through it the way the Prometheus would
(`curl -k -H "Authorization: Bearer $(kubectl create token ...)" https://...`) and note
that in the provenance — it changes the chart's monitor TLS/auth config.

**Exercise the signals before capturing** where cheap and read-only is possible: at
minimum ensure ≥1 `LoadBalancer` Service exists so allocator series are non-empty. Do
**not** break BGP sessions on a shared cluster to capture failure series; the unit tests
synthesize those.

## Afterwards

1. Write `fixtures/README.md`: cluster (generic descriptor only — **this repo is public**:
   no internal cluster names/ids), date, versions, backend mode, scrape surface answers,
   and the exact label shapes of the key series.
2. Generate the allowlist: `./generate-allowlist.sh` →
   `metrics-allowlist.captured.txt` (copy the script from kcp-observability).
3. **Revise `docs/roadmap.md`**: retag [documented] → [captured] / [absent], fix label
   assumptions, settle the metric-family and monitor-type decisions, then request
   approval.
