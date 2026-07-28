# Alerts guide — why each of the 29 alerts exists

The companion to [`dashboard-guide.md`](dashboard-guide.md): for every alert this chart
ships — why it exists, what value it offers, and **what we would miss if it didn't exist**.
Grounded in [`roadmap.md`](roadmap.md)'s user stories and hardened by the live us-2
validation (`tests/reports/`), where three of these alerts fired falsely and were fixed —
the hardening notes below are part of each alert's story.

**Naming and philosophy.** Every alert starts with `Kcp` and carries `rulesgroup: kcp` —
they are unmistakably ours in Alertmanager and route as one group. The design rule: **no
generic catch-alls**. Each alert names one kcp failure mode, is deterministic (a metric
crosses a budget — no heuristics), and must be *actionable*: if the receiving human can't
do anything with it, it doesn't ship. A permanently-firing alert is treated as a defect
(that's why us-2 overrides the etcd disk thresholds rather than letting a known storage
baseline page forever). Thresholds all live in `values.yaml` under `prometheus.rules.*` —
calibrate per cluster, never edit exprs to tune.

All `for:` durations exist for the same reason: to require the condition to *sustain*, so a
scrape blip or a single slow minute never pages anyone.

---

## Area 1 — Front-proxy edge (the customer contract)

The only layer tenants touch directly — the closest thing the platform has to customer-SLA
alerts.

| Alert | Severity / for / threshold | Fires when | Why it exists — the value | Without it, we'd miss |
| --- | --- | --- | --- | --- |
| `KcpFrontProxyDown` | critical / 2m | `up{job=frontproxy} == 0` | When the front-proxy is down, *every tenant loses every workspace at once* — the maximum-severity event the platform has. The most aggressive setting in the chart: there is no tolerable duration. | A total outage, discovered by customer tickets instead of a page. Shard and etcd can be perfectly healthy while the door is closed. |
| `KcpFrontProxyErrorRateHigh` | warning / 10m / 0.5% | Edge 5xx ratio (`kcp:front_proxy_error_ratio:rate5m`) over budget | A climbing edge 5xx rate is the earliest *customer-visible* sign anything behind the proxy broke — it aggregates every backend failure into the one number tenants experience. | Partial degradations (one shard erroring, an auth regression) staying invisible until a component alert trips — customers notice first. |
| `KcpFrontProxyLatencyHigh` | warning / 30m / p95 > 1s | Edge p95 latency above SLO, sustained | Slow is the new down — a hanging `kubectl` is a support ticket even when nothing has "failed"; no error-based alert can ever fire for it. | The platform degrading to unusable-but-technically-up with zero pages. The only latency promise the customer contract has. |

## Area 2 — Shard apiservers

Is the kcp apiserver healthy — and is it about to stop being healthy?

| Alert | Severity / for / threshold | Fires when | Why it exists — the value | Without it, we'd miss |
| --- | --- | --- | --- | --- |
| `KcpShardDown` | critical / 2m | `up{job=shard} == 0` | A down shard means every workspace scheduled to it is gone; with 2 replicas it also means quorum-of-one on the serving path. | The "which layer?" answer during the worst minutes — shard death would surface only as edge errors. |
| `KcpShardErrorRateHigh` | warning / 10m / 1% | Shard-side 5xx ratio over budget | Paired with the edge alert it *localizes*: edge + shard erroring → problem here or below (etcd); edge only → the proxy is the patient. A built-in decision tree. | Every edge-error investigation starting from zero. |
| `KcpShardAPFRejecting` | warning / 10m | APF rejections non-zero, sustained | Rejections mean the shard is *already* shedding load — tenants get 429s. The "over the cliff" complement to watching inflight climb. (Counter registers lazily: absent = never rejected, benign.) | Load-shedding masquerading as flaky tenant clients ("retry worked") for days. |
| `KcpShardLatencyHigh` | warning / 30m / p99 > 1s | Read or write p99 (non-streaming verbs) above budget | The read/write split makes it diagnostic: slow writes implicate etcd consensus, slow reads implicate cache/informer pressure. | Creeping apiserver slowness surfacing only via the edge alert — after every tenant feels it. |
| `KcpShardStorageObjectsHigh` | warning / 30m / 10000 per resource | One resource type's stored-object count crosses the line | Unbounded object growth is the slow killer — burns etcd quota and list latency weeks before anything errors. Per-resource: the offender is named in the labels. (us-2 max today ~200 — a deliberate early tripwire.) | A leaking controller whose first symptom would otherwise be `KcpEtcdDBSizeHigh` — much later, diagnosis still to do. |

