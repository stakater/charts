# MTO Observability Roadmap

**Status:** 🔨 **Captured (kind lab, 2026-11-26) — Tier 2 built; approval + real-cluster
comparison pending.** The metric-reality step ran against a live kind lab running the
full suite (10 of 11 pods scraped, 210 families in `tests/fixtures/`, provenance in
`tests/fixtures/README.md`): every metric below tagged **[captured]** carries labels
verified from a real scrape, including the three pre-release gauge families from the
upstream PR branches. Remaining gates: per-story approval (Q1–Q9) and a read-only
comparison capture on a real OpenShift cluster before release (TLS/Service/label
parity — the metallb precedent).
**Scope (settled 2026-11-26):** MTO is a suite of **four operators**, and this chart
covers all of them: **tenant-operator** (Areas 1–6), **finops-operator** (Area 7 — the
priority: cost-collection jobs failing silently is the incident class that motivated
this chart), **hibernation-operator** (Area 8), **template-operator-v2** (Area 9).
MTO Console/Gateway remain out of scope (separate systems).
**Build status (2026-11-26):** the **generic Tier 2 suite is built** behind a green
`tests/validate.sh`, and the **kind-lab capture is done** — selectors, ports and all
Tier 2 families re-verified [captured]; the per-operator `scheme` and the
hibernation-manager-only selector are capture corrections already folded into the
chart. Story 6.1's watchdog is **folded into the Down alerts** (their `absent()`
half); stories 1.2 / 2.4 / 3.4 are unblocked ([captured] families). The three
upstream state-gauge PRs are CI-green in review and their families are [captured]
from branch builds — Tier 1 builds the moment they release. Before release:
story approval (Q1–Q9) and the OpenShift comparison capture.
**Owner:** Platform / SRE

---

## How to read this document

Organized **by user story**: need → measurement → target → alert → dashboard.

Lifecycle: 📝 Draft → 👍 Approved (human gate) → 🔨 In progress → ✅ Done. Approval is
per story; killing a weak Draft here is the method working.

### Metric reality (the discipline)

- **[captured]** — in `tests/fixtures/` with the exact labels stated (kind lab
  2026-11-26; the three suite-operator gauge families come from the upstream PR
  branch builds, pre-release).
- **[captured, lazy]** — family proven on this build but the series registers only on
  an event (first success, first error): `absent()`-style logic must account for it.
- **[documented]** — in the published MTO docs (Reference → Metrics) or the
  controller-runtime metrics reference, not yet in our fixtures.
- **[cr-default]** — standard controller-runtime / client-go / Go runtime family that
  every manager process exports; exact set to be confirmed by capture.
- **[bundle]** — a deployment-shape fact read from the v1.10.x OLM bundle manifests
  (Services, args, webhook configurations), not a metric.
- **[ksm]** — kube-state-metrics / platform Prometheus series: usable on dashboards
  (Thanos querier federates platform + UWM) but **never in alerts** (thanos-ruler for
  user workloads evaluates against UWM data only).
- **[absent]** — looked for and not there. Never faked.

### Structural facts (to be re-verified by the capture)

1. **MTO v1.10.x runs as seven Deployments**, one per controller, each with
   `--metrics-bind-address=:6443 --leader-elect` **[bundle]**: *namespace*
   (`control-plane: controller-manager`), *tenant* (`…-tenant`), *quota-intconfig*
   (`…-quota-intconfig`), *pilot* (`…-pilot`), *db* (`…-db-controller`), *extensions-argocd*
   (`…-extensions-argocd`), and a dedicated *webhook* server (`…-webhook`). db and
   extensions-argocd are optional components (enabled per install).
