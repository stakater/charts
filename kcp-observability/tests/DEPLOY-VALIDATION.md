# Deploy-validation brief — kcp-observability

**Audience:** the agent (or human) with cluster access deploying this chart and reporting
back. Same loop that hardened crossplane-observability: deploy → verify each layer against
the live cluster → file a structured report in `tests/reports/validation-<cluster>-<date>.md`.

**Honesty rule:** report what you SAW (query outputs, screenshots), not what should happen.
"Could not verify" beats a guessed PASS. Never mark an item PASS without pasted evidence.

## 0. Pre-flight

- Cluster: us-2 (or note which). Namespace: `kcp-config`.
- Record: kcp version (RootShard CR image tag), chart version, git SHA deployed.
- The SRE steps in README ("Deploying on a cluster") are prerequisites — especially the
  shard `/metrics` authz (step 2) and removing the old `kcp-front-proxy` ServiceMonitor (3).

## 1. Scrape targets land in UWM

For each enabled monitor, from the thanos-querier API (`oc whoami -t` token):

```
count by (job) (up{namespace="kcp-config"})
```

Expect jobs: `root-kcp` (2 targets), `frontproxy-front-proxy` (2), `root-client` (3 etcd +
backup-restore endpoints), `kcp-syncagent` (10). **The shard job is the one most likely to
fail** — if `up{job="root-kcp"}` is missing or 0 with scrape errors, check the authz
prerequisite (403 = always-allow-paths not applied). Report the exact scrape error from the
Prometheus targets page (`oc -n openshift-user-workload-monitoring port-forward ...` or the
console UI).

## 2. The kcp-specific series arrive

These are the chart's differentiator — verify each returns data:

```
kcp_workspace_count
kcp_logicalcluster_count
kcp_apibinding_phase
kcp_apibinding_condition_status{condition="Ready"}
kcp_apiexport_condition_status
kcp_apibinding_ready_duration_ms_bucket
etcdbr_snapshot_latest_timestamp{kind="Full"}
proxy_request_duration_seconds_count
leader_election_master_status{job="kcp-syncagent"}
```

For the syncagent job also verify the **`service_agent` relabel** worked:
`count by (service_agent) (up{job="kcp-syncagent"})` should list the 10 service names,
NOT a hash.

## 3. Recording rules evaluate

```
kcp:front_proxy_error_ratio:rate5m
kcp:front_proxy_latency_seconds:p95
kcp:shard_error_ratio:rate5m
kcp:workspace_ready_ratio
kcp:apibinding_ready_ratio
kcp:etcd_db_used_ratio
kcp:workspaces_not_ready:count
```

Each must return a value (thanos-ruler evaluates them; allow ~2 eval cycles). If a recording
rule is empty but its inputs (section 2) have data, check thanos-ruler logs for the rule group.

## 4. Alerts: state + one live-fire

- `ALERTS{rulesgroup="kcp"}` — expect the full rule set present (mostly `inactive` is fine;
  list any `firing` and judge each: real issue vs threshold-to-calibrate).
- **Known live-fire candidates on us-2 at capture time:** `KcpWorkspacesStuck` sits exactly at
  its baseline (8 stuck logical clusters were standing) — if it fires, that's the calibration
  question, not a bug; report the actual count.
- **Negative check:** no alert should be firing on empty/absent data (a firing alert whose
  panel shows no data = a broken expr — report as MAJOR).
- Verify Alertmanager receives at least one kcp alert (silence it afterwards if you trigger
  one artificially).

## 5. Dashboard

Import lands in folder "kcp Observability" (GrafanaDashboard CR reconciled). Walk the 10 rows:

- **kcp alerts** row: the stat matches `count(ALERTS{rulesgroup="kcp", alertstate="firing"})`;
  the alert list shows the kcp rules.
- **Platform overview**: all tiles show numbers (Workspaces Ready ≈ 108 ballpark on us-2,
  Bindings Bound ≈ 808, Shards up ≥ 1, agents leading = 10).
- Every other row: no "No data" on panels whose inputs you proved in section 2. Empty panels
  with a reason (e.g. APF rejections = 0-series until a rejection happens;
  `apiserver_flowcontrol_rejected_requests_total` registers lazily) are OK — note them.
- Screenshot each row for the report.

## 6. The documented-not-captured metrics

`tests/metrics-allowlist.documented.txt` lists metrics we could NOT capture from the rig.
Check each against live thanos (they come from KSM/cAdvisor/the rule engine):
`kube_pod_container_status_restarts_total{namespace="kcp-config"}`, `container_memory_working_set_bytes{namespace="kcp-config"}`, etc.
If found live → note "graduate to captured" in the report (we'll fold a scrape into fixtures).
Specifically watch for `apiserver_flowcontrol_rejected_requests_total` (absent until APF
rejects — confirm absence is benign).

## Report format

```
# Validation report — <cluster> — <date>
Chart/git: ... | kcp: v0.32.1 | Verdict: PASS / PASS-WITH-ISSUES / FAIL
## Evidence per section (1–6, with query outputs / screenshots)
## Issues
- [MAJOR|MINOR] <symptom> — <evidence> — <suspected cause>
## Calibration observations (thresholds vs observed baseline)
```

Commit the report under `tests/reports/` on the chart branch.
