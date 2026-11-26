# Capturing live MTO metrics into `tests/fixtures/`

The roadmap is Draft until these fixtures exist: every metric a rule or panel uses must
be **[captured]** here (exact names + label shapes) or documented-with-citation in
`metrics-allowlist.documented.txt`. Capture from a **real cluster running MTO** (any
install where the operator version matches what we target, v1.10.x), read-only.

## What to capture

One fixture per controller Deployment, named `<component>-metrics.txt`:

| fixture | deployment (`control-plane` label) |
| --- | --- |
| `tenant-metrics.txt` | `controller-manager-tenant` |
| `namespace-metrics.txt` | `controller-manager` |
| `quota-intconfig-metrics.txt` | `controller-manager-quota-intconfig` |
| `pilot-metrics.txt` | `controller-manager-pilot` |
| `webhook-metrics.txt` | `controller-manager-webhook` |
| `db-controller-metrics.txt` | `controller-manager-db-controller` (if installed) |
| `extensions-argocd-metrics.txt` | `controller-manager-extensions-argocd` (if installed) |

Capture at a moment when at least one Tenant exists and, ideally, one resource is in a
known reconcile-error state — the `multi_tenant_operator_*` gauges and their label
shapes are the whole point, and several register lazily.

## How (read-only)

The endpoint is HTTPS on container port `:6443`, authenticated against the API server —
the request needs a token bound to MTO's `metrics-reader` ClusterRole.

```bash
NS=multi-tenant-operator            # MTO install namespace
cd tests/fixtures

# A short-lived token for a SA bound to metrics-reader. If no such SA exists yet,
# bind one temporarily (remove it afterwards):
#   kubectl -n "$NS" create serviceaccount metrics-capture
#   kubectl create clusterrolebinding mto-metrics-capture \
#     --clusterrole=<metrics-reader ClusterRole name> \
#     --serviceaccount="$NS:metrics-capture"
TOKEN=$(kubectl -n "$NS" create token metrics-capture)

for cp in controller-manager-tenant controller-manager \
          controller-manager-quota-intconfig controller-manager-pilot \
          controller-manager-webhook controller-manager-db-controller \
          controller-manager-extensions-argocd; do
  pod=$(kubectl -n "$NS" get pod -l control-plane="$cp" -o name | head -1)
  [ -z "$pod" ] && { echo "SKIP $cp (not installed)"; continue; }
  kubectl -n "$NS" port-forward "$pod" 16443:6443 & pf=$!; sleep 2
  out=$(echo "$cp" | sed -e 's/^controller-manager-//' -e 's/^controller-manager$/namespace/')
  curl -sk -H "Authorization: Bearer $TOKEN" https://127.0.0.1:16443/metrics \
    > "${out}-metrics.txt"
  kill $pf
done
```

Then:

1. Record provenance in `fixtures/README.md`: MTO version, cluster/platform version,
   install method (OperatorHub/Helm), date, which optional components were on, and
   anything induced (e.g. a deliberate reconcile error).
2. `./tests/generate-allowlist.sh` and commit the regenerated
   `metrics-allowlist.captured.txt` together with the fixtures.
3. **Revise `docs/roadmap.md` against the capture**: retag `[documented]`/`[cr-default]`
   → `[captured]` or `[absent]`, fix label shapes, and only then take stories to the
   approval gate.

## Capture-time questions the roadmap is waiting on

- Does the install serve metrics at all (roadmap Q2), and is the port/args layout as
  the bundle says?
- Which deployments export the `multi_tenant_operator_*` families (expected: tenant
  only), and with which `kind` values?
- Do `leader_election_master_status`, `controller_runtime_webhook_*`, `certwatcher_*`
  and `controller_runtime_reconcile_panics_total` exist on this build (stories 1.2,
  2.3, 2.4, 3.4)?
- Exact `job` label values once the chart's monitors scrape (naming feeds every `up`
  expression).