## Area 3 — etcd + backups (the storage backbone)

kcp is exactly as healthy as this etcd: three outage predictors, two capacity guards, one
recoverability guard.

| Alert | Severity / for / threshold | Fires when | Why it exists — the value | Without it, we'd miss |
| --- | --- | --- | --- | --- |
| `KcpEtcdMembersDown` | critical / 15m / healthy < 3 | Fewer healthy members (scrape up on the etcd container) than the cluster size | The only alert that can see a **dead** member: a dead etcd container produces ABSENT metrics, so NoLeader/DiskSlow/DBSize can never fire for it. Proven live (release audit): a member with a read-only PVC sat in CreateContainerError for **3 days** with quorum intact and nothing fired. `or vector(0)` keeps it alive even when all members vanish. | Running one failure away from a full control-plane outage without knowing it — for days. |
| `KcpEtcdNoLeader` | critical / 1m | Any member's `etcd_server_has_leader` (etcd container only) = 0 | No leader = no writes = the control plane is read-only *right now*. Shortest `for:` in the chart — a hard outage in progress. | The cause behind "everything is mysteriously timing out" — no other alert names it. |
| `KcpEtcdLeaderChangesHigh` | warning / 15m / > 3 per hour | Leader elections churning | Each election is a write stall; churn is the signature of disk/network distress *before* quorum is lost — the early-warning twin of `NoLeader`. Churn + `DiskSlow` = "storage is killing etcd". | Only ever seeing the terminal state. |
| `KcpEtcdDiskSlow` | warning / 15m / fsync p99 > 10ms, commit p99 > 25ms | WAL fsync or backend commit p99 over upstream guidance | Slow fsync is *the* canonical predictor of etcd trouble (elections, write stalls). Deterministic, upstream-sanctioned budgets. | Storage degradation presenting as unexplained shard write latency and leader churn, root cause invisible. |
| `KcpEtcdDBSizeHigh` | warning / 15m / > 80% of quota | DB crosses the act-soon line | At 100% etcd goes **read-only** — a self-inflicted total outage with an avoidable cause. 80% = schedule compaction/defrag/quota raise. | — (see next row) |
| `KcpEtcdDBSizeCritical` | critical / 5m / > 95% of quota | DB crosses the act-now line | Two stages because the correct responses differ; 95% means do it now. | The most preventable full-platform outage in the book, discoverable only by hitting it. |
| `KcpEtcdBackupStale` | critical / 15m / Full > 26h, Incr > 60m | *Cluster-latest* snapshot (max across members) over its age budget | The restore-point objective as an alert; 26h gives the daily druid full snapshot 2h grace. A control plane without a recent backup is one incident from unrecoverable. | Backup rot, discovered during a disaster — i.e. never in time. etcd can be green for months while backups quietly fail. |

**Hardening notes (us-2):**
- `KcpEtcdNoLeader` fired on all 3 *healthy* members: the backup-restore sidecar exports its
  own permanently-zero copy of the gauge. Fixed by pinning `container="etcd"` and dropping
  the sidecar's `etcd_*` mirror at ingestion.
- `KcpEtcdBackupStale` fired on two members whose *cluster* backup was 5 minutes old:
  snapshot timestamps are per-member and only the snapshotting member's are fresh. Fixed
  with `max by (kind)` across members.
- `KcpEtcdDiskSlow` calibration: us-2's storage baseline is ~170–190ms fsync p99 — genuinely
  bad (SRE finding F1) but *chronic*, so the us-2 values raise thresholds to 0.5s/1.0s to
  page on degradation-from-baseline instead of firing forever. The finding is tracked in the
  validation report, not silenced.

