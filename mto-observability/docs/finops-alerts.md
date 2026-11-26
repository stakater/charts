# finops-operator alert set (roadmap Area 7)

The concrete alerts this chart will ship for finops-operator. Names and logic are
settled; thresholds and `for:` windows are **placeholders** until the approval gate and
a live baseline. Status: 📝 planned — Tier 2 is buildable now; Tier 1 is gated on a
finops-operator release carrying the `finops_costjob_*` gauges (upstream change in
review), which the chart then pins as its minimum supported version.

## Tier 1 — cost pipeline (the reason this chart exists)

Built on the CostJob execution-state gauges. The loader pod writes execution results
into the CostJob CR status, so a CronJob that never runs leaves the status **stale, not
failed** — every Tier 1 alert fires on that staleness. Both job types are covered
(`ResourceCostCollection`, `SubscriptionChargeCollection`).

### `MTOCostDataStale` — critical

```promql
time() - finops_costjob_last_successful_execution_timestamp_seconds
  > 2 * <costjob interval>     # threshold per CostJob from chart values
```

The headline alert: no successful cost collection for twice the job's interval.
Catches every silent failure shape — CronJob suspended, unpullable image, quota
blocking the pod, loader crash-looping, OpenCost or PostgreSQL down. All of them look
identical from here: data stops, the timestamp freezes, this pages.

### `MTOCostJobNeverSucceeded` — critical

```promql
max by (costjob, namespace, type) (finops_costjob_last_execution_status)
  unless on (costjob, namespace, type)
    finops_costjob_last_successful_execution_timestamp_seconds
```

The CostJob exists (its status series are published) but has never once succeeded, for
longer than ~2× its interval. Catches the day-one failure `MTOCostDataStale` cannot
see: a new or re-created CostJob that never worked, so there is no last-success
timestamp to age. The one-hot status gauge is deliberately published all-zero for a
never-executed job to make this expressible.

### `MTOCostJobFailing` — warning, escalating critical

```promql
finops_costjob_last_execution_status{status=~"Failed|Error"} == 1
```

The job runs but its last execution failed; warning after one missed interval.
Separates "runs but fails" (look at OpenCost, PostgreSQL, credentials) from "never
runs" (look at the CronJob, schedule, quota) — the fix differs, so the alert does too.

### `MTOFinopsMetricsAbsent` — warning

```promql
absent(finops_costjob_last_execution_status)
```

Every CostJob gauge vanished: the scrape died, the operator stopped, or all CostJobs
were deleted. The watchdog that keeps the three alerts above honest — without it they
silently stop evaluating.

## Tier 2 — operator health (buildable now, no upstream dependency)

Standard controller-runtime families, scraped through the chart's authenticated-HTTPS
monitor. These ship first; until Tier 1 lands they are the **only** finops signal, and
they must not be mistaken for cost-data coverage — a healthy operator can watch its
CronJobs rot.

### `MTOFinopsOperatorDown` — critical

`up{job=<finops monitor>} == 0 or absent(...)` for 5m. Both finops webhooks (Offering,
Subscription) are `failurePolicy: Fail`: operator down means every Offering/Subscription
write in the cluster is rejected — and nobody is updating CostJob CronJobs or status.

### `MTOFinopsReconcileErrors` — warning

Per-controller `controller_runtime_reconcile_errors_total` ratio over 15m above
threshold (placeholder 10%). The earliest real signal for a wedged
Offering/Subscription/CostJob reconciler.

### `MTOFinopsWebhookErrors` / `MTOFinopsWebhookLatencyHigh` — warning

Webhook 5xx rate and p99 `controller_runtime_webhook_latency_seconds` (exact family
names confirmed at capture). With Fail-policy webhooks, 500s here are user-visible
rejections before the operator is even "down".

### `MTOFinopsWorkqueueBacklog` — warning

`workqueue_depth` sustained above threshold, or p99 time-in-queue above ~60s: slow
cost/subscription convergence before anyone files a ticket.

## Coverage map

| Failure shape | Caught by |
| --- | --- |
| CronJob suspended / never scheduled | `MTOCostDataStale` (or `NeverSucceeded` if new) |
| Loader pod can't start (image, quota) | `MTOCostDataStale` / `MTOCostJobNeverSucceeded` |
| Loader runs but fails (OpenCost, Postgres, creds) | `MTOCostJobFailing`, then `MTOCostDataStale` |
| CostJob CR deleted / never reconciled | `MTOFinopsMetricsAbsent` (series are removed with the CR) |
| Operator down (also blocks Offering/Subscription writes) | `MTOFinopsOperatorDown` |
| Scrape/observability itself dead | `MTOFinopsMetricsAbsent` + chart watchdog |
| Finops PostgreSQL volume filling | **not this chart** — kubelet volume stats are platform-side (roadmap Q9); belongs with the platform-stack rules |

## One home per alert (roadmap Q9)

A parallel incident-driven rule set exists, built on `kube_job`/`kube_cronjob`/kubelet
series and shipped platform-side, where those families are alertable. The overlap with
Tier 1 is by design; the approval gate decides the split. The gauge-based Tier 1 set
works from UWM and needs no platform-stack access; the KSM-based set needs
platform-side rules but no operator release. Whatever the split, each failure shape
pages exactly once.
