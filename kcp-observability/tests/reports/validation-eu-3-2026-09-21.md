# Validation report — eu-3 — 2026-09-21

Chart/git: kcp-observability 0.0.1, branch `kcp-observability` @ `b4d9e19` | kcp:
kcp-operator layout, 2-replica root shard, api-syncagent v0.5.0 | Helm: release
`kcp-observability` in `kcp-config`, **rev 1** | **Verdict: PASS-WITH-ISSUES**
(every chart layer verified live on eu-3 first try; 1 threshold to set for this cluster,
and 1 structurally broken alert found that affects all clusters — see §7b / O2)

This is the chart's **second cluster**. It was written and hardened against us-2; eu-3 is
the portability test. Everything below was observed live (thanos-querier API +
thanos-ruler `/api/v1/rules`), not inferred.

## 0. Portability — what did NOT need changing

The headline result: **all four monitor selectors matched eu-3 unchanged**, and the only
values override that carries real cluster-specific content is the Grafana namespace.

| Chart assumption | eu-3 reality | Verdict |
| --- | --- | --- |
| shard Svc `component=rootshard, managed-by=kcp-operator, name=kcp` | `root-kcp` carries exactly these | matches |
| front-proxy Svc `component=front-proxy` | `frontproxy-front-proxy` | matches |
| etcd Svc `component=etcd-client-service, managed-by=etcd-druid` | `root-client` | matches |
| syncagent pods `app.kubernetes.io/name=kcp-api-syncagent` | 18 pods / 9 service APIs | matches |
| etcd secrets `etcd-client-tls` + `etcd-ca-tls` | both present (druid-created) | matches |
| `kcp.shards.job` regex `.*-kcp`, `etcd.job` `.*-client` | `root-kcp`, `root-client` | matches |
| `kcp.etcd.expectedMembers: 3` | 3-member druid StatefulSet | matches |
| `kcp.podRegex` | covers `root-kcp-*`, `frontproxy-*`, `root-proxy-*`, `root-N`, `services-*`, `system-*` | matches |

Three us-2 battle scars turned out to be **us-2-specific, not chart bugs** — eu-3 needed
none of the workarounds:

- **S1 (syncagent metrics bound to loopback)** — a non-issue here. eu-3's api-syncagent
  v0.5.0 releases already pass `--metrics-address=0.0.0.0:8085`. All 18 agent pods scrape
  green on the first try. The port-less-pod `__address__` relabel was still required (the
  agents declare no containerPort on eu-3 either) — that part of the design carried over
  and is now confirmed on two independent clusters.
