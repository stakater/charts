# Alerts guide — why each of the 26 alerts exists

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

The only layer tenants touch directly. These three are the closest thing the platform has
to customer-SLA alerts.

### `KcpFrontProxyDown` — critical, 2m
- **Fires when:** `up{job=frontproxy} == 0` for 2 minutes.
- **Why it exists:** when the front-proxy is down, *every tenant loses every workspace at
  once* — the maximum-severity event the platform has. 2m/`critical` is the most aggressive
  setting in the chart because there is no such thing as a tolerable duration.
- **Without it:** total outage discovered by customer tickets instead of a page. Nothing
  else covers it — shard and etcd can be perfectly healthy while the door is closed.

### `KcpFrontProxyErrorRateHigh` — warning, 10m, threshold 0.5%
- **Fires when:** edge 5xx ratio (`kcp:front_proxy_error_ratio:rate5m`) exceeds 0.5% for 10m.
- **Why it exists:** a climbing edge 5xx rate is the earliest *customer-visible* sign that
  anything behind the proxy is broken — it aggregates every backend failure into the one
  number tenants experience.
- **Without it:** partial degradations (one shard erroring, an auth regression) stay
  invisible until they're big enough to trip a component alert — customers notice first.

### `KcpFrontProxyLatencyHigh` — warning, 30m, p95 > 1s
- **Fires when:** edge p95 latency stays above the SLO for 30 minutes.
- **Why it exists:** slow is the new down — a tenant's hanging `kubectl` is a support
  ticket even when nothing has "failed", and no error-based alert will ever fire for it.
- **Without it:** the platform can degrade to unusable-but-technically-up with zero pages.
  This is the only latency promise the customer contract has.

## Area 2 — Shard apiservers

One layer in: is the kcp apiserver itself healthy, and is it about to *stop* being healthy?

### `KcpShardDown` — critical, 2m
- **Fires when:** `up{job=shard} == 0` for 2 minutes.
- **Why it exists:** a down shard means every workspace scheduled to it is gone. With 2
  replicas it also means quorum-of-one on the serving path — the next failure is total.
- **Without it:** shard death would surface only as edge errors, costing the on-call the
  "which layer?" triage step during the worst possible minutes.

### `KcpShardErrorRateHigh` — warning, 10m, threshold 1%
- **Fires when:** shard-side 5xx ratio exceeds 1% for 10m.
- **Why it exists:** paired with the edge alert, it *localizes*: edge + shard both erroring
  → problem is here or below (etcd); edge only → the proxy is the patient. The pair is a
  built-in decision tree.
- **Without it:** every edge error investigation starts from zero.

### `KcpShardAPFRejecting` — warning, 10m
- **Fires when:** API Priority & Fairness rejections are non-zero, sustained.
- **Why it exists:** APF rejections mean the shard is *already* shedding load — tenants are
  getting 429s. It's the "over the cliff" complement to watching inflight climb.
- **Without it:** load-shedding looks like flaky tenant clients ("retry worked") and can go
  on for days. Note: the rejection counter registers lazily — the metric being absent is
  itself proof no rejection has ever happened.

### `KcpShardLatencyHigh` — warning, 30m, p99 > 1s
- **Fires when:** read or write p99 (non-streaming verbs) stays above budget 30m.
- **Why it exists:** the read/write split in the recording rules makes this diagnostic, not
  just alarming: slow writes implicate etcd consensus, slow reads implicate cache/informer
  pressure. The alert inherits that direction-finding.
- **Without it:** creeping apiserver slowness surfaces only via the edge alert — after
  every tenant already feels it.

### `KcpShardStorageObjectsHigh` — warning, 30m, threshold 10000/resource
- **Fires when:** any single resource type's stored-object count crosses the capacity line.
- **Why it exists:** unbounded object growth is the *slow* killer — it burns etcd quota and
  list latency weeks before anything errors. Per-resource, so the offender is named in the
  alert labels (us-2 max today: ~200 — the 10k threshold is a deliberate early tripwire).
