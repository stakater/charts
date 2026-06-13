# Inventory & billing (Managed Resource Units)

Simple "how much is there" numbers and the basis for billing service-provider tenants on
**Managed Resource Units (MRU)**.

## The metric

`crossplane_managed_resource_exists{gvk}` — emitted natively by every crossplane-runtime
provider — has a **value equal to the number of managed resources of that GVK**. So counts
need no extra exporter:

| Number | Query |
| --- | --- |
| Total managed resources | `sum(crossplane_managed_resource_exists)` |
| Per kind (MRU basis) | `crossplane_managed_resource_exists > 0` (by `gvk`) |
| Distinct kinds in use | `count(crossplane_managed_resource_exists > 0)` |
| Total billable MRUs | `sum(crossplane_managed_resource_exists{gvk=~"<billableKinds>"})` |

These ship as recording rules (`crossplane:managed_resource:total`,
`crossplane:mru_billable:total`) and the **Inventory & Billing** dashboard row (Total MRs,
Billable MRUs, Distinct kinds, Composites, Tenants, MRs-by-kind table, growth-over-time).

## Fleet & per-kind MRU — available now

Set which kinds you charge for:

```yaml
billing:
  billableKinds: "ec2.aws.*|rds.aws.*|.*Cluster.*"   # regex on the gvk label; default ".+" = all
```

`crossplane:mru_billable:total` then tracks only those kinds, and the dashboard's **Billable
MRUs** tile shows the live number. Per-kind counts (the MRs-by-kind table) give you the
breakdown for invoicing. Weighting (e.g. "an RDS cluster = 5 MRU") is best applied in the
billing system from the per-kind counts, or via a small recording rule per weight class.

## Per-tenant MRU — needs one exporter step

**Why it isn't automatic:** `crossplane_managed_resource_exists` carries **only `gvk`** — the
provider does not put object labels on it. So even though your MR *objects* have a tenant
label, the metric can't attribute counts to a tenant. You need the inventory exporter
(ksm-crossplane / KSM CustomResourceState / RSM) to emit an MR count that **includes the
tenant label**.

### 1. Configure the exporter to expose the tenant label

With KSM CustomResourceState, add an entry per billable managed-resource kind that pulls the
tenant label off the object (`labelsFromPath`). Example for one kind:

```yaml
# ksm-crossplane CustomResourceState config (one block per billable MR kind)
- groupVersionKind:
    group: ec2.aws.upbound.io
    version: v1beta1
    kind: Instance
  labelsFromPath:
    name: [metadata, name]
    tenant: [metadata, labels, "tenant.example.com/id"]   # <-- YOUR tenant label key
  metrics:
    - name: "crossplane_mr_info"
      help: "Managed resource presence, labelled by tenant"
      each:
        type: Info
        info: { labelsFromPath: {} }
```

This yields `kube_customresource_crossplane_mr_info{kind, tenant, name, …}` = 1 per MR. (RSM
can do the same with a CEL resolver; pick whichever your `ksm-crossplane` already uses.)

### 2. Capture it and wire the chart

```bash
# confirm the real metric name + tenant label key:
curl -s localhost:8080/metrics | grep -E 'kube_customresource_.*(mr|managed)' | head
```

Then set:

```yaml
billing:
  perTenant:
    enabled: true
    mrCountMetric: kube_customresource_crossplane_mr_info   # what your exporter actually emits
    tenantLabel: "tenant"
```

Per-tenant MRU is then:

```promql
# total MRU per tenant:
count by (tenant) (kube_customresource_crossplane_mr_info)
# billable MRU per tenant per kind:
count by (tenant, kind) (kube_customresource_crossplane_mr_info{kind=~"<billable>"})
```

Following the project discipline: once you capture that metric into
`tests/fixtures/inventory-metrics.txt`, it moves into `metrics-allowlist.captured.txt` and we
add the per-tenant recording rule + dashboard panel (verified, not assumed) — same workflow
that graduated the XR condition metric.

### What we need from you to finish per-tenant

1. The **tenant label key** on your MRs (e.g. `tenant.example.com/id`, a workspace label, …).
2. Whether `ksm-crossplane` already emits an MR-level metric (run the grep above) or needs the
   CRS entries added.

With those, per-tenant MRU panels + recording rules land the same day.
