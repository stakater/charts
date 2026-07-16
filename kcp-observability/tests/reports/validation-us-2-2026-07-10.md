# Validation report — us-2 — 2026-07-10

Chart/git: kcp-observability 0.0.1, branch `kcp-observability` @ `0b8b1a8` (+ sidecar
metric-drop commit following this report) | kcp: v0.32.1 (kcp-operator, 2-replica root
shard) | Helm revs exercised: 4 → 10 | **Verdict: PASS-WITH-ISSUES** (chart layers all
verified live; 3 SRE findings open, 1 agent-side blocker for syncagent scraping)

Everything below was observed against live us-2 (thanos-querier API + in-cluster
Prometheus/Thanos-Ruler endpoints), not inferred.

## 1. Scrape targets

| Job | Expected | Observed |
| --- | --- | --- |
| `root-kcp` (shard) | 2 | 2 up |
| `frontproxy-front-proxy` | 2 | 2 up |
| `root-client` (etcd client + backup-restore endpoints) | 6 | 6 up |
| `kcp-syncagent` | 20 | 20 **discovered**, 0 up — see issue S1; monitor disabled on us-2 |

Syncagent discovery itself is fixed and verified: after replacing the port field with an
`__address__` relabel to `podIP:8085`, all 20 agent pods appeared as active targets
(previously: 20 dropped). Scrapes then failed `connection refused` — the agent binds
metrics to loopback (S1), which no PodMonitor can work around.

**Front-proxy ServiceMonitor swap (2026-07-10, team-approved, recorded here per audit):**
the chart's `kcp-observability-front-proxy` ServiceMonitor was applied and verified
scraping (both pods up in a second scrape pool), then the 51-day-old hand-made
`kcp-front-proxy` monitor was deleted — zero metrics gap, same `job` label
(`frontproxy-front-proxy`) throughout. The 2 front-proxy targets in the table above are
the chart's monitor.

## 2. kcp-specific series

All present via thanos-querier (series counts at capture):
`kcp_workspace_count` 6, `kcp_logicalcluster_count` 6, `kcp_apibinding_phase` 4,
`kcp_apibinding_condition_status{condition="Ready"}` 2, `kcp_apiexport_condition_status` 2,
`kcp_apibinding_ready_duration_ms_bucket` 22, `etcdbr_snapshot_latest_timestamp{kind="Full"}` 3,
`proxy_request_duration_seconds_count` 30.

`service_agent` relabel: verified in the generated scrape config (pod-name prefix →
`service_agent`); end-to-end value check blocked by S1.

## 3. Recording rules

All 14 recording rules load and evaluate in **thanos-ruler** (not prometheus-user-workload —
UWM routes user rules there; recorded series live in the ruler TSDB and are queryable only
via thanos-querier). Spot values: `kcp:workspace_ready_ratio` = 1.0,
`kcp:workspaces_not_ready:count{shard="root"}` = 10, `kcp:etcd_db_used_ratio` ≈ 0.001,
`kcp:etcd_fsync_seconds:p99` ≈ 0.12–0.19 per member.

## 4. Alerts

25 kcp rule groups, 24 alerts + 14 recording rules, all `health: ok`, zero eval errors.

Five alerts were firing at session start; each was triaged to a verdict:

| Alert | Verdict | Root cause / action |
| --- | --- | --- |
| `KcpEtcdNoLeader` | **false positive — fixed** | etcd-backup-restore sidecar exports its own `etcd_server_has_leader`, permanently 0, on all 3 members (real etcd container reported 1). Expr now filters `container="etcd"`; sidecar's `etcd_*` mirror dropped at ingestion. |
| `KcpEtcdBackupStale` | **false positive — fixed** | Only the currently-snapshotting member's sidecar carries fresh timestamps; others report last-leadership times (cluster Full snapshot was 5 min old while two members claimed days). Expr now takes `max by (kind)` across members. |
| `KcpControllerQueueBacklog` | **false positive — fixed** | All firing series came from the non-leader shard replica, whose workqueues are never drained (follower 202, leader 0). Expr now takes `min` across replicas; blind spot documented in the template. |
| `KcpEtcdDiskSlow` | **real — SRE finding F1** | fsync p99 0.12s instant, 0.17–0.19s 7-day average on all 3 members vs 10 ms upstream guidance. us-2 values raise thresholds (0.5s/1.0s) to page on degradation-from-baseline instead of firing permanently. |
| `KcpWorkspacesStuck` | **real — SRE finding F2** | 10 logicalclusters in phase `Scheduling`; `min_over_time` 7d = 8, i.e. at least 8 stuck all week. Alert kept as-is. |

