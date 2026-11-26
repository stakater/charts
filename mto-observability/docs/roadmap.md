# MTO Observability Roadmap

**Status:** 📝 **Draft — awaiting live metrics capture and story approval.** Nothing below
is built: this chart ships no rules, monitors or dashboard until stories pass the human
approval gate AND every metric they use is verified against a capture from a real cluster
(`tests/METRICS-CAPTURE.md`). The facts in this draft come from the Multi Tenant Operator
**v1.10.x OLM bundle manifests** and the **published MTO documentation**
(Reference → Metrics), not from a live scrape — label shapes and lazily-registered
families must be confirmed before any expression is trusted.
**Owner:** Platform / SRE

---

## How to read this document

Organized **by user story**: need → measurement → target → alert → dashboard.

Lifecycle: 📝 Draft → 👍 Approved (human gate) → 🔨 In progress → ✅ Done. Approval is
per story; killing a weak Draft here is the method working.

### Metric reality (the discipline)

- **[captured]** — in `tests/fixtures/` with the exact labels stated. **None yet.**
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
2. **The metrics endpoint is authenticated HTTPS** **[documented]**: container port
   `:6443`, requests authenticated/authorized against the Kubernetes API
   (TokenReview + SubjectAccessReview) — a scraper must present a token bound to the
   `metrics-reader` ClusterRole. The serving cert is self-signed unless a cert is
   configured, so scrapes need `insecureSkipVerify` (or a configured CA). Upstream
   default is metrics **disabled** (`--metrics-bind-address=0`); the OLM bundle enables
   it — whether a given install serves metrics at all is a capture-time check.
3. **Only three metrics Services exist** **[bundle]**: `…-tenant-metrics-service`,
   `…-quota-intconfig-metrics-service`, `…-pilot-metrics-service` (port 8443 → named
   port `https`). The namespace, webhook, db and extensions deployments expose the pod
   port only. The ServiceMonitor in MTO's kustomize config is **not** in the OLM bundle —
   **on an OperatorHub install nothing scrapes MTO until this chart does.**
4. **Custom metrics are five GAUGES under `multi_tenant_operator_*`** **[documented]**:
   `resources_deployed_total{kind,name,namespace}`,
   `resources_deployed{kind,name,namespace,type}`,
   `reconcile_error{kind,name,namespace,state,errors}`, `reconcile_count{kind,name}`,
   `reconcile_seconds{kind,name}`. All gauges — `rate()` applies to **none** of them,
   including the `_total`-suffixed ones. `reconcile_error` carries the **error text in a
   label** (unbounded cardinality: alert on presence, never aggregate across `errors`).
   Which deployment exports which family is unknown until capture — the emitting code
   paths sit in the tenant-side reconcilers, so expect them on the tenant controller and
   possibly nowhere else.
5. **Webhook failure policies split in two** **[bundle]**: `failurePolicy: Fail` on the
   Tenant, Quota and IntegrationConfig validators — webhook down ⇒ **every tenancy
   admin-plane write is rejected cluster-wide**. `failurePolicy: Ignore` on the
   namespace and rolebinding validators — webhook down ⇒ those requests are admitted
   **unvalidated**: a silent tenancy-guardrail bypass. One outage, two very different
   blast radii; both argue the webhook is the single most alert-worthy component.
6. **UWM evaluation constraint**: alerts render only from series UWM itself scrapes.
   Platform families (`apiserver_admission_webhook_*`, kube-state-metrics) are
   dashboard-only here **[ksm]**.

### The SLI / SLO / SLA distinction

- **SLI** — the measurement. **SLO** — internal target with an error budget; pages
  on-call. **SLA** — externally promised, only a few, looser than the SLO.
- MTO's customer-facing promise is: *a tenant change (Tenant/Template/Quota) converges to
  real namespaces, RBAC and quotas promptly — and tenancy boundaries stay enforced.*
  Areas 2 and 3 are the SLA candidates; everything else is internal.

> **Calibration:** every numeric target below is a **placeholder** until 2–4 weeks of
> live baseline on a real cluster.

---

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

## Story 4.1 — What is deployed per tenant? 📝 Draft

> **As a platform operator, I want to see what MTO has deployed per kind and namespace,
> because "what did the operator just change" is the first question in every incident.**

- **Metric(s):** `multi_tenant_operator_resources_deployed_total{kind,name,namespace}`,
  `…_resources_deployed{…,type}` **[documented]**
- **Dashboard:** deployed-resources by kind; per-namespace drill-down. No alert.

## Story 4.2 — Which reconciles are slow? 📝 Draft

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

## Story 5.1 — Is MTO abusing or losing the API server? 📝 Draft

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

---

## Open design questions (settle at the approval gate)

- **Q1 — Scrape surface.** The bundle gives Services for only tenant / quota-intconfig /
  pilot. The *webhook* and *namespace* controllers — the two most alert-worthy pods —
  have none. Options: (a) ServiceMonitors for the three Services + PodMonitors for the
  rest; (b) PodMonitors for all seven (one mechanism, uniform relabeling); (c) chart
  ships its own Services. The chart must also ship the scraper RBAC (ClusterRoleBinding
  of the UWM Prometheus SA — or a chart SA + token — to MTO's `metrics-reader`
  ClusterRole). Leaning (b) + RBAC toggle, mirroring the metallb/kcp precedents.
- **Q2 — Do OperatorHub installs serve metrics at all?** Bundle args say yes (:6443),
  upstream default says no. First capture settles it; README gets a prerequisite either
  way.
- **Q3 — Scope.** One chart, one mechanism: the MTO **operator** (controllers +
  webhook). MTO Console/Gateway are separate systems → separate chart if wanted.
  Per-tenant quota dashboards (4.3) default **out**. Confirm.
- **Q4 — Optional components.** db-controller and extensions-argocd exist only on some
  installs — their monitors/alerts sit behind per-component `enabled` toggles, default
  off?
- **Q5 — `reconcile_error` cardinality.** The `errors` label is unbounded. Chart-side:
  aggregate it away everywhere. Upstream ask: drop the label / convert the gauges to
  counters + histogram (would unlock rate-based stories in Areas 3–4).
- **Q6 — Severity map.** Which stories page (critical) vs ticket (warning), and which
  become the SLA set (2.1, 3.1, 3.3 proposed).
