# End-to-end on kind

Deploys the chart onto a **real** stack on a throwaway kind cluster, drives **every alert** to
firing and back, and screenshots the dashboard.

| Component | Version | Why |
| --- | --- | --- |
| kind | node image from your kind version | the cluster |
| kube-prometheus-stack | 91.8.2 | Prometheus Operator, Prometheus, Alertmanager, kube-state-metrics. It picks up the chart's ServiceMonitors and PrometheusRules as OpenShift user-workload monitoring would. |
| grafana-operator | v5.25.0 | imports the chart's `GrafanaDashboard` CR into a real Grafana |
| SeaweedFS | 4.48 | S3-compatible bucket for Velero (MinIO no longer publishes images) |
| **Velero** | **1.16.2** (+ AWS plugin v1.12.2) | the version OADP 1.5 ships, in `openshift-adp` |
| OADP metrics Service | from `oadp-operator@oadp-1.5` source | [`stack/oadp-metrics-service.yaml`](stack/oadp-metrics-service.yaml): same name, port, and labels as the one the OADP operator creates, so the chart's ServiceMonitor runs **unmodified** |
| this chart | working tree | [`values-e2e.yaml`](values-e2e.yaml): everything on, **timings shortened** |

## Run it

```bash
./tests/e2e/up.sh          # ~10 min: cluster + stack + chart (idempotent)
./tests/e2e/status.sh      # what Prometheus/Grafana see right now
./tests/e2e/scenarios.sh   # ~25 min: every alert fires and resolves; writes tests/reports/ and docs/images/
./tests/e2e/scenarios.sh 6b 6c   # re-run only some scenarios (own report file)
./tests/e2e/screenshots.sh <name>   # ad-hoc dashboard screenshot (headless Chrome)
./tests/e2e/down.sh        # delete the cluster
```

The scripts use an **isolated kubeconfig** (`$TMPDIR/oadp-obs-e2e.kubeconfig`) and never change
your current kubectl context. Screenshots need Google Chrome; set `CHROME=/path/to/chrome` to
use another binary.

## What `scenarios.sh` breaks, and what must happen

Every "fires" assertion requires the alert to be **firing in Prometheus and delivered to
Alertmanager**. Every "resolves" requires it to clear **with no human action** beyond fixing
the cause.

| # | Breakage (real, on Velero or the scrape path) | Must fire | Then |
| --- | --- | --- | --- |
| 0 | none: one schedule (annotated with a 3-minute budget), one Completed backup | nothing | — |
| 1 | no new backups for longer than the schedule's **own** budget (3m; the default is 6m, so a missed annotation would miss the 300s deadline) | `OadpBackupStale`, and `oadp:schedule_budget_seconds` = 180 | — |
| 2 | the BSL points at a missing bucket; a run fails validation | `OadpBackupStorageLocationUnavailable`, `OadpBackupFailed{phase="FailedValidation"}` | — |
| 3 | a new **unannotated** schedule whose every run fails (default 6m budget) | `OadpBackupNoSuccessfulBackup` (not `Stale`), budget = 360 | screenshot `failing` |
| 4 | Completed backups deleted and Velero restarted (success series **absent**) | `OadpBackupNoSuccessfulBackup`; `Stale` resolves | — |
| 5 | fix the bucket, run the schedules | — | all of the above resolve |
| 6a | the Velero scrape target fails (wrong port) | `OadpTargetDown{target="velero"}` and, by design, `OadpBackupNoSuccessfulBackup` | resolves on fix |
| 6b | the Velero metrics Service is deleted | `OadpMetricsAbsent{target="velero"}` | resolves on fix |
| 6c | the state exporter is scaled to 0 | `OadpMetricsAbsent{target="backupstoragelocations"}`, `{target="schedules"}` | resolves on fix |
| 6d | the state exporter's scrape fails (the ServiceMonitor path returns 404) | `OadpTargetDown{target="state-exporter"}` | resolves on fix |
| 7 | fresh backups | nothing | screenshot `healthy` |

## Honest limits

- **Prometheus can stall on a laptop** (the Docker VM pauses: every rule group misses
  iterations, and unrelated scrapes gap). The assertions detect this through
  `prometheus_rule_group_iterations_missed_total`, extend the wait once, and mark the row, so
  a stall isn't mistaken for a rule failure.

- **Timings are shortened** (default budget 6m instead of 25h with the baseline schedule annotated
  3m, `for` 1m instead of 15m, failure window 5m instead of 12h). The expressions are the production ones.
- It's plain Prometheus, not OpenShift user-workload monitoring, so UWM's namespace enforcement
  isn't exercised (all objects share `openshift-adp`, which is what that enforcement needs).
- Velero's `Failed` / `PartiallyFailed` phases aren't produced here. They're covered by
  `tests/unit/rules.test.yaml`.
