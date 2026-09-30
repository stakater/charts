# OADP / Velero backup alerts — runbook

For whoever holds the page. Each section covers what the alert means, what is at risk, the
first commands to run, and when it clears. Every alert resolves **on its own** once the
underlying condition is gone. No manual silence is needed after a fix.

All commands assume OADP runs in `openshift-adp` and use Velero's own CLI inside the Velero
pod (`oc -n openshift-adp exec deploy/velero -c velero -- ./velero ...`), which is the
pattern Red Hat's OADP docs use.

> **Secrets by reference.** Never paste a bucket key into a ticket or chat, and don't
> `-o yaml` credential-bearing objects into shared channels.

## Which alert tells you what

| Alert | Question it answers | Severity |
| --- | --- | --- |
| [OadpBackupStale](#oadpbackupstale) | Is the newest good backup older than the RPO? | critical |
| [OadpBackupNoSuccessfulBackup](#oadpbackupnosuccessfulbackup) | Is there **no** good backup at all? | critical |
| [OadpBackupStorageLocationUnavailable](#oadpbackupstoragelocationunavailable) | Can Velero reach its bucket? | critical |
| [OadpBackupFailed](#oadpbackupfailed) | Did a run just fail, and how? | warning |
| [OadpMetricsAbsent](#oadpmetricsabsent) | Are we blind? | warning |
| [OadpTargetDown](#oadptargetdown) | Is a scrape target down? | critical |

The outcome alerts (`Stale`, `NoSuccessfulBackup`) are the page. The others name the cause.
A BSL alert plus a `NoSuccessfulBackup` alert together is the signature of rejected bucket
credentials (see the failure scenario below).

---

## OadpBackupStale

**Means:** the newest *Completed* backup of the schedule is older than **that schedule's** RPO
budget: its `oadp-observability.stakater.com/max-age-hours` annotation, or the chart default
(25h). Runs are failing, or not running at all. The dashboard's Budget column shows the budget
in force; if it's wrong, fix (or add) the annotation on the Schedule. Unannotated schedules use
the chart default (25h), which is right for a daily schedule and too slow for an hourly one.

**At risk:** restoring to within the RPO. Older backups may still exist and be restorable.

**First:**

```bash
# the recent runs, newest last: phase, failure reason, validation errors
oc -n openshift-adp get backups.velero.io -l velero.io/schedule-name=<schedule> \
  --sort-by=.metadata.creationTimestamp \
  -o custom-columns=NAME:.metadata.name,PHASE:.status.phase,REASON:.status.failureReason,ERRORS:.status.validationErrors
oc -n openshift-adp get backupstoragelocations.velero.io     # Available?
oc -n openshift-adp get schedules.velero.io <schedule> -o jsonpath='{.spec.paused} {.status.lastBackup}'
```

**Common causes:**
- Every run ends `FailedValidation`: the BSL is Unavailable (see below).
- `PartiallyFailed`: a volume snapshot or item failed. Read `./velero backup logs <name>`.
- No new Backups at all: the schedule is paused, or Velero is down (`OadpTargetDown`).

**Clears when:** a run of that schedule Completes.

## OadpBackupNoSuccessfulBackup

**Means:** the Schedule has existed for longer than its budget (annotation, else the 25h
default), and **no** Completed backup of it is visible. Either it never succeeded, every success has expired (TTL 48h), or Velero's
metrics aren't scraped (then `OadpTargetDown`/`OadpMetricsAbsent` fire too).

**At risk:** everything the schedule covers. There may be **nothing** to restore.

**First:** the same commands as [OadpBackupStale](#oadpbackupstale). Then:

```bash
./velero backup describe <newest-backup> --details     # via: oc -n openshift-adp exec deploy/velero -c velero --
```

**Clears when:** a run Completes. To confirm a fix without waiting for 01:00, trigger one:

```bash
oc -n openshift-adp exec deploy/velero -c velero -- ./velero backup create --from-schedule <schedule>
```

`--from-schedule` labels the backup with the schedule name, so a success counts for this
alert.

## OadpBackupStorageLocationUnavailable

**Means:** Velero's periodic validation of the BackupStorageLocation (the bucket) fails. Every
backup that targets it ends `FailedValidation` until it's fixed.

**At risk:** all backups to that location, from now on.

**First:**

```bash
oc -n openshift-adp get backupstoragelocations.velero.io <name> -o jsonpath='{.status.message}{"\n"}'
oc -n openshift-adp get backupstoragelocations.velero.io <name> -o jsonpath='{.spec.objectStorage.bucket} {.spec.credential.name}/{.spec.credential.key}{"\n"}'
oc -n openshift-adp logs deploy/velero -c velero --since=30m | grep -i 'storage location'
```

**Common causes:** credentials rejected (403), a bucket deleted or renamed, a bucket policy that
doesn't grant the key's principal, or no network path to the endpoint. Check that the key's
AWS **account** matches the bucket's account (`aws sts get-caller-identity` with that
profile). Don't print the key.

**Clears when:** the next validation succeeds, usually within a minute of the fix.

## OadpBackupFailed

**Means:** at least one backup of the schedule ended in the `phase` label's state within the
window (12h):
- `FailedValidation`: the spec or storage location is invalid. Check the BSL first.
- `PartiallyFailed`: some items or volumes weren't backed up. The backup exists but is
  incomplete.
- `Failed`: the run itself errored.

**First:** `./velero backup describe <name> --details` and `./velero backup logs <name>`, both
via `oc -n openshift-adp exec deploy/velero -c velero --`.

**Clears when:** the window passes with no new failure. It's a cause notification. The outcome
alerts keep paging until a backup succeeds.

## OadpMetricsAbsent

**Means:** the series that the alerts above depend on **don't exist**. The `target` label says
which: `velero`, `backupstoragelocations`, or `schedules`. **Every alert that depends on them
is silently disarmed**, and backups can fail unseen. Without it, a cluster can go months with
every backup failing and no alert at all, because nothing is scraped.

**First:**

```bash
oc -n openshift-adp get servicemonitors,svc,pods
# velero:    does openshift-adp-velero-metrics-svc exist and select the velero pod?
# exporter:  is the state-exporter pod running, and are its logs free of RBAC "forbidden"?
oc -n openshift-adp logs deploy/<release>-oadp-observability-state-exporter --tail=50
```

**Timing:** this can fire up to about 5 minutes after `for` has elapsed. Prometheus keeps a
vanished series visible for its 5-minute lookback unless it wrote a staleness marker.

**Special case, `target="schedules"`:** this also fires when **no Velero Schedule exists at
all**. The exporter is fine but has nothing to report, which means nothing is being backed up
on a schedule. Check with `oc -n openshift-adp get schedules.velero.io`. If that's
intentional, disable the alert (`prometheus.rules.watchdog.metricsAbsent.enabled=false`) or
leave the exporter off.

**Clears when:** the series exist again.

## OadpTargetDown

**Means:** Prometheus can't scrape the target (`target` label: `velero` or `state-exporter`).
Its alerts are disarmed while it's down. If it's Velero, scheduled backups aren't running either.

**First:** `oc -n openshift-adp get pods`, then `describe` and `logs` on the failing pod.

**Clears when:** the scrape succeeds.

---

## Failure scenario — rejected bucket credentials

**Shape:** the BSL's credentials can't list the bucket. A common cause is a key from a
different cloud account than the one that owns the bucket and its policy. Every scheduled run
ends `FailedValidation`, nothing ever Completes, and if Velero isn't scraped, nothing alerts.

**What this chart shows:**
1. `OadpBackupStorageLocationUnavailable{name="<bsl>"}` within **15 minutes** of the BSL going
   Unavailable.
2. `OadpBackupFailed{phase="FailedValidation"}` at every scheduled run.
3. `OadpBackupNoSuccessfulBackup{schedule="<schedule>"}` once the schedule is older than 25h
   with no success. It pages immediately on a schedule that has been failing for a long time.

**Diagnose:** `oc -n openshift-adp get backupstoragelocations.velero.io <bsl> -o jsonpath='{.status.message}'`
shows the provider error (for example S3 `403 AccessDenied` on `ListBucket`). Compare the
credential's account and principal with the bucket's owner and policy, without printing the key.

**Verify the fix:** the BSL goes `Available` (the BSL alert clears within a minute). Then run
`oc -n openshift-adp exec deploy/velero -c velero -- ./velero backup create --from-schedule <schedule>`
and watch it Complete, which clears `OadpBackupNoSuccessfulBackup`.