2. **The metrics scheme depends on cert configuration — CAPTURED both ways.** With a
   cert dir the endpoint is HTTPS with TokenReview+SubjectAccessReview (finops and
   template-v2 served https in the lab). **Without one, controller-runtime serves
   PLAIN HTTP** (`Serving metrics server {"secure": false}`) — every tenant-operator
   deployment and the hibernation manager did **[captured]**. The chart's monitors
   therefore take a per-operator `scheme` value; which scheme a real install uses is
   the main question for the OpenShift comparison capture. Also **[captured]**: macOS
   curl (LibreSSL) cannot even handshake the https variants — capture runs from an
   in-cluster pod (`tests/capture.sh`).
3. **Only three metrics Services exist** **[bundle]**: `…-tenant-metrics-service`,
   `…-quota-intconfig-metrics-service`, `…-pilot-metrics-service` (port 8443 → named
   port `https`). The namespace, webhook, db and extensions deployments expose the pod
   port only. The ServiceMonitor in MTO's kustomize config is **not** in the OLM bundle —
   **on an OperatorHub install nothing scrapes MTO until this chart does.**
4. **Custom metrics are five GAUGES under `multi_tenant_operator_*`** — now settled:
   `reconcile_count{kind,name}` and `reconcile_seconds{kind,name}` **[captured]** on
   the **tenant controller only**, exactly as predicted; `resources_deployed`,
   `resources_deployed_total` and `reconcile_error` are **[captured, lazy]** — they
   register only when the manifest-deploy path runs / a resource errors (the lab
   Tenant exercised neither). All gauges — `rate()` applies to **none** of them.
   `reconcile_error` carries the **error text in a label** (unbounded cardinality:
   alert on presence, never aggregate across `errors`).
5. **Webhook failure policies split in two** **[bundle]**: `failurePolicy: Fail` on the
   Tenant, Quota and IntegrationConfig validators — webhook down ⇒ **every tenancy
   admin-plane write is rejected cluster-wide**. `failurePolicy: Ignore` on the
   namespace and rolebinding validators — webhook down ⇒ those requests are admitted
   **unvalidated**: a silent tenancy-guardrail bypass. One outage, two very different
   blast radii; both argue the webhook is the single most alert-worthy component.
6. **UWM evaluation constraint**: alerts render only from series UWM itself scrapes.
   Platform families (`apiserver_admission_webhook_*`, kube-state-metrics) are
   dashboard-only here **[ksm]**. This bites hardest in Area 7: `kube_cronjob_*` /
   `kube_job_*` — the obvious signals for a failing cost-collection CronJob — **cannot
   be alerted on from UWM.** They ARE alertable where rules are shipped into the
   **platform** monitoring stack instead (some fleets deploy rules that way) — which
   stack evaluates this chart's rules is Q9, and it decides whether KSM-based
   expressions are allowed in alerts or stay dashboard-only.
7. **The three suite-operator gauge families now EXIST and are [captured]** (from
   the upstream PR branch builds, pending release): `finops_costjob_*` (one-hot
   status incl. the all-zero never-executed shape AND a live `Failed=1`;
   `last_successful_execution_timestamp_seconds` is **[captured, lazy]** — registers
   on first success), `hibernation_supervisor_*`
   (`{kind,supervisor,namespace}` + `ready{reason}`, next-reconcile timestamps live),
   `template_operator_instance_*` (`{instance,namespace,template,template_namespace}`,
   a real `ready{reason="NamespaceNotPermitted"} 0` + `phase{Failed} 1` in the
   fixtures). Released operator versions still carry none of these — the chart pins
   the gauge releases as minimum versions.
8. **Capture-settled generic families**: `leader_election_master_status`,
   `certwatcher_read_certificate_*` and `controller_runtime_reconcile_panics_total`
   are **[captured]** across the suite — stories 1.2, 2.4 and 3.4 are buildable as
   written. `controller_runtime_webhook_*` is **[captured]** on finops, template-v2,
   tenant-webhook and quota-intconfig.
