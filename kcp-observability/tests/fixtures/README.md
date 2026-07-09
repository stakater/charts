# Captured metric fixtures — provenance & findings

**Captured:** 2026-07-09, live from **us-2** (`api-us-2-b24jftow-stakater-cloud`), namespace
`kcp-config` / `kcp-operator`.
**Versions:** kcp **v0.32.1** (root shard + front-proxy), root-proxy v0.31.1 (legacy),
api-syncagent **v0.5.0**, gardener etcd-wrapper v0.6.2 / etcdbrctl v0.41.2, kcp-operator +
etcd-druid.
**Method:** `kubectl port-forward` per pod + curl. Shard `/metrics` requires auth — used the
operator-generated admin kubeconfig (`kubeconfigs.operator.kcp.io/kcp-admin-frontproxy` secret,
by reference, never committed). etcd via `etcd-client-tls` client cert. Front-proxy and
root-proxy allow anonymous `/metrics`.

**Sampling:** raw dumps are large (shard = 4 MB), so each fixture keeps `# HELP`/`# TYPE` lines
plus the **first 8 series per metric family** — enough to pin names and label shapes. Two
exceptions kept **in full** (appended at the bottom of the file): all `kcp_*` series and all
`workqueue_*{name="kcp-*"}` series in `shard-metrics.txt`, and all `proxy_request_duration_*`
in `front-proxy-metrics.txt` — those label sets are load-bearing for the rules.

| Fixture | Component | Scrape endpoint | Auth |
| --- | --- | --- | --- |
| `shard-metrics.txt` | root shard (`root-kcp`) | :6443/metrics | kcp admin kubeconfig |
| `front-proxy-metrics.txt` | `frontproxy-front-proxy` | :6443/metrics | anonymous |
| `root-proxy-metrics.txt` | `root-proxy` (legacy v0.31.1) | :6443/metrics | anonymous |
| `etcd-metrics.txt` | druid etcd (`root-0`) | :2379/metrics | etcd client cert |
| `etcd-backup-restore-metrics.txt` | etcdbrctl sidecar | :8080/metrics (https) | anonymous |
| `syncagent-metrics.txt` | api-syncagent (`services-compute…`) | :8085/metrics (http) | anonymous |

**Not captured:** `kcp-operator` metrics (:8443 behind kube-rbac-proxy returned
"Authentication failed" for the cluster-admin token — not pursued; the operator is a
meta-controller outside the roadmap's critical path). No standalone cache server or
virtual-workspace deployments exist on us-2 (embedded in the shard).

---

## Answers to the 5 open questions (from `../METRICS-CAPTURE.md`)

1. **Do apiserver request metrics carry a workspace/logical-cluster label?** **No.**
   `apiserver_request_total{code,component,dry_run,group,resource,scope,subresource,verb,version}`
   — no `cluster`/`workspace` dimension. Per-tenant *request* observability is not possible;
   per-tenant signals live at the workspace/binding layer (see 2).

2. **Workspace lifecycle metrics?** **Native, aggregate by phase+shard** (not per-workspace):
   - `kcp_workspace_count{phase="Ready|Initializing|Scheduling|Unavailable",shard}` (us-2: 108 Ready)
   - `kcp_logicalcluster_count{phase,shard}` (136 Ready, 8 Scheduling)
   - `kcp_indexed_logicalclusters{shard}`
   Like crossplane's per-GVK counts: inventory + stuck-detection yes; per-tenant attribution
   needs a different layer (deferred honestly, see roadmap 4.1).

3. **Front-proxy metric shape?** **Not** `apiserver_request_*`. The edge signal is the
   proxy-specific family `proxy_request_duration_seconds_{bucket,count,sum}{code,method}` —
   gives edge latency AND error rate (by `code`). Present in v0.32.1; **absent in the legacy
   v0.31.1 `root-proxy`**. Plus standard workqueue/go/process/authentication families.

4. **Separate scrape targets?** Shard, front-proxy, etcd (+ backup-restore sidecar), and each
   api-syncagent are separate targets. Cache server and virtual workspaces are **embedded** in
   the shard on us-2 (no standalone CRs). A `kcp-front-proxy` ServiceMonitor already exists in
   `kcp-config` (UWM-ingested, job=`frontproxy-front-proxy`); nothing scrapes the shard, etcd,
   or syncagents yet.

5. **The real `kcp_*` surface (v0.32.1, from the shard):**
   ```
   kcp_workspace_count{phase,shard}
   kcp_logicalcluster_count{phase,shard}
   kcp_indexed_logicalclusters{shard}
   kcp_apibinding_phase{phase="Binding|Bound",shard}            (us-2: 808 Bound)
   kcp_apibinding_condition_status{condition,status,shard}      (APIExportValid, BindingUpToDate,
                                                                 InitialBindingCompleted, Ready, …)
   kcp_apibinding_ready_duration_ms_{bucket,count,sum}{shard}   (binding TTR histogram!)
   kcp_apiexport_condition_status{condition,status,shard}       (IdentityValid, VirtualWorkspaceURLsReady, …)
   ```

## Other load-bearing facts

- **Shard** exposes the full apiserver surface: `apiserver_request_total` (351 series),
  `apiserver_request_duration_seconds_bucket` (5520), `apiserver_current_inflight_requests`,
  `apiserver_flowcontrol_*` (APF active), `apiserver_storage_objects{resource}` (incl.
  `apibindings.apis.kcp.io` = 202 — largest stored resource), plus etcd-client, workqueue, APF.
- **kcp controllers** run inside the shard as `workqueue_*{name="kcp-*"}` queues (~30:
  `kcp-apibinding`, `kcp-logicalcluster`, `kcp-logicalcluster-deletion`, `kcp-apiexport`,
  `kcp-replication-controller`, …). Controller health = workqueue metrics filtered
  `name=~"kcp-.*"`.
- **etcd**: all the classic series confirmed — `etcd_server_has_leader`,
  `etcd_server_leader_changes_seen_total`, `etcd_mvcc_db_total_size_in_bytes`,
  `etcd_server_quota_backend_bytes`, `etcd_disk_wal_fsync_duration_seconds_bucket`,
  `etcd_disk_backend_commit_duration_seconds_bucket`.
- **api-syncagent** (:8085) exposes only `rest_client_requests_total`,
  `leader_election_master_status`, certwatcher + webhook-panic counters, go/process. **No
  reconcile/workqueue families** — syncagent observability is limited to up/leader/client-errors.
- **`root-proxy` is a legacy v0.31.1 front-proxy** without the `proxy_request_duration` family.
  Flag for decommission or upgrade; the chart targets the v0.32.1 `frontproxy-front-proxy`.

## Re-capturing

Re-run the capture after a kcp upgrade (metric surfaces move between minors — e.g.
`proxy_request_duration` appeared only in 0.32). Follow `../METRICS-CAPTURE.md`; keep the same
sampling rule; never commit tokens/kubeconfigs (scratch dir only).
