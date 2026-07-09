# kcp Observability Roadmap — Stakater Cloud

**Status:** Revised against the live capture from us-2 (2026-07-09) — metric names below are
**real**, from `tests/fixtures/`
**kcp version:** v0.32.1 (root shard + front-proxy), api-syncagent v0.5.0, druid-managed etcd
**Owner:** Platform / SRE

---

## How to read this document

Organized **by user story**: need → measurement → target → alert → dashboard → availability.

### Metric reality (the discipline)

Every metric here was **confirmed against a live scrape** (`tests/fixtures/`, provenance and
label shapes in [`../tests/fixtures/README.md`](../tests/fixtures/README.md)). Tags:

- **[captured]** — present in the us-2 fixtures with the exact labels stated.
- **[ksm]** — standard kube-state-metrics / cAdvisor series; on any OpenShift cluster,
  documented upstream (not in our kcp fixtures by nature).
- **[absent]** — we looked for it and it does not exist on v0.32.1; the story is deferred or
  rebuilt on a captured proxy signal. Never faked.

Two structural facts that shape everything (details in the fixtures README):

1. **No workspace/tenant label on request metrics.** `apiserver_request_total` has no
   `cluster`/`workspace` dimension → per-tenant *request* observability is impossible;
   per-tenant signals live at the workspace/APIBinding layer, and those are **aggregate counts
   by phase+shard** (like crossplane's per-GVK counts), not per-object.
2. **The us-2 layout:** one root shard (`root-kcp`), a v0.32.1 front-proxy (already in UWM),
   druid etcd (`root-0/1/2`), 10 api-syncagents (one per SCO service API), and a **legacy
   v0.31.1 `root-proxy`** (lacks the proxy metrics family — flag for decommission/upgrade).
   Cache server and virtual workspaces are embedded in the shard. Only the front-proxy is
   scraped today — **the chart must ship ServiceMonitors for shard, etcd, and syncagents.**

### The SLI / SLO / SLA distinction

- **SLI** — the measurement. **SLO** — internal target with an error budget; pages on-call.
- **SLA** — externally promised, only a few, always looser than the SLO. Internal control-plane
  health never becomes a customer SLA; the customer-facing promise is the edge (Area 1) and
  workspace/binding lifecycle (Areas 4–5).

> **Calibration:** every numeric target is a **placeholder** until 2–4 weeks of baseline.

---

# Capability Area 1 — Front-Proxy & the Request Edge (customer-facing)

The front-proxy is the single endpoint every client hits. If it's down or slow, every tenant is.

## Story 1.1 — Is the control plane reachable?

> **As an SRE, I want to know the moment the front-proxy stops serving, because when it is down
> every tenant loses access to every workspace at once.**

- **Metric(s):** `up{job="frontproxy-front-proxy"}` **[captured — already UWM-ingested]**
- **SLI:** front-proxy targets up
- **SLO:** ≥ 99.9%  | **SLA:** ✅ candidate
- **Alert:** `KcpFrontProxyDown` (`up == 0` for 2m → critical); `KcpFrontProxyReplicasLow`
  (fewer targets up than replicas → warning)
- **Dashboard:** top-of-glass availability tile

## Story 1.2 — Are requests through the proxy succeeding?

> **As an SRE, I want the error rate at the edge, because a climbing 5xx rate at the front-proxy
> is the earliest customer-visible sign something behind it is broken.**

- **Metric(s):** `proxy_request_duration_seconds_count{code,method}` **[captured]** — the
  proxy-specific family (the front-proxy does **not** expose `apiserver_request_total`)
- **SLI:** `code=~"5.."` / total at the edge
- **SLO:** < 0.5% 5xx over 5m  | **SLA:** ✅ candidate
- **Alert:** `KcpFrontProxyErrorRateHigh` (warning), `…Critical`
- **Dashboard:** edge request rate by code class

## Story 1.3 — Is the edge fast?

> **As an SRE, I want request latency at the proxy, because slow is the new down — a tenant's
> kubectl hanging is a support ticket even when nothing has "failed".**

- **Metric(s):** `proxy_request_duration_seconds_bucket{code,method}` **[captured]**
- **SLI:** p95/p99 edge latency, read (`get`) vs write (`post|put|patch|delete`) via `method`
- **SLO:** p95 ≤ 1s  | **SLA:** ❌ internal
- **Alert:** `KcpFrontProxyLatencyHigh` (p95 above SLO 30m → warning)
- **Dashboard:** edge latency p50/p95/p99 by method

## Story 1.4 — Is every shard reachable through the proxy?

- **Metric(s):** per-backend proxy health **[absent]** on v0.32.1
- **Rebuilt on:** per-shard `up` (Story 2.1) + edge 5xx (1.2) — a shard-down + edge-5xx pair is
  the observable signature. **Deferred as its own alert.**

---

# Capability Area 2 — Shard (apiserver) Health

One root shard today; the rules are written per-`job`/`pod` so added shards inherit coverage.
**Requires the chart's shard ServiceMonitor (auth via kcp-operator-generated cert/token).**

## Story 2.1 — Is each shard serving?

> **As an SRE, I want per-shard availability, because losing a shard takes out exactly the
> workspaces scheduled to it while the rest of the platform looks healthy.**

- **Metric(s):** `up{job=<shard>}` **[captured surface]**
- **SLO:** ≥ 99.9% | **Alert:** `KcpShardDown` (critical)
- **Dashboard:** per-shard availability row

## Story 2.2 — Is a shard erroring or overloaded?

> **As an SRE, I want each shard's request error rate and saturation, because a shard that 5xx-es
> or exhausts its concurrency predicts a customer-facing failure.**

- **Metric(s):** `apiserver_request_total{code,verb,resource}` **[captured]**,
  `apiserver_current_inflight_requests{request_kind}` **[captured]**,
  `apiserver_flowcontrol_rejected_requests_total` **[captured]**
- **SLO:** < 1% 5xx over 5m; no sustained APF rejection
- **Alert:** `KcpShardErrorRateHigh`; `KcpShardAPFRejecting`
- **Dashboard:** per-shard request/error/inflight/APF

## Story 2.3 — Is a shard slow?

> **As an SRE, I want the standard apiserver latency SLO per shard.**

- **Metric(s):** `apiserver_request_duration_seconds_bucket{verb,resource,scope}` **[captured]**
- **SLI:** p99 by verb class (read vs mutating), excluding long-running (`WATCH`/`CONNECT`)
- **SLO:** read p95 ≤ 1s; mutating p95 ≤ 1s
- **Alert:** `KcpShardLatencyHigh` (warning)
- **Dashboard:** shard latency SLO panel

## Story 2.4 — Is a shard's storage growing unboundedly?

> **As an SRE, I want stored-object counts, because unbounded growth is a slow-burn toward etcd
> pressure. (us-2 today: `apibindings.apis.kcp.io` is the largest at 202 objects.)**

- **Metric(s):** `apiserver_storage_objects{resource}` **[captured]**
- **Alert:** `KcpShardStorageObjectsHigh` (warning, threshold from capacity plan)
- **Dashboard:** top stored resources per shard

---

# Capability Area 3 — etcd (the storage backbone)

Druid-managed (`root-0/1/2`, quorate). **Requires the chart's etcd ServiceMonitor (client-cert
scrape via `etcd-client-tls`) — nothing scrapes it today.** All series confirmed in
`etcd-metrics.txt`.

