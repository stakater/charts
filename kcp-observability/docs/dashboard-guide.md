# Dashboard guide — kcp / Control Plane (`kcp-control-plane`)

Why every panel exists and what to do when it moves. The dashboard is the visual layer of
[`roadmap.md`](roadmap.md): each row maps to a capability area, and every query was verified
against live us-2 data (see `tests/reports/`). Panels use the leader-aware aggregations
(`max by (shard)` for `kcp_*` gauges) — the raw per-pod series disagree between shard
replicas and must not be read directly.

The design rule for the whole board: **top rows answer "is the platform OK for customers?",
lower rows answer "which layer is breaking, and why?"**. An on-call engineer should be able
to go top-to-bottom during an incident and stop at the first row that explains the symptom.

---

## Row 1 — kcp alerts

The board opens with the alert state so nobody has to cross-reference Alertmanager.

| Panel | Why it exists / value |
| --- | --- |
| **Alerts firing** (stat) | The one number that says whether this page is an incident review or a routine glance. Counts only `rulesgroup="kcp"` alerts — this chart's, nothing else's. Zero on a healthy day; the validated baseline on us-2 is the true positives documented in the current report. |
| **kcp alert rules (all states)** (alert list) | Shows every rule this chart ships with live state — including `pending`. Value: you see an alert *building* (pending) before it pages, and after an incident you can confirm the rule actually returned to `inactive` instead of assuming. |

## Row 2 — Platform overview

Twelve stats, one screen: the health contract of the whole control plane. Each stat is the
"headline number" of a deeper row below — if a stat looks wrong, its row has the breakdown.
This row exists because the first minute of any incident is triage: *what kind of problem
is this — tenancy, edge, storage, or agents?*

| Panel | Why it exists / value |
| --- | --- |
| **Workspaces Ready** | The platform's reason to exist: how many tenant workspaces are actually usable. This is the number a status page or customer conversation needs. (135 on us-2 at validation.) |
| **Workspaces not Ready** | The complement that makes the first number honest — 500 Ready means nothing if 40 are stuck. Non-zero here sends you to the "Workspaces & logical clusters" row. |
| **Logical clusters Ready** | Workspaces are the tenant-visible wrapper; logical clusters are the underlying kcp primitive (there are more of them — 170 vs 135 on us-2). Divergence between the two counts localizes a lifecycle bug to the wrapper vs the core. |
| **APIBindings Bound** | Every SCO service a tenant consumes is an APIBinding. This is "how many service subscriptions are live" — the platform's consumption headline (~800 at fixture-capture time; not re-checked in the validation report). |
| **Edge p95 latency** | The customer-facing latency promise (Area 1 is the only layer with a customer SLA). One number, alert-threshold colored — if it's green, latency complaints are probably not the platform edge. |
| **Edge 5xx ratio** | Same contract, error dimension. Alert threshold 0.5%; the stat exists so a creeping 0.3% is visible *before* the alert fires. |
| **etcd DB used of quota** | etcd at quota goes read-only — a self-inflicted full outage. This ratio is the earliest cheap warning (us-2 sits at ~0.1%; the alert fires at 80%). |
| **Last full etcd backup age** | The disaster-recovery contract. A control plane without a recent backup is one incident from unrecoverable — this stat makes backup rot visible daily, not discoverable during a restore. Uses `max` across members because only the snapshotting member's timestamp is current. |
| **Shards up** | The apiservers actually serving. Below the replica count → capacity/crash problem, go to "Shard apiservers". |
| **Front-proxy pods up** | The only door customers enter through. Any number below replica count is a customer-facing risk even if the shards are fine. |
| **Service agents leading** | One agent must hold leadership per SCO service API or that service's tenant claims silently stop syncing — "silently" is why the stat exists; nothing else surfaces it. (Blocked on us-2 until the agents expose metrics — see report issue S1.) |
| **APIExports** (IdentityValid) | Exports are the supply side of the API economy; an invalid export breaks *every* binding to it at once — the highest blast radius on the platform. This counts the healthy ones; the APIExport row has the breakdown. |