- **Without it:** the first symptom of a leaking controller would be `KcpEtcdDBSizeHigh` —
  much later, with the diagnosis still to do.

## Area 3 — etcd + backups (the storage backbone)

kcp is exactly as healthy as this etcd. Three alerts predict outages, two guard capacity,
one guards recoverability.

### `KcpEtcdNoLeader` — critical, 1m
- **Fires when:** any member's `etcd_server_has_leader` (etcd container only) reads 0 for 1m.
- **Why it exists:** no leader = no writes = the control plane is read-only *right now*.
  The 1m `for:` is the shortest in the chart because this is a hard outage in progress.
- **Without it:** a leaderless etcd looks like "everything is mysteriously timing out"
  across all other alerts, none of which name the cause.
- **Hardening (us-2):** the backup-restore sidecar exports its own permanently-zero copy of
  this gauge — the alert fired on all 3 healthy members until the expr pinned
  `container="etcd"` and the sidecar's mirror was dropped at ingestion.

### `KcpEtcdLeaderChangesHigh` — warning, 15m, > 3/hour
- **Fires when:** leader elections churn faster than 3/hour.
- **Why it exists:** each election is a write stall; frequent elections are the signature
  of disk or network distress *before* quorum is actually lost — the early-warning twin of
  `NoLeader`.
- **Without it:** we'd only ever see the terminal state. Churn + `DiskSlow` firing together
  is the classic "storage is killing etcd" pattern.

### `KcpEtcdDiskSlow` — warning, 15m, fsync p99 > 10ms / commit p99 > 25ms
- **Fires when:** WAL fsync or backend commit p99 exceeds the upstream etcd guidance.
- **Why it exists:** slow fsync is *the* canonical predictor of etcd trouble (elections,
  write stalls). Deterministic, upstream-sanctioned budgets.
- **Without it:** storage degradation surfaces as unexplained shard write latency and
  leader churn, with the root cause invisible.
- **Calibration (us-2):** the storage baseline is ~170–190ms — genuinely bad (SRE finding
  F1) but *chronic*; the us-2 values raise the thresholds to 0.5s/1.0s so the alert pages
  on degradation-from-baseline instead of firing forever. The finding is tracked in the
  validation report, not silenced by pretending the alert doesn't apply.

### `KcpEtcdDBSizeHigh` — warning, 15m, > 80% of quota / `KcpEtcdDBSizeCritical` — critical, 5m, > 95%
- **Fires when:** the DB crosses 80% (act soon) / 95% (act now) of the backend quota.
- **Why they exist:** at 100% etcd raises a no-space alarm and goes **read-only** — a
  self-inflicted total outage with a documented, avoidable cause. Two stages because the
  correct responses differ: 80% = schedule compaction/defrag/quota-raise; 95% = do it now.
- **Without them:** the single most preventable full-platform outage in the book would be
  discoverable only by hitting it.

### `KcpEtcdBackupStale` — critical, 15m, Full > 26h / Incr > 60m
- **Fires when:** the *cluster-latest* snapshot (max across members) exceeds its age budget.
- **Why it exists:** a control plane without a recent backup is one incident away from
  unrecoverable. This is the platform's restore-point objective as an alert; 26h gives the
  daily druid full-snapshot schedule 2h of grace.
- **Without it:** backup rot is discovered during a disaster, i.e. never in time. The etcd
  can be perfectly green for months while its backups quietly fail.
- **Hardening (us-2):** snapshot timestamps are per-member and only the currently-snapshotting
  member's are fresh — the alert fired on two healthy members whose *cluster* backup was 5
  minutes old. Expr now takes `max by (kind)` across members.

## Area 4 — Workspace lifecycle (the kcp differentiator)

