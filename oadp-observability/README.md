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

> **Status:** built and tested offline and end-to-end on kind. The Velero metric names are pinned from the
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

**OADP / Backup Status** (`grafana.dashboard.enabled`, on by default) answers "can this cluster
be restored?" without `oc`:
- **Velero status table:** one row per schedule, worst first, with the age of its last
  *successful* backup and a status of `OK`, `STALE` (older than `maxAgeHours`, the same budget
  as `OadpBackupStale`) or `NEVER` (the schedule exists but no success is visible). It stays
  readable with many schedules.
- **Tiles:** BSL phase per location, and backup alerts firing.
- **Charts:** backup age against the budget, Velero outcomes over time, and BSL availability
  over time.
- **Optional etcd section** (`grafana.dashboard.etcdBackup.enabled`, **off by default**): for
  clusters that back up etcd with CronJobs. It shows the daily and weekly last-*successful*-run
  age from kube-state-metrics' `kube_cronjob_status_last_successful_time`, with configurable
  namespace, CronJob names, and budgets:

  ```yaml
  grafana:
    dashboard:
      etcdBackup:
        enabled: true
        namespace: etcd-backup
        dailyCronJob: daily-etcd-backup
        weeklyCronJob: weekly-etcd-backup
        dailyMaxAgeHours: 25
        weeklyMaxAgeHours: 192
  ```

### Screenshots

Taken by the end-to-end suite ([`tests/e2e/`](tests/e2e/README.md)) on kind, with real Velero 1.16.2,
the chart installed as-is, and alert timings shortened (a 3-minute budget instead of 25h).
The dashboard is shown in its default configuration, with the optional etcd section off.

**During an outage.** The bucket is unreachable (BSL `Unavailable`), one schedule is `STALE`
(its last success is past the budget), and a new schedule has `NEVER` succeeded. The status
table sorts worst first:

![OADP / Backup Status during an outage](docs/images/dashboard-failing.png)

**After recovery.** The bucket is fixed and fresh backups exist. Every alert resolved by itself,
and the charts still show the outage window:

![OADP / Backup Status after recovery](docs/images/dashboard-healthy.png)

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
- `./tests/e2e/` stands up the full stack on kind (Prometheus Operator, Alertmanager,
  grafana-operator, real Velero 1.16.2) and drives **every alert to firing, delivered to
  Alertmanager, and back to resolved**, including the never-succeeded and the
  expired-and-restarted cases. See [`tests/e2e/README.md`](tests/e2e/README.md) and the latest
  report in [`tests/reports/`](tests/reports/).
- `./tests/component/state-exporter.sh` runs the exporter on a throwaway kind cluster
  (isolated kubeconfig) against the real Velero 1.16 CRDs and asserts its output.
