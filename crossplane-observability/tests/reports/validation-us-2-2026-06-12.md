# Crossplane Observability — Deploy Validation
- Cluster / context: us-2 (`clusters/api-us-2-b24jftow-stakater-cloud:6443/kube:admin`)
- Crossplane version: 2.1.3   Providers: provider-kubernetes v1.2.1, provider-aws-* v2.3.0 (ec2/iam/kms/organizations/route53/s3), provider-family-aws v2.5.0, provider-azuread v2.2.0, provider-keycloak v2.19.0, provider-vault v3.0.3, provider-helm v1.2.0, provider-ansible v0.8.0, **provider-upjet-github v0.18.7**, provider-terraform v1.0.5, netbird v0.4.4; Functions: auto-ready, environment-configs, extra-resources, go-templating, kcl, patch-and-transform, random-string   Inventory exporter: present (`ksm-crossplane`) but NOT wired into the chart (inventory disabled)
- Prometheus: OpenShift UWM (prometheus-user-workload + **thanos-ruler** evaluates the rules; thanos-querier for reads)   Access: full (kubectl admin + minted cluster-monitoring-view token)
- Chart values enabled: recording rules + all Phase-1 alerts (defaults); monitors **disabled** (cluster already scrapes core+providers); upjet/inventory/Phase-2 disabled. Overrides applied: `crossplane.core.job=crossplane-metrics`, `crossplane.providers.job=crossplane-system/crossplane-providers-and-functions`, `grafana.namespace=crossplane-observability`, `grafana.instanceSelector={dashboards: crossplane}` (with `app: null` to defeat Helm deep-merge).
- Date: 2026-06-12   Agent run: chart branch `crossplane-observability` @ `1b0ea46`
- **Overall verdict: PASS-WITH-ISSUES**

Chart loads cleanly (offline `validate.sh` = ALL VALIDATION PASSED; all 19 rules `health=ok` in thanos-ruler, no `lastError`; recording rules produce series; dashboard applied to the Grafana instance). The customer-facing **MRNotReady** alert is unusable as shipped (~97% false-positive rate from empty GVKs), and one Phase-2 rule has a wrong label — both detailed below.

## Story status
| Story | What | Status | Evidence / note |
|---|---|---|---|
| 1.1 | MR ready ratio + MRNotReady | **Noisy (MAJOR)** | recording rule OK (823 gvk series, fleet ratio 0.9498); but 774/823 ratio series == 0 -> 671 firing MRNotReady + 671 MRNotReadyCritical, only ~21 genuine. See F1. |
| 1.2 | TTR p95 / TTRDegraded | OK (steady-state empty) | `crossplane:managed_resource_ttr_seconds:p95` present (4 series); value NaN -> no MR newly became ready in the 30m window. Metric `first_time_to_readiness_seconds_bucket` present, labelled `gvk`. Not firing. |
| 1.3 | Claim-tree p95 / ClaimTreeNotReady | OK (no claim layer) | `crossplane:claim_tree_ttr_seconds:p95` present (1 series), NaN -> composite of MR-readiness only; the claim layer (4.1) isn't wired. health=ok, not firing. |
| 2.1 | reconcile error ratio / ReconcileErrorRateHigh | **OK - firing genuinely** | `crossplane:reconcile_errors:ratio` 130 series; 7 controllers > 1% (XRD defined 15.8%, usage/clusterusage 6.8%, xproject 3.9%, windowsvirtualmachines 3.4%, configurationrevision 3.6%, XRD offered 1.9%, usage 1.3%). Alert correct; threshold may be tight (calibration). |
| 2.2 | reconcile latency / ReconcileLatencyHigh | OK | `crossplane:reconcile_time_seconds:p99` 85 series; 2 controllers pending. controller_runtime histogram present (job=crossplane-metrics). |
| 2.3 | workqueue depth / WorkqueueDepthGrowing | OK | `workqueue_depth{job=crossplane-metrics}` present; not firing. |
| 2.4 | APIService unavailable | OK | `aggregator_unavailable_apiservice{name=~".*crossplane.*"}` present and 0 (API healthy); alert quiet - correct. |
| 2.5 | detection lag / DetectionLagHigh | OK (steady-state) | `first_time_to_reconcile_seconds_bucket` present (gvk); health=ok, not firing. |
| 3.1 | drift / DriftDetected | N/A (no data) | `crossplane_managed_resource_drift_seconds` absent - no drift has occurred (metric only registers on drift). Expected, not a bug. |
| 4.1 | claim / inventory | N/A (disabled) | inventory disabled; `ksm-crossplane` exporter exists on-cluster but isn't wired to `crossplane.inventory.*`. Highest-value next step. |
| 4.2 | circuit breaker (Phase 2) | N/A (disabled) - **but metrics present** | `circuit_breaker_events_total` present with `result="Dropped"` label OK; `circuit_breaker_opens_total` present. Could be enabled. See F3. |
| 5.1/5.2 | functions (Phase 2) | N/A (disabled) - **rule bug found** | `function_run_*` present on this 2.1.3 cluster; `function_run_function_response_total` has NO `result` label -> FunctionErrorRate filter wrong. Cache metrics absent. See F2. |
| 6.1 | upjet cloud | N/A (disabled) - metric labels confirmed | `upjet_resource_reconcile_delay_seconds_bucket` / `upjet_resource_ttr_bucket` present, labelled `group`/`version`/`kind`; rule's `by (le, kind)` + `{{ $labels.kind }}` are valid. Ready to enable with `upjet.enabled=true`. |
| 7.1 | footprint restart/OOM | OK (quiet) | `kube_pod_container_status_restarts_total` / `..._last_terminated_reason` present for crossplane-system; not firing. |
| 7.2 | footprint CPU-throttled | **NoData (MINOR)** | `container_cpu_cfs_throttled_periods_total{pod=~"provider.*"}` = 0 series (while `container_memory_working_set_bytes{pod=~"provider.*"}` is present). See F5. |