- **Grafana `instanceSelector` `app: null` override** — not needed. eu-3's Grafana instance
  carries the SAAP-default `app=grafana`, so the chart's shipped default matches as-is.
  (us-2's `dashboards: crossplane` selector was the outlier.)
- **Hand-made `kcp-front-proxy` ServiceMonitor conflict** — `kcp-config` on eu-3 had **zero**
  pre-existing ServiceMonitors/PodMonitors, so no monitor swap and no double-scrape risk.

## 1. Prerequisite applied

`docs/shard-metrics-cert-example.yaml` applied verbatim — cert-manager `Certificate`
`kcp-metrics-scraper-cert` in `kcp-config`, issuer `root-client-ca` (present and Ready on
eu-3), `CN=kcp-metrics-scraper`, `O=system:kcp:admin`. Issued Ready, secret has
`tls.crt`/`tls.key`.

Verified against the live shard via port-forward to `svc/root-kcp:6443`:

| Client | `/metrics` |
| --- | --- |
| anonymous | **403** |
| with `kcp-metrics-scraper-cert` | **200**, 17020 lines |

The RootShard CR on eu-3 carries no `extraArgs`, so option A
(`--authorization-always-allow-paths`) is not in play — the cert is what makes shard
scraping work here. Same hardening TODO as us-2 applies (`O=system:kcp:admin` is broader
than a `/metrics`-only binding needs).

## 2. Offline gate

`./tests/validate.sh` — **all green**, run before touching the cluster:
helm lint + both renders · promtool check 47 rules · promtool test rules logic SUCCESS ·
captured allowlist in sync with fixtures · metric gate 29/38 captured + 9
documented-upstream + 12 recording refs resolved · dashboard JSON valid, panel ids unique,
59 panel queries parse · kubeconform strict 35/35 valid.

## 3. Scrape targets

Rendered 33 objects (dashboard → `stakater-grafana-operator`, everything else →
`kcp-config`). All targets came up within 15s of install:

| Job | Expected | Observed |
| --- | --- | --- |
| `root-kcp` (shard) | 2 | **2 up** |
| `frontproxy-front-proxy` | 2 | **2 up** |
| `root-client` (etcd client + backup-restore endpoints) | 6 | **6 up** |
| `kcp-syncagent` | 18 | **18 up** |

`up{namespace="kcp-config"} == 0` → empty. **28/28 targets green, zero down.**

This is the first cluster where all four monitors are live simultaneously (us-2 shipped
with the syncagent monitor disabled until S1 was resolved).

## 4. Recording rules

All **15/15** recording rules evaluate and produce series in thanos-ruler:
`kcp:apibinding_ready_ratio`, `kcp:apibinding_ttr_ms:p95`, `kcp:etcd_commit_seconds:p99`,
`kcp:etcd_db_used_ratio`, `kcp:etcd_fsync_seconds:p99`,
`kcp:front_proxy_error_ratio:rate5m`, `kcp:front_proxy_latency_seconds:p95`,
`kcp:front_proxy_latency_seconds:p99`, `kcp:front_proxy_requests:rate5m`,
`kcp:logicalclusters_not_ready:count`, `kcp:shard_error_ratio:rate5m`,
`kcp:shard_latency_seconds:read_p99`, `kcp:shard_latency_seconds:write_p99`,
`kcp:workspace_ready_ratio`, `kcp:workspaces_not_ready:count`.

No dead recording rule — i.e. every SLI signal the dashboard and alerts depend on has real
data on eu-3, not just on us-2.

## 5. Alerts

**28 rule groups / 45 rules** loaded in thanos-ruler. 45 = the 47 rendered minus the two
default-disabled kcp#4277 gauge-drift alerts (`workspaces.stuck`,
`workspaces.logicalClustersStuck`) — the shipped defaults behaved exactly as intended.

**Zero firing.** Two alerts pending at the observation point:

| Alert | Scope | Status |
| --- | --- | --- |
| `KcpEtcdDiskSlow` | all 3 members (`root-0/1/2`) | pending — needs baseline (below) |
| `KcpFrontProxyLatencyHigh` | front-proxy | pending — needs baseline (below) |

Neither is a chart defect: both are the *placeholder thresholds* that values.yaml
explicitly marks "calibrate". `KcpEtcdDiskSlow` on all three members at once is the same
signature us-2 showed, where the cause was a network-attached-storage fsync baseline
(~170–190ms vs the upstream 10ms default) and the fix was the documented per-cluster
`fsyncP99Seconds`/`commitP99Seconds` override, not a rule change.

## 6. Dashboard

`GrafanaDashboard` `kcp-observability-dashboard` in `stakater-grafana-operator`:

```
type:    DashboardSynchronized
status:  True
reason:  ApplySuccessful
message: Dashboard was successfully applied to 1 instances
```

`grafana.namespace: stakater-grafana-operator` was required — eu-3's grafana-operator is
OLM OwnNamespace (OperatorGroup targets only its own namespace), the same constraint class
as us-2 but a different namespace. This confirms `grafana.namespace` is the right knob to
have exposed.

## 7. Baselines measured (follow-up session, same day)

Cluster access was restored and both pending alerts were characterised.

### 7a. `KcpEtcdDiskSlow` — real signal, needs an eu-3 threshold (now **firing**)

