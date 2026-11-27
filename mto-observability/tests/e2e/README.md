# kind e2e — every alert fires AND resolves

The chart's end-to-end layer (method §3): a kind cluster running the **full MTO
suite from source**, kube-prometheus-stack, OpenCost, and this chart with
shrunk alert windows — then scenarios that drive alerts through a complete
fire→resolve cycle against the live Prometheus.

```bash
export TENANT_OPERATOR_DIR=... FINOPS_OPERATOR_DIR=... \
       HIBERNATION_OPERATOR_DIR=... TEMPLATE_OPERATOR_DIR=... \
       GIT_USER=<gh-user> GIT_TOKEN=<token-with-repo>   # private Go modules
./up.sh          # kind + cert-manager + suite + kps + opencost + chart
./scenarios.sh   # drives the alerts; PASS/FAIL per transition; exit = #fails
./down.sh
```

## What the scenarios drive live

| Scenario | Alerts exercised | Mechanism |
| --- | --- | --- |
| 1 — cost pipeline lifecycle | `MTOCostJobFailing`, `MTOCostJobNeverSucceeded` resolve on the first real Success; `MTOCostDataStale` fires on suspended CronJobs and resolves on unsuspend | OpenCost makes the loader succeed; `suspend: true` ages the success timestamp |
| 2 — operator down ×4 | `MTO<Op>Down` fire and resolve for all four operators | scale the manager to 0 and back |
| 3 — watchdog | `MTOFinopsMetricsAbsent` fire + resolve | finops manager to 0 kills every `finops_costjob` series |
| 4 — reconcile errors | `MTOFinopsOperatorReconcileErrors` fire + resolve | kill the finops PostgreSQL; Offering syncs error on every requeue |

## Deliberately not driven live (and why that is honest)

`WorkqueueBacklog`, `WebhookErrors`, `WebhookLatencyHigh`, and the non-finops
`ReconcileErrors` twins have no clean external forcing function on a healthy
lab (you cannot make a live controller stop draining its queue, or make a
webhook return 5xx, without breaking the very pod that reports the metric).
Their logic is pinned by the promtool unit layer (`tests/unit/rules.test.yaml`
— every alert fires and resolves on synthetic series); the live layer proves
the pipeline those rules run in. Reports are committed per run to
`tests/reports/e2e-kind-<date>.md`.

## Lab facts the scripts encode (capture findings)

- tenant + hibernation serve plain-http metrics here (cert-less kustomize
  layout) — `values-e2e.yaml` sets their `scheme`
- tenant-operator needs `PLATFORM_TYPE=Kubernetes` off OpenShift, the
  `tenant-operator-postgresql` secret, and a cluster `owner` CRB
- finops needs `OPERATOR_IMAGE` set or CostJob CronJobs render an unrunnable
  placeholder
- the `monitoring` namespace must be privileged through MTO's IntegrationConfig
  (the vnamespace webhook denies it otherwise — tenancy enforcement working)
