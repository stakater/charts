# MetalLB e2e stack (kind + FRR peer)

A disposable lab that (a) produced the **metric capture** in `../fixtures/` and (b) will
run the **alert e2e scenarios** once the chart is built. Everything is pinned and
idempotent; nothing touches your current kube context (isolated kubeconfig, see `lib.sh`).

```
kind cluster (1 cp + 2 workers)          docker network "kind"
  metallb-system:                        ┌──────────────────────┐
    controller (allocator)               │ frr peer container   │
    speaker DaemonSet ──── BGP 64513 ──► │ FRR 9.1, AS 64512    │
    frr-k8s DaemonSet ──── BFD ────────► │ dynamic neighbors on │
  default:                               │ the kind subnet      │
    echo deployment                      └──────────────────────┘
    echo-bgp  LoadBalancer <- bgp-pool (BGPAdvertisement, BFD)
    echo-l2   LoadBalancer <- l2-pool  (L2Advertisement)
```

MetalLB runs in **FRR-K8s mode** (`frrk8s.enabled=true` — what recent OpenShift MetalLB
operators deploy), so the capture answers the roadmap's metric-family question for that
backend. Both a BGP and an L2 pool are advertised so both code paths emit series.

## Run

```bash
./up.sh         # kind + FRR peer + MetalLB + pools/peers + sample services (~5 min cold)
./capture.sh    # scrape every metrics endpoint -> ../fixtures/*-metrics.txt + surface facts
./down.sh       # delete cluster + peer container
```

After a capture: `../generate-allowlist.sh`, update `../fixtures/README.md` (provenance),
revise `../../docs/roadmap.md` tags, and re-seek approval.

## Deliberate simplifications (and the handover task they create)

This lab is upstream MetalLB via Helm. A real OpenShift cluster runs the **MetalLB
operator**, which may differ in exactly the ways the chart's monitors care about:
namespace labels, kube-rbac-proxy in front of the metrics ports (TLS + bearer token),
operator-created ServiceMonitors/PodMonitors, and the shipped MetalLB/FRR-K8s versions.

**Handover activity — done 2026-11-06:** the capture procedure (`../METRICS-CAPTURE.md`)
was re-run read-only against an OpenShift cluster running the MetalLB operator
(`../fixtures/operator/`, `../reports/operator-openshift-2026-11-06.md`). The operator
layout became the chart's default; this lab is now the **upstream profile**, selected by
`values-e2e.yaml` (upstream pod labels, `metallb.operatorManagedMonitors: false`,
`metallb-*` jobs, frr-k8s in the same namespace with both proxy ports named
`metricshttps`).

## Later: scenarios.sh

Once the chart is built, this stack gains kube-prometheus-stack + grafana-operator (the
oadp-observability pattern) and a `scenarios.sh` that drives **every alert to fire and
resolve**: kill the FRR peer (BGP/BFD session down), fill a pool (exhaustion), apply a
broken config (stale), scale the controller to 0 (down), etc.
