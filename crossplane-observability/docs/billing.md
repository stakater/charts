# Inventory & billing (Managed Resource Units)

## Scope — read this first

This page is about the **MRU count the cloud provider is invoiced for by Stakater**, as shown on
the Grafana dashboard. It is **not** end-customer pricing (what an organisation pays for its hosted
clusters, VMs or databases) — that is owned by FinOps and the SCO console and has nothing to do
with this chart.

## The definition: 1 Claim = 1 MRU

Ruled 2026-09-09 and final: **an MRU is one Crossplane Claim object.** Not an XR, not a leaf
managed resource, not a VM or a cluster. The XR a Claim creates is the same unit and is never
counted.

Two different numbers appear on the dashboard and they must not be confused:

- **Capacity** — how many leaf cloud resources the platform manages. From the provider metric
  `crossplane_managed_resource_exists` (per `gvk`); recording rule `crossplane:managed_resource:total`
  and the **Inventory & capacity** row. **Capacity is not billed.** Dedupe per GVK before summing —
  see [Capacity: never `sum()` the exists gauge](#capacity-never-sum-the-exists-gauge).
- **MRUs** — Claim objects, from the inventory exporter (`ksm-crossplane`). The **Billing — MRUs**
  row. **This is what is invoiced.**

## How MRUs are counted

The exporter emits, per Crossplane object, a one-hot **condition** metric
(`kube_customresource_crossplane_claim_<kind>_condition`). For every Claim the
`{type="Ready", status="True"}` series exists (value 1 if ready, 0 if not), so **counting that
series = counting Claims**:

```promql
# MRUs, narrowed to the billable kinds:
count({__name__=~"kube_customresource_crossplane_claim_.+_condition", type="Ready", status="True", crossplane_kind=~"$billable"})

# per kind:
count by (crossplane_kind) ({__name__=~"kube_customresource_crossplane_claim_.+_condition", type="Ready", status="True", crossplane_kind=~"$billable"})
```

Only `claim_` families are matched. The `xr_` families are used by the composite-readiness rules,
never by billing.

### Per tenant

Claims are namespaced and **`namespace` = the tenant workspace**, so the per-tenant breakdown is
free:

```promql
# MRUs per tenant:
count by (namespace) ({__name__=~"kube_customresource_crossplane_claim_.+_condition", type="Ready", status="True", crossplane_kind=~"$billable", namespace=~"$tenant"})

# MRUs per tenant per kind:
count by (namespace, crossplane_kind) ({__name__=~"kube_customresource_crossplane_claim_.+_condition", type="Ready", status="True", crossplane_kind=~"$billable"})
```

These four queries are the **Billing — MRUs (1 Claim = 1 MRU)** dashboard row, with `$billable`
(kind regex) and `$tenant` (namespace) variables.

## The one knob: `$billable`

`$billable` is a **Grafana dashboard variable** (regex on `crossplane_kind`, default `.+`). There
are deliberately no `billing.*` Helm values — the dashboard JSON is shipped verbatim, so a value
could not reach it, and a knob that does nothing is worse than none.

⚠️ **`.+` means every Claim kind, including the platform's own plumbing** — `K8sObjectReplicator`,
`KeycloakRealmClient`, `AwsBucket`, `VaultConfig` and the rest are Claims too, and on a real cluster
they outnumber customer-facing ones by a wide margin. Set `$billable` to the kinds that are actually
invoiced before reading the headline number as an invoice.

Also note which kinds **cannot** appear here: the kcp customer-facing XRDs (`OpenShiftCluster`,
`VirtualMachine`, `Postgres`, `S3Bucket`, `Vault`, `User`, `Group`) declare no `claimNames`, so they
are never Claims and count zero MRUs under this definition. If that is not intended, it is a
definition question for the architects, not a dashboard change.

## Capacity: never `sum()` the exists gauge

`crossplane_managed_resource_exists` (and `_ready` / `_synced`) is a **per-GVK count emitted by
every replica of the provider that serves that GVK**. The replicas duplicate the count — they do
not shard it — so a plain `sum()` multiplies scaled-out providers by their replica count.

```promql
sum(max by (gvk) (crossplane_managed_resource_exists))   # correct — dedupe, then sum
sum(crossplane_managed_resource_exists)                  # WRONG — counts each replica
count(count by (gvk) (crossplane_managed_resource_exists > 0))  # distinct kinds
count(crossplane_managed_resource_exists > 0)                   # WRONG — counts series
```

Measured on eu-2 (2026-09-08): two `provider-aws-s3` pods each reported `12` for
`s3.aws.upbound.io/v1beta1, Kind=Bucket` while the API held exactly 12 Buckets. Fleet-wide the
naive form gave **2119** against a true **2049**, and distinct kinds **62** against a true **54**.

The overcount is **uneven** — it applies only to providers that happen to be scaled out — so it
cannot be corrected with a flat factor, and nothing in the number itself reveals it. Ready/synced
*ratios* are unaffected, since numerator and denominator inflate together.

## Billing is dashboard-only, not a UWM recording rule

The inventory series carry tenant namespaces; a UWM `PrometheusRule` would be namespace-enforced
to empty (same as the composite alerts — see README "Inventory rules on OpenShift UWM"). The
dashboard queries thanos-querier (not namespace-enforced), so the MRU panels work. If you want MRU
*recording rules* (long-term retention, an invoice exporter), evaluate them in a
non-namespace-enforced context — platform monitoring or your own Prometheus.

## Prerequisite

All of this needs the inventory exporter (`crossplane.inventory.*`, job `ksm-crossplane`) to be
scraped. Without it the MRU row is empty — not zero, empty. Check
`count({__name__=~"kube_customresource_crossplane_claim_.+_condition"})` returns series before
trusting any number on that row.

## Note

The exporter exposes far more than billing — it also has **package health**
(`pkg_*_condition` → `Healthy`/`Installed`) and **XRD established** (`xrd_*_condition` →
`Established`). Those close real coverage gaps (see [coverage.md](coverage.md)) and are the
next alerts to add now that the metrics are captured.