| Member | `kcp:etcd_fsync_seconds:p99` | `kcp:etcd_commit_seconds:p99` |
| --- | --- | --- |
| `root-0` | 24.7 ms | 28.6 ms |
| `root-1` | 69.8 ms | 26.1 ms |
| `root-2` | 64.6 ms | 27.3 ms |

Defaults are `fsyncP99Seconds: 0.01` / `commitP99Seconds: 0.025`, so both clauses are
breached and the alert has gone pending → firing on all three members.

eu-3 is **not** us-2: fsync is 25–70 ms here vs us-2's 170–190 ms. Still above the
upstream 10 ms guidance, but by ~3–7× rather than ~20×. **Do not apply us-2's 0.5/1.0
override** — it would be ~7× looser than eu-3's worst member and would blind the alert
entirely. Commit p99 in particular sits only just over its 25 ms default, so a small
raise there is enough.

Suggested starting point once a ≥24h window confirms these are the standing baseline and
not a transient: `fsyncP99Seconds: 0.15`, `commitP99Seconds: 0.06` (≈2× the observed
worst member, leaving room to detect real degradation). Treat the 25–70 ms baseline
itself as an SRE storage observation for eu-3, as was done for us-2.

### 7b. `KcpFrontProxyLatencyHigh` — **chart defect, not a threshold problem**

`kcp:front_proxy_latency_seconds:p95` reads exactly **60** — the top finite bucket of
`proxy_request_duration_seconds`. The histogram's shape explains it:

| `le` | cumulative count |
| --- | --- |
| 1.0 | 23368 |
| 10.0 | 23418 |
| 60.0 | 23469 |
| `+Inf` | **25394** |

**1925 observations (7.6%) exceed 60 s** — long-running watch requests against the edge.
Because the watch fraction is above 5%, the p95 lands in the `+Inf` bucket and
`histogram_quantile` returns the highest finite boundary, pinning the recorded value at a
constant 60. The p99 is pinned the same way.

