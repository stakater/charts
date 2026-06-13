# Alerting architecture — why two kinds of alerts

This chart deliberately uses **two alerting mechanisms**. This is not duplication or
indecision — each covers a class of signal the other *cannot*, because of how OpenShift
multi-tenant monitoring works. This document explains why, so the split is intentional and
maintained on purpose.

## The constraint that forces it: UWM namespace enforcement

OpenShift **User Workload Monitoring (UWM)** is multi-tenant. To stop one team's alerts from
reading another team's metrics, it **enforces namespace scoping**: every user-workload
`PrometheusRule` is automatically rewritten to add `namespace="<the rule's own namespace>"`.
You cannot disable or override this — it's a security boundary
(see [README → Inventory rules on OpenShift UWM](../README.md)).

That enforcement is **fine for most of our signals and fatal for one**:

| Signal class | Where the metric originates | Works as a UWM `PrometheusRule`? |
| --- | --- | --- |
| Control plane (reconcile, workqueue, API), providers, **managed resources**, footprint | the Crossplane namespace's scrape jobs (core + provider pods live there) | ✅ Yes — the enforced `namespace=<crossplane-ns>` matches |
| **Composite / Claim inventory** (`kube_customresource_crossplane_xr_*_condition`) | the inventory exporter, **one series per XR carrying the TENANT namespace** (`ws-*`, …) | ❌ No — enforced `namespace=<crossplane-ns>` matches nothing; rule is healthy but fires 0 (silent) |

The cross-tenant composite layer is exactly the platform-team, fleet-wide view we want — and
it's the one UWM's per-namespace model rejects.

## Why not just pick one mechanism

- **Why not all PrometheusRules (UWM only)?** The composite/cross-tenant alerts can't fire
  under UWM enforcement, and the OpenShift **platform** monitoring stack is *not* a valid
  workaround: Red Hat reserves `openshift-*` namespaces for its own components and the stack
  *resets any user objects you add to it*
  ([OpenShift monitoring docs](https://docs.openshift.com/container-platform/4.11/monitoring/configuring-the-monitoring-stack.html)).
  So there is no supported PrometheusRule path for cross-tenant alerting.
- **Why not all Grafana alerts?** The control-plane / MR / footprint rules already work
  natively on UWM, come with Prometheus **recording rules** and `promtool` unit tests, and fit
  the Prometheus-native model the rest of the platform uses. Moving them to Grafana would throw
  away working, tested, supported infrastructure for no benefit.

**So we use the right tool per scope:**

| Scope | Mechanism | Stories |
| --- | --- | --- |
| Namespace-local (originates in the Crossplane namespace) | **Prometheus `PrometheusRule`** evaluated by UWM/thanos-ruler | 1.1–1.3, 2.x, 3.1, 6.1, 7.x |
| Cross-tenant (composite/claim series carry tenant namespaces) | **Grafana-managed alert rules** (grafana-operator), evaluated against thanos-querier (not namespace-enforced) | 4.1 (composite), and any future cross-namespace rollups |

## Your notification pipeline is NOT broken

Grafana-managed alerts **evaluate** in Grafana but can **notify through your existing
Prometheus Alertmanager** — so routing, grouping, silences, and Slack/PagerDuty receivers stay
exactly as they are. Two supported ways
([Grafana docs](https://grafana.com/docs/grafana/latest/alerting/set-up/configure-alertmanager/),
[Alertmanager contact point](https://grafana.com/docs/grafana/latest/alerting/configure-notifications/manage-contact-points/integrations/configure-alertmanager/)):

1. **Alertmanager contact point** — point a Grafana contact point at your Alertmanager; route
   the composite alerts to it. Notifications land in the same Alertmanager as everything else.
2. **External Alertmanager + forwarding** — add Alertmanager as a data source and enable
   "Receive Grafana Alerts" + alert forwarding (both toggles required).

The only practical differences vs a `PrometheusRule`:
- the alert is *evaluated* by Grafana, not thanos-ruler (so it doesn't appear in
  `ALERTS{...}` in Prometheus — it shows in Grafana's alert UI);
- Alertmanager *config* objects (routes, templates) remain managed where they are today;
  Grafana just hands the firing alert to Alertmanager to route.

Net: same Alertmanager, same receivers, same on-call experience — just a different evaluator
for the cross-tenant signals UWM can't handle.

## Summary

Two mechanisms because OpenShift gives us two scopes with two different rules. Namespace-local
signals stay Prometheus-native on UWM (proven, tested, supported). Cross-tenant composite
signals go through Grafana (the only supported way to read across tenant namespaces) and
forward to the **same Alertmanager**, so the pipeline is intact.