After the fixes (rev 10), firing set is exactly the true positives:
`KcpWorkspacesStuck` (F2) and `KcpPodCPUThrottled` (**real — SRE finding F3**: both
`root-kcp` pods CFS-throttled, leader at 9.6% of periods over 5m — shard CPU limits too
tight). Negative check passes: no alert fires on empty/absent data.

## 5. Dashboard

GrafanaDashboard CR reconciled: `DashboardSynchronized / ApplySuccessful — applied to
1 instances` (uid `kcp-control-plane`, folder "kcp Observability"). Getting there needed
two fixes (issues D1, D2 below).

Panel walk — all 54 panel queries executed against thanos-querier: **50 return data,
0 errors, 4 empty with explained causes**:
- APF rejections overlay: `apiserver_flowcontrol_rejected_requests_total` registers lazily;
  absent until the first rejection (documented-upstream metric — benign, confirmed absent).
- 3 syncagent panels (agent up/leader, client error ratio): blocked by S1.

`min(etcd_server_has_leader)` panel re-verified = 1 after the sidecar metric drop
(was pinned to 0 by the zero-mirror before rev 10). Platform-overview ballparks:
Workspaces Ready 135, logicalclusters Ready 170, alerts-firing stat matches
`count(ALERTS{rulesgroup="kcp", alertstate="firing"})` = 2.

## 6. Documented-not-captured metrics — graduate candidates

Confirmed live on us-2 (can graduate from `documented` to `captured` once a KSM/cAdvisor
fixture scrape is added): `kube_pod_container_status_restarts_total` (32 series),
`container_memory_working_set_bytes` (90), `kube_pod_container_resource_limits` (56).
`apiserver_flowcontrol_rejected_requests_total`: absent, benign (lazy registration).

## Issues

- [MAJOR, fixed `d554220`] **N1 — every `kcp_*` gauge is per-replica and replicas
  disagree**: only the controller-leader holds the full informer index (leader 108→135
  Ready workspaces, follower 27). `sum()` over pods double-counts; recording rules, 2
  alerts and 7 dashboard queries switched to `max by (shard, …)`; regression test added.
- [MAJOR, fixed `0b8b1a8`] **S0 — PodMonitor port fields cannot target an undeclared
  port**: `port`/`targetPort`/`portNumber` all generate a keep-relabel on declared
  container ports (upstream CRD doc confirms); syncagent pods declare none → 20 dropped
  targets. Fixed with an `__address__` relabel; job pinned to `kcp-syncagent` (operator
  defaults PodMonitor job to `<ns>/<name>`).
- [MAJOR, **open — agent-side**] **S1 — api-syncagent v0.5.0 binds metrics to
  `127.0.0.1:8085`** (verified in-pod: sole listener `0100007F:1F95`; flag default
  `--metrics-address=127.0.0.1:8085`). Unscrapeable until the 20 `api-syncagent` Helm
  releases pass `--metrics-address=0.0.0.0:8085`. Monitor + both syncagent alerts disabled
  in `docs/values-us-2-example.yaml` to avoid a 20-alert false flood; flip on after the
  agent fix.
- [MAJOR, fixed `0b8b1a8` + rev 9] **D1 — dashboard never reconciled**: (a) helm deep-merge
  kept the default `app: grafana` selector key alongside the override → selector matched no
  instance (`app: null` now documented in the values); (b) `spec.instanceSelector` is
  immutable → CR deleted/recreated; (c) the OLM-installed grafana-operator watches only
  `crossplane-observability` (OperatorGroup OwnNamespace) → `grafana.namespace` lands the
  CR there.
- [MAJOR, fixed (sidecar-drop commit)] **E1 — backup-restore sidecar exports a zero-valued
  mirror of every `etcd_*` metric** (db size 0, quota 0, has_leader 0, full histogram
  skeletons), polluting panels and any cross-container aggregation. Dropped at ingestion via
  `metricRelabelings` keep `etcdbr_.*` on the backuprestore endpoint; verified junk series
  gone from thanos after rev 10.
- Alert false positives: see triage table (3 fixed, unit tests encode each).

## SRE findings (open, not chart defects)

- **F1** etcd fsync p99 0.17–0.19s sustained (7d, all members) vs 10 ms guidance — etcd on
  slow/network storage; risks latency and leader elections under load.
- **F2** 10 logicalclusters stuck in `Scheduling` ≥7 days — needs cleanup/diagnosis;
  `KcpWorkspacesStuck` will keep firing until resolved (correctly).