9. **Scrape-surface gaps found by the capture** (upstream asks): the
   **hibernation webhook pod serves no metrics at all** (no `--metrics-bind-address`
   — its Down story is blind until fixed; the chart's monitor covers the manager
   only); **template-v2's kustomize metrics patch does not reach the rendered
   Deployment** (no metrics arg — enabled by hand in the lab); tenant-operator
   **crashes on vanilla Kubernetes** unless `PLATFORM_TYPE=Kubernetes` (watches
   OpenShift-only CRDs); finops CronJobs render an **`OPERATOR_IMAGE_PLACEHOLDER`**
   image until that env is set on the manager — itself a live demonstration of the
   silent cost-collection failure (pods `InvalidImageName`, status forever empty).
10. **finops-operator shape** **[code/bundle]**: one manager Deployment; Offering +
   Subscription validating webhooks, both `failurePolicy: Fail`. A `CostJob` CR renders
   a **CronJob** per job type — `ResourceCostCollection` (OpenCost → PostgreSQL) and
   `SubscriptionChargeCollection` (charge records) — and the **loader pod itself**
   writes `status.lastExecutionTime/lastSuccessfulExecutionTime/lastExecutionStatus` +
   a 10-entry `executionHistory` (with error text) back to the CR. Consequence: when
   the CronJob never starts (suspended, image pull, quota, schedule drift), the status
   simply goes **stale** — no error is recorded anywhere. Freshness, not failure, is
   the only honest SLI.
11. **hibernation-operator shape** **[code/bundle]**: manager + webhook Deployments;
   `ResourceSupervisor`/`ClusterResourceSupervisor` CRs with a `Ready` condition;
   both validators `failurePolicy: Fail`. A webhook metrics Service exists.
12. **template-operator-v2 shape** **[code/bundle]**: manager (+ webhook Service);
    `Template`/`TemplateInstance` (v2alpha1) with `observedGeneration`, `phase` and a
    `Synced` condition; validating webhook `failurePolicy: Fail`. The bundle ships a
    metrics Service and a `metrics-reader` ClusterRole. Note: tenant-operator v1's
    custom gauges covered template reconciliation (TGI); v2 has none — an
    observability **regression** to raise upstream.

### The SLI / SLO / SLA distinction

- **SLI** — the measurement. **SLO** — internal target with an error budget; pages
  on-call. **SLA** — externally promised, only a few, looser than the SLO.
- MTO's customer-facing promise is: *a tenant change (Tenant/Template/Quota) converges to
  real namespaces, RBAC and quotas promptly — and tenancy boundaries stay enforced.*
  Areas 2 and 3 are the SLA candidates; everything else is internal.

> **Calibration:** every numeric target below is a **placeholder** until 2–4 weeks of
> live baseline on a real cluster.

---