### `KcpWorkspacesStuck` — warning, 15m, > 8 not-ready
- **Fires when:** `kcp:workspaces_not_ready:count` (workspaces + logicalclusters in
  non-Ready phases, leader's view) exceeds the per-cluster baseline.
- **Why it exists:** stuck tenancy provisioning is the platform failing at its core job,
  and nothing in a stock Kubernetes alert set knows workspaces exist. Phase-based and
  deterministic.
- **Without it:** tenants wait on workspaces that will never arrive, and the platform's
  flagship feature has zero coverage.
- **Calibration (us-2):** the threshold sits at the standing baseline (8–10 logicalclusters
  in `Scheduling` all week — SRE finding F2). It fires today as a **true positive**. When
  SRE resolves or accepts F2, recalibrate `baseline` above the accepted floor — the panel
  "Not-ready trend" is the evidence for choosing the number.

## Area 5 — APIExport / APIBinding (the API economy)

### `KcpAPIBindingNotReady` — warning, 15m
- **Fires when:** any binding condition (`Ready` and friends) sits `False|Unknown`, by
  condition name.
- **Why it exists:** a degraded binding is a tenant whose subscribed service stopped
  working. The condition label in the alert *is* the diagnosis direction
  (`APIExportValid` → supply side; `PermissionClaimsApplied` → authz).
- **Without it:** broken service consumption is a per-tenant support ticket instead of a
  single platform signal.

### `KcpAPIBindingSlow` — warning, 30m, TTR p95 > 5s
- **Fires when:** binding time-to-ready p95 regresses past budget (histogram is in **ms** —
  threshold `p95Ms`).
- **Why it exists:** provisioning UX regresses silently as scale grows; a binding that
  takes 4 minutes still "succeeds" and would never trip `NotReady`.
- **Without it:** the subscribe-to-usable experience decays with no signal until users
  complain — the classic slow-boil regression.

### `KcpAPIExportNotValid` — critical, 10m
- **Fires when:** an export's `IdentityValid`/`VirtualWorkspaceURLsReady` condition leaves
  `True`.
- **Why it exists:** one invalid export breaks **every** binding to it simultaneously — the
  single highest blast radius on the platform (hundreds of bindings per export). That's why
  it's the only `critical` in the area.
- **Without it:** a mass-outage of a service API would present as hundreds of individual
  binding alerts (or tickets) with the common cause unnamed.

## Area 6 — kcp controllers (the reconciliation machinery)

Two alerts covering the ways the machinery degrades that rows of green pods won't show.

### `KcpControllerQueueBacklog` — warning, 15m, depth > 10
- **Fires when:** a `kcp-*` workqueue's depth — `min` across shard replicas — stays high.
- **Why it exists:** backlog is latency between "tenant changed something" and "it took
  effect". By the time this bites, workspaces and bindings are slow with nothing "down";
  the queue *name* in the alert points at the exact controller.
- **Without it:** reconciliation lag is invisible until `WorkspacesStuck`/`BindingSlow`
  fire — this is their earliest common ancestor.
- **Hardening (us-2):** the non-leader replica never runs workers, so its queues grow
  forever — the alert fired permanently on the follower (202 deep) while the leader sat at
  0. Expr now takes `min` across replicas (the actively-drained queue). Documented blind
  spot, accepted over a permanent false page: a real leader backlog is masked while a
  freshly-restarted replica's near-empty queues hold the min down.

### `KcpControllerProcessingSlow` — warning, 30m, work p99 > 10s
- **Fires when:** a controller's per-item work duration p99 stays pathological.
- **Why it exists:** the failure mode depth can't see — items *succeed slowly* (a slow
  external call, a huge LIST per reconcile). Depth may barely move while throughput dies.
- **Without it:** slow-reconcile bugs hide behind healthy-looking queue depths; together
  with `QueueBacklog` (and the retries panel) the jammed/slow/thrashing triad is covered.

## Area 7 — SCO service agents (api-syncagent)

> Both alerts are **disabled on us-2** until the agents expose metrics
> (`--metrics-address=0.0.0.0:8085` — report issue S1). Deliberately disabled-with-reason
> beats firing 20 false pages: benign ≠ actionable.

### `KcpSyncAgentDown` — critical, 5m
- **Fires when:** an agent target is down **or** a service has no leading agent
  (`leader_election_master_status` max == 0 per service).
