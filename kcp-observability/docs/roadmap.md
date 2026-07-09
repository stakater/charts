# kcp Observability Roadmap — Stakater Cloud

**Status:** Draft for review (no rules built yet — awaiting live `/metrics` capture)
**Target:** kcp.io control plane — **confirm running version before building**
**Owner:** Platform / SRE

---

## How to read this document

This roadmap is organized **by user story**. Each capability starts with what someone
operating the kcp control plane actually needs, and *why*. Everything else — the metric that
answers it, how we judge good-vs-bad (SLI/SLO/SLA), the alert, the dashboard — hangs off that
need. Read each story as: **need → measurement → target → alert → dashboard → availability.**

### ⚠️ Metric reality (read first — this is the whole discipline)

kcp is built on the Kubernetes apiserver/controller machinery, so the **majority of what we
need is standard**: apiserver, etcd, workqueue, and client-go (`rest_client_*`) metrics, one
set per kcp component (each shard, front-proxy, cache server). Those we can rely on. The
**kcp-specific** series (workspace/logicalcluster lifecycle, APIExport/APIBinding, cache
replication) have names we have **not yet confirmed** — kcp's own metric surface must be read
off a real scrape, not assumed. We learned this the hard way on crossplane-observability, where
assumed labels/metric names caused most of the bugs.

Each metric below carries a confidence tag:

- **[std]** — standard apiserver / etcd / workqueue / client-go / process / go metric. High
  confidence it exists; still confirm the exact label set (esp. whether kcp adds a
  workspace/cluster dimension) from the dump.
- **[kcp?]** — kcp-specific. **Name is provisional** until the live `/metrics` dump lands
  (`tests/METRICS-CAPTURE.md`). Nothing referencing a `[kcp?]` metric gets written into a rule
  until it appears in `tests/fixtures/`.

> **No rule ships against an unconfirmed metric.** A capability whose only metric is `[kcp?]`
> and absent from the dump gets deferred (or rebuilt on a `[std]` proxy signal), never faked.

### The SLI / SLO / SLA distinction (read once, applies throughout)

- **SLI** — the *measurement*: what the metric actually computes.
- **SLO** — our *internal target* with an error budget; what pages on-call.
- **SLA** — an *externally promised* threshold, defined for **only a few** stories and always
  **looser than the SLO**. We do **not** turn internal control-plane health into customer SLAs;
  the customer-facing promise lives at the front-proxy edge (Area 1) and workspace lifecycle
  (Area 4).

> **Calibration note:** every numeric target below is a **placeholder**. Run 2–4 weeks against
> real baseline before committing any SLA number.

### Availability legend

- **🟢 Standard** — a `[std]` metric; present on any kcp/apiserver build today.
- **🔵 kcp-specific** — a `[kcp?]` metric; confirm exact name + labels from the live dump.
- **🟡 Conditional** — present only when a feature/component is deployed (e.g. standalone cache
  server, virtual-workspace apiservers, audit enabled).

---

# Capability Area 1 — Front-Proxy & the Request Edge (customer-facing)

The front-proxy is the single endpoint every client hits; it routes by workspace path to the
owning shard. This is the closest thing kcp has to a customer-facing SLA — if the proxy is down
or slow, *every* workspace is down or slow.

## Story 1.1 — Is the control plane reachable?

> **As an SRE, I want to know the moment the front-proxy stops serving, because when it is down
> every tenant loses access to every workspace at once.**

- **Metric(s):** `up{job=front-proxy}` **[std]**; `apiserver_current_inflight_requests` **[std]**
- **SLI:** front-proxy targets `up == 1`
- **SLO:** ≥ 99.9% availability (edge is the tightest tier)
- **SLA:** ✅ candidate — reachability is the baseline platform promise
- **Alert:** `FrontProxyDown` (`up == 0` for 2m → critical)
- **Dashboard:** top-of-glass availability tile
- **Availability:** 🟢 Standard

## Story 1.2 — Are requests through the proxy succeeding?

> **As an SRE, I want the error rate at the edge, because a climbing 5xx rate at the front-proxy
> is the earliest customer-visible sign something behind it is broken.**

- **Metric(s):** `apiserver_request_total{code}` **[std]** (front-proxy job). *Confirm the
  front-proxy exposes apiserver-style request metrics vs a proxy-specific family from the dump.*
