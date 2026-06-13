# Dashboard panels — what each one is for

Why every panel on the **Crossplane Observability** Grafana dashboard exists, what an SRE
reads from it, and **what you'd be blind to without it**. Panels map to the roadmap user
stories (`docs/roadmap.md`); thresholds match the alert thresholds in `values.yaml`, so a
tile/line turns red exactly when its alert would fire.

**Reading order:** top-down. Row 1 (Overview) tells you *if* something is wrong and roughly
*where*; the rows below tell you *why*. Filters at the top: `$datasource` and `$gvk` (managed
resource kind).

**Conventions:** stat tiles colour the whole tile (green/amber/red); timeseries keep
per-series colours and draw a red SLO guide line at the threshold; the resource-health table
colours its cells.

---

## Row 1 — Overview / SLO (top-of-glass)

Four numbers you can read across the room. Green here = you can stop looking.

| Panel | What it shows | Why it matters / blind spot without it |
| --- | --- | --- |
| **Fleet MR Ready ratio** (red < 99.5%) | `ready/exists` across all managed resources | One-glance fleet health. **Without it:** no single "are we healthy?" number — you'd eyeball dozens of kinds. |
| **Claim tree p95 TTR** (red ≥ 360s) | p95 time for provisioning to reach ready | The headline customer-experience SLO. **Without it:** you only learn provisioning is slow when a customer complains. |
| **Crossplane API available** (red = DOWN) | aggregated API up/down | If this is down, *nothing* reconciles. **Without it:** a control-plane outage looks like "everything is slow" with no obvious cause. |
| **MRs not ready** (red ≥ 5) | absolute count of `exists − ready` | The blast radius right now. **Without it:** you see a ratio dip but not *how many* resources are affected. |

## Row 2 — Resource Health (Stories 1.1, 1.2)

| Panel | What it shows | Why it matters / blind spot without it |
| --- | --- | --- |
| **Not-ready / not-synced by GVK** (table, red ≥ 5) | per-kind counts where `exists > ready` / `exists > synced` | *Which kind* is unhealthy, and ready-vs-synced (synced=False usually means an auth/API push failure, not a slow cloud). **Without it:** you know the fleet ratio dipped but not which kind or whether it's a provisioning vs sync problem. |
| **Time-to-readiness p50/p95/p99 by kind** (red ≥ 300s) | provisioning latency distribution | p50 fine but p99 huge = a tail of stuck resources. Your SLA evidence for "slow provisioning." **Without it:** averages hide the stuck-resource tail. |

## Row 3 — Control Plane (Stories 2.1–2.5) — the leading indicators

These move *before* the customer-facing numbers do — they tell you *why* trouble is coming.

| Panel | What it shows | Why it matters / blind spot without it |
| --- | --- | --- |
| **Reconcile rate & error ratio** (error line red ≥ 1%) | reconciles/s per controller + error ratio | Earliest "trouble's coming" signal — climbing errors precede stalled provisioning. **Without it:** you only see the failure after resources are already stuck. |
| **Reconcile latency p50/p95/p99** (red ≥ 30s) | controller reconcile duration | Controllers slowing = provider/cloud-API degradation upstream. **Without it:** a TTR breach with no explanation of where the time went. |
| **Workqueue depth & add rate** | backlog + arrival rate | Depth climbing and not draining = you can't keep up with demand. **Without it:** capacity exhaustion looks like random slowness. |
| **Detection lag p95** (red ≥ 30s) | time from resource created → first reconcile | High = watch/informer problems, upstream of provisioning entirely. **Without it:** you'd chase the provider when the controller never even noticed the resource. |

## Row 4 — Correctness & Drift (Story 3.1)

| Panel | What it shows | Why it matters / blind spot without it |
| --- | --- | --- |
| **Time-out-of-sync (drift) by kind** (red ≥ 600s) | resources drifted from desired state | The silent one — nothing is "down," but config you believe is enforced isn't. Compliance/security signal. **Without it:** drift is invisible until an incident reveals the real state ≠ declared state. *(Empty until a drift actually occurs.)* |

## Row 5 — Fleet & Multi-tenancy (Stories 4.1, 4.2)

