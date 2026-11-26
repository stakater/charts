# Fixture provenance

**Captured 2026-11-26** from a **kind lab** (`kind` v1.36.1 node, cert-manager v1.19.2)
running the full MTO suite, source-built images (procedure: `../METRICS-CAPTURE.md`,
mechanics: `../capture.sh` — in-cluster curl pod, temporary SA bound to a
`GET /metrics` ClusterRole, both removed after).

| fixture | component | source build |
| --- | --- | --- |
| `tenant/namespace/quota-intconfig/pilot/webhook/db-controller/extensions-argocd-metrics.txt` | tenant-operator, all 7 deployments (kustomize `config/default`, `PLATFORM_TYPE=Kubernetes`) | main @ `9a36e81d` (v1.10.x line) |
| `finops-operator-metrics.txt` | finops-operator manager | **PR #107 branch** `sa-9738-costjob-state-gauges` (the CostJob gauges, pre-release) |
| `hibernation-operator-metrics.txt` | hibernation-operator manager | **PR #117 branch** `sa-9739-supervisor-state-gauges` (pre-release) |
| `template-operator-metrics.txt` | template-operator-v2 manager | **PR #93 branch** `sa-9740-instance-state-gauges` (pre-release) |

Cluster state at capture: one Tenant + Quota (admitted through the live webhook), two
CostJobs at 1m interval — `daily-scraping-job` **Failed** (OpenCost absent: the
one-hot shows `status="Failed" 1`) and `subscription-scraping-job` **never executed**
(all-zero one-hot) — a ClusterResourceSupervisor + ResourceSupervisor (Ready,
schedules pending), and two TemplateInstances **Failed/NamespaceNotPermitted**. No
CostJob had ever succeeded, so `finops_costjob_last_successful_execution_timestamp_seconds`
is deliberately absent (lazy — documented allowlist).

Scrape-surface findings recorded in the roadmap (structural facts): plain-HTTP
metrics in the cert-less kustomize layout, no metrics on the hibernation webhook pod,
`PLATFORM_TYPE` crash on vanilla k8s, finops `OPERATOR_IMAGE` placeholder.

**Pending before release:** a read-only comparison capture on a real OpenShift
cluster (OperatorHub/Helm layout: TLS scheme, Service/port names, label parity).
