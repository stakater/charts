# MetalLB Observability Roadmap

**Status:** 📝 **Draft — not yet revised against a live capture.** Every metric below is
**[documented]** (cited from upstream docs), none is **[captured]** yet. The capture step
(`../tests/METRICS-CAPTURE.md`) is blocked until a cluster running MetalLB is reachable;
the roadmap must be revised against `tests/fixtures/` and re-reviewed before any story is
approved and built.
**MetalLB version:** TBD at capture (metric families differ by version and backend — see below)
**Owner:** Platform / SRE

---

## How to read this document

Organized **by user story**: need → measurement → target → alert → dashboard.

Lifecycle: 📝 Draft → 👍 Approved (human gate) → 🔨 In progress → ✅ Done. **Nothing below
is approved yet.**

### Metric reality (the discipline)

Tags used below:

- **[documented]** — named in the upstream MetalLB docs
  (<https://metallb.io/prometheus-metrics/>); exact labels **not** stated upstream, so label
  shapes are unverified until capture.
- **[undocumented]** — observed in the wild / in MetalLB source but absent from the docs
  page; must be confirmed by capture or the story is deferred.
- **[captured]** — present in `tests/fixtures/` with the exact labels stated. **None yet.**
- **[ksm]** — standard kube-state-metrics / cAdvisor series, documented upstream.

### Structural facts that shape everything

1. **The BGP/BFD metric family depends on the MetalLB backend.**
   - *Native BGP speaker* and the *deprecated FRR sidecar*: `metallb_bgp_*` — and the
     `peer` label carries `IP:port`.
   - *FRR-K8s mode* (the upstream default today, and what recent OpenShift MetalLB
     operators deploy): `frrk8s_bgp_*` / `frrk8s_bfd_*` — `peer` is the bare IP (no port),
     plus a `vrf` label when VRFs are used. Upstream offers `metricRelabelings` to rename
     `frrk8s_*` back to `metallb_*`, but the peer-label format difference cannot be
     relabeled away.
   - **Consequence:** alert exprs and panels must either cover both families (`or`) or the
     chart must pick one and normalize at the ServiceMonitor. **Decided at capture.**
2. **Metrics split by component.** The *controller* (Deployment) owns allocation
   (`metallb_allocator_*`) and config health; each *speaker* (DaemonSet, host network) owns
   announcement (BGP/BFD/L2) and its own config health; in FRR-K8s mode the `frrk8s_*`
   series come from the frr-k8s daemon pods, not the speaker.
3. **Scrape surface is a capture-time question.** Which Services/ports exist, whether
   metrics sit behind kube-rbac-proxy (TLS + bearer token, as the OpenShift operator is
   believed to do), and whether the operator already creates its own monitors — all decide
   whether this chart ships ServiceMonitors, PodMonitors, or only rules+dashboard on an
   existing scrape. **Do not guess; capture.**
4. **L2 metrics are undocumented upstream.** `metallb_layer2_requests_received` /
   `_responses_sent` / `_gratuitous_sent` and `metallb_speaker_announced` appear in
   MetalLB source/community dashboards but not on the docs page — L2 stories stay deferred
   unless captured.

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
  `metallb_allocator_addresses_total{pool}` **[documented]**
- **SLI:** free IPs per pool
- **SLO:** > 0 free | **SLA:** ✅ candidate
- **Alert:** `MetalLBAddressPoolExhausted` — in-use ≥ total for 5m → critical
- **Dashboard:** per-pool used/total bar gauge; top-of-glass "pools at capacity" stat

## Story 1.2 — Is a pool about to run out? 📝 Draft

> **As an SRE, I want a warning before a pool fills, because adding an IP range needs a
> change window and the exhaustion alert fires only after a user is already stuck.**

- **Metric(s):** same as 1.1 **[documented]**
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

- **Metric(s):** `metallb_bgp_session_up{peer}` **[documented — native/FRR]** *or*
  `frrk8s_bgp_session_up{peer}` **[documented — FRR-K8s]**; family decided at capture
- **SLI:** sessions up / sessions configured
- **SLO:** 100% over 5m | **SLA:** ✅ candidate (reachability)
- **Alert:** `MetalLBBGPSessionDown` — session down for 5m → critical
- **Dashboard:** session state matrix (node × peer); announced prefixes per peer
  (`*_bgp_announced_prefixes_total` **[documented]**)

## Story 2.2 — Is a BGP session flapping? 📝 Draft

> **As an SRE, I want to catch a session that bounces, because a flapping session causes
> intermittent reachability that a point-in-time "down" alert misses between evaluations.**

- **Metric(s):** `frrk8s_bgp_opens_sent` / `frrk8s_bgp_notifications_sent`
  **[documented — FRR-K8s only]**; native-mode equivalent TBD at capture
- **SLI:** session up/down transitions per hour
- **SLO:** 0 sustained flaps | **SLA:** ❌ internal
- **Alert:** `MetalLBBGPSessionFlapping` — `changes()`/open-rate over threshold → warning
- **Dashboard:** opens/notifications rate per peer

---

# Capability Area 3 — BFD (fast failover health)

Only meaningful where BFD is configured on top of BGP; no BFD series on a cluster without
it (alert simply never fires — keep it enabled-by-default only if capture shows the series).

## Story 3.1 — Is a BFD session down? 📝 Draft

> **As an SRE, I want to know when BFD to a peer is down, because the whole point of BFD
> is sub-second failover — without it a dead path lingers for the full BGP hold time.**

- **Metric(s):** `frrk8s_bfd_session_up{peer}` **[documented — FRR-K8s]**; native family
  (`metallb_bfd_session_up`) TBD at capture
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

- **Metric(s):** `metallb_k8s_client_config_loaded_bool` **[documented]** (controller and
  speaker both export it)
- **Alert:** `MetalLBConfigNotLoaded` — `== 0` for 5m → critical
- **Dashboard:** config-loaded stat per pod

## Story 4.2 — Is a component running on a stale config? 📝 Draft

> **As an SRE, I want to know when the latest config failed to apply, because the change
> I just merged silently isn't live and the gap only surfaces at the next pod restart —
> which then fails loudly at the worst time.**

- **Metric(s):** `metallb_k8s_client_config_stale_bool` **[documented]**
- **Alert:** `MetalLBConfigStale` — `== 1` for 5m → warning
- **Dashboard:** stale-config stat per pod

## Story 4.3 — Are config updates erroring? 📝 Draft

> **As an SRE, I want the update-error rate, because repeated reconcile failures predict
> 4.1/4.2 and point at the broken resource before the state bits flip.**

- **Metric(s):** `metallb_k8s_client_update_errors_total` (vs
  `metallb_k8s_client_updates_total`) **[documented]**
- **Alert:** `MetalLBK8sClientErrors` — error increase over 10m → warning
- **Dashboard:** update vs error rate per pod

---

# Capability Area 5 — Component availability

## Story 5.1 — Is the controller up? 📝 Draft

> **As an SRE, I want to know when the MetalLB controller is down or unscraped, because
> nothing allocates IPs: every new or changed `LoadBalancer` Service hangs until it's back.**

- **Metric(s):** `up{job=<this chart's controller monitor>}`; fallback
  `absent(metallb_allocator_addresses_total)` — surface decided at capture
- **SLO:** ≥ 99.9% | **SLA:** ❌ internal (existing allocations keep working)
- **Alert:** `MetalLBControllerDown` — `up == 0` or absent for 5m → critical
- **Dashboard:** availability tile

## Story 5.2 — Is a speaker down? 📝 Draft

> **As an SRE, I want to know when a node's speaker stops, because that node withdraws /
> stops answering for the service IPs it announced; with `externalTrafficPolicy: Local`
> or L2 leadership that can blackhole a service, not just degrade a path.**

- **Metric(s):** `up` per speaker target via this chart's monitor; count vs expected
  (DaemonSet desired via **[ksm]** `kube_daemonset_status_desired_number_scheduled` — only
  if capture confirms UWM can see it, else count-based)
- **Alert:** `MetalLBSpeakerDown` — a speaker target `up == 0` for 5m → warning;
  all speakers down → critical
- **Dashboard:** speakers-up count vs nodes

## Story 5.3 — Watchdog: are the metrics themselves flowing? 📝 Draft

> **As an SRE, I want an alert when MetalLB metrics go absent entirely, because a broken
> scrape (cert rotation, monitor deleted, UWM off) silently disables every alert above —
> green dashboards, blind on-call.**

- **Metric(s):** `absent()` over the family chosen at capture
- **Alert:** `MetalLBMetricsAbsent` — 15m → warning (oadp watchdog pattern)

---

# Capability Area 6 — Layer 2 mode (deferred)

## Story 6.1 — L2 announcement visibility 📝 Draft — deferred until capture

> **As an SRE on an L2 cluster, I want to see ARP/NDP announcement activity, because in L2
> mode "is anyone answering for this IP?" has no session metric like BGP — traffic just
> stops.**

- **Metric(s):** `metallb_layer2_requests_received` / `metallb_layer2_responses_sent` /
  `metallb_layer2_gratuitous_sent`, `metallb_speaker_announced` — all **[undocumented]**;
  build only what capture shows. Dashboard panels only, no alert (no good signal for
  "nobody answered").

---

# Capability Area 7 — Footprint (deferred)

Speaker/controller restarts, OOM, CPU throttling via **[ksm]**/cAdvisor — same shape as
kcp's footprint rules. Deferred: generic pod alerts likely already cover `metallb-system`;
revisit after capture confirms what the cluster's baseline alerting already catches.

---

## Release gate

Per-story: roadmap revised against capture → 👍 approval → rules/panels built behind
`tests/validate.sh` (unit rule tests: every alert fires and resolves) → read-only deploy
validation on a real cluster, report committed to `tests/reports/`.