- **F3** `root-kcp` CPU throttling (leader 9.6% of CFS periods) — raise shard CPU limits.

## Calibration observations

- `KcpWorkspacesStuck` threshold 8 sits exactly at the us-2 standing baseline (8–10). Kept —
  it is currently a true positive (F2). If SRE declares the stuck LCs permanent, raise the
  threshold above the accepted baseline rather than muting.
- `KcpEtcdDiskSlow` upstream-guidance thresholds (10ms/25ms) are unreachable on us-2 storage;
  us-2 values override to 0.5s/1.0s (degradation-from-baseline). Drop the override if storage
  improves (F1).
- DEPLOY-VALIDATION brief ballparks drifted: workspaces Ready 108 → 135, syncagents 10 → 20.

---

## Addendum — 2026-07-16 live verification (post-audit, chart rev 11)

The runbook was executed live for the first time (all commands in
`docs/alerts-guide.md` § Runbook are now verified; access facts — front-proxy refuses
wildcard, shard requires `system:masters`, workspaces 404 at wildcard — were discovered
here). Findings:

- **F2 resolved to truth:** the "8–10 stuck logical clusters" is **2** in etcd — both
  `root:cloud:e2e-testing:e2e-vm-project` (cluster IDs `1muhm7z511vwnzvd`,
  `2dcwd5j12mtqbikh`), created 2026-03-27/30, stuck in `Scheduling` ~3.5 months; the older
  one orphaned by a workspace re-create. **Action: e2e cleanup deletes two LogicalClusters.**
- **F5 (new, upstream kcp bug):** the `kcp_*` count gauges are unreliable in absolute
  terms on v0.32.1. etcd truth vs metric at verification: workspaces **33** vs 135 Ready;
  logical clusters **36** vs 180; stuck **2** vs 10; apibindings **202** vs ~800 Bound.
  Both shard replicas started within 8s of each other yet report 27 vs 135 — the drift is
  churn-correlated (leader inflates), not uptime- or informer-partiality-correlated, so
  **no aggregation (max/min) recovers truth**. Chart response: count panels and the two
  stuck alerts now carry an explicit unreliability caveat + runbook pointer; treat gauges
  as trend signals only. **Filed upstream: [kcp-dev/kcp#4277](https://github.com/kcp-dev/kcp/issues/4277)**
  (root cause: event-driven Inc/Dec gauges from #4095/#4147 — suggested collect-time
  computation from the informer store). Overview dashboard stats switched to
  `apiserver_storage_objects`, which matched etcd exactly at verification.
- **F4 (new, real):** `PermissionClaimsValid=False` on **98 of 202** apibindings (etcd
  truth; the metric's 392 is the same drift). All 202 bindings are otherwise fully Ready.
  Widespread genuine condition — needs SCO-side triage; deliberately NOT alerted (would
  page forever) but visible in the "Binding conditions not True" panel.
- **`VirtualWorkspaceURLsReady` is never emitted by kcp v0.32.1** (15 exports live, all
  `IdentityValid=True` only). Trimmed from the `KcpAPIExportNotValid` expr with a
  restore-when-observed comment.
- The ephemeral `system:masters` audit cert (`kcp-audit-admin-ephemeral`, 1h TTL) was
  minted for the verification and deleted afterwards.

## Addendum — 2026-07-16 (later): S1 resolved, syncagent monitoring live

The api-syncagent releases now pass `--metrics-address=0.0.0.0:8085` (verified in-pod:
args + socket on all interfaces; pods still declare no containerPort, so the PodMonitor's
`__address__` relabel remains required). `syncAgentPodMonitor` + both syncagent alerts
enabled (rev 14); **20/20 targets up**. Live corrections from first real agent data:

- **Topology**: each service runs a 2-replica agent Deployment with leader election
  (~10 services × 2 pods, one leader each) — not "one agent per service" as previously
  documented. The down-alert's `max by (service_agent)` leadership clause handles this
  correctly by construction.
- **Truncated pod names** (rev 15): `services-experimental.compute...` pods hit the
  63-char name limit, fusing the ReplicaSet hash + suffix; the `service_agent` relabel
  regex gained a second alternative for the fused shape (was: empty label).
- **Refined blindness case**: one agent pod sat in phase `Failed` for ~2 days (preempted;
  a healthy replacement existed). Failed pods are dropped by Prometheus — no target, no
  `up==0` — so a service whose replicas ALL end that way would page nothing. Folded into
  the tracked absent()-watchdog gap.