> **Areas 1–6 are written against tenant-operator** (the suite's largest member). The
> *generic* stories — controller down (1.1), leader election (1.2), webhook down/slow
> (2.1/2.3), reconcile errors (3.2), backlog (3.3), panics (3.4), watchdog (6.1) —
> apply to **all four operators** and are built per-operator from the same templates;
> their fixtures and `job` names are per-operator capture items.

# Capability Area 1 — Control-plane availability (is MTO running at all?)

Seven single-replica controller Deployments. Any of them down means its slice of tenancy
stops converging; none of them down is visible to a user until something doesn't happen.

## Story 1.1 — Is a controller down? 📝 Draft

> **As an SRE, I want to be paged when an MTO controller has no running pod or stops
> being scraped, because a dead controller fails silently — tenant changes just stop
> converging with no error surfaced to anyone.**

- **Metric(s):** `up{job=…}` per monitor (exists only once the chart's monitors are the
  scrape — fact 3) **[captured-pending]**
- **SLI:** per-controller scrape liveness
- **SLO:** up ≥ 1 for each enabled controller | **SLA:** ❌ internal (symptom feeds Area 3 SLA)
- **Alert:** `MTOControllerDown` — `up == 0 or absent()` for 5m → **critical** for
  tenant / namespace / quota-intconfig / webhook; **warning** for pilot / db /
  extensions-argocd (optional components, gated by values toggles — Q4)
- **Dashboard:** top-of-glass per-controller status row

## Story 1.2 — Is leader election healthy? 📝 Draft

> **As an SRE, I want to know when a controller holds no leadership or leadership flaps,
> because a pod can be Running and scraped while doing no work at all.**

- **Metric(s):** `leader_election_master_status{name}` **[cr-default — verify at
  capture; defer the story if absent]**
- **SLI:** leader held per controller; leadership transitions over 1h
- **SLO:** exactly one leader per controller, < 3 transitions/h (placeholder) | **SLA:** ❌
- **Alert:** `MTOLeaderElectionLost` — max by controller == 0 for 10m → critical;
  flapping variant warning
- **Dashboard:** leadership status + transitions timeline

# Capability Area 2 — Admission webhooks (the tenancy enforcement point)

Fact 5: the webhook pod is where tenancy is *enforced*. Down, it simultaneously blocks
the admin plane (`Fail` policies) and silently stops guarding namespaces/rolebindings
(`Ignore` policies). This area is the chart's reason to exist.

## Story 2.1 — Is the webhook unavailable? 📝 Draft

> **As an SRE, I want an immediate page when the MTO webhook stops serving, because
> every Tenant/Quota/IntegrationConfig write in the cluster is being rejected (Fail
> policies) at that moment.**

- **Metric(s):** `up{job=<webhook monitor>}` — **requires a scrape surface the bundle
  does not provide** (no metrics Service on the webhook deployment — Q1)
- **SLI:** webhook scrape liveness
- **SLO:** up ≥ 1 | **SLA:** ✅ candidate
- **Alert:** `MTOWebhookDown` — 2m → **critical**
- **Dashboard:** webhook status + request-rate panel

## Story 2.2 — Are tenancy guardrails silently bypassed? 📝 Draft

> **As a platform owner, I want the webhook-down condition framed as a security event,
> because with `failurePolicy: Ignore` on the namespace and rolebinding validators an
> outage means requests are being admitted unvalidated — nobody sees tenancy isolation
> not being enforced.**

- **Metric(s):** same signal as 2.1; `apiserver_admission_webhook_rejection_count`
  would prove actual bypass but is platform-only **[ksm — dashboard candidate, no alert]**
- **Deliverable:** this story sharpens 2.1's severity/annotations (runbook text: "while
  this fires, namespace/rolebinding changes are NOT validated") rather than adding a
  second alert — kept separate so the *why* survives review.

## Story 2.3 — Is the webhook slow? 📝 Draft

> **As an SRE, I want to know when admission latency degrades, because the webhook sits
> in the write path of namespaces and rolebindings cluster-wide — its latency is
> everyone's latency.**

- **Metric(s):** `controller_runtime_webhook_latency_seconds` (histogram),
  `controller_runtime_webhook_requests_total{code}` **[cr-default — verify at capture]**
- **SLI:** p99 admission latency; 5xx ratio
- **SLO:** p99 < 1s, 5xx < 1% over 30m (placeholders) | **SLA:** ❌ internal
- **Alert:** `MTOWebhookLatencyHigh` warning; `MTOWebhookErrors` warning
- **Dashboard:** latency heatmap + per-webhook request/rejection rates

## Story 2.4 — Will the webhook cert expire or fail to reload? 📝 Draft

> **As an SRE, I want cert problems before they bite, because an expired or unreadable
> serving cert is a webhook outage with a countdown.**

- **Metric(s):** `certwatcher_read_certificate_errors_total`,
  `certwatcher_read_certificate_total` **[cr-default — verify at capture]**; expiry
  timestamp likely **[absent]** from the process — if so, defer expiry to the
  cert-manager/service-ca layer and keep only read-error alerting here.
- **Alert:** `MTOWebhookCertReadErrors` — increase over 15m → warning

# Capability Area 3 — Reconciliation convergence (is tenant state converging?)

The SLA-facing area: a Tenant/Template change must become real namespaces, RBAC and
quotas, and stay that way.

## Story 3.1 — Is a tenancy resource stuck in error? 📝 Draft

> **As an SRE, I want to know when any MTO-managed resource sits in reconcile error,
> because that is a tenant-visible promise being broken (their namespace/RBAC/template
> is not what their Tenant CR says), and today the only place it surfaces is operator
> logs.**

- **Metric(s):** `multi_tenant_operator_reconcile_error{kind,name,namespace,state} > 0`
  **[documented]** — expression must aggregate WITHOUT the `errors` label (fact 4)
- **SLI:** count of resources in error, by kind
- **SLO:** 0 sustained | **SLA:** ✅ candidate
- **Alert:** `MTOResourceReconcileError` — `count by (kind) (… > 0)` for 15m → warning,
  60m → critical (placeholders)
- **Dashboard:** errored resources table (kind/name/namespace/state)

## Story 3.2 — Are controllers erroring at rate? 📝 Draft

> **As an SRE, I want per-controller reconcile error rates, because a rising error rate
> precedes 3.1's stuck states and names the failing controller directly.**

- **Metric(s):** `controller_runtime_reconcile_errors_total{controller}`,
  `controller_runtime_reconcile_total{controller,result}` **[cr-default]**
- **SLI:** error ratio per controller over 15m
- **SLO:** < 10% (placeholder) | **SLA:** ❌ internal
- **Alert:** `MTOReconcileErrorsHigh` → warning
- **Dashboard:** per-controller reconcile rate/result stacked panel

## Story 3.3 — Is work backing up? 📝 Draft

> **As an SRE, I want queue depth and queue age per controller, because a growing or
> aging workqueue is slow tenant provisioning before anyone files a ticket.**

- **Metric(s):** `workqueue_depth{name}`, `workqueue_queue_duration_seconds_bucket{name}`,
  `workqueue_retries_total{name}` **[cr-default]**
- **SLI:** depth; p99 time-in-queue
- **SLO:** depth ~0 steady-state, p99 < 60s (placeholders) | **SLA:** ✅ candidate
  (latency half of the convergence promise)
- **Alert:** `MTOWorkqueueBacklog` — depth > N for 15m → warning
- **Dashboard:** depth + queue-age per controller

## Story 3.4 — Did a reconciler panic? 📝 Draft

> **As an SRE, I want panics surfaced, because controller-runtime recovers them and the
> controller limps on — the only trace is a counter nobody looks at.**

- **Metric(s):** `controller_runtime_reconcile_panics_total` / webhook panics
  **[cr-default — verify at capture; defer if absent]**
- **Alert:** `MTOReconcilePanics` — any increase over 1h → warning

# Capability Area 4 — Tenancy state & performance (dashboard-first)

What has MTO built, for whom, and how fast — context for every alert above. No paging.

## Story 4.1 — What is deployed per tenant? 🔨 Built (dashboard panel)

> **As a platform operator, I want to see what MTO has deployed per kind and namespace,
> because "what did the operator just change" is the first question in every incident.**

- **Metric(s):** `multi_tenant_operator_resources_deployed_total{kind,name,namespace}`,
  `…_resources_deployed{…,type}` **[documented]**
- **Dashboard:** deployed-resources by kind; per-namespace drill-down. No alert.

## Story 4.2 — Which reconciles are slow? 🔨 Built (dashboard panel)

> **As an SRE, I want the slowest reconcile targets visible, because one pathological
> Template/TGI can dominate a controller's cycle and starve the rest.**

- **Metric(s):** `multi_tenant_operator_reconcile_seconds{kind,name}` (last-duration
  gauge — no histogram, no rate) **[documented]**,
  `controller_runtime_reconcile_time_seconds_bucket` **[cr-default]**
- **Dashboard:** `topk(10, …reconcile_seconds)` + per-controller reconcile-time
  heatmap. No alert until baselined.

## Story 4.3 — Are tenants hitting their quotas? 📝 Draft — **scope question (Q3)**

> **As a platform operator, I want per-tenant quota saturation, because "tenant can't
> schedule" tickets are usually a full quota, not an MTO failure.**

- **Metric(s):** `kube_resourcequota` **[ksm — dashboard-only]**
- **Open:** arguably a *tenant*-facing concern, not the operator mechanism — may belong
  in a separate chart. Decide at approval; default is **out**.

# Capability Area 5 — Process & API-client health (dashboard-first)

## Story 5.1 — Is MTO abusing or losing the API server? 🔨 Built (dashboard panels; alert deferred to baseline)

> **As an SRE, I want client-side request/error rates per controller, because MTO at
> scale is one of the busiest API clients on the cluster, and client-side 429/5xx
> explains most "slow convergence" mysteries.**

- **Metric(s):** `rest_client_requests_total{code,method}` **[cr-default]**; Go runtime
  (`go_goroutines`, `go_memstats_*`, `process_*`) **[cr-default]**
- **Dashboard:** client error ratio, request rate, memory/goroutines per controller.
  Alert only if the capture baselines show a usable threshold (else dashboard-only).

# Capability Area 6 — Watchdog (is observability itself alive?)

## Story 6.1 — Are we blind? 📝 Draft

> **As an SRE, I want to know when MTO metrics stop arriving entirely, because every
> alert above silently stops evaluating the moment the scrape dies.**

- **Metric(s):** `absent(up{job=…})` per enabled monitor **[captured-pending]**
- **Alert:** `MTOMetricsAbsent` — 15m → warning

# Capability Area 7 — finops-operator: cost collection (the priority)

The incident class that motivated this chart: **a cost-collection CronJob stops
running, nobody notices, and FinOps — charges, invoicing, everything downstream —
silently runs on stale data.** Facts 6–8: the job's own status lives only in the
CostJob CR (written by the loader pod), `kube_cronjob_*` is un-alertable from UWM, and
the operator exports no custom metrics. So the stories below are **blocked on one
small upstream change** (Q7) — which is exactly why it is written down first.

## Story 7.1 — Is cost data fresh? 🔨 Built (chart side; live on the gauge release) — **the headline story**

> **As a FinOps/platform owner, I want a page when any CostJob's last successful
> execution is older than its interval allows, because every way this fails —
> CronJob suspended, image unpullable, quota blocking the pod, loader crash, OpenCost
> or PostgreSQL down — looks identical: data quietly stops, and billing/showback runs
> on stale numbers until a human notices weeks later.**

- **Metric(s):** `finops_costjob_last_successful_execution_timestamp_seconds{costjob,type}`
  — **[absent]: does not exist yet.** Upstream ask (Q7): the finops-operator reconciler
  already reads CostJob status; publishing it as gauges is a small change. Freshness is
  the right SLI precisely because the status goes *stale* rather than *failed* when the
  job never runs (fact 8).
- **SLI:** `time() - last_successful_execution_timestamp`, per CostJob (both types:
  ResourceCostCollection AND SubscriptionChargeCollection)
- **SLO:** age < 2× the CostJob interval (placeholder) | **SLA:** ✅ candidate — this IS
  the finops promise
- **Alert:** `MTOCostDataStale` — age > 2× interval → **critical**; plus
  `absent()` guard so a deleted/never-reconciled CostJob also fires
- **Dashboard:** per-CostJob freshness stat (green/red by age) + `kube_cronjob_status_last_successful_time` / `kube_job_status_failed` panels **[ksm — dashboard-only]**
- **Interim until upstream lands:** no honest UWM alert exists. Dashboard-only KSM
  panels + Story 7.3 (operator up) as a weak proxy. Say so loudly in the README.

## Story 7.2 — Is a CostJob failing (not just stale)? 🔨 Built (chart side; live on the gauge release)

> **As an SRE, I want to distinguish "runs but fails" from "never runs", because the
> fix differs: a failing loader points at OpenCost/PostgreSQL/credentials; a
> never-running one at the CronJob/schedule/quota.**

- **Metric(s):** `finops_costjob_last_execution_status{costjob,type,status}` or
  `finops_costjob_consecutive_failures` — **[absent]**, same upstream ask (status enum
  Success/Failed/Error already in `executionHistory`)
- **Alert:** `MTOCostJobFailing` — last status != Success for > 1 interval → warning,
  escalating critical
- **Dashboard:** execution-history table (status, duration, error)

## Story 7.3 — Is the finops-operator itself healthy? 📝 Draft

> **As an SRE, I want the generic suite (down / webhook / reconcile errors / backlog)
> on finops-operator, because its webhooks are `failurePolicy: Fail` — operator outage
> blocks every Offering/Subscription write — and its reconcile errors are the earliest
> real signal we can alert on today.**

- **Metric(s):** `up`, `controller_runtime_*`, `workqueue_*` **[cr-default — capture]**
- **Alert:** per Areas 1–3 templates: `MTOFinopsOperatorDown` critical,
  webhook/reconcile/backlog warnings
- **Note:** until Q7 lands, **this is the only alertable finops signal** — it must not
  be mistaken for cost-data coverage (an operator can be perfectly healthy while its
  CronJobs rot).

## Story 7.4 — Are the cost pipeline's dependencies up? 📝 Draft

> **As an SRE, I want OpenCost (the data source) and the finops PostgreSQL (the sink)
> visible next to the CostJob story, because 7.1 firing with OpenCost down is a
> different incident than 7.1 firing alone.**

- **Metric(s):** OpenCost's own `/metrics` (`up{job=<opencost>}`, if UWM scrapes it —
  capture question), PostgreSQL via the existing `postgres-observability` chart