## Story 3.1 — Does etcd have a leader and a quorum?

- **Metric(s):** `etcd_server_has_leader` **[captured]**,
  `etcd_server_leader_changes_seen_total` **[captured]**
- **Alert:** `KcpEtcdNoLeader` (critical, 1m); `KcpEtcdLeaderChangesHigh` (warning)

## Story 3.2 — Is etcd disk keeping up?

- **Metric(s):** `etcd_disk_wal_fsync_duration_seconds_bucket` **[captured]**,
  `etcd_disk_backend_commit_duration_seconds_bucket` **[captured]**
- **SLO:** fsync p99 ≤ 10ms; backend commit p99 ≤ 25ms | **Alert:** `KcpEtcdDiskSlow`

## Story 3.3 — Is etcd running out of space?

- **Metric(s):** `etcd_mvcc_db_total_size_in_bytes` **[captured]**,
  `etcd_server_quota_backend_bytes` **[captured]**
- **Alert:** `KcpEtcdDBSizeHigh` (80% warning / 95% critical)

## Story 3.4 — Are backups happening? (druid bonus — captured, cheap, high value)

> **As an SRE, I want to know when etcd snapshots stop landing, because a control plane without
> a recent backup is one incident away from unrecoverable.**

- **Metric(s):** `etcdbr_snapshot_latest_timestamp{kind="Full|Incr"}` **[captured]**,
  `etcdbr_snapshotter_failure` **[captured]** (in `etcd-backup-restore-metrics.txt`)
