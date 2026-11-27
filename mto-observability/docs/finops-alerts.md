# finops-operator alert set (roadmap Area 7)

The concrete alerts this chart will ship for finops-operator. Names and logic are
settled; thresholds and `for:` windows are **placeholders** until the approval gate and
a live baseline. Status: 🔨 **both tiers are BUILT** behind a green `tests/validate.sh` (every alert
promtool-tested to fire and resolve); the gauge families are [captured] in the chart
fixtures from the gauge PR branch build. Tier 1 goes LIVE once a finops-operator
release carries the gauges — the chart then pins that release as its minimum
supported version. Until then `MTOFinopsMetricsAbsent` fires by design on clusters
running older finops versions.

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

## "Isn't this just a failing-CronJob alert?" — no, and here is exactly why

The objection is fair on its face: Kubernetes already exposes `kube_job_status_failed`
and `kube_cronjob_status_last_successful_time`, and a parallel incident-driven rule set
was built on them platform-side. But "the CronJob is failing" is only **one** of the
ways this pipeline dies — and it is the only one a failing-job alert actually sees.
Walk the pipeline:

```
CostJob CR ──▶ operator renders CronJob ──▶ kube schedules Job ──▶ loader pod runs
          ──▶ fetches OpenCost ──▶ writes PostgreSQL ──▶ writes CostJob status
```

Every stage fails differently, and the two signal families see different stages:

| # | Failure shape | What `kube_job`/`kube_cronjob` sees | What the gauges see |
|---|---|---|---|
| 1 | Operator reconcile fails → **CronJob never created** | **Nothing.** No CronJob = no series at all; a failing-job alert is structurally silent. The only KSM fix is a "job missing" rule fed an external list of what *should* exist — which must be maintained forever. | Series exist the moment the CostJob CR does. `MTOCostJobNeverSucceeded` fires. |
| 2 | CronJob **suspended** / schedule wrong | No failure is ever recorded — nothing runs, so nothing fails. Needs its own dedicated suspend rule. | Last-success timestamp freezes. `MTOCostDataStale` fires. |
| 3 | Loader pod **can't start** (unpullable image, quota, no node) | The pod sits Pending: `kube_job_status_failed` often stays **0**. Only a staleness rule on `last_successful_time` catches it — i.e. the platform set *also* needed staleness, not failure. | Same freeze, same `MTOCostDataStale`. |
| 4 | Loader **runs and exits non-zero** | ✅ `kube_job_status_failed` fires. | ✅ `MTOCostJobFailing` fires. **This row — the "failing CronJob" — is the only true overlap.** |
| 5 | Loader **exits 0 but the contract wasn't met** (crashed after the fetch, before the status/DB write) | Success. The Job metric measures "pod exited 0", not "cost data landed". | The status write is the *last* thing the loader does after the DB work, so the success timestamp only advances when the contract was met. Staleness fires. |
| 6 | CostJob **deleted** (or CronJob removed) | Series silently vanish — a firing alert resolves with no page, and nothing says whether that was intended. | Gauges are deleted *with the CR*, deliberately; `MTOFinopsMetricsAbsent` watchdogs the scrape itself. |

Three structural differences on top of the matrix:

- **Thresholds.** Staleness is only meaningful against *each CostJob's own interval*
  (1m–24h, per CR spec). A KSM rule cannot know the interval, so it hardcodes one
  number for the whole cluster; the gauge alerts take the threshold per CostJob from
  chart values, next to the truth.
- **Where it can run.** `kube_job`/`kube_cronjob` live in **platform** monitoring: on
  OpenShift, user-workload alert rules cannot reference them. The KSM rule set
  therefore works only on fleets where we control the platform stack. MTO is a
  product: on a customer's cluster, the chart gets UWM and nothing else — the gauges
  are the **only** alert path that ships with the product and works everywhere.
- **One mechanism for the suite.** Hibernation's missed wake and template-v2's
  unsynced instances have **no** `kube_*` equivalent at all; operator gauges are the
  only option there. Building finops the same way gives the chart one pattern, and
  every rule is unit-tested by `promtool` against synthetic series in
  `tests/validate.sh` — rules living outside the chart sit outside that gate.

**Honest limit of both families:** a loader with a logic bug that writes `Success`
over bad data fools the gauges exactly as it fools Kubernetes. That is a
data-*quality* concern (row counts, sum sanity), a separate story if we ever need it.

## The split (proposal for the approval gate — roadmap Q9)

One pager per failure shape, the portable set in the product, platform-only signals
platform-side:

| Failure shape | Pages from | Rationale |
|---|---|---|
| Rows 1–3, 5 (never created / suspended / can't start / contract unmet) | **Chart** (`MTOCostDataStale`, `MTOCostJobNeverSucceeded`) | Only the gauges see all of these with two rules and no expectations list. |
| Row 4 (runs and fails) | **Chart** (`MTOCostJobFailing`) | The one overlap: the gauge version adds the job `type` and survives on customer clusters; the platform twin gets retired or downgraded to ticket-severity defense-in-depth — not both paging. |
| Row 6 + observability dead | **Chart** (`MTOFinopsMetricsAbsent`) | Watchdog belongs next to what it watches. |
| Operator down | **Chart** (`MTOFinopsOperatorDown`) | `up` on the chart's own monitor. |
| PostgreSQL **volume filling** | **Platform, permanently** | Kubelet volume stats exist nowhere else. This alert never moves into the chart. |
| `kube_job`/`kube_cronjob` panels | **Dashboard only** (both stacks) | Thanos-querier federates them for *viewing* everywhere; they are an alert source nowhere in the chart. |

Sequencing, not either/or: the platform-side set is live **today** and needs no
operator release — it keeps paging on fleets we control until the gauge release ships
and the chart's Tier 1 goes live there; then the overlapping platform rules are retired
or downgraded in the same change, so no failure shape ever pages twice or goes dark
between the two.
