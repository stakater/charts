# Inventory & billing (Managed Resource Units)

## Scope — read this first

This page is about the **MRU count the cloud provider is invoiced for by Stakater**, as shown on
the Grafana dashboard. It is **not** end-customer pricing (what an organisation pays for its hosted
clusters, VMs or databases) — that is owned by FinOps and the SCO console and has nothing to do
with this chart.

## The definition: one requested unit = 1 MRU

Ruled 2026-09-09 and final: **an MRU is one unit a user asked for** — one cluster, one VM, one
database. Not a leaf managed resource, and never the same unit counted twice.

The ruling says "Claim", and on a different fleet that would be the whole implementation. On
**this** fleet it is not, and this is the one thing to understand before reading any number here:

> A full scan of the 116 XRDs in `stakater-ab/compositions` (2026-09-18) found **55 with
> `claimNames`, and not one of them in a `*.cloud.stakater.com` group.** Every customer-facing
> kind — `OpenShiftCluster`, `VirtualMachine`, `Postgres`, `Database`, `S3Bucket`, `Vault`,
> `Group`, `User`, `TechnicalUser`, `Mesh` — is a **claimless namespaced XR**. The only
> claim-backed kinds are `infrastructure.stakater.com` plumbing (`AzureADGroupPim`,
> `KeycloakRealmClient`, `VaultConfig`, …) plus the single `tenant.cloud.stakater.com` `Project`.

So a literal "count Claim objects" query bills **none of the products and all of the plumbing**.
The requested unit is real; on our XRDs it is simply carried by the XR object, not by a Claim.
Billing therefore counts **the billable object itself**, whichever kind of object that is.

*(`apiVersion` v1 vs v2 is a red herring here — match on `claimNames`/`scope`, not on version.)*

Two different numbers appear on the dashboard and they must not be confused:

- **Capacity** — how many leaf cloud resources the platform manages. From the provider metric
  `crossplane_managed_resource_exists` (per `gvk`); recording rule `crossplane:managed_resource:total`
  and the **Inventory & capacity** row. **Capacity is not billed.** Dedupe per GVK before summing —
  see [Capacity: never `sum()` the exists gauge](#capacity-never-sum-the-exists-gauge).
- **MRUs** — billable objects, from the inventory exporter (`ksm-crossplane`). The
  **Billing — MRUs** row. **This is what is invoiced.**

## How MRUs are counted

The exporter emits, per Crossplane object, a one-hot **condition** metric
(`kube_customresource_crossplane_{claim,xr}_<kind>_condition`). For every object the
`{type="Ready", status="True"}` series exists exactly once (value 1 if ready, 0 if not) — verified
against a live capture, 11 series for 11 objects — so **counting that series = counting objects**:

```promql
# MRUs, narrowed to the billable API surface and kinds:
count({__name__=~"kube_customresource_crossplane_(claim|xr)_.+_condition", type="Ready", status="True", crossplane_group=~"$billable_group", crossplane_kind=~"$billable"})

# per kind:
count by (crossplane_kind) ({__name__=~"kube_customresource_crossplane_(claim|xr)_.+_condition", type="Ready", status="True", crossplane_group=~"$billable_group", crossplane_kind=~"$billable"})
```

Both families are matched, and **the no-double-count property lives in `$billable`, not in the
family regex**: it lists exactly one kind per XRD (see below).

### Per tenant

Claims and namespaced XRs are both namespaced and **`namespace` = the tenant workspace**, so the
per-tenant breakdown is free either way:

```promql
# MRUs per tenant:
count by (namespace) ({__name__=~"kube_customresource_crossplane_(claim|xr)_.+_condition", type="Ready", status="True", crossplane_group=~"$billable_group", crossplane_kind=~"$billable", namespace=~"$tenant"})

# MRUs per tenant per kind:
count by (namespace, crossplane_kind) ({__name__=~"kube_customresource_crossplane_(claim|xr)_.+_condition", type="Ready", status="True", crossplane_group=~"$billable_group", crossplane_kind=~"$billable", namespace=~"$tenant"})
```

These four queries are the **Billing — MRUs** dashboard row, with `$billable_group`
(API-group regex), `$billable` (kind regex) and `$tenant` (namespace) variables.

## The two knobs: `$billable_group` and `$billable`

Both are **Grafana dashboard variables**. There are deliberately no `billing.*` Helm values — the
dashboard JSON is shipped verbatim, so a value could not reach it, and a knob that does nothing is
worse than none.

### `$billable_group` — regex on `crossplane_group`, default `.*cloud\.stakater\.com`

This is the customer-facing API surface, and it is **not cosmetic**: kind names collide across
groups *inside the same metric family*. `OpenShiftCluster`, `VirtualMachine`,
`VirtualMachineVolume` and `WindowsVirtualMachine` each exist in both the legacy
`infrastructure.stakater.com` group and the new `*.cloud.stakater.com` ones, and the exporter
derives the family name from the **kind** — so both land in e.g.
`kube_customresource_crossplane_xr_virtual_machine_condition` and are separable only by
`crossplane_group`. Filtering on kind alone double-counts every migrating kind. **Always filter on
group *and* kind.**

### `$billable` — regex on `crossplane_kind`, default = top-level products

```
OpenShiftCluster|VirtualMachine|WindowsVirtualMachine|Postgres|Database|S3Bucket|Vault|Group|User|TechnicalUser|Mesh|Project
```

Two rules govern this list:

1. **Exactly one kind per XRD.** The claim kind where the XRD offers one (`Project`, never
   `XProject`); the XR kind where it does not (`OpenShiftCluster`, `Vault`, …). Claim-backed XRDs
   are reliably `X`-prefixed on the XR side, so the two are always distinguishable — and listing
   both is the double-count. `tests/validate.sh` step 5f fails the build if a kind and its `X`
   twin both appear.
2. **Top-level products only.** Sub-units are part of the unit their parent bills:
   `OpenShiftNodePool`, `VirtualMachineVolume`/`Backup`/`Snapshot`/`Restore`, the seven `Mesh*`
   components, and Stakater's own cluster-scoped `*Stack` kinds are **not** billed.

PromQL anchors regex matchers fully, which is what keeps the list this short — `Group` cannot
match `MeshGroup`, and `Vault` cannot match `VaultConfig`. For the same reason, never put a
wildcard in `$billable`: it would silently widen the invoice.

**The contents of this list are a product decision, not an observability one.** The mechanism is
ours; which kinds are invoiced is Callum's / the architects' call. Re-check it whenever a new
customer-facing XRD ships.

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
`count({__name__=~"kube_customresource_crossplane_(claim|xr)_.+_condition"})` returns series before
trusting any number on that row.

## Note

The exporter exposes far more than billing — it also has **package health**
(`pkg_*_condition` → `Healthy`/`Installed`) and **XRD established** (`xrd_*_condition` →
`Established`). Those close real coverage gaps (see [coverage.md](coverage.md)) and are the
next alerts to add now that the metrics are captured.