- **Alert:** `KcpEtcdBackupStale` (no full/delta snapshot within budget → critical)
- **Dashboard:** last-backup-age tile

---

# Capability Area 4 — Workspace / Logical-Cluster Lifecycle (the kcp differentiator)

Native, aggregate **phase-count gauges** (us-2: 108 workspaces Ready, 136 logicalclusters Ready,
8 Scheduling). Inventory and stuck-detection are real; **per-tenant attribution and a
workspace-TTR histogram do not exist natively** — deferred, not faked.

## Story 4.1 — How many workspaces are there, and in what state? (inventory)

> **As a platform owner, I want a live count of workspaces by phase, because that is the health
> picture (how many are stuck) and the platform's footprint at a glance.**

- **Metric(s):** `kcp_workspace_count{phase,shard}` **[captured]**,
  `kcp_logicalcluster_count{phase,shard}` **[captured]**,
  `kcp_indexed_logicalclusters{shard}` **[captured]**
- **Dashboard:** inventory row — totals, by phase, by shard; trend over time
- **Billing note:** per-tenant billing on workspaces needs per-object data that these aggregates
  don't carry. If billing-by-workspace becomes a requirement, the path is a small exporter
  reading kcp's workspace API (the crossplane-inventory pattern) — **deferred, out of chart scope.**

## Story 4.2 — Are workspaces stuck scheduling/initializing?

> **As an SRE, I want to know when workspaces sit in a non-ready phase, because a stuck workspace
> is a tenant who cannot work at all.**

- **Metric(s):** `kcp_workspace_count{phase="Scheduling|Initializing|Unavailable"}` **[captured]**,
  same for `kcp_logicalcluster_count` (us-2 shows a standing `Scheduling=8` — calibrate the
  baseline before alerting!)
- **SLI:** count in non-ready phase, sustained
- **Alert:** `KcpWorkspacesStuck` (non-ready count above baseline for 15m → warning, 1h → critical)
- **Dashboard:** stuck-workspace count by phase

## Story 4.3 — How fast do workspaces become ready?

- **Metric(s):** workspace-TTR histogram **[absent]** on v0.32.1 (only APIBindings have a
  ready-duration histogram — Story 5.2)
- **Rebuilt on:** phase-count deltas give a coarse in-flight view, not a latency SLI.
  **Deferred** as an SLO; revisit on kcp upgrades.

---

# Capability Area 5 — API Surface: APIExport / APIBinding

The API-sharing machinery — and on Stakater Cloud, **the product surface**: every SCO service
(compute, database, netbird, …) reaches tenants as an APIExport bound into their workspaces
(808 bindings Bound on us-2). All native, all captured.

## Story 5.1 — Are APIBindings healthy?

