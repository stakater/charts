# MetalLB Observability Roadmap

**Status:** ✅ **Built, e2e-verified (2026-11-01) and validated against the OpenShift
MetalLB operator (2026-11-06)** — every story below is implemented behind
`tests/validate.sh` (unit-tested rule logic), verified on the kind lab
(`tests/reports/e2e-kind-2026-11-01.md`: every alert fired and resolved), and the
real-cluster comparison is done (`tests/reports/operator-openshift-2026-11-06.md`: scrape
surface diffed, deltas folded into the chart defaults, every alert expression evaluated
live, read-only deploy validation passed). Metric names and label shapes marked
**[captured]** are real, from `tests/fixtures/` (provenance in
[`../tests/fixtures/README.md`](../tests/fixtures/README.md)). **Release gate cleared.**
**Captured:** upstream v0.15.3 FRR-K8s mode (kind) **and** OpenShift MetalLB operator
4.22 FRR-K8s mode (OCP 4.22.13).
**Owner:** Platform / SRE

---

## How to read this document

Organized **by user story**: need → measurement → target → alert → dashboard.

Lifecycle: ✅ Done → 👍 Approved (human gate) → 🔨 In progress → ✅ Done. Stories below
were approved 2026-11-01 and built the same day; Area 7 stays deferred.

### Metric reality (the discipline)

- **[captured]** — in `tests/fixtures/` with the exact labels stated (on both the upstream
  and the operator capture unless a story says otherwise).
- **[captured, lazy]** — in the fixtures, but the series **registers lazily** (only on the
  speaker currently announcing); `absent()`-style logic on it is unsafe.