| Panel | What it shows | Why it matters / blind spot without it |
| --- | --- | --- |
| **Ready ratio by GVK** (red < 99.5%) | the *leaf-MR* fleet ratio broken out per kind | Shows *which* kind drags the fleet number down. **Without it:** you know the fleet dipped but not the culprit kind. |
| **Composite (XR) ready ratio by kind** (red < 99.5%) | per-XR-kind ready ratio (Story 4.1), via a **raw cross-namespace query** (not the recording rule, so it works under UWM) | The customer-facing composite layer — "are the things tenants asked for healthy." **Without it:** you only see leaf resources, never whether the composite the customer owns is actually up. |
| **Circuit-breaker drop ratio** *(Phase 2, red ≥ 20%)* | % of watch events dropped per controller | Noisy-neighbour protection — a thrashing XR starving other tenants. **Without it:** one runaway tenant degrades everyone and you can't see who. *(Dark until 2.2/2.3.)* |
| **Circuit-breaker opens / hr** *(Phase 2, red ≥ 6)* | how often the breaker trips | Repeated reconcile storms. **Without it:** intermittent control-plane saturation has no fingerprint. *(Dark until 2.2/2.3.)* |

## Row 6 — Composition / Function Pipeline *(Phase 2, collapsed)*

Composition Functions run *custom code* in the provisioning path — a hidden failure point.

| Panel | What it shows | Why it matters / blind spot without it |
| --- | --- | --- |
| **Function execution p95** (red ≥ 5s) | per-function latency | Which function is slow. **Without it:** "provisioning is slow" with no idea which function. |
| **Function error ratio** (red ≥ 0.5%) | per-function fatal-error rate (`result_severity="Fatal"`) | A failing function surfaces only as a generic reconcile error otherwise. **Without it:** you can't attribute reconcile failures to a specific function. |
| **Function cache hit ratio** (red < 90%) | response-cache effectiveness | Cache misses silently inflate reconcile latency. **Without it:** latency creeps up with no obvious cause. |

*(All dark until Functions actually run on 2.2/2.3.)*

## Row 7 — Cloud Provider Interaction *(Upjet only, collapsed)*

| Panel | What it shows | Why it matters / blind spot without it |
| --- | --- | --- |
| **Reconcile delay p95** (red ≥ 60s) | how far behind a provider is vs its poll cadence | The fingerprint of cloud-API throttling — "it's not us, AWS is rate-limiting us." **Without it:** throttling masquerades as generic provider slowness and you waste time looking in the wrong place. *(Dark unless you run Upjet providers.)* |

## Row 8 — Resource Footprint (Stories 7.1, 7.2) — is the platform itself starving?

| Panel | What it shows | Why it matters / blind spot without it |
| --- | --- | --- |
| **Provider pod restarts** (red ≥ 2/h) | restarts per provider pod | A crashing/OOMing provider silently stops *all* its reconciles. **Without it:** a dead provider looks like "nothing is provisioning" with no cause. |
| **Provider memory working set** | provider memory over time | Leak/pressure watch; pairs with restarts to explain OOMs. **Without it:** OOM kills are a surprise. |
| **Provider CPU throttled %** (red ≥ 1%) | CFS throttling per provider | Under-provisioning shows up as mysterious slowness, not failure. **Without it:** a latency row with no other explanation stays unexplained. |

---

## Known gaps (panels we don't have yet)

- **Composite (Story 4.1)** now has a panel ("Composite (XR) ready ratio by kind") *and*
  alerts (`CompositeNotReady`/`CompositeNotSynced`). On OpenShift UWM the alerts are
  **Grafana-managed** (the PrometheusRule variant is namespace-enforced) — see
  [alerting-architecture.md](alerting-architecture.md). The panel uses a raw cross-namespace
  query so it works regardless.
- **Per-tenant view.** The leaf metrics are per-GVK (no namespace) and the XProject condition
  metric has no namespace label, so the dashboard answers *what kind* is broken, not *whose*.
  True per-tenant panels need a claim/namespace-labelled metric.
- **No alert-state annotations.** The timeseries don't yet mark when the matching alert fired;
  the red SLO line is the visual proxy.

## Honest caveat

A panel renders correctly only once its metric flows. The Phase-2 / Upjet / inventory rows are
intentionally dark until those backends exist; the verified-vs-documented status of each
metric is tracked in `tests/metrics-allowlist.{captured,documented}.txt` and `README.md`.