## Area 4 — Workspace lifecycle (the kcp differentiator)

Workspaces and logical clusters alert **separately** (team feedback: a combined count read
"10 workspaces not ready" on us-2 when it was actually 0 workspaces + 10 logical clusters —
the alert must name the resource that is stuck).

> **Both alerts ship DISABLED by default** since the release audit: kcp v0.32.1's phase
> gauges drift unboundedly ([kcp#4277](https://github.com/kcp-dev/kcp/issues/4277)) — on
> us-2 the LC alert fired ~60% of a week on phantom counts (gauge 28, etcd truth 2), and
> the gauge can also drift BELOW truth, so no threshold direction is trustworthy. The
> trend panel and the runbook keep the signal observable; re-enable on a fixed kcp.

| Alert | Severity / for / threshold | Fires when | Why it exists — the value | Without it, we'd miss |
| --- | --- | --- | --- | --- |
| `KcpWorkspacesStuck` | warning / 15m / > 8 not-ready | `kcp:workspaces_not_ready:count` (workspaces non-Ready, leader's view) above the per-cluster baseline | Stuck tenancy provisioning is the platform failing at its core job — and nothing in a stock Kubernetes alert set knows workspaces exist. Workspaces are the *tenant-visible* resource: this alert means users are waiting. | Tenants waiting on workspaces that will never arrive; the flagship feature with zero coverage. |
| `KcpLogicalClustersStuck` | warning / 15m / > 8 not-ready | `kcp:logicalclusters_not_ready:count` (logical clusters non-Ready, leader's view) above the per-cluster baseline | Logical clusters are the internal per-workspace primitive; they can be stuck *without* any workspace being stuck (exactly the us-2 state — SRE finding F2). Splitting them means the alert names the layer: workspace controller vs core scheduling. | Internal lifecycle rot invisible behind healthy workspace counts — accumulating stuck LCs that surface only when tenants eventually hit them. |

Both alerts carry a `runbook_url` to the section below — the metrics are counts by phase
only, so identifying *which* objects are stuck is a kubectl step, not a metrics query.

**Calibration (us-2, updated 2026-07-16):** the metric's "8–10 standing" turned out to be
mostly phantom — etcd truth is **2** stuck logical clusters (both `e2e-vm-project` e2e-test
leftovers from March; see the runbook's observed output). The alert still fires because the
drifting gauge reads 10 > 8. Until the upstream gauge bug is fixed, treat this alert as
"something may be stuck — run the runbook", not as a count. Original text follows for
history: the threshold sits at the standing baseline (8–10 in
`Scheduling` all week — SRE finding F2). It fires today as a **true positive**. When SRE
resolves or accepts F2, recalibrate `logicalClustersStuck.baseline` using the "Not-ready
trend" panel as evidence. Workspaces on us-2 have a standing not-ready count of 0.

### Runbook: identifying stuck workspaces and logical clusters

**Verified live on us-2 2026-07-16 (kcp v0.32.1).** Two reasons this runbook is mandatory,
not optional: (1) kcp exposes no per-object identity in metrics, so no panel can list the
stuck objects; (2) the `kcp_*` count gauges are **unreliable in absolute terms** — at
verification, etcd truth was 33 workspaces / 36 logical clusters / 2 stuck, while the
metrics claimed 135 / 180 / 10, and the two shard replicas (same start time) reported 27
vs 135. Neither `max` nor `min` recovers truth; only the API does.

Hard-won access facts (all verified):
- Wildcard (`/clusters/*`) requests are **refused via the front-proxy** for every identity
  (even `O=system:kcp:admin`) — go to the shard service directly.
- On the shard, wildcard requires **`system:masters`**; `system:kcp:admin`,
  `logical-cluster-admin`, and `external-logical-cluster-admin` are all denied.
- `tenancy.kcp.io` workspaces are **404 at wildcard scope** (they are per-parent
  projections) — enumerate LogicalClusters instead; workspace-owned ones carry
  `spec.owner.resource: workspaces`.

```bash
# 1. Mint a SHORT-LIVED shard-admin client cert (delete it in step 4):
kubectl -n kcp-config apply -f - <<'CERT'
apiVersion: cert-manager.io/v1
kind: Certificate
metadata: {name: kcp-audit-admin-ephemeral, namespace: kcp-config}
spec:
  commonName: kcp-audit-admin
  subject: {organizations: ["system:masters"]}
  issuerRef: {name: root-client-ca}
  duration: 1h
  secretName: kcp-audit-admin-ephemeral
  usages: ["client auth"]
CERT
kubectl -n kcp-config wait certificates.cert-manager.io/kcp-audit-admin-ephemeral --for=condition=Ready
kubectl -n kcp-config get secret kcp-audit-admin-ephemeral -o jsonpath='{.data.tls\.crt}' | base64 -d > /tmp/audit.crt
kubectl -n kcp-config get secret kcp-audit-admin-ephemeral -o jsonpath='{.data.tls\.key}' | base64 -d > /tmp/audit.key

# 2. Port-forward the root shard (wildcard only works here, not the front-proxy):
kubectl -n kcp-config port-forward svc/root-kcp 16443:6443 &

# 3. Which logical clusters are not Ready (path + cluster id + phase + age):
curl -sk --cert /tmp/audit.crt --key /tmp/audit.key \
  "https://localhost:16443/clusters/*/apis/core.kcp.io/v1alpha1/logicalclusters" \
  | jq -r '.items[] | select(.status.phase != "Ready")
      | [.metadata.annotations["kcp.io/path"], .metadata.annotations["kcp.io/cluster"],
         .status.phase, .metadata.creationTimestamp] | @tsv'

# 4. Clean up the credential:
kubectl -n kcp-config delete certificate/kcp-audit-admin-ephemeral secret/kcp-audit-admin-ephemeral
rm -f /tmp/audit.crt /tmp/audit.key
```

Observed output at verification (the alert said "10"; the truth was these two — both
e2e-test leftovers stuck in `Scheduling` since March, the older one orphaned by a
workspace re-create):

```
root:cloud:e2e-testing:e2e-vm-project  1muhm7z511vwnzvd  Scheduling  2026-03-30T11:57:00Z
root:cloud:e2e-testing:e2e-vm-project  2dcwd5j12mtqbikh  Scheduling  2026-03-27T21:21:51Z
```

## Area 5 — APIExport / APIBinding (the API economy)

| Alert | Severity / for / threshold | Fires when | Why it exists — the value | Without it, we'd miss |
| --- | --- | --- | --- | --- |
| `KcpAPIBindingNotReady` | warning / 15m | The **Ready** rollup condition sits `False\|Unknown` for any binding (per shard; no per-condition label — audit corrected this row, the expr never watched other conditions) | A degraded binding is a tenant whose subscribed service stopped working. Per-condition diagnosis lives in the dashboard's "Binding conditions not True" panel, deliberately not in the alert: us-2 genuinely carries `PermissionClaimsValid=False` on 98 of 202 bindings (etcd truth 2026-07-16; the metric said 392 — same gauge drift; SRE finding F4) that would page forever if every condition alerted. | Broken service consumption arriving as per-tenant support tickets instead of one platform signal. |
| `KcpAPIBindingSlow` | warning / 30m / TTR p95 > 5000ms | Binding time-to-ready p95 regresses (histogram is in **ms**) | Provisioning UX regresses silently with scale; a binding that takes 4 minutes still "succeeds" and never trips `NotReady`. | The subscribe-to-usable experience decaying with no signal — the classic slow-boil regression. |
| `KcpAPIExportNotValid` | critical / 10m | An export's `IdentityValid` leaves `True` (expr trimmed to IdentityValid — kcp v0.32.1 never emits `VirtualWorkspaceURLsReady`, verified live; re-add when observed) | One invalid export breaks **every** binding to it at once — the highest blast radius on the platform (hundreds of bindings per export). Hence the area's only `critical`. The `$value` is approximate (audit: `False` and `Unknown` states count independently, so a replica-disagreement can double-count one export — firing behavior and labels stay correct). | A mass service-API outage presenting as hundreds of individual binding alerts with the common cause unnamed. |

## Area 6 — kcp controllers (the reconciliation machinery)

The ways the machinery degrades that rows of green pods won't show.

| Alert | Severity / for / threshold | Fires when | Why it exists — the value | Without it, we'd miss |
| --- | --- | --- | --- | --- |
| `KcpControllerQueueBacklog` | warning / 15m / depth > 10 | A `kcp-*` workqueue's depth — `min` across shard replicas — stays high | Backlog is latency between "tenant changed something" and "it took effect". The queue *name* points at the exact controller. | Reconciliation lag until `WorkspacesStuck`/`BindingSlow` fire — this is their earliest common ancestor. |
| `KcpControllerProcessingSlow` | warning / 30m / work p99 > 5s (**must stay < 10**) | A controller's per-item work duration p99 stays pathological | The failure mode depth can't see: items *succeed slowly* (slow external call, huge LIST per reconcile) while depth barely moves. Audit found the original 10s threshold was **unsatisfiable** — client-go workqueue histograms top out at `le="10"`, so `histogram_quantile` can never exceed 10 and the alert could never fire; a firing unit test now pins this. | Slow-reconcile bugs hiding behind healthy-looking queue depths. Together with backlog (+ the retries panel), the jammed/slow/thrashing triad is covered. |

**Hardening note (us-2):** `QueueBacklog` fired permanently on the follower replica (202
deep, leader at 0) — the non-leader never runs workers, so its queues grow forever. Fixed
with `min` across replicas (the actively-drained queue). Documented blind spot, accepted
over a permanent false page: a real leader backlog is masked while a freshly-restarted
replica's near-empty queues hold the min down.

## Area 7 — SCO service agents (api-syncagent)

> **S1 resolved 2026-07-16**: the agent releases now pass `--metrics-address=0.0.0.0:8085`;
> monitor + both alerts are live on us-2 (20/20 targets up at verification). Topology
> correction from live data: each service runs a **2-replica** agent Deployment with
> leader election (~10 services × 2 pods, one leader each) — the down-alert's leadership
> clause exists precisely for the up-but-not-leading replica.

| Alert | Severity / for / threshold | Fires when | Why it exists — the value | Without it, we'd miss |
| --- | --- | --- | --- | --- |
| `KcpSyncAgentDown` | critical / 5m | Agent target down **or** a service has no leading agent (`leader_election_master_status` max = 0 per service) | A dead or leaderless agent means that service's tenant claims **silently stop syncing** — no errors appear anywhere else. The leadership clause matters: up-but-not-leading has the identical tenant-visible outcome. | This failure mode entirely — it has *zero* other coverage. Tenants discover it when resources stop converging. |
| `KcpSyncAgentClientErrors` | warning / 15m / > 5% of client calls | An agent's REST calls (to kcp or the service cluster) erroring | Expiring kubeconfigs, RBAC drift, unreachable endpoints — the leading indicators that end in `SyncAgentDown`. Business-hours work instead of a page. | Agent death arriving without warning; per-service credential rot invisible until total. |

## Area 8 — Footprint (the pods)

The most "generic-looking" alerts in the chart — kept because they're **scoped, not
generic**: `podRegex` restricts them to kcp components in the release namespace. Every
layer above degrades mysteriously when its pod is throttled, OOM-killed, or restart-looping.

| Alert | Severity / for / threshold | Fires when | Why it exists — the value | Without it, we'd miss |
| --- | --- | --- | --- | --- |
| `KcpPodRestarting` | warning / 15m / > 3 per hour | A kcp pod restarting repeatedly | Crash-looping that readiness probes hide (pod recovers between probes). Found a real thing on day one: the us-2 syncagents' standing restart baseline that nothing else surfaced. | Flapping components looking healthy in every phase-based view. |
| `KcpPodOOMKilled` | critical / no `for:` | `last_terminated_reason=OOMKilled` **and** a restart within the last 30m (the reason label alone persists indefinitely — the restart conjunct makes the alert auto-resolve ~30m after the kill instead of paging forever) | An OOM kill is a discrete fact — there is no "sustained" version, hence no `for:`. Always memory-limit misconfiguration or a leak; both actionable. | The *reason* — the part that names the fix — buried inside generic restart counts. |
| `KcpPodCPUThrottled` | warning / 30m / > 5% of CFS periods | A kcp pod throttled by its CPU limit | Throttling is the invisible latency source — slow with zero errors in any log. Proven live: us-2's shard *leader* throttled 9.6% of periods (SRE finding F3), taxing every apiserver request. | Tuning etcd and chasing latency alerts while the actual cause is a too-tight CPU limit. |
| `KcpPodMemoryHigh` | warning / 30m / > 90% of limit | Working set near the container limit, sustained | The pre-OOM warning: 90% for 30m means the next load spike is a `critical`. With the goroutine panel it separates "leak" from "undersized". | Memory problems only ever surfacing as the OOM kill itself — reactive instead of preventive. |

---

## Watchdog — guarding the alerting system itself

| Alert | Severity / for / threshold | Fires when | Why it exists — the value | Without it, we'd miss |
| --- | --- | --- | --- | --- |
| `KcpMetricsAbsent` (one instance per enabled monitor, `target` label names the layer) | warning / 10m | `absent(up{job=~...})` — a layer's scrape targets have **vanished** entirely | Every `*Down` alert is `up == 0`, which only fires while targets *exist and fail*. When targets vanish (monitor deleted, selector drift, relabel bug, cert rot) everything goes silently green — it happened live twice (20 syncagent targets dropped by a port bug; a preempted `Failed` pod producing no target). Gated per monitor so a deliberately disabled layer never fires it. | The alerting system itself dying invisibly: a green board that is green because nothing is measured. |

## Known gaps (deliberate, tracked)
- **Story 1.4** (per-shard reachability through the proxy): no per-backend proxy metric
  exists on v0.32.1; the observable signature is `KcpShardDown` + edge 5xx together.
  Deferred as its own alert, on purpose.
- **Per-service agent blindness** (finer-grained than the shipped `KcpMetricsAbsent`,
  which catches the whole job vanishing but not one service of many): a pod
  in phase `Failed` (e.g. preempted) is dropped by Prometheus entirely — no target, no
  `up==0`, and if ALL of a service's replicas are gone there is also no leader series, so
  `KcpSyncAgentDown` cannot fire for a service that never comes up. A per-service
  `absent()` needs an expected-services list (not derivable from metrics); still open — a per-service
  `absent()` needs an expected-services list (not derivable from metrics).

## Maintenance rules

- New alerts: `Kcp` prefix, `rulesgroup: kcp`, one named failure mode, deterministic expr,
  every threshold in `values.yaml`, **both a firing and a must-NOT-fire promtool test**
  (all five shipped bugs — three false positives and two never-fires — lived in the gap
  between those two assertions), and metrics proven in `tests/fixtures/`.
- The summary must name **exactly** the resource its expr counts — never aggregate
  distinct resource types into one series (the workspaces/logicalclusters conflation),
  and never promise a label the aggregation drops (the binding-condition doc drift).
- Quantile thresholds must sit strictly below the histogram's top finite bucket —
  `histogram_quantile` is capped there, so a threshold at/above it can never fire
  (the ProcessingSlow bug; workqueue histograms cap at `le="10"`).
- An alert whose only input is a recorded series must gate on
  `prometheus.recordingRules.enabled` too, or a values combination ships a dead alert.
- A firing alert nobody acts on is a defect: either fix the condition, recalibrate the
  threshold with panel evidence, or delete the alert. Never mute-and-forget.
- Every threshold-bearing alert shares its query with a dashboard panel
  (`dashboard-guide.md`) — the panel is
  where you *calibrate*, the alert is where you *commit* to a budget.