- **Open (Q8):** boundary — this chart alerts on *reachability from the finops
  perspective* at most; deep Postgres/OpenCost health belongs to their own charts.

# Capability Area 8 — hibernation-operator: sleep/wake

## Story 8.1 — Is the hibernation control plane healthy? 📝 Draft

> **As an SRE, I want the generic suite on hibernation-operator, because both its
> validators are `failurePolicy: Fail` (outage blocks supervisor CRUD) and a dead
> controller means schedules silently stop being acted on.**

- **Metric(s):** `up`, `controller_runtime_*` **[cr-default — capture]**; webhook
  metrics Service exists [bundle]
- **Alert:** `MTOHibernationOperatorDown` → critical (a tenant not woken on schedule
  is a user-facing outage), generic webhook/reconcile warnings

## Story 8.2 — Did sleep/wake actually happen on schedule? 📝 Draft

> **As a platform owner, I want to know when a supervised namespace missed its wake
> (tenant outage) or its sleep (silent cost leak), because a healthy operator that
> skips transitions is invisible today.**

- **Metric(s):** supervisor state/transition gauges (e.g.
  `hibernation_supervisor_state{supervisor}`,
  `…_last_transition_timestamp_seconds`) — **[absent]**, upstream ask alongside Q7;
  the `Ready` condition exists on the CR but no metric exposes it
