# Captured metric fixtures

Real Prometheus exposition scraped from a pinned, ephemeral stack by tests/integration.sh.
tests/validate.sh derives the captured allowlist from these and checks the chart offline.

| Component | Version |
| --- | --- |
| kind node | kindest/node:v1.31.2 |
| Crossplane | 2.3.1 |
| provider-kubernetes | xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v1.2.1 |

Captured: 2026-06-09T10:49:15Z

Note: the pinned kind rig above does not exercise composition functions, the realtime
circuit breaker, or Upjet providers, so those metrics are NOT scraped here. They are
captured separately from a live cluster and committed as side-fixtures this capture does
not overwrite, then folded into the captured allowlist via capture-metrics.sh:
  - inventory-metrics.txt      (--inventory) — ksm-crossplane inventory exporter (XR/claim conditions)
  - live-exercised-metrics.txt (--extra)     — function_run_*, circuit_breaker_*, upjet_resource_*
