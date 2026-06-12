# Crossplane Observability — Deploy Validation
- Cluster / context: us-2 (`clusters/api-us-2-b24jftow-stakater-cloud:6443/kube:admin`)
- Crossplane 2.1.3; ~16 providers (provider-kubernetes, provider-aws-* ec2/iam/kms/organizations/route53/s3, provider-family-aws, provider-azuread, provider-keycloak, provider-vault, provider-helm, provider-ansible, provider-upjet-github, provider-terraform, netbird); Functions: auto-ready, environment-configs, extra-resources, go-templating, kcl, patch-and-transform, random-string. Inventory exporter: **yes — `ksm-crossplane` ENABLED & wired** (job `ksm-crossplane`, up=1).
- Prometheus: OpenShift UWM (thanos-ruler evaluates rules; thanos-querier reads). Access: full.
- Values: recording rules + all Phase-1 + **Story 4.1 inventory** (`conditionMetricPattern=kube_customresource_crossplane_xr_.+_condition`, job ksm-crossplane, Ready/Synced); monitors disabled; upjet/Phase-2 disabled. Overrides: core.job=crossplane-metrics, providers.job=crossplane-system/crossplane-providers-and-functions, grafana.namespace=crossplane-observability, instanceSelector={dashboards: crossplane}.
- Date: 2026-06-13   Agent run: chart `5f0aa43` (PR #274 head; helm rev 6)
- **Overall verdict: PASS-WITH-ISSUES**

Two prior MAJORs resolved with LIVE evidence: F1 (MRNotReady false positives) 671 → 17 firing; F2 (FunctionErrorRate label) now `result_severity="Fatal"` and the live metric carries it. Two NEW issues from enabling Story 4.1 + inspecting the reconcile exclusion: N1 (inventory rules silently match nothing under UWM enforced-namespace) and N2 (reconcile exclusion regex unanchored).

## Story status (highlights)
- **1.1 MRNotReady — FIXED (live):** ratio series 823 → 51; ==0 774 → 2; MRNotReady 671 → **17**, Critical 671 → **17**. Empty GVKs produce no ratio series. Fleet ratio 0.9454.
- **2.1 ReconcileErrorRateHigh — Noisy (N2):** fires 5; 3 are controllers meant to be excluded (usage 1.5%, clusterusage 6.8%, configurationrevision 4.5%) — exclusion regex unanchored.
- **4.1 composite/inventory — Misconfigured (N1):** ksm-crossplane up=1; one-hot metric returns 900 Ready series (600 not-ready); all 3 rules health=ok; BUT `crossplane:composite_ready:ratio` EMPTY and composite alerts fire 0 — UWM injects namespace="crossplane-system", inventory series carry tenant namespaces.
- **5.1 FunctionErrorRate — FIXED (F2):** live `function_run_function_response_total` carries `result_severity` (Fatal=2, Normal=7); rendered expr filters Fatal.
- 1.2/1.3/2.2/2.3/2.4/2.5/7.1 OK (steady-state / quiet). 3.1 no data (no drift). 7.2 NoData (cAdvisor CFS not collected). 4.2/6.1 disabled, metrics present.

## Findings

### [MAJOR] N1 — inventory rules silently match nothing under UWM enforced-namespace
- Symptom: composite recording rule produces 0 series; CompositeNotReady/Synced fire 0 despite 600 not-ready composite Ready conditions; rules report health=ok (silent).
- Evidence: `count({...type="Ready"} == 0)` = 600; `count({...type="Ready", namespace="crossplane-system"})` = empty; `count by (namespace)(...)` shows 31 tenant namespaces (ws-*, hypershift-*, crossplane-observability), none crossplane-system. Live UWM-rewritten query has injected `namespace="crossplane-system"`. Dropping that filter yields 46 real series (OpenShiftCluster=0.769, OpenShiftNodePool=0.667, KubeStackPlus=0). Chart SOURCE expr has no namespace filter — UWM injects it.
- Cause: UWM enforces tenancy by injecting `namespace="<rule's namespace>"`; the PrometheusRule lives in crossplane-system; inventory series carry tenant namespaces.
- **RESOLUTION:** documented (README "Inventory rules on OpenShift UWM", values caveat, DEPLOY-VALIDATION check); expr correctness proven by a namespace-labelled unit test. Not an expr bug — a UWM tenancy constraint. Options: deploy inventory rule per-tenant-namespace, or evaluate in platform monitoring; dashboard panels work (thanos-querier is not namespace-enforced).

### [MAJOR] N2 — ReconcileErrorRateHigh exclusion list unanchored
- Symptom: 3 of 4 intended exclusions still fire (usage/clusterusage/configurationrevision). Only `.*compositeresourcedefinition.*` worked (it's wildcarded).
- Evidence: live controller labels are path-prefixed FQDNs — `usage/usage.apiextensions.crossplane.io`, `usage/clusterusage.protection.crossplane.io`, `packages/configurationrevision.pkg.crossplane.io`. PromQL `!~` is fully anchored, so bare `usage` etc. never match.
- **RESOLUTION:** fixed — default `excludeControllers` wildcards every alternative: `.*usage.*|.*compositeresourcedefinition.*|.*configurationrevision.*`. Unit test now uses the real path-prefixed labels.

### [MINOR] 7.2 ProviderPodCPUThrottled — no data (unchanged); cAdvisor CFS series not collected. No in-chart fix.
### [MINOR] ReconcileErrorRateHigh 1% threshold tight pre-baseline; calibrate over 2–4 weeks. Independent of N2.

## Changes since 2026-06-12 (`1b0ea46` → `5f0aa43`)
- F1 RESOLVED (live): MRNotReady 671 → 17.
- F2 RESOLVED (live): result_severity="Fatal".
- F4 RESOLVED (deployed): rev 6 clean; GrafanaDashboard applied to 1 instance.
- Reconcile calibration PARTIAL: CRD controllers excluded; usage/clusterusage/configurationrevision still fire → N2 (now fixed).
- Story 4.1 NEWLY ENABLED: rules health=ok but ineffective on UWM → N1 (now documented).

## Metric reality (live)
16 present / 10 absent of 26 referenced. PRESENT: controller_runtime_*, crossplane_managed_resource_{exists,ready,synced,first_time_to_*}, function_run_* (result_severity Fatal=2), upjet_resource_* (group/version/kind), workqueue_*. Inventory one-hot `kube_customresource_crossplane_xr_.+_condition` labels crossplane_kind/type/status OK — but namespace is the TENANT workspace, not crossplane-system (N1). Targets: up{job=crossplane-metrics}=1, providers up=30, up{job=ksm-crossplane}=1, count(crossplane_managed_resource_exists)=1167.
(verify-fetched.py printed a stale `result="error": NOT FOUND` — the script's allowlist label, not the rule; fixed to result_severity="Fatal".)

## Not validatable here
3.1 drift (no drift), 4.2/5.1/5.2 Phase-2 (disabled; metrics present), 6.1 Upjet (disabled, labels OK), 7.2 (cAdvisor CFS absent), chart monitors (disabled), dashboard visual render (no browser; GrafanaDashboard applied; backing recording-rule series confirmed).
