# Captured metric fixtures

Real Prometheus exposition scraped from a pinned, ephemeral stack by tests/integration.sh.
tests/validate.sh derives the captured allowlist from these and checks the chart offline.

| Component | Version |
| --- | --- |
| kind node | kindest/node:v1.31.2 |
| Crossplane | 2.3.1 |
| provider-kubernetes | xpkg.upbound.io/crossplane-contrib/provider-kubernetes:v1.2.1 |

Captured: 2026-06-09T10:49:15Z

Note: function_run_* and circuit_breaker_* are core metrics that only register once a
composition function / realtime composition actually runs; this capture does not exercise
one, so those remain in metrics-allowlist.documented.txt (confirmed in the upstream docs).