- **Alert:** deferred until the metric exists; interim: Ready-condition dashboard via
  KSM custom-resource state **[ksm — only if configured; verify]**

# Capability Area 9 — template-operator-v2: template distribution

## Story 9.1 — Is template distribution healthy? 📝 Draft

> **As an SRE, I want the generic suite on template-operator-v2, because failed
> template reconciliation is tenants missing secrets/configs they were promised, and
> v2 lost the custom gauges v1 had (fact 10) — generic signals are all there is.**

- **Metric(s):** `up`, `controller_runtime_reconcile_errors_total`, `workqueue_*`
  **[cr-default — capture]**; bundle ships metrics Service + metrics-reader role
- **Alert:** `MTOTemplateOperatorDown` critical; reconcile-errors/backlog warnings

## Story 9.2 — How many TemplateInstances are out of sync? 📝 Draft

> **As a platform owner, I want a count of TemplateInstances not Synced/degraded,
> because that is the tenant-visible promise, and `phase`/`Synced` live only in CR
> status today.**

- **Metric(s):** `template_operator_instances{phase}` or per-condition gauge —
  **[absent]**, upstream ask (restoring v1-level visibility)
- **Dashboard:** phase breakdown; alert deferred until the metric exists.

---

## Open design questions (settle at the approval gate)

