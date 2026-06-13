# Crossplane components & observability coverage

The full set of Crossplane (v2) "things", what each emits, whether this chart observes it
today, and the gaps. Use this to decide what else to monitor.

## The Crossplane component inventory (v2)

| Component | What it is | Notes (v2) |
| --- | --- | --- |
| **Core control plane** | the `crossplane` pod: package manager, composition engine, RBAC manager | emits controller-runtime + workqueue + (2.2/2.3) function/circuit-breaker metrics |
| **Providers** | controllers that talk to an external API (AWS, Azure, Vault, Kubernetes, …); OCI **packages** | each runs as a pod; emits `crossplane_managed_resource_*` natively |
| **Managed Resources (MRs)** | the leaf external resources a provider reconciles | per-GVK state/TTR/drift metrics |
| **ManagedResourceDefinitions (MRDs)** | **v2-new** — activate MR types independently of provider install | |
| **Composite Resources (XRs)** | one object representing a tree of composed resources | **v2**: can be namespaced; this is the customer-facing unit |
| **Composite Resource Definitions (XRDs)** | define the XR API schema | must be **Established** for the API to exist |
| **Compositions** | the blueprint for an XR — a **pipeline of Functions** | a broken Composition stalls provisioning |
| **Composition Functions** | OCI **packages** that template resources in the pipeline | emit `function_run_*` (from core) |
| **Claims** | namespaced request for an XR | **deprecated in v2** in favour of namespaced XRs |
| **Packages + Revisions** | `Provider` / `Configuration` / `Function` (pkg.crossplane.io) + their `…Revision`s | health via `Healthy`/`Installed` conditions; a failed install kills everything downstream |
| **ProviderConfigs** | credentials/endpoint config for a provider | not metric-bearing |

Sources: [Crossplane v2.3 docs](https://docs.crossplane.io/latest/composition/compositions/) ·
[Composite Resource Definitions](https://docs.crossplane.io/latest/composition/composite-resource-definitions/) ·
[crossplane overview (DeepWiki)](https://deepwiki.com/crossplane/crossplane/1-overview).

## What this chart observes today

| Component | Observed? | Via | Where |
| --- | --- | --- | --- |
| Core control plane | ✅ | controller-runtime, workqueue, aggregated-API, function/circuit-breaker | Rows 1, 3, 5, 6 |
| Providers (pods) | ✅ | controller-runtime + restarts/OOM/CPU | Rows 3, 8 |
| Managed Resources | ✅ | `crossplane_managed_resource_{exists,ready,synced,drift,first_time_to_*}` | Rows 1, 2, 4 |
| Composition Functions | ✅ *(Phase 2)* | `function_run_*` | Row 6 |
| Realtime compositions / circuit breaker | ✅ *(Phase 2)* | `circuit_breaker_*` | Row 5 |
| Upjet provider ↔ cloud | ✅ *(Upjet)* | `upjet_resource_*` | Row 7 |
| Composites (XRs) | ⚠️ alerts only | inventory exporter condition metric (`CompositeNotReady/Synced`) | no dashboard panel yet |

## Gaps — Crossplane components we do NOT observe yet

These are real blind spots. All of them are reachable the **same way Story 4.1 already works**:
the inventory exporter (ksm-crossplane / resource-state-metrics) can emit a
`kube_customresource_crossplane_*_condition` series for **any** Crossplane kind, so closing
these is mostly exporter-config + a few alerts — no new moving parts.

| Gap | Why it hurts | How to close |
| --- | --- | --- |
| **Package health** — `Provider`/`Configuration`/`Function` + `…Revision` `Healthy`/`Installed` | A provider/config package that fails to install or upgrade silently disables **everything** it manages. (us-2 already showed `configurationrevision` churn.) | exporter condition metric on pkg.crossplane.io kinds → `PackageUnhealthy` alert |
| **XRD/MRD Established** | If an XRD isn't `Established`, its API doesn't exist — claims/XRs can't be created at all | exporter condition on `CompositeResourceDefinition` → `XRDNotEstablished` alert |
| **Composition validity** | A broken/invalid Composition stalls provisioning; only shows as generic reconcile errors today | exporter condition on `Composition`, or function-error row |
| ~~Composite (XR) dashboard panel~~ | ✅ DONE — "Composite (XR) ready ratio by kind" panel + `CompositeNotReady`/`CompositeNotSynced` alerts (Grafana-managed on UWM) | — |
| **Function pod footprint** | the footprint row matches `pod=~"provider.*"` — it misses **function** and **core** pod restarts/OOM | widen the regex / add function-pod selectors |
| **Per-tenant rollups** | leaf + XProject metrics carry no `namespace` label — we answer *what kind*, not *whose* | a claim/namespace-labelled metric from the exporter |

## Inventory & billing (MRU)

Live counts come from `crossplane_managed_resource_exists` (value = #MRs per gvk): total,
per-kind, distinct kinds, billable MRUs — shipped as recording rules + an "Inventory & Billing"
dashboard row. **Per-tenant MRU** needs the exporter to emit an MR count carrying your tenant
label (the native metric has only `gvk`). See [billing.md](billing.md).

## See YOUR actual surface

```bash
# Every Crossplane API type installed on the cluster:
kubectl api-resources | grep -iE 'crossplane|upbound'

# The live objects by category:
kubectl get providers,configurations,functions -o wide        # packages
kubectl get xrd,compositions -A                               # APIs + blueprints
kubectl get managed                                           # leaf MRs (can be huge)

# MOST USEFUL — which Crossplane kinds your inventory exporter already emits conditions for
# (this tells us exactly which gaps above are one alert away):
curl -s localhost:8080/metrics \
  | grep -oE 'kube_customresource_crossplane_[a-z_]+' | sort -u
```

The last command is the key one: if it lists `…_provider_condition`, `…_configuration_condition`,
`…_compositeresourcedefinition_condition`, etc., then package/XRD health is already being
exported and we just need the matching alerts.

## Reference: the us-2 inventory (from tests/reports/validation-us-2-2026-06-12.md)

- **Crossplane** 2.1.3
- **Providers:** provider-kubernetes, provider-aws-* (ec2/iam/kms/organizations/route53/s3),
  provider-family-aws, provider-azuread, provider-keycloak, provider-vault, provider-helm,
  provider-ansible, provider-upjet-github, provider-terraform, netbird
- **Functions:** auto-ready, environment-configs, extra-resources, go-templating, kcl,
  patch-and-transform, random-string
- **Composites:** `XProject` (group `tenant.cloud.stakater.com`) + other XR kinds
- **Inventory exporter:** `ksm-crossplane` present