- **SLI:** ratio of `code=~"5.."` responses to total, at the edge
- **SLO:** < 0.5% 5xx over 5m
- **SLA:** ✅ candidate
- **Alert:** `FrontProxyErrorRateHigh` (> threshold for 10m → warning)
- **Dashboard:** edge request rate + error rate, by code class
- **Availability:** 🟢 Standard (pending metric-shape confirmation)

## Story 1.3 — Is the edge fast?

> **As an SRE, I want request latency at the proxy, because slow is the new down — a tenant's
> kubectl hanging is a support ticket even when nothing has "failed".**

- **Metric(s):** `apiserver_request_duration_seconds_bucket` **[std]** (front-proxy job)
- **SLI:** p95/p99 request duration at the edge, split read vs write
- **SLO:** read p95 ≤ 1s, write p95 ≤ 1s (Kubernetes apiserver SLO convention; recalibrate)
- **SLA:** ❌ internal (headline latency SLA, if any, belongs per-verb per-tier)
- **Alert:** `FrontProxyLatencyHigh` (p95 above SLO for 30m → warning)
- **Dashboard:** latency heatmap / p50-p95-p99 by verb
- **Availability:** 🟢 Standard

## Story 1.4 — Is every shard reachable *through* the proxy?

> **As an SRE, I want to know when the proxy can't reach a shard, because a single unreachable
> shard silently blackholes just the workspaces it owns — invisible in an aggregate success rate.**

- **Metric(s):** front-proxy → shard connection / routing metrics **[kcp?]**; fall back to
  per-shard `up` **[std]** correlated with proxy routing config
- **SLI:** each configured shard reachable from the proxy
- **SLO:** 100% of shards reachable
- **Alert:** `ShardUnreachableFromProxy` (→ critical)
- **Dashboard:** shard reachability matrix
- **Availability:** 🔵 kcp-specific — confirm whether the proxy exposes per-backend health

---

# Capability Area 2 — Shard (apiserver) Health

Each shard is a Kubernetes-derived apiserver serving a subset of workspaces. These are
**leading indicators** — they should move before Area 1 does. Not SLA candidates.

## Story 2.1 — Is each shard serving?

> **As an SRE, I want per-shard availability, because losing a shard takes out exactly the
> workspaces scheduled to it while the rest of the platform looks healthy.**

- **Metric(s):** `up{job=shard}` **[std]** per shard
- **SLI:** each shard `up == 1`
- **SLO:** ≥ 99.9% per shard
- **Alert:** `ShardDown` (`up == 0` 2m → critical)
- **Dashboard:** per-shard availability row
- **Availability:** 🟢 Standard

## Story 2.2 — Is a shard erroring or overloaded?

> **As an SRE, I want each shard's request error rate and inflight saturation, because a shard
> that starts 5xx-ing or hits its concurrency limit predicts a customer-facing failure.**

- **Metric(s):** `apiserver_request_total{code}` **[std]**,
  `apiserver_current_inflight_requests` **[std]**,
  `apiserver_flowcontrol_rejected_requests_total` **[std]** (APF)
- **SLI:** per-shard 5xx ratio; inflight vs limit; APF rejections
- **SLO:** < 1% 5xx over 5m; zero sustained APF rejection
- **Alert:** `ShardErrorRateHigh` (warning); `ShardAPFRejecting` (warning)
- **Dashboard:** per-shard request/error/inflight
- **Availability:** 🟢 Standard

## Story 2.3 — Is a shard slow (apiserver latency SLO)?

> **As an SRE, I want the Kubernetes apiserver latency SLO per shard, because read/write latency
> is the standard, well-understood health signal for an apiserver.**

- **Metric(s):** `apiserver_request_duration_seconds_bucket{verb,resource,scope}` **[std]**
- **SLI:** p95/p99 by verb class (LIST/GET vs mutating), per shard
- **SLO:** non-streaming read p95 ≤ 1s; mutating p95 ≤ 1s (recalibrate)
- **Alert:** `ShardLatencyHigh` (p99 above SLO for 30m → warning)
- **Dashboard:** apiserver latency SLO panel per shard
- **Availability:** 🟢 Standard

## Story 2.4 — Is a shard's storage growing unboundedly?

> **As an SRE, I want object counts per shard, because unbounded growth in stored objects is a
> slow-burn toward etcd pressure and latency.**

- **Metric(s):** `apiserver_storage_objects{resource}` **[std]**
- **SLI:** object count by resource, per shard; growth rate
- **SLO:** no resource growing beyond capacity plan (threshold TBD)
- **Alert:** `ShardStorageObjectsHigh` (warning)
- **Dashboard:** top resources by object count, per shard
- **Availability:** 🟢 Standard

---