## Findings
(severity-ordered: BLOCKER > MAJOR > MINOR > NIT)

### [MAJOR] MRNotReady / MRNotReadyCritical fire on empty GVKs - ~97% false positives
- Story/area: 1.1
- Symptom: 671 GVKs firing `MRNotReady` (warning) **and** 671 firing `MRNotReadyCritical` (critical), +117 pending each. Only ~21 reflect a real problem.
- Evidence (thanos-querier, this cluster):
  ```
  count(crossplane:managed_resource_ready:ratio)                                   = 823
  count(crossplane:managed_resource_ready:ratio == 0)                              = 774   # all fire <1.0
  count(crossplane_managed_resource_exists == 0)                                   = 1103  # empty GVKs
  count(crossplane_managed_resource_exists  > 0)                                   = 64
  count((exists>0) and (ready < exists))   genuine partially-not-ready             = 19
  count((exists>0) and (ready == exists))  fully ready                             = 45
  ```
- Likely cause: `crossplane:managed_resource_ready:ratio = sum by (gvk)(ready) / clamp_min(sum by (gvk)(exists), 1)`. For a GVK whose CRD is installed but has **no live resources**, `ready=0` and `exists=0`, so the ratio is `0/1 = 0`, and the alert `ratio < 1.0` fires. The `clamp_min(...,1)` is exactly what manufactures the false 0.
- Suggested fix: only evaluate the ratio where the GVK actually has resources (gate denominator on `exists > 0`), plus a `tests/unit/rules.test.yaml` case for the empty GVK.
- **RESOLUTION:** fixed — recording rule denominator changed to `sum by (gvk)(exists > 0)` so empty GVKs produce no ratio series; regression test added. (chart-side)

### [MAJOR] FunctionErrorRate filters `result="error"` - that label does not exist
- Story/area: 5.1 (Phase 2; ships disabled - but `function_run_*` is emitted on this 2.1.3 cluster)
- Symptom: `verify-fetched.py` reported `label check 'result="error"': NOT FOUND`. Numerator always 0 -> alert can never fire.
- Evidence (real line from core `/metrics`):
  ```
  function_run_function_response_total{function_name="function-environment-configs",
    grpc_code="OK",grpc_method=".../RunFunction",result_severity="Fatal"} 12716
  # label KEYS: function_name, function_package, grpc_code, grpc_method, grpc_target, result_severity
  ```
- Likely cause: rule assumed an upstream `result="error"` label; the real error signal is `result_severity="Fatal"` (function-reported) or `grpc_code!="OK"` (transport).
- **RESOLUTION:** fixed — alert + dashboard panel now filter `result_severity="Fatal"`. (chart-side)

