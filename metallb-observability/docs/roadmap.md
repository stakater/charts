# MetalLB Observability Roadmap

**Status:** 📝 **Draft, revised against a live capture (2026-11-01)** — metric names and
label shapes below marked **[captured]** are real, from `tests/fixtures/` (provenance in
[`../tests/fixtures/README.md`](../tests/fixtures/README.md)). Captured from the kind lab
in `tests/e2e/`, **not yet from a production cluster** — the real-cluster comparison is a
committed follow-up (handover activity, see `tests/e2e/README.md`). **No story is
approved yet.**
**MetalLB version captured:** v0.15.3, **FRR-K8s mode** (frr-k8s v0.0.21, FRR 10.4.1)
**Owner:** Platform / SRE

---

## How to read this document

Organized **by user story**: need → measurement → target → alert → dashboard.

Lifecycle: 📝 Draft → 👍 Approved (human gate) → 🔨 In progress → ✅ Done.

### Metric reality (the discipline)

- **[captured]** — in `tests/fixtures/` with the exact labels stated.
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
3. **The chart must ship PodMonitors** **[captured]**: no metrics Services and no
   operator-created monitors exist. Controller + speaker are plain HTTP on container port
   `monitoring` (7472). frr-k8s raw ports bind 127.0.0.1; its only scrapeable surface is
   kube-rbac-proxy TLS on `metricshttps` 9140/9141 (bearer token + TLS + RBAC for the
   scraping SA). **Verify against the real OpenShift operator layout in the handover
   comparison before freezing monitor defaults.**
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

## Story 1.1 — Is an address pool exhausted? 📝 Draft

> **As an SRE, I want to know when an address pool has no free IPs, because every new
> `LoadBalancer` Service against it stays `<pending>` with no error anywhere a user looks.**

- **Metric(s):** `metallb_allocator_addresses_in_use_total{pool}`,
  `metallb_allocator_addresses_total{pool}` **[captured]**
- **SLI:** free IPs per pool
- **SLO:** > 0 free | **SLA:** ✅ candidate
- **Alert:** `MetalLBAddressPoolExhausted` — in-use ≥ total for 5m → critical
- **Dashboard:** per-pool used/total bar gauge; top-of-glass "pools at capacity" stat

## Story 1.2 — Is a pool about to run out? 📝 Draft

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

## Story 2.1 — Is every BGP session up? 📝 Draft

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

## Story 2.2 — Is a BGP session flapping? 📝 Draft

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

Only meaningful where BFD is configured on top of BGP (it was in the capture). On a
cluster without BFD the series never registers, so the alert stays silent.

## Story 3.1 — Is a BFD session down? 📝 Draft

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

## Story 4.1 — Is a component running without any config? 📝 Draft

> **As an SRE, I want to know when a MetalLB pod has never loaded a config, because it is
> allocating nothing and announcing nothing while its pod reports Ready.**

- **Metric(s):** `metallb_k8s_client_config_loaded_bool` (controller + every speaker) and
  `frrk8s_k8s_client_config_loaded_bool` (every frr-k8s pod) — both **[captured]**, no
  extra labels beyond the scrape-target ones
- **Alert:** `MetalLBConfigNotLoaded` — `== 0` for 5m → critical
- **Dashboard:** config-loaded stat per pod

## Story 4.2 — Is a component running on a stale config? 📝 Draft

> **As an SRE, I want to know when the latest config failed to apply, because the change
> I just merged silently isn't live and the gap only surfaces at the next pod restart —
> which then fails loudly at the worst time.**

- **Metric(s):** `metallb_k8s_client_config_stale_bool`,
  `frrk8s_k8s_client_config_stale_bool` **[captured]**
- **Alert:** `MetalLBConfigStale` — `== 1` for 5m → warning
- **Dashboard:** stale-config stat per pod

## Story 4.3 — Are config updates erroring? 📝 Draft