# Capability Area 3 — etcd (the storage backbone)

kcp lives or dies by etcd. Highest-leverage leading indicators on the platform. Not SLA
candidates, but the tightest early-warning margin.

## Story 3.1 — Does etcd have a leader and a quorum?

> **As an SRE, I want to know about lost leader / churning elections, because a control plane
> with no etcd quorum is a hard, total outage.**

- **Metric(s):** `etcd_server_has_leader` **[std]**,
  `etcd_server_leader_changes_seen_total` **[std]**
- **SLI:** `has_leader == 1`; leader-change rate ≈ 0
- **SLO:** leader present 100%; < N leader changes / hour
- **Alert:** `EtcdNoLeader` (critical); `EtcdLeaderChangesHigh` (warning)
- **Dashboard:** etcd leader status + election churn
- **Availability:** 🟢 Standard (etcd job)

## Story 3.2 — Is etcd disk keeping up?

> **As an SRE, I want fsync and backend-commit latency, because rising disk latency is the
> canonical precursor to apiserver-wide slowness.**

- **Metric(s):** `etcd_disk_wal_fsync_duration_seconds_bucket` **[std]**,
  `etcd_disk_backend_commit_duration_seconds_bucket` **[std]**
- **SLI:** p99 fsync + backend commit
- **SLO:** fsync p99 ≤ 10ms, backend commit p99 ≤ 25ms (etcd guidance; recalibrate)
- **Alert:** `EtcdDiskSlow` (warning)
- **Dashboard:** etcd disk latency
- **Availability:** 🟢 Standard

## Story 3.3 — Is etcd running out of space?

> **As an SRE, I want DB size vs quota, because hitting the etcd space quota puts the cluster
> into read-only alarm — a self-inflicted outage.**

- **Metric(s):** `etcd_mvcc_db_total_size_in_bytes` **[std]**,
  `etcd_server_quota_backend_bytes` **[std]**
- **SLI:** DB size / quota
- **SLO:** < 80% of quota
- **Alert:** `EtcdDBSizeHigh` (warning at 80%, critical at 95%)
- **Dashboard:** etcd DB size vs quota gauge
- **Availability:** 🟢 Standard

---

# Capability Area 4 — Workspace / Logical-Cluster Lifecycle (the kcp differentiator)

Workspaces (logical clusters) are what kcp actually sells to tenants. Their creation,
scheduling, and deletion are the product's core UX — and the natural **billing/inventory unit**.
This is the kcp analog of the crossplane "Claim tree" and the billing story.

## Story 4.1 — How many workspaces are there, and in what state? (inventory + billing)

> **As a platform owner, I want a live count of workspaces by phase and by tenant, because that
> is both the health picture (how many are stuck) and the billable footprint of the platform.**

- **Metric(s):** workspace/logicalcluster phase gauge **[kcp?]** — e.g. a `_info`/phase series
  by `Ready|Initializing|Deleting`. **Confirm from the dump**; if kcp doesn't emit it natively,
  candidate for a `kube-state-metrics` custom-resource config (as we did for crossplane inventory).
- **SLI:** count of workspaces by phase, by tenant/parent
- **SLO:** n/a (inventory) — but "stuck" counts feed Story 4.3
- **Billing:** count of `Ready` workspaces per tenant = the billable unit (mirror `docs/billing.md`)
- **Alert:** none directly (see 4.3)
- **Dashboard:** workspace inventory row — total, by phase, by tenant
- **Availability:** 🔵 kcp-specific — **primary target of the metrics capture**

## Story 4.2 — How fast do workspaces become ready?

> **As an SRE, I want workspace provisioning time (created → Ready), because slow workspace
> creation is the first thing a new tenant experiences.**

- **Metric(s):** derived from workspace phase transitions **[kcp?]**, or a lifecycle controller
  histogram if one exists; otherwise computed from creation timestamp → Ready
- **SLI:** p95 time created → `Ready`
- **SLO:** p95 ≤ 30s (placeholder)
- **Alert:** `WorkspaceProvisioningSlow` (warning)
- **Dashboard:** workspace TTR p50/p95/p99
- **Availability:** 🔵 kcp-specific

## Story 4.3 — Are workspaces stuck initializing or deleting?

> **As an SRE, I want to know when a workspace is wedged in Initializing or Deleting, because a
> stuck workspace is a tenant who can't work, or leaked resources that keep billing.**

- **Metric(s):** workspace phase gauge **[kcp?]** with an age/duration; or a controller
  workqueue signal (Area 6) as a proxy