- **Why it exists:** a dead or leaderless agent means that service's tenant claims
  **silently stop syncing** — no errors appear anywhere else in the platform. The
  leadership clause matters: an agent can be up and not leading, with the identical
  tenant-visible outcome.
- **Without it:** this failure mode has *zero* other coverage. Tenants discover it when
  their resources stop converging; nobody else notices at all.

### `KcpSyncAgentClientErrors` — warning, 15m, > 5% of client calls
- **Fires when:** an agent's REST calls (to kcp or the service cluster) error above 5%.
- **Why it exists:** expiring kubeconfigs, RBAC drift, unreachable endpoints — the leading
  indicators that end in `SyncAgentDown`. Catching them here is business-hours work instead
  of a page.
- **Without it:** agent death arrives without warning; per-service credential rot is
  invisible until it's total.

## Area 8 — Footprint (the pods)

The most "generic-looking" alerts in the chart — kept because they're **scoped, not
generic**: `podRegex` restricts them to kcp components in the release namespace, so each is
"a kcp control-plane pod is in trouble", not cluster noise. Every layer above degrades
mysteriously when its pod is throttled, OOM-killed, or restart-looping.

### `KcpPodRestarting` — warning, 15m, > 3 restarts/hour
- **Why it exists:** crash-looping that readiness probes hide (pod recovers between
  probes). It found a real thing on day one: the us-2 syncagents carry a standing restart
  baseline that nothing else surfaced.
- **Without it:** flapping components look healthy in every phase-based view.

### `KcpPodOOMKilled` — critical, no `for:`
- **Why it exists:** an OOM kill is a discrete fact (`last_terminated_reason=OOMKilled`) —
  there is no "sustained" version, hence no `for:`. Any kcp component being OOM-killed is
  memory-limit misconfiguration or a leak, both actionable.
- **Without it:** OOM kills bury themselves in restart counts, and the *reason* — the part
  that names the fix — is lost.

### `KcpPodCPUThrottled` — warning, 30m, > 5% of CFS periods
- **Why it exists:** throttling is the invisible latency source — a throttled pod is slow
  with zero errors in any log or metric. Proven live: us-2's shard *leader* was throttled
  9.6% of periods (SRE finding F3), directly taxing every apiserver request.
- **Without it:** we'd tune etcd and chase latency alerts while the actual cause is a CPU
  limit set too tight.

### `KcpPodMemoryHigh` — warning, 30m, > 90% of limit
- **Why it exists:** the pre-OOM warning. 90%-of-limit for 30m means the next load spike is
  a `critical`. Paired with the goroutine panel it separates "leak" from "undersized".
- **Without it:** memory problems would only ever surface as the OOM kill itself — reactive
  instead of preventive.

---

## Known gaps (deliberate, tracked)

- **Blindness watchdog (planned):** every `*Down` alert is `up == 0`, which only fires
  while the target *exists and fails*. If targets **vanish** (ServiceMonitor deleted,
  selector drift, relabel bug — exactly what happened to the 20 syncagent targets during
  validation), `up == 0` matches nothing and everything goes silently green. The fix is one
  `absent(up{job=...})` alert per enabled monitor — kcp-scoped, guards the alerting system
  itself.
- **Story 1.4** (per-shard reachability through the proxy): no per-backend proxy metric
  exists on v0.32.1; the observable signature is `KcpShardDown` + edge 5xx together.
  Deferred as its own alert, on purpose.
- **Syncagent alerts disabled on us-2** until S1 (loopback bind) is fixed agent-side.

## Maintenance rules

- New alerts: `Kcp` prefix, `rulesgroup: kcp`, one named failure mode, deterministic expr,
  every threshold in `values.yaml`, a promtool unit test that encodes the *fix rationale*
  (see the leader/follower and sidecar tests), and metrics proven in `tests/fixtures/`.
- A firing alert nobody acts on is a defect: either fix the condition, recalibrate the
  threshold with panel evidence, or delete the alert. Never mute-and-forget.
- Every alert shares its query with a dashboard panel (`dashboard-guide.md`) — the panel is
  where you *calibrate*, the alert is where you *commit* to a budget.