- **[documented]** — upstream-documented (<https://metallb.io/prometheus-metrics/>) but not
  in our fixtures (wrong mode/version for this deployment).
- **[absent]** — looked for and not there on this build. Never faked.
- **[ksm]** — standard kube-state-metrics/cAdvisor series, documented upstream.

### Structural facts (settled by the capture)

1. **The deployment is FRR-K8s mode, so the BGP/BFD family is `frrk8s_*`.**
   `frrk8s_bgp_*` / `frrk8s_bfd_*` carry `{peer="<IP>", vrf="default"}` — **no port in
   `peer`** **[captured]**. The native family (`metallb_bgp_*`, `peer="IP:port"`) is
   **[absent]** here and exists only on native-BGP deployments **[documented]**.
   *Open design question for approval:* alert exprs on `frrk8s_*` only, or
   `frrk8s_* or metallb_bgp_*` to also cover native-mode installs.
2. **Who exports what** **[captured]**: *controller* → `metallb_allocator_*{pool}` (plus
   undocumented `metallb_allocator_ipv{4,6}_*` variants) + `metallb_k8s_client_*`;
   *each speaker* → `metallb_k8s_client_*`, and (lazily, announcer-only)
   `metallb_speaker_announced{ip,node,protocol,service}` + `metallb_layer2_*{ip}`;
   *each frr-k8s pod* → `frrk8s_k8s_client_*` (port 7572) and the BGP/BFD families
   (port 7573), both per node per peer.
3. **Who scrapes depends on the layout** **[captured, both]**. *Upstream* (kind): no
   metrics Services, no monitors — the chart's PodMonitors are the only scrape
   (controller/speaker plain HTTP on `monitoring` 7472; frr-k8s only via kube-rbac-proxy
   TLS on `metricshttps` 9140/9141). *OpenShift operator* (the default): the operator
   ships its own ServiceMonitors into `cluster-monitoring` namespaces and the **platform**
   Prometheus already scrapes everything under jobs `controller-monitor-service` /
   `speaker-monitor-service` / `frr-k8s-monitor-service`; pod labels are `app` +
   `component`, raw ports are 29150 / 7572 / 7573, every port sits behind a proxy, and
   **FRR-K8s runs in its own namespace (`openshift-frr-k8s`)**. The chart therefore
   targets the operator's job labels by default (`metallb.*.job`), keeps its PodMonitors
   off (`metallb.operatorManagedMonitors: true`), and `tests/e2e/values-e2e.yaml` is the
   upstream profile.
4. **Per-node semantics**: BGP sessions and `announced_prefixes` are per frr-k8s pod per
   peer; a node announcing nothing legitimately reports 0 prefixes.

### The SLI / SLO / SLA distinction

- **SLI** — the measurement. **SLO** — internal target with an error budget; pages on-call.
- **SLA** — externally promised, only a few, looser than the SLO. MetalLB's customer-facing
  promise is: *a `LoadBalancer` Service gets an IP, and that IP is reachable*. Areas 1–2
  are the SLA candidates; everything else is internal.

> **Calibration:** every numeric target is a **placeholder** until 2–4 weeks of baseline.

---

# Capability Area 1 — Address allocation (does a Service get an IP?)

The controller's one job: hand every `LoadBalancer` Service an external IP from a pool.
When a pool is full, new Services sit `<pending>` forever — silently.

## Story 1.1 — Is an address pool exhausted? ✅ Done

> **As an SRE, I want to know when an address pool has no free IPs, because every new
> `LoadBalancer` Service against it stays `<pending>` with no error anywhere a user looks.**

- **Metric(s):** `metallb_allocator_addresses_in_use_total{pool}`,
  `metallb_allocator_addresses_total{pool}` **[captured]**
- **SLI:** free IPs per pool
- **SLO:** > 0 free | **SLA:** ✅ candidate
- **Alert:** `MetalLBAddressPoolExhausted` — in-use ≥ total for 5m → critical
- **Dashboard:** per-pool used/total bar gauge; top-of-glass "pools at capacity" stat

## Story 1.2 — Is a pool about to run out? ✅ Done

> **As an SRE, I want a warning before a pool fills, because adding an IP range needs a
> change window and the exhaustion alert fires only after a user is already stuck.**

- **Metric(s):** same as 1.1 **[captured]**
- **SLI:** pool utilization %
- **SLO:** ≤ 90% (placeholder) | **SLA:** ❌ internal
- **Alert:** `MetalLBAddressPoolNearExhaustion` — utilization > threshold for 15m → warning
- **Dashboard:** utilization % trend per pool

---

# Capability Area 2 — Announcement: BGP (is the IP reachable?)

An allocated IP is worthless until the network learns a route to it. A down BGP session
means the peer router stopped hearing announcements from that node.

## Story 2.1 — Is every BGP session up? ✅ Done

> **As an SRE, I want to know the moment a BGP session to a peer drops, because traffic to
> service IPs announced over that session blackholes or loses a path, and the Services
> themselves still look green in Kubernetes.**

- **Metric(s):** `frrk8s_bgp_session_up{peer,vrf}` **[captured]** (per node per peer;
  native-mode `metallb_bgp_session_up` **[absent]** here — see structural fact 1)
- **SLI:** sessions up / sessions configured
- **SLO:** 100% over 5m | **SLA:** ✅ candidate (reachability)
- **Alert:** `MetalLBBGPSessionDown` — session down for 5m → critical
- **Dashboard:** session state matrix (node × peer); per-peer
  `frrk8s_bgp_announced_prefixes_total` **[captured]** (per-node value — 0 is legitimate
  on a non-announcing node)

## Story 2.2 — Is a BGP session flapping? ✅ Done

> **As an SRE, I want to catch a session that bounces, because a flapping session causes
> intermittent reachability that a point-in-time "down" alert misses between evaluations.**

- **Metric(s):** `frrk8s_bgp_opens_sent`, `frrk8s_bgp_notifications_sent` **[captured]**
- **SLI:** session up/down transitions per hour
- **SLO:** 0 sustained flaps | **SLA:** ❌ internal
- **Alert:** `MetalLBBGPSessionFlapping` — `changes(frrk8s_bgp_session_up)` / open-rate
  over threshold → warning
- **Dashboard:** opens/notifications rate per peer

---

# Capability Area 3 — BFD (fast failover health)

Only meaningful where BFD is configured on top of BGP (it was in the kind capture; the
operator cluster has no `BFDProfile` and the family is **[absent]** there). On a cluster
without BFD the series never registers, so the alert stays silent.

## Story 3.1 — Is a BFD session down? ✅ Done

> **As an SRE, I want to know when BFD to a peer is down, because the whole point of BFD
> is sub-second failover — without it a dead path lingers for the full BGP hold time.**

- **Metric(s):** `frrk8s_bfd_session_up{peer,vrf}` **[captured]**, with
  `frrk8s_bfd_session_{up,down}_events` **[captured]** for churn context
- **SLO:** 100% | **SLA:** ❌ internal
- **Alert:** `MetalLBBFDSessionDown` — down for 2m → warning (BGP hold-time still protects)
- **Dashboard:** BFD session state per peer; up/down event rate

---

# Capability Area 4 — Configuration health

MetalLB keeps running on its last good config when a new one is rejected — invisible
until an address or peer you *thought* you added isn't there.

## Story 4.1 — Is a component running without any config? ✅ Done

> **As an SRE, I want to know when a MetalLB pod has never loaded a config, because it is
> allocating nothing and announcing nothing while its pod reports Ready.**

- **Metric(s):** `metallb_k8s_client_config_loaded_bool` (controller + every speaker) and
  `frrk8s_k8s_client_config_loaded_bool` (every frr-k8s pod) — both **[captured]**, no
  extra labels beyond the scrape-target ones
- **Alert:** `MetalLBConfigNotLoaded` — `== 0` for 5m → critical
- **Dashboard:** config-loaded stat per pod

## Story 4.2 — Is a component running on a stale config? ✅ Done

> **As an SRE, I want to know when the latest config failed to apply, because the change
> I just merged silently isn't live and the gap only surfaces at the next pod restart —
> which then fails loudly at the worst time.**

- **Metric(s):** `metallb_k8s_client_config_stale_bool`,
  `frrk8s_k8s_client_config_stale_bool` **[captured]**
- **Alert:** `MetalLBConfigStale` — `== 1` for 5m → warning
- **Dashboard:** stale-config stat per pod

## Story 4.3 — Are config updates erroring? ✅ Done

> **As an SRE, I want the update-error rate, because repeated reconcile failures predict
> 4.1/4.2 and point at the broken resource before the state bits flip.**

- **Metric(s):** `metallb_k8s_client_update_errors_total` /
  `metallb_k8s_client_updates_total` (+ `frrk8s_` twins) **[captured]**
- **Alert:** `MetalLBK8sClientErrors` — error increase over 10m → warning
- **Dashboard:** update vs error rate per pod

---

# Capability Area 5 — Component availability

`up{job=<metallb.*.job>}` — the operator's own monitors by default, or the chart's
PodMonitors on upstream installs (structural fact 3). The `up` alerts render whenever one
of the two scrapes exists.

## Story 5.1 — Is the controller up? ✅ Done

> **As an SRE, I want to know when the MetalLB controller is down or unscraped, because
> nothing allocates IPs: every new or changed `LoadBalancer` Service hangs until it's back.**

- **Metric(s):** `up` via the chart's controller PodMonitor; `absent()` fallback over
  `metallb_allocator_addresses_total` **[captured]**
- **SLO:** ≥ 99.9% | **SLA:** ❌ internal (existing allocations keep working)
- **Alert:** `MetalLBControllerDown` — `up == 0` or absent for 5m → critical
- **Dashboard:** availability tile

## Story 5.2 — Is a speaker down? ✅ Done

> **As an SRE, I want to know when a node's speaker stops, because that node withdraws /
> stops answering for the service IPs it announced; with `externalTrafficPolicy: Local`
> or L2 leadership that can blackhole a service, not just degrade a path.**

- **Metric(s):** `up` per speaker target via the chart's speaker PodMonitor; expected
  count via `kube_daemonset_status_desired_number_scheduled` **[ksm — verified visible
  in the same Prometheus on the operator cluster, 2026-11-06]**
- **Alert:** `MetalLBSpeakerDown` — a speaker target `up == 0` for 5m → warning;
  all speakers down → critical
- **Dashboard:** speakers-up count vs nodes

## Story 5.3 — Watchdog: are the metrics themselves flowing? ✅ Done

> **As an SRE, I want an alert when MetalLB metrics go absent entirely, because a broken
> scrape (cert rotation, monitor deleted, UWM off) silently disables every alert above —
> green dashboards, blind on-call.**

- **Metric(s):** `absent(metallb_k8s_client_updates_total)` and
  `absent(frrk8s_k8s_client_updates_total)` **[captured]** — always-registered families,
  safe for absence logic (unlike the lazy speaker families)
- **Alert:** `MetalLBMetricsAbsent` — 15m → warning (oadp watchdog pattern)

---

# Capability Area 6 — Announcement visibility (L2 + who-announces-what)

The capture **un-deferred this area**: the upstream-undocumented families exist on
v0.15.3, but **register lazily and only on the announcing speaker** — panel material and
join material, not `absent()` material.

## Story 6.1 — Which node announces which service? ✅ Done

> **As an SRE, I want to see which speaker currently announces each service IP and over
> which protocol, because during an incident "who owns this IP right now" is the first
> question for both BGP (which sessions matter) and L2 (which node answers ARP).**

- **Metric(s):** `metallb_speaker_announced{ip,node,protocol,service}` **[captured, lazy]**
  (protocol `bgp`|`layer2`; `service` is `<namespace>/<name>`). On the operator cluster
  (BGP only) **every** speaker registers it for every IP — the lazy/announcer-only
  behaviour is the L2 case.
- **Dashboard:** announcement table (service → ip → node → protocol); no alert from this
  series alone (lazy registration makes absence ambiguous)

## Story 6.2 — L2 announcement activity ✅ Done

> **As an SRE on an L2 service, I want ARP/NDP request/response rates per IP, because in
> L2 mode there is no session metric — a service nobody answers for just goes dark, and
> gratuitous-announcement bursts are the visible trace of failover.**

- **Metric(s):** `metallb_layer2_requests_received{ip}`,
  `metallb_layer2_responses_sent{ip}`, `metallb_layer2_gratuitous_sent{ip}`
  **[captured, lazy]** (kind; **[absent]** on the operator cluster, which has no
  `L2Advertisement`)
- **Dashboard:** rates per IP; panels only, no alert (lazy + announcer-only).

---

# Capability Area 7 — Footprint (deferred)

Speaker/controller restarts, OOM, CPU throttling via **[ksm]**/cAdvisor — same shape as
kcp's footprint rules. Deferred: the operator cluster had **no MetalLB-specific alerts at
all** (the operator ships no `PrometheusRule`s), but the platform's generic
`KubePodCrashLooping` / `KubeDaemonSetRolloutStuck` family covers the pod-footprint
cases; revisit only if those prove too coarse.

---

## Release gate

Per-story: 👍 approval → rules/panels built behind `tests/validate.sh` (unit rule tests:
every alert fires and resolves on synthetic series) → alert e2e on the kind stack
(`tests/e2e/`, scenarios drive every alert to fire and resolve) → ✅ **real-cluster
comparison capture** (2026-11-06: `tests/METRICS-CAPTURE.md` re-run read-only against
an OpenShift cluster running the MetalLB operator, fixtures + scrape surface diffed,
deltas folded into the chart defaults) → ✅ read-only deploy validation, report
`tests/reports/operator-openshift-2026-11-06.md`.