> **As an SRE, I want the update-error rate, because repeated reconcile failures predict
> 4.1/4.2 and point at the broken resource before the state bits flip.**

- **Metric(s):** `metallb_k8s_client_update_errors_total` /
  `metallb_k8s_client_updates_total` (+ `frrk8s_` twins) **[captured]**
- **Alert:** `MetalLBK8sClientErrors` — error increase over 10m → warning
- **Dashboard:** update vs error rate per pod

---

# Capability Area 5 — Component availability

The chart ships its own PodMonitors (structural fact 3), so `up{job=<chart monitor>}` is a
surface the chart controls.

## Story 5.1 — Is the controller up? 📝 Draft

> **As an SRE, I want to know when the MetalLB controller is down or unscraped, because
> nothing allocates IPs: every new or changed `LoadBalancer` Service hangs until it's back.**

- **Metric(s):** `up` via the chart's controller PodMonitor; `absent()` fallback over
  `metallb_allocator_addresses_total` **[captured]**
- **SLO:** ≥ 99.9% | **SLA:** ❌ internal (existing allocations keep working)
- **Alert:** `MetalLBControllerDown` — `up == 0` or absent for 5m → critical
- **Dashboard:** availability tile

## Story 5.2 — Is a speaker down? 📝 Draft

> **As an SRE, I want to know when a node's speaker stops, because that node withdraws /
> stops answering for the service IPs it announced; with `externalTrafficPolicy: Local`
> or L2 leadership that can blackhole a service, not just degrade a path.**

- **Metric(s):** `up` per speaker target via the chart's speaker PodMonitor; expected
  count via `kube_daemonset_status_desired_number_scheduled` **[ksm — verify UWM
  visibility on the real cluster before relying on it]**
- **Alert:** `MetalLBSpeakerDown` — a speaker target `up == 0` for 5m → warning;
  all speakers down → critical
- **Dashboard:** speakers-up count vs nodes

## Story 5.3 — Watchdog: are the metrics themselves flowing? 📝 Draft

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

## Story 6.1 — Which node announces which service? 📝 Draft

> **As an SRE, I want to see which speaker currently announces each service IP and over
> which protocol, because during an incident "who owns this IP right now" is the first
> question for both BGP (which sessions matter) and L2 (which node answers ARP).**

- **Metric(s):** `metallb_speaker_announced{ip,node,protocol,service}` **[captured, lazy]**
  (protocol `bgp`|`layer2`)
- **Dashboard:** announcement table (service → ip → node → protocol); no alert from this
  series alone (lazy registration makes absence ambiguous)

## Story 6.2 — L2 announcement activity 📝 Draft

> **As an SRE on an L2 service, I want ARP/NDP request/response rates per IP, because in
> L2 mode there is no session metric — a service nobody answers for just goes dark, and
> gratuitous-announcement bursts are the visible trace of failover.**

- **Metric(s):** `metallb_layer2_requests_received{ip}`,
  `metallb_layer2_responses_sent{ip}`, `metallb_layer2_gratuitous_sent{ip}`
  **[captured, lazy]**
- **Dashboard:** rates per IP; panels only, no alert (lazy + announcer-only).

---

# Capability Area 7 — Footprint (deferred)

Speaker/controller restarts, OOM, CPU throttling via **[ksm]**/cAdvisor — same shape as
kcp's footprint rules. Deferred: generic pod alerts likely already cover the MetalLB
namespace; revisit after the real-cluster comparison shows what baseline alerting exists.

---

## Release gate

Per-story: 👍 approval → rules/panels built behind `tests/validate.sh` (unit rule tests:
every alert fires and resolves on synthetic series) → alert e2e on the kind stack
(`tests/e2e/`, scenarios drive every alert to fire and resolve) → **real-cluster
comparison capture** (handover activity: re-run `tests/METRICS-CAPTURE.md` read-only
against a cluster running the MetalLB operator, diff fixtures + scrape surface, fold
deltas into monitor defaults) → read-only deploy validation, dated report in
`tests/reports/`.