> **As an SRE, I want to know when APIBindings leave Bound or their conditions degrade, because
> the tenant's API silently disappears — no error on their side, their kubectl just stops
> listing the resource.**

- **Metric(s):** `kcp_apibinding_phase{phase="Binding|Bound",shard}` **[captured]**,
  `kcp_apibinding_condition_status{condition,status,shard}` **[captured]** (conditions:
  `Ready`, `APIExportValid`, `BindingUpToDate`, `InitialBindingCompleted`, `PermissionClaimsValid`, …)
- **SLI:** bindings with `condition="Ready",status="True"` / total; count not Bound
- **SLO:** ≥ 99.9% Ready
- **Alert:** `KcpAPIBindingNotReady` (any binding condition Ready!=True sustained → warning)
- **Dashboard:** binding health — phase counts, condition matrix

## Story 5.2 — How fast do APIBindings become ready?

> **As an SRE, I want binding TTR, because binding an API into a workspace is a core tenant
> onboarding step.**

- **Metric(s):** `kcp_apibinding_ready_duration_ms_{bucket,sum,count}{shard}` **[captured]**
- **SLI:** p95 binding ready-duration | **SLO:** p95 ≤ 5s (placeholder)
- **Alert:** `KcpAPIBindingSlow` (warning)
- **Dashboard:** binding TTR p50/p95/p99

## Story 5.3 — Are APIExports valid and their virtual workspaces ready?

> **As an SRE, I want APIExport condition health, because an invalid export breaks every tenant
> bound to it at once (blast radius = all 808 bindings of that export).**

- **Metric(s):** `kcp_apiexport_condition_status{condition,status,shard}` **[captured]**
  (`IdentityValid`, `VirtualWorkspaceURLsReady`)
- **SLO:** 100% exports valid
- **Alert:** `KcpAPIExportNotValid` (critical — high blast radius)
- **Dashboard:** export condition matrix

---

# Capability Area 6 — kcp Controller Health

kcp's controllers run **inside the shard** as workqueues named `kcp-*` (~30 queues:
`kcp-apibinding`, `kcp-logicalcluster`, `kcp-logicalcluster-deletion`, `kcp-apiexport`,
`kcp-replication-controller`, …). All standard workqueue families, captured.

## Story 6.1 — Is any kcp controller backing up?

> **As an SRE, I want queue depth and retries per kcp controller, because a growing queue is the
> earliest sign workspace/binding reconciliation is falling behind.**

- **Metric(s):** `workqueue_depth{name=~"kcp-.*"}` **[captured]**,
  `workqueue_retries_total{name=~"kcp-.*"}` **[captured]**,
  `workqueue_unfinished_work_seconds` / `workqueue_longest_running_processor_seconds` **[captured]**
- **Alert:** `KcpControllerQueueBacklog` (depth sustained > 0 baseline → warning);
  `KcpControllerStalled` (longest-running processor above budget → warning)
- **Dashboard:** workqueue depth/retries per kcp controller (topk)

## Story 6.2 — Are kcp controllers processing slowly?

- **Metric(s):** `workqueue_work_duration_seconds_bucket{name=~"kcp-.*"}` **[captured]**,
  `workqueue_queue_duration_seconds_bucket{…}` **[captured]**
- **Alert:** `KcpControllerProcessingSlow` (warning) | **Dashboard:** p99 work/wait durations

## Story 6.3 — Cache/replication healthy? (embedded cache server)

> **As an SRE, I want the replication controller's queue health, because on this layout the
> cache layer is embedded and its controller queue is the observable replication signal.**

- **Metric(s):** `workqueue_*{name="kcp-replication-controller"}` **[captured]** (+
  `kcp_indexed_logicalclusters` as a liveness signal of the index)
- **Alert:** covered by 6.1's per-queue alerts; called out on the dashboard
- **Note:** a dedicated replication-lag metric is **[absent]**; revisit if a standalone
  CacheServer is deployed.

---

# Capability Area 7 — SCO Service Agents (api-syncagent)