- **SLI:** count of workspaces in a non-terminal phase beyond a time budget
- **SLO:** zero workspaces stuck > 10m
- **Alert:** `WorkspaceStuck` (warning → critical by age)
- **Dashboard:** stuck-workspace table
- **Availability:** 🔵 kcp-specific

---

# Capability Area 5 — API Surface: APIExport / APIBinding

kcp's multi-tenant API sharing. A tenant binds an `APIExport` into its workspace via an
`APIBinding`; the exported API is served from a virtual workspace. Broken bindings = tenants
silently lose APIs.

## Story 5.1 — Are APIBindings healthy?

> **As an SRE, I want to know when APIBindings fail to bind (schema conflict, unmet permission
> claim), because the tenant's API just disappears with no error on their side.**

- **Metric(s):** APIBinding condition/phase **[kcp?]** — confirm; likely a KSM custom-resource
  target if not native
- **SLI:** % of APIBindings in `Bound`/healthy over total
- **SLO:** ≥ 99.9% bound
- **Alert:** `APIBindingNotBound` (warning)
- **Dashboard:** APIBinding health table by workspace/export
- **Availability:** 🔵 kcp-specific

## Story 5.2 — Are APIExport virtual workspaces serving?

> **As an SRE, I want the virtual-workspace apiservers backing APIExports to be up and fast,
> because every bound tenant reads through them.**

- **Metric(s):** `up` **[std]** + `apiserver_request_*` **[std]** on the virtual-workspace
  apiservers (if served standalone); `apiserver_request_duration_seconds` **[std]**
- **SLI:** VW availability + error/latency
- **SLO:** ≥ 99.9% up; latency per Area 2 convention
- **Alert:** `APIExportVWDown` (critical); `APIExportVWLatencyHigh` (warning)
- **Dashboard:** virtual-workspace availability + latency
- **Availability:** 🟡 Conditional — only if virtual workspaces are served as separate targets

---

# Capability Area 6 — kcp Controller Health

The reconcilers that make workspaces schedule, bindings bind, and exports export. Standard
controller signals — leading indicators for Areas 4 and 5.

## Story 6.1 — Is any controller backing up?

> **As an SRE, I want workqueue depth and retry rate per kcp controller, because a growing queue
> is the earliest sign that workspace/binding reconciliation is falling behind.**

- **Metric(s):** `workqueue_depth{name}` **[std]**, `workqueue_adds_total` **[std]**,
  `workqueue_retries_total` **[std]** (per controller `name`)
- **SLI:** queue depth; retry rate; unfinished-work age
- **SLO:** depth ≈ 0 steady-state; no sustained growth
- **Alert:** `ControllerQueueBacklog` (warning); `ControllerQueueGrowing` (warning)
- **Dashboard:** workqueue depth + retries per controller
- **Availability:** 🟢 Standard

## Story 6.2 — Are controllers processing slowly?

> **As an SRE, I want work-duration and queue-wait per controller, because slow processing
> stretches workspace TTR (Story 4.2) before the queue visibly backs up.**

- **Metric(s):** `workqueue_work_duration_seconds_bucket` **[std]**,
  `workqueue_queue_duration_seconds_bucket` **[std]**
- **SLI:** p99 work + queue-wait duration per controller
- **SLO:** placeholder pending baseline
- **Alert:** `ControllerProcessingSlow` (warning)
- **Dashboard:** controller processing latency
- **Availability:** 🟢 Standard

## Story 6.3 — Are controllers erroring against the shards?

> **As an SRE, I want the client-go request error rate from controllers to shards, because
> controllers that can't talk to their shard stall silently.**

- **Metric(s):** `rest_client_requests_total{code}` **[std]**,
  `rest_client_request_duration_seconds_bucket` **[std]**
- **SLI:** controller→shard 4xx/5xx ratio
- **SLO:** < 1% error over 10m
- **Alert:** `ControllerClientErrors` (warning)
- **Dashboard:** rest_client error rate by controller
- **Availability:** 🟢 Standard

---

# Capability Area 7 — Cache Server & Cross-Shard Replication

The cache server replicates a subset of resources (APIExports, schemas, shards, partitions)
across shards so cross-workspace resolution works. If it lags, cross-shard API resolution breaks
in ways that are hard to attribute.

## Story 7.1 — Is the cache server up and serving?

> **As an SRE, I want cache-server availability and request health, because when it stalls,
> cross-shard features degrade without an obvious single failure.**

