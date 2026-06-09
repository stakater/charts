# Crossplane Observability Roadmap — Stakater Cloud

**Status:** Draft for review
**Current Crossplane version:** v2.1.3
**Target version:** v2.3 (stepwise: 2.1.3 → 2.2 → 2.3)
**Owner:** Platform / SRE

---

## How to read this document

This roadmap is organized **by user story**. Each capability below starts with what
someone operating the platform actually needs, and *why*. Everything else — the metric
that answers it, how we judge good-vs-bad (SLI/SLO/SLA), the alert, the dashboard, and
when we can have it — hangs off that need.

Read each story top to bottom as: **need → measurement → target → alert → dashboard → availability.**

### The SLI / SLO / SLA distinction (read once, applies throughout)

- **SLI** — the *measurement*. What the metric actually computes (e.g. "% of managed
  resources in Ready=True"). Defined for every story; it is what turns a raw metric into
  a good-vs-bad signal.
- **SLO** — our *internal target* with an error budget. This is what pages on-call and
  what governs whether we ship features or fix reliability. Defined for every story.
- **SLA** — an *externally promised* threshold with contractual consequences. Defined for
  **only a few** stories, and always **looser than the SLO**. The gap between SLO and SLA
  is our early-warning safety margin. We deliberately do **not** turn internal
  control-plane health into customer-facing SLAs.

> **Calibration note:** Every numeric target below is a **placeholder**. Run 2–4 weeks
> against real baseline before committing any SLA number. For a multi-tenant platform,
> SLA targets must be **per-tier and per-resource-class** — a flat promise across a
> lightweight `Object` and a multi-AZ RDS cluster is unkeepable.

### Availability legend

- **🟢 Now (2.1.3)** — works on our current version today.
- **🔵 After upgrade** — requires upgrade to 2.2/2.3; confirm on the actual build.
- **🟡 Now, conditional** — works now but only for a subset (e.g. Upjet providers).

---

# Capability Area 1 — Customer-Facing Resource Health

These stories map most directly to what a customer perceives. Most of our SLA candidates
live here.

## Story 1.1 — Is a customer's resource actually healthy?

> **As an SRE, I want to know when a managed resource has provisioned but is not healthy,
> because a customer's infrastructure may exist while being unusable — and that is invisible
> in a simple "does it exist" check.**

- **Metric(s):** `crossplane_managed_resource_ready`, `crossplane_managed_resource_synced`
- **Source:** Provider (any crossplane-runtime provider)
- **SLI:** % of managed resources in `Ready=True` over total, per tenant
- **SLO:** ≥ 99.5% of MRs Ready over rolling 30 days
- **SLA:** ✅ **Yes** — "your managed resources reach a healthy state" is core platform value
- **Alert:** `MRNotReady` (`== 0` for 15m → warning); `MRNotReadyCritical` (1h → critical)
- **Dashboard:** MR-state row — not-ready / not-synced table, grouped by namespace + kind
- **Availability:** 🟢 Now (2.1.3)

## Story 1.2 — How fast do resources come up?

> **As an SRE, I want to know how long resources take to become ready, because slow
> provisioning is a customer-visible SLA breach even when nothing has "failed."**

- **Metric(s):** `crossplane_managed_resource_first_time_to_readiness_seconds` (native TTR,
  all providers). **On Upjet providers, prefer `upjet_resource_ttr`** — it is more accurate
  for async resources, where the native metric can report readiness before the external
  resource is truly available.
- **Source:** Provider (all providers — native; Upjet providers additionally expose the more
  accurate Upjet TTR)
- **SLI:** p95 time from MR creation → `Ready=True`
- **SLO:** p95 ≤ 5 min, p99 ≤ 15 min — **per resource class**
- **SLA:** ✅ **Yes**, but segmented per resource class (a VPC ≠ an RDS cluster)
- **Alert:** `TTRDegraded` (p95 above SLO for 30m → warning)
- **Dashboard:** TTR p50/p95/p99 histogram, split by provider / kind
- **Availability:** 🟢 Now (2.1.3)

## Story 1.3 — Does the whole thing the customer asked for actually work? (headline SLA)

> **As an SRE, I want to know when a customer's full Claim → XR → MR tree is ready as a
> single signal, because that end-to-end state is what the customer actually experiences —
> not the readiness of any individual leaf resource.**

- **Metric(s):** *Derived* — composed in PromQL from the per-layer `_ready` metrics in
  Stories 1.1 and 4.2
- **Source:** RSM + provider metrics, combined via a Prometheus recording rule
- **SLI:** p95 time for the full Claim → XR → MR tree to reach fully-ready
- **SLO:** p95 ≤ tier target — set **meaningfully tighter than the published SLA**
  (e.g. publish 10 min, run internal SLO at 6 min) to burn error budget *before* a breach
- **SLA:** ✅ **Yes — this is the truest customer-experience SLA; treat it as the headline.**
- **Alert:** `ClaimTreeNotReady` (recording rule + alert)
- **Dashboard:** Top-of-glass composite SLO panel
- **Availability:** 🟢 Now (2.1.3) — build-it-yourself recording rule

---

# Capability Area 2 — Control-Plane Health (Internal)

These stories are **leading indicators**. They should page on-call *before* a
customer-facing SLA (Area 1) moves. None of them are SLA candidates — they are the
early-warning margin that protects the SLAs.

## Story 2.1 — Is the controller failing its reconcile loop?

> **As an SRE, I want to know when the reconcile error rate rises, because climbing errors
> precede stalled provisioning and predict a customer-facing failure.**

- **Metric(s):** `controller_runtime_reconcile_errors_total`,
  `controller_runtime_reconcile_total{result}`
- **Source:** controller-runtime (core + providers)
- **SLI:** error reconciles / total reconciles
- **SLO:** < 1% error ratio over 1h
- **SLA:** ❌ No — leading indicator, not a customer promise
- **Alert:** `ReconcileErrorRateHigh` (rate above threshold for 10m)
- **Dashboard:** Reconcile rate + error rate, per controller
- **Availability:** 🟢 Now (2.1.3)

## Story 2.2 — Are reconciles slowing down?

> **As an SRE, I want to know when reconcile latency climbs, because it signals provider or
> cloud-API degradation before it becomes a TTR breach.**

- **Metric(s):** `controller_runtime_reconcile_time_seconds_bucket`
- **Source:** controller-runtime
- **SLI:** p99 reconcile duration per controller
- **SLO:** p99 ≤ X s (baseline-calibrated)
- **SLA:** ❌ No — internal
- **Alert:** `ReconcileLatencyHigh` (p99 spike for 15m)
- **Dashboard:** Reconcile latency p50/p95/p99
- **Availability:** 🟢 Now (2.1.3)

## Story 2.3 — Can the controller keep up with demand?

> **As an SRE, I want to know when the work queue grows unbounded, because a growing backlog
> means customer requests are piling up faster than we can service them.**

- **Metric(s):** `workqueue_depth`, `workqueue_adds_total`,
  `workqueue_unfinished_work_seconds`
- **Source:** controller-runtime
- **SLI:** sustained queue depth / unfinished work seconds
- **SLO:** depth returns to baseline within 15m
- **SLA:** ❌ No — capacity signal
- **Alert:** `WorkqueueDepthGrowing` (sustained climb for 15m)
- **Dashboard:** Queue depth + add rate + unfinished work
- **Availability:** 🟢 Now (2.1.3)

## Story 2.4 — Is the Crossplane API layer up?

> **As an SRE, I want to know immediately if the Crossplane aggregated API is unavailable,
> because if it is down, nothing in the platform works.**

- **Metric(s):** `aggregator_unavailable_apiservice{name=~"crossplane.*"}`
- **Source:** kube-apiserver
- **SLI:** Crossplane aggregated API uptime
- **SLO:** 99.95% over 30 days
- **SLA:** ✅ **Yes** — this *is* the control-plane availability SLA
- **Alert:** `APIServiceUnavailable` (5m → critical)
- **Dashboard:** API health row
- **Availability:** 🟢 Now (2.1.3)

## Story 2.5 — How quickly do we even notice a new resource?

> **As an SRE, I want to know the time from resource creation to first detection, because
> detection lag points to watch/informer problems upstream of provisioning.**

- **Metric(s):** `crossplane_managed_resource_first_time_to_reconcile_seconds`
- **Source:** Provider
- **SLI:** p95 create → first detection
- **SLO:** p95 ≤ 30s
- **SLA:** ❌ No — internal
- **Alert:** `DetectionLagHigh`
- **Dashboard:** Detection-time panel beside TTR
- **Availability:** 🟢 Now (2.1.3)

---

# Capability Area 3 — Correctness & Drift

## Story 3.1 — Has a resource drifted from its desired state?

> **As an SRE, I want to know when a managed resource drifts out of sync, because silent
> drift means configuration we believe is enforced actually is not.**

- **Metric(s):** `crossplane_managed_resource_drift_seconds`
- **Source:** Provider
- **SLI:** time-out-of-sync before detection
- **SLO:** detect drift within one reconcile interval, 99% of the time
- **SLA:** ❌ No — internal correctness signal
- **Alert:** `DriftDetected` (above threshold)
- **Dashboard:** Drift heatmap by kind
- **Availability:** 🟢 Now (2.1.3)

---

# Capability Area 4 — Fleet Inventory & Multi-Tenancy

## Story 4.1 — What is running, and how much of it is healthy fleet-wide?

> **As an SRE, I want a per-kind / Claim / Composition inventory with ready-synced rollups,
> because I need fleet-wide and per-tenant health, not just per-pod metrics.**

- **Metric(s):** Exporter-generated XRD / Composition / **Claim** inventory + counts, with
  claim-namespace labels. *(Leaf-MR ready/synced now comes natively from providers — see
  Stories 1.1/1.2 — so the exporter is needed only for the composite/claim/inventory layer
  that providers do not self-report.)*
- **Source:** **KSM Custom Resource State (lean here until RSM maturity is confirmed)**, or
  `resource-state-metrics` (RSM) once verified. See Decision 1.
- **SLI:** fleet-wide ready ratio, per tenant / kind; XRD/Composition/Claim counts
- **SLO:** ≥ 99.5% ready (rolls up into Story 1.1)
- **SLA:** Reports against the Story 1.1 SLA (not its own line)
- **Alert:** `ClaimNotReady`, fleet ready-ratio alerts
- **Dashboard:** Overview row — XRD / Composition / Claim counts + ready ratios
- **Availability:** 🟢 Now (2.1.3) — RSM reads CRD status, so it is version-independent

## Story 4.2 — Can one noisy tenant starve everyone else? (multi-tenant protection)

> **As an SRE, I want to know when a single XR is thrashing (reconcile storm), because in a
> multi-tenant platform a runaway XR can saturate the control plane and starve other
> tenants' reconciles.**

- **Metric(s):** `circuit_breaker_events_total{result="Dropped"}`,
  `circuit_breaker_opens_total`
- **Source:** Crossplane core circuit breaker
- **SLI:** % of watch events dropped per XRD
- **SLO:** < 0.1% dropped; tenant isolation maintained
- **SLA:** ✅ **Yes (indirect)** — protects the multi-tenant "noisy-neighbor" guarantee
- **Alert (upstream-published, use verbatim):**
  - `CircuitBreakerDropRatioHigh` — > 20% events dropped for 5m → critical
  - `CircuitBreakerFrequentOpens` — > 6 opens/hr for 15m → warning
- **Dashboard:** Thrashing row — drop ratio + opens per controller
- **Availability:** 🔵 After upgrade — circuit breaker *mechanism* runs on 2.1.x, but treat
  its Prometheus *metrics* as confirm-on-build, guaranteed after upgrade to 2.2/2.3.
  **This is a primary reason to prioritize the upgrade for a multi-tenant offering.**

---

# Capability Area 5 — Composition / Function Pipeline (Upgrade Payoff)

Composition functions are arbitrary code in the provisioning path and a hidden failure
point. On 2.1.3 we are largely blind here; the upgrade closes this gap natively.

## Story 5.1 — Is a composition function slow or erroring?

> **As an SRE, I want to know when a composition function is slow or failing, because
> functions run custom code during provisioning and a hidden failure there surfaces only as
> a generic reconcile error with no indication of which function.**

- **Metric(s):** `function_run_function_seconds`, `function_run_function_response_total`
- **Source:** Crossplane core
- **SLI:** function execution p95; function error ratio
- **SLO:** p95 ≤ X s; errors < 0.5%
- **SLA:** ❌ No — internal pipeline health
- **Alert:** `FunctionLatencyHigh`, `FunctionErrorRate`
- **Dashboard:** Composition / function pipeline row
- **Availability:** 🔵 After upgrade (confirm on build; guaranteed 2.2/2.3)

## Story 5.2 — Is the function response cache healthy?

> **As an SRE, I want to know the function response cache hit ratio, because cache misses and
> errors silently inflate reconcile latency.**

- **Metric(s):** `function_run_function_response_cache_{hits,misses,errors}_total`
- **Source:** Crossplane core
- **SLI:** cache hit ratio
- **SLO:** ≥ 90% hit ratio
- **SLA:** ❌ No — efficiency signal
- **Alert:** `FunctionCacheErrorRate`
- **Dashboard:** Cache hit-ratio panel
- **Availability:** 🔵 After upgrade

---

# Capability Area 6 — Cloud Provider Interaction

## Story 6.1 — Are we hitting cloud rate limits?

> **As an SRE, I want to know when we are being throttled by the cloud provider, because
> throttling at the cloud SDK is the root cause behind many latency and TTR alerts — and
> it is upstream of us.**

- **Metric(s):** `upjet_resource_ext_api_duration`,
  `upjet_resource_external_api_calls_total`, `upjet_resource_reconcile_delay_seconds`
- **Source:** Upjet providers only
- **SLI:** reconcile delay vs configured poll period
- **SLO:** delay < poll interval, 95% of the time
- **SLA:** ❌ **No — never SLA this.** The failure is upstream of us (the cloud provider);
  promising a contractual threshold on something we don't control is a trap.
- **Alert:** `CloudAPIThrottling` (delay rising)
- **Dashboard:** Upjet diagnostics row (variable-gated so it stays empty/ hidden for
  native providers)
- **Availability:** 🟡 Now (2.1.3), Upjet providers only

---

# Capability Area 7 — Resource Footprint

## Story 7.1 — Is a provider pod crashing or OOMing?

> **As an SRE, I want to know when a provider pod is restarting or hitting OOM, because a
> dead provider silently stops all of its reconciles.**

- **Metric(s):** `kube_pod_container_status_restarts_total`,
  `container_memory_working_set_bytes`
- **Source:** kube-state-metrics + cAdvisor
- **SLI:** restart count per provider per 1h
- **SLO:** 0 unexpected restarts; provider availability ≥ 99.9%
- **SLA:** Indirect — feeds the Story 2.4 control-plane availability SLA, not its own line
- **Alert:** `ProviderPodRestarting`, `ProviderPodOOM`
- **Dashboard:** Provider pod CPU / mem / restarts
- **Availability:** 🟢 Now (2.1.3)

## Story 7.2 — Is a provider under-provisioned?

> **As an SRE, I want to know when a provider is being CPU-throttled, because
> under-provisioning shows up as mysterious slowness rather than an outright failure.**

- **Metric(s):** `container_cpu_cfs_throttled_periods_total`
- **Source:** cAdvisor
- **SLI:** % of time throttled
- **SLO:** < 1% throttled
- **SLA:** ❌ No — right-sizing signal
- **Alert:** `ProviderPodCPUThrottled` (15m → info)
- **Dashboard:** Throttling panel in saturation row
- **Availability:** 🟢 Now (2.1.3)

---

# Phasing Summary

| Phase | What we get | Stories |
|---|---|---|
| **Phase 1 — Now (2.1.3)** | ~75% coverage, including everything customer-facing | 1.1, 1.2, 1.3, 2.1–2.5, 3.1, 4.1, 6.1, 7.1, 7.2 |
| **Phase 2 — After upgrade (2.2/2.3)** | Function-pipeline visibility + multi-tenant thrashing protection | 4.2, 5.1, 5.2 |

We are **not blind** on 2.1.3 — every customer-facing story is achievable today. The
upgrade payoff is specifically (a) seeing inside the composition/function pipeline and
(b) reconciliation-thrashing protection, which matters most because Stakater Cloud is
multi-tenant.

---

# Open Decisions & Verification Steps

## Decision 1 — How do we get MR-state and inventory metrics? (RESEARCHED — scope narrowed)

**Finding that changes this decision:** Providers now emit MR-state metrics *natively*.
As of upjet v1.3.0 / provider-upjet-aws v1.4.0 (and the equivalent crossplane-runtime
change, PR #683), every crossplane-runtime provider exports the
`crossplane_managed_resource_*` family — ready, synced, TTR, drift — directly on its
`/metrics` port. **We do not need an external exporter for leaf-MR readiness, TTR, or
drift** (Stories 1.1, 1.2, 1.3-inputs, 3.1). Those just need provider metrics enabled
(`PodMonitor` or annotations on the provider `DeploymentRuntimeConfig`).

**Accuracy detail for Story 1.2:** for *async* resources on Upjet providers,
`upjet_resource_ttr` is a more accurate readiness measure than
`crossplane_managed_resource_first_time_to_readiness_seconds`. → Prefer Upjet TTR on Upjet
providers; use the native `crossplane_managed_resource_*` TTR as the cross-provider fallback.

**What an exporter is *still* needed for (the narrowed scope):** XRD / Composition / Claim
**inventory and counts**, and **Claim-level** readiness with claim-namespace labels — i.e.
the composite/claim layer that providers do not self-report. This is Story 4.1 and feeds 1.3.

**The remaining choice (lower stakes now):**

| Option | Pros | Cons |
|---|---|---|
| **`resource-state-metrics` (RSM)** | Community-blessed direction (x-metrics archived in its favor, proposal #6865); Crossplane-aware; built on upstream K8s SIG-Instrumentation RSM | ⚠️ **Maturity unconfirmed** — could not verify current release/stability; adopting a young exporter for production multi-tenant is a real risk |
| **KSM Custom Resource State (CRS)** | No new component (we already run KSM); fully under our control; battle-tested machinery | We hand-author the CRS config; less Crossplane-aware out of the box |

**⚠️ Open — needs hands-on verification:** Confirm RSM's current maturity (latest release,
tag, production adopters, open critical issues) before choosing it. **Until confirmed, lean
KSM-CRS** for the inventory/claim layer, since the scope is now small enough that a
hand-authored CRS config is low-effort and avoids taking a dependency on an unproven exporter.

## Decision 2 — What is actually in our 2.1.3 build? (verify hands-on)

Enable `--set metrics.enabled=true`, then `curl` the core pod `/metrics` and grep for:
- `function_run_` → tells us if Stories 5.1 / 5.2 are available now or strictly post-upgrade
- `circuit_breaker_` → tells us if Story 4.2 is available now or post-upgrade
- `crossplane_managed_resource_` on each provider pod → confirms Stories 1.1–1.3, 3.1 are live

This replaces doc-version inference with ground truth from our exact build.

## Other verification steps

3. **Re-validate exporter config after each CRD migration** — upgrading minor versions
   migrates stored CRD versions, which can change the series labels in Story 4.1.
4. **Calibrate all SLA numbers** over 2–4 weeks of real baseline before committing; segment
   per tier and per resource class.

---

# Master Summary Table

Every story in one scannable view. Stories for understanding (above); this table for
comparison. SLA column is the one to scan first — note how few rows are `Yes`.

| Story | Need (1-line) | Metric | Source | SLI | SLO | SLA? | Alert | Dashboard | Available |
|---|---|---|---|---|---|---|---|---|---|
| 1.1 | MR healthy, not just exists | `crossplane_managed_resource_ready` / `_synced` | Provider | % MRs Ready / total, per tenant | ≥ 99.5% over 30d | ✅ Yes | MRNotReady / Critical | MR-state table | 🟢 Now |
| 1.2 | How fast resources come up | `..._first_time_to_readiness_seconds`; Upjet: `upjet_resource_ttr` | Provider | p95 create→Ready | p95 ≤ 5m, p99 ≤ 15m per class | ✅ Yes (per class) | TTRDegraded | TTR histogram | 🟢 Now |
| 1.3 | Whole Claim→XR→MR tree ready (**headline**) | *derived* recording rule | RSM/KSM + provider | p95 full-tree ready | tighter than published SLA | ✅ **Headline** | ClaimTreeNotReady | Top-of-glass SLO | 🟢 Now |
| 2.1 | Controller failing reconcile loop | `controller_runtime_reconcile_errors_total` | controller-runtime | errors / total | < 1% over 1h | ❌ No | ReconcileErrorRateHigh | Reconcile rate+errors | 🟢 Now |
| 2.2 | Reconciles slowing down | `controller_runtime_reconcile_time_seconds` | controller-runtime | p99 duration | p99 ≤ X s | ❌ No | ReconcileLatencyHigh | Latency p50/95/99 | 🟢 Now |
| 2.3 | Controller can't keep up | `workqueue_depth`, `_unfinished_work_seconds` | controller-runtime | sustained depth | baseline within 15m | ❌ No | WorkqueueDepthGrowing | Queue depth+adds | 🟢 Now |
| 2.4 | API layer down | `aggregator_unavailable_apiservice` | kube-apiserver | aggregated API uptime | 99.95% over 30d | ✅ Yes | APIServiceUnavailable | API health | 🟢 Now |
| 2.5 | How fast we notice a resource | `..._first_time_to_reconcile_seconds` | Provider | p95 create→detect | p95 ≤ 30s | ❌ No | DetectionLagHigh | Detection-time | 🟢 Now |
| 3.1 | Resource drifted from desired | `crossplane_managed_resource_drift_seconds` | Provider | time-out-of-sync before detect | within 1 interval, 99% | ❌ No | DriftDetected | Drift heatmap | 🟢 Now |
| 4.1 | Fleet inventory + readiness | exporter Claim/XRD/Composition counts | KSM-CRS / RSM | fleet ready ratio per tenant | ≥ 99.5% (rolls to 1.1) | Reports to 1.1 | ClaimNotReady | Overview counts+ratios | 🟢 Now |
| 4.2 | Noisy tenant starving others | `circuit_breaker_events_total{result="Dropped"}` | Core circuit breaker | % events dropped per XRD | < 0.1% dropped | ✅ Yes (indirect) | CircuitBreakerDropRatioHigh / FrequentOpens | Thrashing row | 🔵 Upgrade |
| 5.1 | Function slow/erroring | `function_run_function_seconds`, `_response_total` | Core | function p95, error ratio | p95 ≤ X s, < 0.5% | ❌ No | FunctionLatencyHigh / ErrorRate | Function pipeline | 🔵 Upgrade |
| 5.2 | Function cache healthy | `..._cache_{hits,misses,errors}_total` | Core | cache hit ratio | ≥ 90% | ❌ No | FunctionCacheErrorRate | Cache hit-ratio | 🔵 Upgrade |
| 6.1 | Hitting cloud rate limits | `upjet_resource_reconcile_delay_seconds`, `_external_api_calls_total` | Upjet only | delay vs poll period | delay < interval, 95% | ❌ **Never** (upstream) | CloudAPIThrottling | Upjet diagnostics | 🟡 Now (Upjet) |
| 7.1 | Provider pod crashing/OOM | `kube_pod_container_status_restarts_total` | KSM + cAdvisor | restarts per provider/1h | 0 unexpected; ≥ 99.9% avail | Indirect (→2.4) | ProviderPodRestarting / OOM | Pod CPU/mem/restarts | 🟢 Now |
| 7.2 | Provider under-provisioned | `container_cpu_cfs_throttled_periods_total` | cAdvisor | % time throttled | < 1% | ❌ No | ProviderPodCPUThrottled | Throttling panel | 🟢 Now |

**Legend:** 🟢 Now (2.1.3) · 🔵 After upgrade (2.2/2.3) · 🟡 Now, Upjet providers only

**SLA candidates (scan):** only 1.1, 1.2, 1.3, 2.4, 4.2 — everything else is an internal
SLI/SLO that exists to protect those. Story 6.1 is explicitly *never* an SLA (failure is
upstream at the cloud provider).

---

# Next Deliverables (not yet built)

- **Phased `PrometheusRule` set** — Phase 1 (2.1.3) and Phase 2 (post-upgrade) alerts,
  with SLO-burn thresholds rather than arbitrary cutoffs.
- **SLO recording rules** — so error-budget burn is directly queryable.
- **RSM (or KSM-CRS) exporter config** for Story 4.1, regex-based (not a hardcoded CRD list).
- **Consolidated Grafana dashboard JSON** — Phase 2 rows pre-built but variable-gated so
  they light up the moment we upgrade, with no dashboard rework.
