# Design — why the alerts are shaped the way they are

The goal is: **when backups stop working, someone finds out within a day, from an alert that
says what's broken, and the alert clears by itself once a backup succeeds again.** Two rules
follow from that:

1. **Alert on the outcome, not on proxies.** "Time since the last *successful* backup" is the
   outcome. "A Job failed" or "the cron fired" are proxies: a cron that fires and fails every
   day looks healthy to a last-*schedule* check, and a per-Job failure flag stays set until
   history is garbage-collected, long after recovery.
2. **Don't go silent when blind.** An alert that needs a series can't fire once the series
   disappears. Every "the data is missing" case is either covered explicitly or watched.

## Facts from the Velero source that drive the design

Pinned to `vmware-tanzu/velero@release-1.16` (OADP 1.5 ships Velero 1.16). Each is a trap for a
naive rule.

| # | Fact | Source | Consequence |
| --- | --- | --- | --- |
| F1 | `velero_backup_last_successful_timestamp{schedule}` is **recomputed every minute from the Backup CRs that exist**, counting `Completed` only | `pkg/controller/backup_controller.go` (`updateTotalBackupMetric`, `getLastSuccessBySchedule`) | Survives restarts (good). But once every Completed backup has expired (TTL) and Velero restarts, the series is **absent**, not stale. It's also absent when nothing ever succeeded. A bare `time() - ts > 25h` is blind in exactly those cases. |
| F2 | `velero_backup_last_status{schedule}` is reset to `1` by `InitSchedule` on **every** Schedule reconcile, which runs every minute (`scheduleSyncPeriod`) | `pkg/controller/schedule_controller.go` (`Reconcile` → `metrics.InitSchedule`), `pkg/metrics/metrics.go` (`InitSchedule`) | A failed run's `0` survives under a minute. **No rule may use it.** It looks like an upstream bug; it's still present on Velero `main`. |
| F3 | `FailedValidation` returns **before** `RegisterBackupAttempt` | `backup_controller.go` (`Reconcile`) | `velero_backup_attempt_total` never moves when the BSL is broken, so it can't anchor "a backup was attempted and failed". |
| F4 | The only label on backup metrics is `schedule`. Ad-hoc and self-service backups are `schedule=""` | `pkg/metrics/metrics.go` | No per-namespace view. Ad-hoc backups carry no RPO promise and are excluded. |
| F5 | Failure counters (`…_failure_total`, `…_validation_failure_total`, `…_partial_failure_total`) are zero-initialised per schedule | `metrics.go` (`InitSchedule`) | `increase()` sees the first failure. |
| F6 | There is **no** BackupStorageLocation metric | `metrics.go` | The bucket's reachability, which Velero knows every minute, is invisible to Prometheus. Hence the state exporter. |
| F7 | `velero_csi_snapshot_*` carry a per-backup `backupName` label | `metrics.go` | Unbounded series growth. Dropping only the label would make series collide within one scrape, so the ServiceMonitor drops the whole family (no rule uses it). |

## The alerts

**Outcome (critical, these page):**
- `OadpBackupStale`: `time() - last_successful_timestamp > 25h`. A success exists but is too
  old.
- `OadpBackupNoSuccessfulBackup`: the Schedule is older than 25h **unless** a success timestamp
  exists. It's anchored on the Schedule's creation time from the
  [state exporter](state-exporter.md), not on F2 or F3. This covers never-succeeded,
  all-expired (F1), and Velero-unscraped, and gives a new Schedule one full budget first.
- The two are **mutually exclusive by construction** (one needs the timestamp, the other its
  absence), and both resolve on the next Completed backup.

**Cause (names what's broken):**
- `OadpBackupStorageLocationUnavailable` (critical, 15m): the BSL isn't `Available`. This is the
  most common reason every run ends `FailedValidation`, and it's visible about a day before the
  outcome alerts can fire.
- `OadpBackupFailed` (warning): a backup ended `Failed` / `FailedValidation` / `PartiallyFailed`
  within a 12h window, with the `phase` label saying which. It's windowed so it clears by
  itself. The outcome alerts keep paging until a backup succeeds. The window stays short
  because user-workload monitoring keeps 24h by default.

**Blindness (the watchdog):**
- `OadpMetricsAbsent`: `absent()` per enabled component (`velero`, `backupstoragelocations`,
  `schedules`). For the exporter it checks the *data* series, because kube-state-metrics can be
  up and still export nothing (RBAC denied, nothing to report).
- `OadpTargetDown`: a scrape target exists but fails.

## Deployment choices

- **Everything is opt-in:** monitors and the exporter default to off. That fits a shared chart,
  but it means *installing the chart isn't enough*: enable both per cluster.
- **Same namespace as Velero:** user-workload monitoring rewrites rule queries to the rule's
  namespace, so rules, monitors, and exporter all live in `openshift-adp`.
- **The state exporter is stock kube-state-metrics**, not custom code
  ([details](state-exporter.md)).

## Known limitations

- The Velero metric names are pinned from source and confirmed by the component test only for
  the exporter. A live capture (`tests/METRICS-CAPTURE.md`) is the release gate for the Velero
  series.
- The 25h budget is a single value, because one daily schedule is the expected setup. Add
  per-schedule budgets if you run more.
- `OadpBackupFailed` clears 12h after the last failure even if the next run hasn't happened yet.
  That's by design, since it's a cause notification, not the page.

## Testing

| Layer | What | Where |
| --- | --- | --- |
| Unit | Rule logic on synthetic series, including the never-succeeded scenario with `last_status` modelled as Velero really behaves (F2), and the dashboard tiles' "NEVER" branches | `tests/unit/rules.test.yaml` (promtool) |
| Static | Render, lint, PromQL parse, every referenced metric captured or cited, runbook anchors resolve, strict CRD schema validation, no internal identifiers | `tests/validate.sh` |
| Component | The state exporter on a throwaway kind cluster against the real Velero CRDs | `tests/component/state-exporter.sh` |
| Live | A real Velero `/metrics` capture | `tests/METRICS-CAPTURE.md` |
