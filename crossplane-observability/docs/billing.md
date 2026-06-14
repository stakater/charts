# Inventory & billing (Managed Resource Units)

Two different numbers, two different sources:

- **Capacity** — how many leaf cloud resources we manage. From the provider metric
  `crossplane_managed_resource_exists` (per `gvk`). Works as a UWM recording rule
  (`crossplane:managed_resource:total`) + dashboard.
- **Billing (MRU)** — the customer-facing **XR / Claim** units you charge for. From the
  inventory exporter (`ksm-crossplane`). **This is what you bill on, confirmed.**

## What counts as a billable unit

The exporter emits, per Crossplane object, a one-hot **condition** metric
(`kube_customresource_crossplane_<xr|claim>_<kind>_condition`). For every object the
`{type="Ready", status="True"}` series exists (value 1 if ready, 0 if not), so **counting that
series = counting objects**:

```promql
# total billable units (XRs + Claims), narrowed by kind:
count({__name__=~"kube_customresource_crossplane_(xr|claim)_.+_condition", type="Ready", status="True", crossplane_kind=~"$billable"})

# per-kind:
count by (crossplane_kind) ({__name__=~"kube_customresource_crossplane_(xr|claim)_.+_condition", type="Ready", status="True", crossplane_kind=~"$billable"})
```

### Per-tenant (chargeback)

**Claims carry `namespace` = the tenant workspace** (`ws-…`); cluster-scoped XRs (e.g. XProject)
do not. So per-tenant billing is done on **Claims**:

```promql
# MRU per tenant:
count by (namespace) ({__name__=~"kube_customresource_crossplane_claim_.+_condition", type="Ready", status="True", crossplane_kind=~"$billable", namespace=~"$tenant"})

# MRU per tenant per kind (the invoice breakdown):
count by (namespace, crossplane_kind) ({__name__=~"kube_customresource_crossplane_claim_.+_condition", type="Ready", status="True", crossplane_kind=~"$billable"})
```

These are the **Billing — MRU (XR / Claim)** dashboard row (total, by-kind, by-tenant,
by-tenant-and-kind), with `$billable` (kind regex) and `$tenant` (namespace) variables.

## ⚠️ Two things to get right

1. **Don't double-count a Claim and the XR it creates.** A Claim (`Project/alpha` in
   `ws-…`) produces an XR (`XProject/alpha-7rnnh`, cluster-scoped) — the **same unit**. Pick
   one layer per kind via `$billable`. For tenant chargeback, **Claims** are the right layer
   (namespaced, one per customer request). For cluster-scoped infra XRs with no Claim, count
   the XR.
2. **Billing is dashboard-only, not a UWM recording rule.** The inventory series carry tenant
   namespaces; a UWM `PrometheusRule` would be namespace-enforced to empty (same as the
   composite alerts — see README "Inventory rules on OpenShift UWM"). The dashboard queries
   thanos-querier (not namespace-enforced), so the billing panels work. If you want billing
   *recording rules* (e.g. for long-term retention / an invoice exporter), evaluate them in a
   non-namespace-enforced context (platform monitoring or your own Prometheus).

## Configuration

```yaml
billing:
  # which condition families to count (XR/Claim). Default counts both — narrow per your model.
  unitMetricPattern: "kube_customresource_crossplane_(xr|claim)_.+_condition"
  tenantLabel: "namespace"   # claims + namespaced XRs carry the tenant workspace here
```

`billableKinds` is the dashboard **`$billable`** variable (regex on `crossplane_kind`, default
`.+`) — set it to the kinds you charge for, e.g. `OpenShiftCluster|Project|Vault|VirtualMachine`.
Weighting (e.g. "an OpenShiftCluster = 5 MRU") is best applied in the billing system from these
per-kind counts.

## Note

The exporter exposes far more than billing — it also has **package health**
(`pkg_*_condition` → `Healthy`/`Installed`) and **XRD established** (`xrd_*_condition` →
`Established`). Those close real coverage gaps (see [coverage.md](coverage.md)) and are the
next alerts to add now that the metrics are captured.