- **Q1 — Scrape surface. ~~Settled by live validation~~:** the chart ships
  **headless Services (one per controller deployment) + one ServiceMonitor per
  operator** + scraper RBAC. PodMonitors were tried first and failed live on the
  kind lab: `targetPort`-by-number silently matches nothing when pods declare no
  container ports (all MTO pods), and the pods share no common label for a single
  Service. Original question kept for the record below.
- **Q1 (original) — Scrape surface.** The bundle gives Services for only tenant / quota-intconfig /
  pilot. The *webhook* and *namespace* controllers — the two most alert-worthy pods —
  have none. Options: (a) ServiceMonitors for the three Services + PodMonitors for the
  rest; (b) PodMonitors for all seven (one mechanism, uniform relabeling); (c) chart
  ships its own Services. The chart must also ship the scraper RBAC (ClusterRoleBinding
  of the UWM Prometheus SA — or a chart SA + token — to MTO's `metrics-reader`
  ClusterRole). Leaning (b) + RBAC toggle, mirroring the metallb/kcp precedents.
- **Q2 — Do OperatorHub installs serve metrics at all?** Bundle args say yes (:6443),
  upstream default says no. First capture settles it; README gets a prerequisite either
  way.
- **Q3 — Scope. ~~Settled 2026-11-26~~:** the chart covers the MTO **suite of four
  operators** (tenant, finops, hibernation, template-v2 — the mechanism is the MTO
  control plane). MTO Console/Gateway stay out (separate systems). Per-tenant quota
  dashboards (4.3) still default **out** — confirm that part.
