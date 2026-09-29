# e2e on kind — 2026-09-29

Every alert of this chart driven to **firing** (in Prometheus, and delivered to
Alertmanager) and back to **resolved** on a real stack: kind, kube-prometheus-stack 91.8.2,
grafana-operator v5.25.0, **Velero 1.16.2** (what OADP 1.5 ships) with a SeaweedFS S3 bucket,
the OADP-shaped metrics Service, and this chart with `tests/e2e/values-e2e.yaml`.

> **Timings are shortened** for the run (budget 3m instead of 25h, `for` 1m instead of 15m,
> failure window 5m instead of 12h). The rule expressions are the production ones.
> Not exercised here: OpenShift user-workload monitoring's namespace enforcement, and the
> `Failed` / `PartiallyFailed` phases (covered by `tests/unit/rules.test.yaml`).

| Scenario | Alert | Expected | Result |
| --- | --- | --- | --- |
| 6b absent | OadpMetricsAbsent {"target":"velero"} | firing | ✅ firing after 101s, delivered to Alertmanager |
| 6b absent | OadpMetricsAbsent {"target":"velero"} | resolved | ✅ resolved after 20s |

**Result: PASS**
