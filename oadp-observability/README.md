# oadp-observability

Prometheus alerts, a small state exporter, and a Grafana dashboard for **OADP** (OpenShift API
for Data Protection, i.e. Velero on OpenShift), built for OpenShift user-workload monitoring and
the grafana-operator.

It answers one question: **can this cluster be restored?** It alerts on the *outcome* (time since
the last **successful** backup, including "never succeeded"), not on proxies. It names the cause
(an unreachable bucket, failed runs), and warns when the monitoring itself goes blind. Every
alert clears on its own once a backup succeeds again.

Sibling of [`../oadp-operator`](../oadp-operator) and [`../oadp-instance`](../oadp-instance),
which install OADP. This chart only observes it.

> **Status:** built and tested offline and on kind. The Velero metric names are pinned from the
> Velero 1.16 source, and a **live capture must confirm them before the first release**
> ([`tests/METRICS-CAPTURE.md`](tests/METRICS-CAPTURE.md)).

## Alerts

| Alert | Fires when | Severity | Needs |
| --- | --- | --- | --- |
| `OadpBackupStale` | The newest Completed backup of a schedule is older than `maxAgeHours` (25h) | critical | Velero scrape |
| `OadpBackupNoSuccessfulBackup` | A Schedule is older than 25h and **no** Completed backup of it is visible (never succeeded, all expired, or Velero isn't scraped) | critical | state exporter |
| `OadpBackupStorageLocationUnavailable` | A BackupStorageLocation isn't `Available` for 15m, so every backup to it will fail | critical | state exporter |
| `OadpBackupFailed` | A backup ended `Failed` / `FailedValidation` / `PartiallyFailed` within `window` (12h). The `phase` label says which. | warning | Velero scrape |
| `OadpMetricsAbsent` | The series these alerts depend on don't exist (`target`: velero, backupstoragelocations, schedules) | warning | per enabled component |
| `OadpTargetDown` | The Velero or state-exporter scrape target is down | critical | per enabled component |

`Stale` and `NoSuccessfulBackup` are mutually exclusive. Ad-hoc backups (`schedule=""`) are
excluded. Velero's own `velero_backup_last_status` is deliberately **not** used: Velero resets it
to 1 every minute. See [`docs/design.md`](docs/design.md) for why each alert is shaped this way.

## The state exporter

Velero doesn't publish whether its backup bucket is reachable, nor how long a schedule has
existed. Both are needed: the first names the most common cause, and the second catches a
schedule that has *never* succeeded. The chart can run a stock **kube-state-metrics** (read-only,
one small pod) that turns those two object fields into metrics. It's off by default; see
[`docs/state-exporter.md`](docs/state-exporter.md) for what it is, what it exports, its
permissions, and troubleshooting.

## Dashboard

**OADP / Backup Status** (`grafana.dashboard.enabled`, on by default):
- **Status tiles:** Velero's last *successful* backup per schedule, BSL phase, and backup
  alerts firing. `NEVER` (red) means the schedule exists but no success is visible.
- **Charts:** backup age against the 25h budget, Velero outcomes per hour, and BSL availability
  over time.
- **Optional etcd panels:** CronJob-based etcd backups (`daily-etcd-backup` /
  `weekly-etcd-backup` in namespace `etcd-backup`), read from kube-state-metrics'
  `kube_cronjob_status_last_successful_time`. They're empty if you don't run such CronJobs.

## Install

```bash
helm upgrade --install oadp-observability . -n openshift-adp \
  --set prometheus.monitors.veleroServiceMonitor.enabled=true \
  --set stateExporter.enabled=true
```

Both are opt-in, so **installing the chart alone monitors nothing**. The objects must land in the
namespace Velero runs in (`openshift-adp`), so user-workload monitoring scrapes it and evaluates
the rules there. Route alerts with `prometheus.rules.labels`, which is merged into every
PrometheusRule.

## Docs

| Doc | For |
| --- | --- |
| [`docs/runbook.md`](docs/runbook.md) | On-call: what each alert means, the first commands, when it clears |
| [`docs/state-exporter.md`](docs/state-exporter.md) | Operators: the optional exporter, including what, why, permissions, and troubleshooting |
| [`docs/design.md`](docs/design.md) | Maintainers: the Velero source facts behind each alert, trade-offs, limitations |
| [`tests/METRICS-CAPTURE.md`](tests/METRICS-CAPTURE.md) | The release gate: capturing real Velero metrics |

## Testing

- `./tests/validate.sh` runs offline (local `promtool`/`kubeconform` if present, otherwise
  Docker). It checks public-repo hygiene, `helm lint`/`template`, `promtool check` and
  `promtool test` (alert logic and dashboard tile logic), that every metric is captured or
  cited, that runbook anchors resolve, the dashboard (required panels, JSON, PromQL parse), and
  runs strict kubeconform against vendored CRD schemas.
- `./tests/component/state-exporter.sh` runs the exporter on a throwaway kind cluster
  (isolated kubeconfig) against the real Velero 1.16 CRDs and asserts its output.
