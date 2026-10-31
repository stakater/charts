# NetBird Observability Roadmap

**Status:** v1 stories ✅ shipped; Draft stories 📝 awaiting approval
**NetBird version observed:** v0.75.0 (management, signal, relay)
**Owner:** Platform / SRE

---

## How to read this document

Organized **by user story**: each starts with what someone operating a fleet of NetBird
instances actually needs, and *why*. The metric that answers it, how we judge good-vs-bad
(SLI/SLO), the alert, and the dashboard hang off that need. Read each story as:
**need → measurement → target → alert → dashboard → status.**

Lifecycle: 📝 Draft (written down, not agreed) → 👍 Approved → 🔨 In progress → ✅ Done.
A Draft story is never built without approval.

> **Calibration note:** every numeric threshold below is a **placeholder** until it has run
> 2–4 weeks against a real fleet baseline. Thresholds live in `values.yaml` per alert, so
> calibration is a values change, not a chart change.

## The deployment model this chart assumes

A **fleet** of NetBird instances, **one instance per customer/organization**, each in its
own namespace. One instance = a management deployment, a signal deployment, and a relay
deployment (the dashboard is a static frontend; PostgreSQL is a CNPG cluster covered by
`cloudnative-pg-observability` — one chart, one mechanism).

**This chart installs once per instance namespace.** That is forced by the platform's
monitoring tenancy model (OpenShift UWM): ServiceMonitors only discover targets in their
own namespace, and ThanosRuler enforces the `namespace` label of origin onto every
user-created rule — a single central install could neither scrape the fleet nor evaluate
cross-namespace rules without a cluster-level opt-out (`namespacesWithoutLabelEnforcement`).
Per-instance installs need no opt-out, and every alert naturally carries the instance's
namespace, which is exactly the routing dimension on-call needs ("which customer's mesh?").
The **dashboard is fleet-capable**: one `$namespace` template variable spans all instances
(Grafana's datasource reads cluster-wide), so enable `grafana.dashboard.enabled` on exactly
one install per cluster.

The chart ships its own per-component **metrics Services with fixed names**
(`netbird-management-metrics`, `netbird-signal-metrics`, `netbird-relay-metrics`), so the
Prometheus `job` label is identical across every instance in the fleet — rules and
dashboard queries don't depend on release names. NetBird needs no configuration for this:
all three components expose `:9090/metrics` by default.

## Metric reality (captured 2026-10-30, v0.75.0 containers)

The chart is built against **captured** `/metrics` output (`tests/fixtures/`), not the docs,
because the docs are wrong or incomplete in ways that would have produced silent-empty rules:

- `management_grpc_connected_streams` exports as **`management_grpc_connected_streams_ratio`**
  (OTel gauge suffix). The documented name has no series.
- The aggregate HTTP response-code counter exports as
  **`management_http_response_counter_code_total`**, not `…response_code_total`.
- `management_http_request_counter_total` exports an **aggregate series (no `endpoint`
  label) alongside per-endpoint series** — summing the family double-counts. Totals must
  filter `{endpoint=""}`.
- **Most application metrics are lazily registered**: a freshly started signal exposes *no*
  app metrics at all (`active_peers` appears on first registration); management's gRPC,
  store, and updatechannel families appear on first use. Alerts must not treat absence of a
  lazy metric as data — only `up` and the watchdogs reason about absence.
- Standalone signal metrics are **unprefixed** (`registrations_total`, `active_peers`) —
  every signal query must be scoped by `job`, or it collides with anything else exporting
  generic names.
- On-cluster (caught by the kind e2e, not the docker capture): prometheus-operator stamps
  its own `endpoint` target label (the scrape port name) onto every series, renaming
  NetBird's HTTP `endpoint` label to **`exported_endpoint`**. Queries that segment or pin
  the HTTP endpoint must use `exported_endpoint`.

**Upstream comparison** (netbirdio/netbird `infrastructure_files/observability/grafana/dashboards`,
checked 2026-10-31): NetBird ships per-component Grafana dashboards but **no alert rules** —
the alerts here are designed from the SRE stories below, not adapted from upstream. The
upstream dashboards are single-instance (no fleet dimension) and several of their queries
use metric names that do not match v0.75.0's exporter (e.g.
`management_grpc_login_request_counter_ratio_total`, `…_sync_request_duration_ms_bucket`) —
a live failed-login capture confirmed the docs' names (`…_login_request_counter_total`)
over the dashboard variants. Depth panels upstream has that v2 of our dashboard could add
once a fleet capture confirms their names: update-channel queue length, network-map object
counts, store global-lock/transaction latency, signal forward latency, relay peer-store time.

