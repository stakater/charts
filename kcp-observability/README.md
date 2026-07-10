# kcp-observability

Prometheus alerts, recording rules, ServiceMonitors/PodMonitor, and a Grafana dashboard for a
**kcp.io control plane** on Stakater Cloud (OpenShift UWM + grafana-operator). Covers the
front-proxy edge, the shard apiservers, druid-managed etcd (incl. **backups**),
workspace/logical-cluster lifecycle, the APIExport/APIBinding surface, the kcp controllers,
the SCO api-syncagents, and pod footprint.

**Built against reality:** every metric was pinned from a live capture of us-2
(kcp v0.32.1) — provenance and label shapes in
[`tests/fixtures/README.md`](tests/fixtures/README.md). The offline gate
([`tests/validate.sh`](tests/validate.sh)) makes it impossible to reference a metric nobody
has proven to exist.

## Read these first

- [`docs/roadmap.md`](docs/roadmap.md) — the 8 capability areas / 20 user stories, each with
  SLI/SLO/SLA, the exact (captured) metrics, alert, and dashboard panel.
- [`docs/dashboard-guide.md`](docs/dashboard-guide.md) — every dashboard panel: why it
  exists, what value it offers, and how to read the board during an incident.
- [`docs/alerts-guide.md`](docs/alerts-guide.md) — every alert: why it exists, what we'd
  miss without it, thresholds/calibration, and the live-validation hardening notes.
- [`tests/fixtures/README.md`](tests/fixtures/README.md) — what was captured, how, and the
  answers to the load-bearing metric questions.
- [`tests/DEPLOY-VALIDATION.md`](tests/DEPLOY-VALIDATION.md) — the deploy-then-validate loop
  for the agent/colleague with cluster access.

## What ships

| Piece | Where | Default |
| --- | --- | --- |
| 4 monitors (shard, front-proxy, etcd + backup sidecar, syncagents) | `templates/prometheus/monitors/` | **disabled** (opt-in) |
| 14 recording rules (`kcp:*` SLI signals) | `templates/prometheus/recording/` | enabled |
| 26 alerts across 8 areas | `templates/prometheus/rules/<area>/` | enabled (fire only once monitors are on) |
| Dashboard (10 rows / 46 panels, incl. a unified alert list) | `files/kcp_grafana_dashboard.json` | enabled |

All alerts carry `rulesgroup: kcp` (Alertmanager routing + the dashboard alert panels key on it).

## Deploying on a cluster (the SRE steps)

Install into the namespace kcp runs in (`kcp-config` on us-2) — UWM resolves scrape targets
and TLS secrets from there, and UWM's namespace enforcement then matches the scraped series.

1. **Enable UWM** (already on for us-2).
2. **Shard metrics authz** — kcp returns 403 on `/metrics` to anonymous clients. Two options:
   - *Preferred:* add to the `RootShard` (and any `Shard`) CR:
     ```yaml
     spec:
       extraArgs:
         - --authorization-always-allow-paths=/livez,/readyz,/healthz,/metrics
     ```
     (via the kcp-operator-config ArgoCD repo — same mechanism the front-proxy uses to allow
     anonymous metrics). **Verify the flag is accepted by v0.32.1 at deploy time.**
   - *Alternative:* mint a client cert with a `kubeconfigs.operator.kcp.io` CR, put its
     `tls.crt`/`tls.key` in a secret, set `prometheus.monitors.shardServiceMonitor.certSecret`.
3. **Remove any hand-made `kcp-front-proxy` ServiceMonitor** in `kcp-config` when enabling
   this chart's front-proxy monitor (it would double-scrape). ✅ **Done on us-2 (2026-07-10,
   team-approved):** the chart's ServiceMonitor was applied, verified scraping (both pods up
   in a second scrape pool), then the 51-day-old manual one was deleted — zero metrics gap,
   same `job` label throughout.
4. **Enable the monitors** (they default off):
   ```yaml
   prometheus:
     monitors:
       shardServiceMonitor:      { enabled: true }
       frontProxyServiceMonitor: { enabled: true }
       etcdServiceMonitor:       { enabled: true }   # uses druid's etcd-client-tls secret
       syncAgentPodMonitor:      { enabled: true }
   ```
5. **Calibrate `prometheus.rules.workspaces.stuck.baseline`** — us-2 runs a standing
   `Scheduling` count (8 at capture time); the default baseline assumes that. Watch the
   "Not-ready trend" panel for 2 weeks, then tighten.
6. **Alertmanager routing** — route on `rulesgroup: kcp` (+ `severity`).

No Grafana-managed alerts are needed here (unlike crossplane-observability): every rule is
same-namespace, so UWM's namespace enforcement is satisfied by construction.

## Configuration highlights

| Value | Purpose | Default |
| --- | --- | --- |
| `kcp.shards.job` | job regex the rules use for shard metrics | `.*-kcp` |
| `kcp.frontProxy.job` | front-proxy job | `frontproxy-front-proxy` |
| `kcp.etcd.job` | etcd job (druid `<name>-client` Service) | `.*-client` |
| `kcp.syncAgent.job` | syncagent job (the PodMonitor name) | `kcp-syncagent` |
| `kcp.podRegex` | footprint alert pod scope | all kcp/etcd/agent pods |
| `prometheus.rules.<area>.<alert>.*` | per-alert `enabled`/`for`/`severity`/thresholds | see `values.yaml` |
| `grafana.*` | folder/instanceSelector/datasources for the dashboard CR | SAAP conventions |

Every threshold is a **placeholder pending 2–4 weeks of baseline** (repo-wide rule).

## Testing (offline, self-contained)

```bash
./tests/validate.sh
```

6 layers: helm lint/template → promtool check → **promtool logic tests** (rule firing
behaviour on synthetic series, `tests/unit/rules.test.yaml`) → **metric-reality gate**
(every referenced metric captured in `tests/fixtures/` or documented-with-citation;
recording refs resolve) → dashboard JSON + PromQL parse → kubeconform strict against
vendored CRD schemas. promtool/kubeconform fall back to Docker if not installed.

Every rule change needs a matching unit test; never weaken the gate to pass. New metric?
Re-capture per [`tests/METRICS-CAPTURE.md`](tests/METRICS-CAPTURE.md) and regenerate the
allowlist (`./tests/generate-allowlist.sh`).

## Known platform follow-ups (not chart work)

- The legacy v0.31.1 `root-proxy` deployment lacks the proxy metrics family — decommission
  or upgrade it (the chart targets the v0.32.1 `frontproxy-front-proxy`).
- The api-syncagents carry a standing restart count — investigate; the restart alert's
  threshold assumes it is fixed or baselined.
- kcp-operator's own metrics sit behind kube-rbac-proxy and rejected a cluster-admin token
  during capture — parked (meta-controller, outside the critical path).