- **Metric(s):** `up{job=cache-server}` **[std]**; `apiserver_request_*` **[std]** if the cache
  server exposes apiserver-style metrics — confirm from dump
- **SLI:** cache-server up + error/latency
- **SLO:** ≥ 99.9% up
- **Alert:** `CacheServerDown` (critical); `CacheServerErrorRateHigh` (warning)
- **Dashboard:** cache-server availability + requests
- **Availability:** 🟡 Conditional (standalone cache server) / 🟢 for `up`

## Story 7.2 — Is replication keeping up?

> **As an SRE, I want cache replication freshness/lag, because stale cross-shard data causes
> intermittent, confusing API failures for tenants spanning shards.**

- **Metric(s):** cache replication lag / queue **[kcp?]** — confirm; else a workqueue proxy
- **SLI:** replication lag / backlog
- **SLO:** placeholder
- **Alert:** `CacheReplicationLagging` (warning)
- **Dashboard:** replication lag
- **Availability:** 🔵 kcp-specific

---

# Capability Area 8 — Footprint (the pods)

The kcp component processes themselves — same footprint discipline as crossplane-observability.

## Story 8.1 — Are kcp pods restarting / OOMing?

> **As an SRE, I want restart and OOM signals for shard/proxy/cache pods, because a crash-looping
> control-plane component is both the cause and the symptom of an outage.**

- **Metric(s):** `kube_pod_container_status_restarts_total` **[std, KSM]**,
  `kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}` **[std, KSM]**
- **SLI:** restart rate; OOM events
- **SLO:** zero unexpected restarts / OOMs
- **Alert:** `KcpPodRestarting` (warning); `KcpPodOOMKilled` (critical)
- **Dashboard:** footprint row — restarts, OOM
- **Availability:** 🟢 Standard (requires KSM on the cluster)

## Story 8.2 — Are kcp pods CPU-throttled or memory-pressured?

> **As an SRE, I want CPU throttling and memory/goroutine growth per component, because a
> throttled apiserver is a slow apiserver, and a goroutine leak precedes an OOM.**

- **Metric(s):** `container_cpu_cfs_throttled_periods_total` / `..._periods_total` **[std,
  cAdvisor]**, `container_memory_working_set_bytes` **[std]**, `go_goroutines` **[std]**,
  `process_resident_memory_bytes` **[std]**
- **SLI:** throttle ratio; working-set vs limit; goroutine trend
- **SLO:** throttle ratio < 5%; no sustained memory/goroutine climb
- **Alert:** `KcpPodCPUThrottled` (warning); `KcpPodMemoryHigh` (warning)
- **Dashboard:** footprint row — CPU throttle, memory, goroutines
- **Availability:** 🟢 Standard

---

## Coverage summary

| Area | Stories | Confidence |
| --- | --- | --- |
| 1 — Front-proxy edge | 1.1–1.4 | mostly 🟢, 1.4 🔵 |
| 2 — Shard apiserver | 2.1–2.4 | 🟢 |
| 3 — etcd | 3.1–3.3 | 🟢 |
| 4 — Workspace lifecycle + billing | 4.1–4.3 | 🔵 (capture target) |
| 5 — APIExport / APIBinding | 5.1–5.2 | 🔵 / 🟡 |
| 6 — Controllers | 6.1–6.3 | 🟢 |
| 7 — Cache server / replication | 7.1–7.2 | 🟡 / 🔵 |
| 8 — Footprint | 8.1–8.2 | 🟢 (needs KSM) |

**Build order proposal:** the 🟢 areas (2, 3, 6, 8, most of 1) can be built and validated as
soon as the standard-metrics scrape confirms label shapes. The 🔵 kcp-specific areas (4, 5, 7)
are the reason for the metrics capture — they are the kcp *differentiator* and the billing story,
so getting their real metric names is the highest-value part of the dump.

## Open questions for the metrics capture (see `tests/METRICS-CAPTURE.md`)

1. Do kcp apiserver metrics carry a **workspace / logical-cluster label**? (Determines whether
   per-tenant request observability is even possible, or whether that only lives at the workspace
   inventory layer.)
2. What is the **real metric family for workspace phase/lifecycle** (Story 4.1/4.3)? Native, or
   do we need a KSM custom-resource config like the crossplane inventory exporter?
3. Does the **front-proxy** expose apiserver-style request metrics, or a proxy-specific family?
4. Are **virtual workspaces** and the **cache server** separate scrape targets with their own
   `/metrics`, or embedded in the shards?
5. What are the actual **`kcp_*` metric names** (if any) for bindings, exports, replication?