Two-tier allowlist: `metrics-allowlist.captured.txt` (really scraped from the pinned
fixtures) and `metrics-allowlist.documented.txt` (upstream-documented, lazily registered —
confirmed name-by-name against the docs, to be promoted to captured once a live fleet
capture exercises them). `tests/validate.sh` refuses any query that references a metric in
neither.

---

# Capability Area 1 — Instance availability (the outcome)

An instance whose control plane is down is a customer whose mesh is degrading: peers
cannot enroll, re-authenticate, pick up network-map changes, or fall back to relay.

## Story 1.1 — Is each component of each instance up? ✅

> **As an SRE running N customer meshes, I want to be paged when a component of any
> instance stops being scrapable, because management down means no peer can (re)connect or
> get config, signal down means no new peer-to-peer connections can be negotiated, and
> relay down means peers behind hard NAT lose their fallback path.**

- **Metric:** `up{job="netbird-{management,signal,relay}-metrics"}`
- **SLI:** % of scrape intervals with all three jobs up, per instance
- **SLO:** 99.9% over 30 days per instance
- **Alert:** `NetBirdTargetDown` (per component, `up == 0` for 5m → critical)
- **Dashboard:** fleet overview row — component status per namespace
- **Status:** ✅ v1

## Story 1.2 — Would we even know? (blindness watchdog) ✅

> **As an SRE, I want an alert when the metrics themselves vanish, because a deleted
> ServiceMonitor or a selector drift disarms every other alert silently — the fleet looks
> green precisely when we are blind.**

- **Metric:** `absent(up{job=…, namespace=…})` per enabled component
- **Alert:** `NetBirdMetricsAbsent` (10m → warning)
- **Status:** ✅ v1

# Capability Area 2 — Peer connectivity (what the customer perceives)

## Story 2.1 — Did a customer's peers mass-disconnect? ✅

> **As an SRE, I want to know when an instance that had connected peers suddenly has none,
> because management can be perfectly healthy while every peer is cut off (LB/gRPC path
> broken, TLS expiry on the management endpoint) — and the customer notices before we do.**

- **Metric:** `management_grpc_connected_streams_ratio` (captured; the live gauge of open
  Sync streams ≈ connected peers)
- **SLI:** connected streams > 0 whenever the instance had peers in the recent baseline
- **Alert:** `NetBirdPeersDisconnected` (streams `== 0` while the 6h baseline had ≥
  `minPeers`, for 10m → critical)
- **Dashboard:** connected peers per instance over time (the headline fleet panel)
- **Status:** ✅ v1

## Story 2.2 — Are peers failing to register with signal? ✅

> **As an SRE, I want to know when signal registrations fail or message forwarding
> degrades, because that is the earliest signal that peers cannot negotiate new
> connections even though everything is "up".**

- **Metrics:** `registration_failures_total`, `message_forward_failures_total`,
  `messages_forwarded_total` (documented tier; lazily registered, job-scoped)
- **Alerts:** `NetBirdSignalRegistrationFailures` (failure rate > 0 sustained 15m →
  warning), `NetBirdSignalForwardFailures` (failure ratio > 10% over 15m → warning;
  forwarding to an offline peer is normal in small doses)
- **Dashboard:** signal row — active peers, registration rate, forward failures
- **Status:** ✅ v1

## Story 2.3 — Synthetic probe peer 📝

> **As an SRE, I want a real peer that continuously enrolls and pings across each mesh,
> because only an end-to-end WireGuard handshake proves the data plane a customer uses.**