The 10 `services-*` syncagents publish each SCO service API into kcp — **they are how tenant
intent reaches the underlying clusters**. Restarting frequently on us-2 (13–26 restarts/pod).
Surface is thin but real: **[captured]** `rest_client_requests_total{code,method}`,
`leader_election_master_status`, webhook/certwatcher counters. No reconcile/workqueue families.
**Requires the chart's syncagent PodMonitor (:8085, http).**

## Story 7.1 — Is each service agent up, leading, and talking to kcp?

> **As an SRE, I want per-service agent health, because a dead compute agent means every tenant's
> compute claims silently stop syncing.**

- **Metric(s):** `up{job=<syncagent>}` **[captured surface]**,
  `leader_election_master_status` **[captured]**, `rest_client_requests_total{code}` **[captured]**
- **SLI:** per service: an agent up and leading; client 5xx/401/403 ratio
- **Alert:** `KcpSyncAgentDown` (no leader for a service → critical);
  `KcpSyncAgentClientErrors` (warning)
- **Dashboard:** per-service agent matrix (up / leader / client errors / restarts)

---

# Capability Area 8 — Footprint (the pods)

Same discipline as crossplane-observability. **[ksm]** metrics — standard on OpenShift.

## Story 8.1 — Are kcp pods restarting / OOMing?

- **Metric(s):** `kube_pod_container_status_restarts_total` **[ksm]**,
  `kube_pod_container_status_last_terminated_reason` **[ksm]**
- **Alert:** `KcpPodRestarting` (warning); `KcpPodOOMKilled` (critical)
- **Note:** the syncagents' standing restart counts (13–26) need a calibrated baseline or the
  restart alert will be noise — investigate the restarts themselves as platform work.

## Story 8.2 — Are kcp pods CPU-throttled or memory-pressured?

- **Metric(s):** `container_cpu_cfs_throttled_periods_total` / `container_cpu_cfs_periods_total`
  **[ksm]**, `container_memory_working_set_bytes` **[ksm]**, `go_goroutines` **[captured]**,
  `process_resident_memory_bytes` **[captured]**
- **Alert:** `KcpPodCPUThrottled`; `KcpPodMemoryHigh` (warnings)

---

## Coverage summary

| Area | Stories | Status |
| --- | --- | --- |
| 1 — Front-proxy edge | 1.1–1.3 ✅ captured; 1.4 deferred (no per-backend metric) | already scraped by UWM |
| 2 — Shard apiserver | 2.1–2.4 ✅ captured | **needs shard ServiceMonitor** |
| 3 — etcd (+backups) | 3.1–3.4 ✅ captured | **needs etcd ServiceMonitor (client cert)** |
| 4 — Workspace lifecycle | 4.1–4.2 ✅ captured (aggregate); 4.3 deferred (no TTR histogram) | via shard scrape |
| 5 — APIExport/APIBinding | 5.1–5.3 ✅ captured (incl. binding TTR!) | via shard scrape |
| 6 — kcp controllers | 6.1–6.3 ✅ captured (`workqueue name=~"kcp-.*"`) | via shard scrape |
| 7 — SCO syncagents | 7.1 ✅ captured (thin surface) | **needs syncagent PodMonitor** |
| 8 — Footprint | 8.1–8.2 ✅ ksm-standard | cluster KSM |

**Build order:** monitors first (shard, etcd, syncagent — without them nothing lands in UWM),
then recording rules + alerts per area, then the dashboard. Grafana-managed alerts are **not**
needed here: everything is same-namespace (`kcp-config`), so UWM namespace enforcement — the
reason crossplane needed the Grafana path — doesn't bite. PrometheusRules all the way.

**Platform follow-ups surfaced by the capture** (not chart work): decommission/upgrade the
legacy v0.31.1 `root-proxy`; investigate syncagent restart counts; kcp-operator metrics sit
behind kube-rbac-proxy and rejected the admin token (parked).