This is the mirror image of the already-documented workqueue scar ("histograms cap at
`le=10`, so a ≥10s threshold can never fire"): here the top bucket pins the quantile
*high*, so `KcpFrontProxyLatencyHigh` at `p95Seconds: 1` fires permanently and carries no
information.

**It cannot be fixed by tuning `p95Seconds`.** Raising the threshold above 60 makes the
alert unfirable; leaving it makes it a constant false positive. And it cannot be fixed by
filtering either: `proxy_request_duration_seconds` on this build carries **only `code` and
`method`** — there is no `verb`, `path` or `scope` label, so watches are indistinguishable
from ordinary GETs in this metric.

The shard latency rule sidesteps this by scoping to non-longrunning read/write requests;
the front-proxy rule has no equivalent dimension available. A redesign is needed — e.g.
alert on the slow-fraction *within* the non-watch population,
`1 - (rate(...{le="1"}[5m]) / rate(...{le="60"}[5m]))`, which is watch-insensitive — but
that is a chart-owner design call, not a per-cluster override, so it is left open rather
than patched here.

Front-proxy request rate at capture: ~1.45 req/s on the active series (three sibling
series at 0), i.e. a lightly loaded edge — another reason not to read the raw p95 as a
performance statement.

## 8. Empty-panel sweep (2026-09-22, rev 2)

`python3 tests/walk-panels.py` against live eu-3: **57/59 panel queries returned data**.
Both empties were diagnosed to root cause; **neither was a broken query** — both were
correct-but-invisible, which on a dashboard is indistinguishable from a broken scrape.

### 8a. "Inflight + APF rejections" — APF rejection line missing

`apiserver_flowcontrol_rejected_requests_total{job=~"$shard_job"}` returned nothing, but
APF is demonstrably live on the kcp shards: `apiserver_flowcontrol_dispatched_requests_total`
= **451,502**. The metric is a *labelled counter*, which Prometheus only materialises on
the first increment — so "no series" means "zero rejections ever", not "not collected".
Confirmed by finding the same metric present elsewhere in the cluster on `job=apiserver`
(`reason=time-out`, value 3), i.e. the name is right and it does appear once tripped.

**Fix:** appended `or vector(0)`, pinning the line at a flat 0. This is the dashboard's
established idiom for exactly this case — already used on 7 other targets. Panel
description added explaining why a flat zero is the healthy reading.

### 8b. "OOM kills (last terminated reason)" — no data

The panel filters `reason="OOMKilled"`. kcp-config has 2 containers with a terminated
state, but both are `reason=Error` (the two api-syncagent pods with 1 restart each) — so
**no kcp container has ever been OOM-killed** on eu-3. kube-state-metrics is not the
problem: the sibling `kube_pod_container_status_restarts_total` returns 30 series for the
same namespace.

**Fix:** set `fieldConfig.defaults.noValue: "0"` so Grafana renders `0` instead of
`No data`. `or vector(0)` was deliberately **not** used here: on a `max by (pod, container)`
panel it would fabricate an unlabelled series rendering as a blank `/` legend entry.

### 8c. Tooling: `walk-panels.py` no longer cries wolf

8b is a *render* fix, not a query fix, so the panel walker would have reported that query
EMPTY forever — training readers to ignore the report, the same blindness failure mode the
chart's watchdog alerts exist to prevent. The walker now treats any panel declaring
`fieldConfig.defaults.noValue` as **expected-empty** and reports it as `empty-ok`. The rule
is general (no hardcoded panel list); panels without `noValue` are still required to have
data.

Post-fix walk: **58 with data, 1 expected-empty, 0 unexpectedly empty, 0 errors.**

Both changes verified in the live `GrafanaDashboard` CR after `helm upgrade` (rev 2,
`DashboardSynchronized=True`, applied to 1 instance).

## Open items

**O1 — set eu-3 `KcpEtcdDiskSlow` thresholds.** Baseline measured (§7a); confirm over ≥24h,
then set `prometheus.rules.etcd.diskSlow.fsyncP99Seconds` / `commitP99Seconds` to eu-3's
own numbers. Do not reuse us-2's.

**O2 — `KcpFrontProxyLatencyHigh` is structurally broken (§7b).** Affects **every** cluster,
not just eu-3, and also invalidates the p95/p99 front-proxy latency dashboard panels.
Needs a rule redesign before this alert can be trusted anywhere. Highest-value follow-up
from this validation. Consider defaulting it to `enabled: false` in the interim, the same
treatment the kcp#4277 gauge-drift alerts already get.

**O3 — access interruption (resolved).** eu-3 credentials briefly dropped to bare
`system:authenticated` mid-validation, deferring §7; access returned and the measurements
were completed the same day. No impact on the release.

## Dashboard access (eu-3)

`https://grafana-route-stakater-grafana-operator.apps.eu-3.djo8y3mc.stakater.cloud/d/kcp-control-plane`
(dashboard uid `kcp-control-plane`, title "kcp / Control Plane", folder "kcp Observability")

No Grafana-local credentials exist: the instance runs behind the OpenShift oauth-proxy
(`-provider=openshift`) with `disable_login_form: True`. Sign in with your OpenShift SSO
account. Authorization is the proxy's SAR — `get` on namespace
`stakater-grafana-operator`; `users.auto_assign_org_role: Admin` then grants Grafana Admin.

## Reproducing

```bash
export KUBECONFIG=$HOME/.kube/config-eu3
kubectl apply -f docs/shard-metrics-cert-example.yaml     # prerequisite
./tests/validate.sh                                       # offline gate
helm install kcp-observability . -n kcp-config -f <this cluster's values>
./tests/thanos-query.sh 'sum by (job) (up{namespace="kcp-config"})'
```

The eu-3 values overlay used is `docs/values-eu-3-example.yaml`.