- Requires a probe peer (netbird client + setup key) per mesh and somewhere to report
  (kube-health-inspector pattern). Out of scope for this chart's v1; likely its own
  mechanism.
- **Status:** 📝 Draft

# Capability Area 3 — Control-plane responsiveness (leading indicators)

## Story 3.1 — Is the management API degrading? ✅

> **As an SRE, I want to know when the management HTTP API returns server errors or slows
> down, because the dashboard, the Crossplane provider, and our bootstrap automation all
> drive this API — a degraded API stalls tenant provisioning long before anything is
> "down".**

- **Metrics:** `management_http_response_counter_code_total{code=~"5.."}`,
  `management_http_request_counter_total{endpoint=""}`,
  `management_http_request_duration_ms_total_milliseconds` (all captured)
- **SLI:** 5xx ratio; p95 latency
- **SLO:** < 1% 5xx over 1h; p95 ≤ 500ms (placeholder)
- **Alerts:** `NetBirdManagementApiErrorRateHigh` (warning),
  `NetBirdManagementApiLatencyHigh` (warning)
- **Status:** ✅ v1

## Story 3.2 — Are peer logins/syncs slow or being throttled? ✅

> **As an SRE, I want to know when peer login/sync gRPC latency climbs or the built-in
> rate limiter starts rejecting requests, because that precedes mass reconnect storms and
> peers flapping — the classic death spiral after a management restart with many peers.**

- **Metrics:** `management_grpc_sync_request_duration_ms_milliseconds`,
  `management_grpc_login_request_duration_ms_milliseconds`,
  `management_grpc_login_request_blocked_counter_total`,
  `management_grpc_sync_request_blocked_counter_total` (documented tier; lazy)
- **Alerts:** `NetBirdManagementSyncLatencyHigh` (p95 over threshold 15m → warning),
  `NetBirdManagementRequestsBlocked` (any blocked requests sustained 10m → warning)
- **Status:** ✅ v1

## Story 3.3 — Is the store (PostgreSQL, as management sees it) slow? ✅

> **As an SRE, I want the NetBird-side symptom of a degraded database, because CNPG's own
> alerts say "postgres is slow" but not "and that is why this customer's peers see login
> timeouts" — the correlation needs both ends measured.**

- **Metric:** `management_store_persistence_duration_ms_milliseconds` (documented tier)
- **Alert:** `NetBirdManagementStoreSlow` (p95 over threshold 15m → warning)
- **Status:** ✅ v1 (postgres itself: `cloudnative-pg-observability`)

# Capability Area 4 — Data-path visibility (dashboard-first)

## Story 4.1 — How much traffic rides the relay? ✅ (dashboard only)

> **As an SRE, I want relay peer counts and throughput visible, because a rising share of
> relayed peers means direct connectivity (STUN/NAT traversal) is degrading — peers still
> work but with worse latency and our egress costs climb. It needs eyes, not pages.**

- **Metrics:** `relay_peers_active`, `relay_peers_idle` (captured);
  `relay_transfer_sent_bytes_total`, `relay_transfer_received_bytes_total` (documented)
- **Dashboard:** relay row. No alert in v1 — threshold needs fleet baseline first.
- **Status:** ✅ v1 dashboard; alert 📝 Draft

## Story 4.2 — IdP integration health 📝

> **As an SRE, I want to know when management→Keycloak calls fail, because peers with
> expiring auth then cannot re-login.**

- **Metrics:** `management_idp_request_error_counter_total` etc. (documented tier)
- **Status:** 📝 Draft — needs a live capture from an IdP-enabled instance first to
  confirm the family's real names and labels.

# Capability Area 5 — Gaps found in the coverage review (2026-10-31, all 📝 Draft)

A systematic sweep (golden signals × components × user journeys × fleet lifecycle) after
v1 shipped. Written down so they are not lost; none is built without approval.

## Story 5.1 — Do NetBird alerts actually reach a human? 📝 **(urgent, not a chart change)**

