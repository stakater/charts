# Validation — Task 3: Grafana composite-alert delivery (us-2)

**Date:** 2026-07-16
**Cluster:** us-2 (`api-us-2-b24jftow.stakater.cloud`)
**Chart:** `crossplane-observability` @ local `pr-274`, version bumped `0.1.0` → `0.1.1`
**Jira:** SA-8539 sub-task 3 (DoD Blocker 3 — "prove a Grafana composite alert is *delivered* to a contact point")
**Verdict:** **PASS** — full fix + end-to-end delivery proven.

## Problem (carried over)

The Grafana-managed composite path was NON-FUNCTIONAL: `GrafanaFolder crossplane-observability-alerts`
and `GrafanaAlertRuleGroup crossplane-observability-composite` had blank status / never reconciled
for 31 days; Grafana's alerting engine showed **0 rule groups**.

## Root cause (two chart bugs)

1. **Wrong namespace.** The two composite CRs used the release-namespace helper
   (`crossplane-observability.namespace` → `crossplane-system`), but the grafana-operator on us-2 runs
   **namespace-scoped** (`OperatorGroup targetNamespaces: [crossplane-observability]`; operator log:
   `operator running in namespace scoped mode {"namespace": "crossplane-observability"}`). It never
   watched `crossplane-system`, so it never saw the CRs. The `GrafanaDashboard` reconciled fine only
   because it already used `grafana.namespace` (= `crossplane-observability`).
   **Fix:** the folder + alertrulegroup now use
   `.Values.grafana.namespace | default (include "…namespace" .)`, same as the dashboard.

2. **Folder title collision.** Once the CRs landed in the watched namespace, the folder reported
   `FolderSynchronized=True` but the alertrulegroup failed:
   `folder with uid f83ec84c-… not found`. The `GrafanaFolder` title defaulted to `grafana.folder`
   ("Crossplane Observability") — the **same title as the dashboard folder** (`cfoy1ajo1vv28d`).
   grafana-operator keys folders by title, so it matched the existing dashboard folder and never
   created a folder at this CR's UID; the alertrulegroup's `folderRef` then resolved to a
   non-existent UID.
   **Fix:** the alert folder title now defaults to `"<grafana.folder> Alerts"`
   ("Crossplane Observability Alerts"), distinct from the dashboard folder.
   Overridable via `grafana.compositeAlerts.folder`.

## Verification (live, us-2)

Deployed rev 11 (`helm upgrade … -f docs/values-stakater-cloud-example.yaml -f deploy-us-2-values.yaml
--set grafana.compositeAlerts.datasourceUid=2470be9b-…`):

| Check | Result |
|---|---|
| CRs relocate to `crossplane-observability`, removed from `crossplane-system` | ✅ |
| `GrafanaFolder` status | `FolderSynchronized=True` — applied to 1 instance |
| Folder created in Grafana with CR UID | ✅ uid `f83ec84c-…`, title "Crossplane Observability Alerts" |
| `GrafanaAlertRuleGroup` status | `AlertGroupSynchronized=True` — applied to 1 instance |
| Grafana alerting engine `/api/prometheus/grafana/api/v1/rules` | 1 group `crossplane-observability-composite`; `CompositeNotReady` + `CompositeNotSynced` both **firing**, health ok (was 0 groups) |

### Delivery proof (step b)

Grafana had **0 contact points** and root policy receiver `"empty"` (alerts fired but went nowhere).
Stood up a throwaway webhook sink (`cpobs-webhook-test` ns), created a **webhook contact point**
(`cpobs-webhook-test`) and a **notification policy route** matching `rulesgroup="crossplane"` → that
contact point.

- Within ~10s (group_wait) Grafana POSTed firing notifications to the sink. **9 notification POSTs**
  captured; batches for both `CompositeNotReady` and `CompositeNotSynced`.
- Payload carried real composites, e.g.
  `CompositeNotReady` → `HostedClusterConfig/oauth420test-hosted-cluster-config` (ns
  `hypershift-oauth420test`); `CompositeNotSynced` → `KubeStackConfig/claws-config`.
- Full label set present (`rulesgroup=crossplane`, `crossplane_kind`, `name`, `namespace`, `severity`,
  condition `values A/B/C`), i.e. the alert is deliverable and actionable.

**Conclusion:** the Grafana-managed composite alert path fires AND delivers end-to-end once the two
chart bugs are fixed and a contact point + route exist.

## Not shipped by the chart (SRE decision)

The contact point + notification policy are **cluster-specific** (target Alertmanager/webhook, creds,
routing tree) and are intentionally NOT in the chart. Production intent (per HANDOVER §B):
route `rulesgroup=crossplane` to the platform `alertmanager-main` (where UWM alerts land via receiver
`kubeward`). The webhook sink used here was a test artifact and was torn down after the proof.

## Teardown

- Deleted ns `cpobs-webhook-test` (sink pod/svc/cm).
- Deleted Grafana contact point `cpobs-webhook-test` and reset the notification policy route.
</content>