- **Q4 — Optional components.** db-controller and extensions-argocd exist only on some
  installs — their monitors/alerts sit behind per-component `enabled` toggles, default
  off?
- **Q5 — `reconcile_error` cardinality.** The `errors` label is unbounded. Chart-side:
  aggregate it away everywhere. Upstream ask: drop the label / convert the gauges to
  counters + histogram (would unlock rate-based stories in Areas 3–4).
- **Q6 — Severity map.** Which stories page (critical) vs ticket (warning), and which
  become the SLA set (2.1, 3.1, 3.3, **7.1** proposed).
- **Q7 — The upstream metrics ask (the critical path for Area 7).** finops-operator,
  hibernation-operator and template-operator-v2 export no workload metrics; the
  stories that matter most (7.1/7.2 cost freshness, 8.2 missed transitions, 9.2
  unsynced instances) are **unbuildable in UWM** until each operator publishes small
  state gauges from status it already tracks. Proposal: a shared `localmetrics`-style
  package (tenant-operator precedent) with per-CR gauges:
  `*_last_successful_execution_timestamp_seconds`, `*_last_execution_status`,
  state/condition gauges. File the upstream issues at approval time; sequence the
  chart so generic stories (Areas 1–3 per operator) ship first and the [absent]
  stories land as the operators do.
- **Q8 — Dependency boundary for the cost pipeline.** How far does this chart reach
  toward OpenCost and PostgreSQL (7.4): reachability-only here, deep health in their
  own charts (postgres-observability exists) — confirm.
- **Q9 — Where do the rules evaluate: UWM or the platform stack?** A parallel
  incident-driven effort drafted finops job alerts on KSM/kubelet series shipped
  platform-side, where those series ARE alertable (fact 6). One home per alert, no
  duplicate paging: decide which alerts live in this chart (UWM, operator-gauge-based)
  vs platform-side rule packs, and fold the drafted rules into that split.