> **As an SRE, I want every `NetBird*` alert mapped to a receiver in the cluster's
> Alertmanager routing, because an alert that fires into a catch-all drop rule protects
> nobody — and this exact failure has bitten this platform's alerting before.**

- Not solved by this chart: it is routing configuration where Alertmanager lives.
  The chart's hook is `prometheus.rules.labels` (merged into every rule) — set the
  routing label the cluster's Alertmanager keys on, and add `NetBird*` mappings.
- **Verification:** a routed test alert per cluster, not a config review.

## Story 5.2 — Is every mesh in the fleet actually monitored? 📝 **(urgent)**

> **As an SRE, I want to know when a NetBird instance EXISTS but this chart is not
> installed in its namespace, because the per-instance blindness watchdog only exists
> where the chart is installed — a mesh provisioned without it degrades invisibly, and
> nothing in the current design can notice.**

- Inherently cluster-scoped (one per cluster, not per instance): compare namespaces
  running netbird workloads (e.g. KSM `kube_pod_container_info` on netbird images)
  against namespaces exporting `up{job="netbird-management-metrics"}`.
- Belongs in a small hub-mode toggle of this chart or in the mesh composition's
  provisioning contract (install the observability chart transactionally with the mesh).
  Decide before building.

## Story 5.3 — Are the components resource-starved? (saturation) 📝

> **As an SRE, I want OOM-kill / crashloop / CPU-throttling alerts for management,
> signal and relay, because management's memory grows with peer count and an OOM
> crashloop today only surfaces as a flapping TargetDown — symptom, not cause.**

- KSM + cadvisor metrics (`kube_pod_container_status_*`, `container_cpu_cfs_throttled_*`),
  scoped to the instance namespace; same pattern as crossplane-observability's footprint
  rules. The restarts dashboard panel exists; the alerts do not.

## Story 5.4 — Registered peers vs connected peers 📝

> **As an SRE, I want "how many peers SHOULD be connected" per instance, because
> connected-streams alone cannot distinguish a healthy quiet mesh from a half-outage —
> today's NetBirdPeersDisconnected only catches the all-gone case, not a 50% drop.**

- NetBird exports no registered-peers gauge; needs a tiny exporter against the
  management API (`GET /api/peers` — the bootstrap PAT exists for exactly this kind of
  service account), the oadp state-exporter pattern. Unlocks a partial-disconnect alert
  with a real denominator.

## Story 5.5 — Instance provisioning convergence (bootstrap) 📝

> **As an SRE, I want to know when a mesh's zero-touch bootstrap never converges,
> because the bootstrap CronJob retries forever by design — a tenant whose IdP client or
> PAT never materializes is a provisioning outage that currently pages nobody.**

- `kube_job_status_failed` / job age for the instance's bootstrap CronJob, or an
  absent-PAT-Secret check via the state exporter of Story 5.4. Part of observing the
  instance, so it belongs here — but confirm against "one chart, one mechanism" first.

## Story 5.6 — Per-tenant SLO attainment and error budget 📝

> **As the platform owner, I want the SLIs defined in Areas 1–3 rolled up into
> per-tenant SLO attainment with an error budget, because the targets in this document
> are not yet computed anywhere — they are definitions without measurement.**

- Recording rules feeding the platform's existing SLO tooling; do after thresholds are
  calibrated on fleet baseline. Also the natural place for customer-facing reporting.

Also noted, smaller: the admin web dashboard (static frontend) has no metrics — its
availability is synthetic-probe territory (platform health-check tooling, with Story 2.3);
a fleet version-skew panel (netbird image per instance via KSM) for v2 of the dashboard.

# Out of scope (deliberately)

- **PostgreSQL internals** — `cloudnative-pg-observability` (one chart, one mechanism).
- **Certificates** (management/signal/relay TLS) — `cert-manager-observability`.
- **LoadBalancer/MetalLB reachability** — platform networking observability.
- **NetBird client-side metrics** (`/debug` local endpoint) — client fleet is customer
  infrastructure.
- **Combined-container / proxy deployments** — the platform runs the multi-container
  layout only; combined-container metric prefixes (`signal_*`) differ and are not covered.