### [MAJOR] Out-of-the-box defaults don't match a SAAP cluster (monitors + job + grafana)
- Story/area: deployment / plumbing
- Symptom: with chart defaults, nothing would scrape and the dashboard would not import.
- Evidence:
  ```
  svc crossplane-metrics labels = {app.kubernetes.io/component: metrics, app.kubernetes.io/name: crossplane}  # no instance label
  provider PodMonitor default selector: pkg.crossplane.io/provider: ""  # matches 0 pods
  live job labels: core => "crossplane-metrics"; providers => "crossplane-system/crossplane-providers-and-functions"
  GrafanaDashboard NoMatchingInstances=true with default instanceSelector {app: grafana}; live instance labelled {dashboards: crossplane}
  ```
- **RESOLUTION:** fixed/documented — core SM selector now configurable (`crossplane.core.serviceMonitorSelector`, default component=metrics, no instance label); provider selector default `pkg.crossplane.io/revision: Exists`; README documents SAAP `job` values + the Grafana deep-merge/immutability gotchas. (chart-side)

### [MINOR] Phase-2 + Upjet metrics already present on Crossplane 2.1.3
- Evidence: `circuit_breaker_*`, `function_run_*`, `upjet_resource_*` all PRESENT on 2.1.3.
- **RESOLUTION:** README "Phase 2" reworded to *confirm-on-build* (not strictly post-upgrade). These can be enabled on this cluster after F2; graduate documented->captured per HANDOFF.md §4.

### [MINOR] Story 7.2 ProviderPodCPUThrottled - no data on this cluster
- Evidence: `count(container_cpu_cfs_throttled_periods_total{pod=~"provider.*"}) = 0` while memory series present.
- Likely cause: CFS-throttling cAdvisor series not collected/retained, or providers run without CPU limits. **No in-chart fix**; flagged as not-validatable here.

### [MINOR] ReconcileErrorRateHigh threshold (1%) likely tight pre-baseline
- Evidence: 7 control-plane controllers at 1.3%-15.8% steady-state (XRD/usage/composite reconcilers).
- **Disposition:** keep as-is (surfaces real errors); calibrate `reconcileErrorRateHigh.threshold` over 2-4 week baseline; consider excluding `usage/*` and `*/compositeresourcedefinition` or a higher threshold for them.

## Metric reality (live)
`python3 tests/verify-fetched.py --dumps /tmp/fetched-us-2` (Crossplane 2.1.3, 25 provider pods):
```
SUMMARY: 16 present, 10 absent, of 26 referenced.
PRESENT: circuit_breaker_events_total (result="Dropped" OK), circuit_breaker_opens_total,
  controller_runtime_reconcile_{errors_total,time_seconds_bucket,total}, crossplane_managed_resource_{exists,ready,synced},
  crossplane_managed_resource_first_time_to_{readiness,reconcile}_seconds_bucket (labelled gvk),
  function_run_function_response_total (result="error": NOT FOUND -> F2), function_run_function_seconds_bucket,
  upjet_resource_reconcile_delay_seconds_bucket / upjet_resource_ttr_bucket (labelled group/version/kind),
  workqueue_adds_total, workqueue_depth
ABSENT (expected): aggregator_unavailable_apiservice*, container_cpu_cfs_*, container_memory_working_set_bytes*,
  crossplane_managed_resource_drift_seconds, function_run_*_cache_*, kube_pod_container_status_*
  (* apiserver/cAdvisor/KSM ones ARE in UWM via thanos-querier, just not on Crossplane /metrics dumps)
```
Label reconciliation vs rules: `gvk` OK, `result="Dropped"` OK, upjet `kind` OK, `result="error"` WRONG -> F2.

## Not validatable here (and why)
- **3.1 DriftDetected** — `crossplane_managed_resource_drift_seconds` only registers once a real drift occurs.
- **4.1 ClaimNotReady / inventory** — disabled; `ksm-crossplane` exists on-cluster but not wired to `crossplane.inventory.*`. Highest-value next step.
- **4.2 / 5.1 / 5.2 Phase-2** — ship disabled; metrics for 4.2 and 5.1 ARE present; 5.2 cache metrics absent.
- **6.1 Upjet** — disabled; labels confirmed rule-compatible, ready to enable.
- **Chart's own ServiceMonitor/PodMonitor** — left disabled; cluster already scrapes; defaults don't match (F4).