## Row 3 — Request edge (front-proxy) — Area 1

The customer's view of the platform. Everything a tenant does goes through the front-proxy,
so this row is deliberately expressed in *their* terms (rate, latency, errors) and is the
first stop for "the platform feels slow/broken" reports.

| Panel | Why it exists / value |
| --- | --- |
| **Edge request rate by code** | Traffic volume + status mix in one graph. A 401/403 surge is an auth regression, 429s are throttling, 5xx go with the error panel — the *code* split turns "traffic changed" into a diagnosis direction. |
| **Edge latency (p50/p95/p99)** | Three quantiles because they fail differently: p50 shift = systemic slowdown (etcd, shard saturation); p99-only shift = a heavy tenant or pathological request shape. Recording-rule backed so the alert and the panel can never disagree. |
| **Edge 5xx ratio** | The SLI behind the `KcpFrontProxyErrorRateHigh` alert, as a trend. Value over the stat: you see whether an error burst is a spike (deploy blip) or a plateau (real degradation), and when it started. |
| **Edge request rate by method** | Read/write mix. A WATCH storm or a PATCH flood implicate very different components (informers vs controllers); this is the cheapest way to see workload-shape changes that explain load elsewhere. |

## Row 4 — Shard apiservers — Area 2

One layer in from the edge: the kcp apiservers themselves. This row answers "the edge is
degraded — is the shard the reason?" and carries the platform's capacity early-warnings.

| Panel | Why it exists / value |
| --- | --- |
| **Shard 5xx ratio** | The shard-side twin of the edge error ratio. Edge 5xx high + shard 5xx high → problem is here or below (etcd); edge high + shard clean → problem is the proxy itself. That one comparison is the row's main triage value. |
| **Shard request latency p99 (read vs write)** | Reads and writes fail differently: writes go through etcd consensus (slow writes → etcd row), reads come from watch cache/storage (slow reads → informer/cache pressure). Splitting them builds the etcd-or-not decision into the panel. |
| **Inflight + APF rejections** | Saturation, before and after the cliff. Inflight climbing = pressure building; APF rejections non-zero = the shard is already shedding load and tenants are getting 429s. The rejection series registers lazily — an empty overlay genuinely means "never rejected". |
| **Top stored resources (growth watch)** | Object counts are the slow killer: unbounded growth of one resource type quietly burns etcd quota and list latency. `topk(10)` makes the offender self-identifying — you read the legend, you know which controller/tenant to visit. |
| **Shard request rate by verb** | The workload fingerprint. When load doubles, this says *what kind* of load (LIST storms from a misbehaving client vs organic WATCH growth) — the difference between rate-limiting a tenant and scaling the shard. |

## Row 5 — etcd — Area 3

The storage backbone. kcp is exactly as healthy as this etcd; every panel here is either an
outage predictor or a disaster-recovery guarantee. All queries read the etcd container's
series only — the backup sidecar's zero-valued mirror is dropped at ingestion (report E1).

| Panel | Why it exists / value |
| --- | --- |
| **etcd disk p99 (fsync / commit)** | The canonical etcd health signal: slow fsync precedes leader elections and write stalls. Budgets annotated (10ms fsync / 25ms commit upstream). us-2 reality: ~120–190ms baseline on network storage — a standing SRE finding (F1); the panel is what proves improvement if the storage changes. |
| **etcd DB size vs quota** | Trend version of the overview stat. Value is the *slope*: you can read off "at this growth we hit quota in N weeks" and act (compaction/defrag/quota) months before the read-only cliff. |
| **Leader changes (1h) / has-leader** | has-leader==0 is a hard outage (writes stop). Leader *churn* is the subtler signal: elections every few minutes mean disk or network distress even though each individual state looks "healthy". Churn here + fsync spikes to the left = storage, not etcd, is the patient. |
| **Backup age (full / incremental)** | The restore-point guarantee, as a sawtooth. A healthy pattern is visible at a glance (age climbs, drops to zero on each snapshot); a flatlining sawtooth is backup death even before the 26h alert budget. `max` across members — per-member ages are meaningless (only the snapshotting member is current). |
| **Snapshot failures** | Backup age only rises *after* backups have been failing for a while; the failure rate says it immediately, and catches flapping (fail-fail-succeed) that never trips the age alert but signals a rotting backup path. |

## Row 6 — Workspaces & logical clusters — Area 4

The kcp differentiator: multi-tenant workspace lifecycle. Nothing in stock Kubernetes
dashboards covers this — these panels are why the chart exists rather than a generic
apiserver board.

| Panel | Why it exists / value |
| --- | --- |
| **Workspaces by phase** | The tenancy pipeline over time. A growing `Scheduling` band = provisioning is stuck (scheduler/shard assignment); growing `Initializing` = initializers (controllers) are stuck. The phase tells you *which* subsystem owns the bug. |
| **Logical clusters by phase** | Same pipeline one level down. Because every workspace is backed by a logical cluster, comparing the two panels localizes lifecycle failures: workspace stuck + LC fine → workspace controller; both stuck → core scheduling. (us-2's standing 10 `Scheduling` LCs — finding F2 — live here.) |
| **Not-ready trend (stuck watch)** | The exact inputs of the `KcpWorkspacesStuck` and `KcpLogicalClustersStuck` alerts, plotted as two named series (workspaces vs logical clusters) so the stuck *resource* is identified at a glance — a combined count once read "10 workspaces" on us-2 when it was 0 workspaces + 10 logical clusters. Value: separates "stuck and accumulating" (bad, slope up) from "high but stable baseline" (calibration question), and is how you re-baseline the alert thresholds with evidence. The metrics are counts only — to list *which* objects are stuck, use the runbook in [`alerts-guide.md`](alerts-guide.md#runbook-identifying-stuck-workspaces-and-logical-clusters). |

## Row 7 — APIBindings & APIExports — Area 5

The API economy: services published (exports) and consumed (bindings). This is where "my
service claim isn't working" tickets get triaged.

| Panel | Why it exists / value |
| --- | --- |
| **APIBindings by phase** | Consumption health over time. A dip in `Bound` during a service rollout = the rollout broke consumers; flat during the same rollout = it didn't. Before/after evidence for every export change. |
| **Binding conditions not True** | A superset diagnostic view of every binding condition — deliberately WIDER than `KcpAPIBindingNotReady`, which fires only on the `Ready` rollup (audit-corrected: conditions here can be non-zero without paging; us-2 carries a standing `PermissionClaimsValid=False` ~392). The condition name is the diagnosis: `APIExportValid` → supply side broke; `PermissionClaimsValid` → authz; `InitialBindingCompleted` → binding controller. |
| **APIBinding time-to-ready p95** | Provisioning UX as a number: how long a tenant waits between "subscribe" and "usable". Creeping TTR is invisible in binary up/down metrics but is exactly what tenants feel — and it regresses silently as scale grows. |
| **APIExport conditions (instant)** (table) | The supply-side truth table per shard. Only `IdentityValid` has been observed on us-2 (kcp v0.32.1); `VirtualWorkspaceURLsReady` appears in no capture — its absence is expected, not data loss. A table, not a graph, because during an incident you want *current state* readable in one look, not history. |
| **Export conditions not True** | The trend twin of the table, and the `KcpAPIExportNotValid` alert input. Highest blast radius on the platform (one export ↦ hundreds of bindings), so it gets both an instant and a trend view. |

## Row 8 — kcp controllers (workqueues) — Area 6

The reconciliation machinery. Everything in rows 6–7 is *done by* these controllers, so
this row is the "why" behind lifecycle symptoms: workspaces stuck → which queue is jammed?

Panels show raw per-replica queues (`topk` across both shard pods) — remember the
`KcpControllerQueueBacklog` alert takes `min` across replicas because the non-leader's
queues are never drained; on these panels a follower's flat-lining queue is expected noise
and the leader's series is the signal.

| Panel | Why it exists / value |
| --- | --- |
| **Queue depth (top 10)** | Backlog = latency between "tenant changed something" and "it took effect". `topk` self-selects the jammed controller by name (`kcp-apibinding`, `kcp-permissionclaimlabel`, …) — the legend is the diagnosis. |
| **Retries/s (top 10)** | Depth can be zero while a controller retry-loops on a poison object. Sustained retries with stable depth = failing-fast on the same item; the fix is that object, not capacity. Complements depth exactly where depth is blind. |
| **Work duration p99 (top 10)** | The third failure mode: items processed successfully but *slowly* (each reconcile hits a slow external call or a huge LIST). Depth rises but retries stay flat → look here. The three panels together cover jammed / thrashing / slow — every way a controller degrades. |

## Row 9 — SCO service agents (api-syncagent) — Area 7

The last mile: agents that sync tenant claims from kcp to the underlying service clusters.
A dead agent produces **no** errors anywhere else — tenant claims just silently stop
converging — so this row is the only coverage this failure mode has.

> Currently empty on us-2: api-syncagent v0.5.0 binds metrics to `127.0.0.1:8085`
> (report issue S1). The panels, monitor, and alerts are ready; flip
> `syncAgentPodMonitor.enabled` + the syncagent alerts on once the agent releases pass
> `--metrics-address=0.0.0.0:8085`.

| Panel | Why it exists / value |
| --- | --- |
| **Agent up / leader per service** | Per-service liveness *and* leadership, keyed by the `service_agent` relabel (pod-name prefix → human-readable service name, e.g. `services-compute.cloud.stakater.com`). Both series matter: a pod can be up and not leading — same tenant-visible outcome as down. |
| **Agent client error ratio** | Agents live or die by their API calls to kcp and the service cluster. A rising 5xx/error ratio per service catches expired kubeconfigs, RBAC drift, or an unreachable kcp *before* the agent gives up leadership — the leading indicator for the panel above. |

## Row 10 — Footprint — Area 8

The pods themselves, filtered to kcp components (`$pod_regex`). This row exists because
every layer above degrades mysteriously when its pod is being throttled, OOM-killed, or
restart-looping — cheap infra signals that explain expensive control-plane symptoms.

| Panel | Why it exists / value |
| --- | --- |
| **Container memory working set** | The OOM predictor, `topk(15)` so the hungriest pods self-identify. Read together with limits: working set near limit = next load spike is an OOM kill. |
| **CPU throttle ratio** | The invisible latency source: a throttled pod is slow with *zero* errors in any log. us-2 proof: the shard leader was CFS-throttled 9.6% of periods (finding F3) — this panel is what surfaced it and what proves a limits increase worked. |
| **Restarts (1h)** | Crash-looping that readiness probes hide (pod recovers between scrapes). Also the panel that made the us-2 syncagent standing-restart baseline visible — a real finding no other signal caught. |
| **Goroutines (kcp components)** | Go-specific early warning: a monotonic goroutine climb is a leak and precedes the OOM by hours — enough time to act during business hours instead of at 3am. |
| **Process RSS (kcp components)** | The process-level memory twin, comparable across shard/proxy/etcd/agents in one graph since they're all Go. Divergence between RSS and working set also flags page-cache-vs-heap confusion when debugging "memory growth". |

---

## Reading the board during an incident

1. **Row 1** — is anything firing? Trust the triage table in the latest
   `tests/reports/validation-*.md` for known baselines.
2. **Row 2** — which stat is off? It names the row to open.
3. Open that row; the panel legends are written to make the failing component
   self-identifying (`topk` + meaningful label dimensions everywhere).
4. Controllers (row 8) and Footprint (row 10) are the two "why" rows — lifecycle symptoms
   usually resolve to a jammed queue or a throttled/OOM pod.

## Maintenance rules

- Every panel query must reference only metrics proven in `tests/fixtures/` or listed
  with a citation in `metrics-allowlist.documented.txt` (the two-allowlist offline
  gate enforces this) — no aspirational panels.
- `kcp_*` gauges: always `max by (shard, …)` (leader's view); workqueue alerts: `min`
  across replicas. Never `sum` over shard pods — the replicas disagree by design.
- If you add a panel, say in its `description` which alert (if any) shares its query, and
  add the metric to the fixtures first.
