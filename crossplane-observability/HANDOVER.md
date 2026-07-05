# crossplane-observability — ownership handover

One-page orientation for the next owner. Read this, then `tests/README.md`.

## What it is

A Helm chart of Prometheus alerts + recording rules + a Grafana dashboard for Crossplane on
Stakater Cloud (OpenShift UWM), implementing the roadmap in `docs/roadmap.md`. Everything is
organised by that roadmap's 7 capability areas / 17 user stories. It ships with a
**self-contained test harness** whose central rule is: **no metric is referenced unless it's
either captured from a real cluster (`tests/fixtures/`) or documented upstream with a citation.**

## Status (2026-07)

- Branch `crossplane-observability`, **PR #274** (open, not merged). Chart `version: 0.0.1`.
- Offline gate `./tests/validate.sh` → green (helm lint/template, promtool check+test, metric
  gate, dashboard PromQL parse, strict CRD-schema validation).
- **Deployed & validated on us-2** repeatedly (`tests/reports/validation-us-2-*.md`). Last run
  (06-16) = PASS-WITH-ISSUES; the one MAJOR was a cluster-side config gap (below), not a chart bug.
- Working end-to-end: all Phase-1 stories; Story 4.1 composite readiness + billing; the
  Grafana-managed composite alerts fire; the dashboard (11 rows, ~45 panels) renders.

## The last pieces to finish

### A. Publish blockers (must do before merge/publish)
1. **Bump `Chart.yaml` `version`** (suggest `0.1.0` for the first release). CI publishes by
   version; an unbumped `0.0.1` fails publish. Repo rule: one chart per PR, **Rebase and Merge**.
2. Merge PR #274.

### B. One-time cluster setup (SRE; see README "What the SRE must do for production")
Per-cluster, not chart code. On us-2: datasource UID set + composite alerts firing; **still open:**
3. **`jsonData.manageAlerts: true`** on the `prometheus-uwm` GrafanaDatasource — without it the
   unified Alert list shows only Grafana-managed alerts (06-16 MAJOR; exact snippet in README 3b).
4. **Grafana → Alertmanager contact point** routing `rulesgroup=crossplane`, and **confirm a
   composite alert actually notifies** (it fires today; delivery not yet verified — DEPLOY-VALIDATION §5b/§5c).

### C. Deferred chart work (optional; metrics already captured, so low-risk)
5. **Gap-closing alerts** — `PackageUnhealthy` (`pkg_*_condition` Healthy/Installed),
   `XRDNotEstablished` (`xrd_*_condition` Established), and **claim coverage** in the composite
   alerts (currently `xr_*` only). Metrics are in `tests/fixtures/inventory-metrics.txt`. See `docs/coverage.md`.
6. **Enable + validate Phase-2 / Upjet** — functions (5.x), circuit-breaker (4.2), Upjet (6.1)
   ship **disabled**; their metrics exist on 2.1.3 (panels show data). Turn on + validate.
7. **Threshold calibration** — every threshold is a placeholder pending 2–4 weeks of baseline
   (e.g. reconcile-error 1% is known-tight).
8. **Billing config the platform owns** — set `$billable` (dashboard var) to the chargeable
   kinds; apply MRU weighting in the billing system. See `docs/billing.md`.

## How to work on it (the discipline — don't skip)

- `./tests/validate.sh` is the gate; it **must stay green** on every change. It runs offline
  (promtool/kubeconform via Docker if not on PATH).
- **Every rule change needs a `tests/unit/rules.test.yaml` case** (promtool). Never weaken the
  gate to pass.
- **Never reference a metric you haven't verified.** New metric → capture it (extend
  `tests/integration.sh` or fold a real dump into `tests/fixtures/`) so it lands in
  `metrics-allowlist.captured.txt`, or add it to `metrics-allowlist.documented.txt` with a
  citation + reason. `tests/check_metrics.py` enforces this (incl. `__name__=~` patterns).
- **Labels are the #1 bug class.** The whole project's pain came from assuming labels
  (`gvk` not `kind/name/namespace`; `result_severity` not `result`; per-GVK not per-tenant).
  Confirm against real data via `tests/fetch-cluster-metrics.sh` + `tests/verify-fetched.py`.

## Agent briefs (this is how validation is run)

- `tests/HANDOFF.md` — verify the "documented" metrics against live clusters → graduate to captured.
- `tests/DEPLOY-VALIDATION.md` — the deploy-then-validate loop; produces a structured report in
  `tests/reports/`. §5b = Grafana composite alerts; §5c = the unified Alert list panel.

## Key design decisions (the "why", so you don't undo them)

- **Two alerting paths on purpose** (`docs/alerting-architecture.md`): OpenShift UWM enforces
  `namespace=<rule ns>` on every user-workload PrometheusRule. Namespace-local signals
  (control-plane, MRs, footprint) stay Prometheus-native. **Cross-tenant composite/claim signals
  can't** (their series carry tenant namespaces), and the platform monitoring stack is
  unsupported — so those go through **Grafana-managed alerts** (query thanos-querier, not
  namespace-enforced) that **forward to the same Alertmanager**. Pipeline intact; only the evaluator differs.
- **Leaf MR metrics are per-GVK counts** (`gvk` label only, no namespace). Per-tenant needs the
  inventory exporter's Claim/XR metrics (`namespace` = workspace = tenant). Billing counts
  XR/Claim units (the `{type="Ready",status="True"}` condition series), not leaf MRs.
- Recording rules that aggregate cross-namespace are **UWM-empty**; the dashboard billing/composite
  panels use **raw cross-namespace queries** (thanos-querier isn't namespace-enforced).

## Definition of Done

This is done when **every box is checked with evidence** (a command's output, a screenshot, a
report file) — not "should work". Honest-over-complete: an unchecked box with a note beats a
checked one you didn't verify.

**Chart & publish**
- [ ] `Chart.yaml` `version` bumped to `0.1.0` (from `0.0.1`).
- [ ] `./tests/validate.sh` exits 0 — full output seen, not assumed.
- [ ] PR #274 rebased on `main`, CI green, **Rebase-and-Merged** (one chart per PR).
- [ ] The published chart is installable from the registry at the new version.

**Alerting pipeline proven end-to-end** (the part most likely to be faked as "done")
- [ ] A Prometheus (UWM) alert from the chart is seen **firing in Alertmanager**.
- [ ] A Grafana-managed composite alert is seen **firing** AND **delivered to a contact point**
      (screenshot of the notification, or Alertmanager showing the `rulesgroup=crossplane` alert)
      — firing alone is not done.
- [ ] The unified Alert list panel shows **both** sources (needs `manageAlerts: true`); the
      "Alerts firing" stat matches the list count.

**Metric reality** (no invented metrics reach production)
- [ ] Every metric the chart references is either in `metrics-allowlist.captured.txt` or in
      `metrics-allowlist.documented.txt` with a citation — `check_metrics.py` passes.
- [ ] On the target cluster, the "documented" metrics that were expected to appear (functions,
      Upjet, circuit-breaker if those paths are enabled) are confirmed present, or the panels/rules
      that depend on them are explicitly marked "awaiting workload".

**Dashboard**
- [ ] Dashboard loads with no "N/A" / "No data" on panels that should have data on the target
      cluster; any empty panel has a known reason (feature disabled / no such workload).

**Docs & thresholds**
- [ ] Every threshold shipped is either calibrated against ≥2 weeks of baseline **or** labelled
      in values as a provisional default.
- [ ] `docs/coverage.md` reflects the actual shipped coverage (gaps listed honestly).

**Deferred items — decision recorded, not silently dropped**
- [ ] The 3 gap-closing alerts (package / XRD / claim), Phase-2, and Upjet are each either
      shipped-and-validated or explicitly deferred with a reason in the PR / an issue.

## Where everything lives

| Path | What |
| --- | --- |
| `docs/roadmap.md` | the 17 user stories (design intent) |
| `docs/coverage.md` | Crossplane components → what we observe vs gaps |
| `docs/alerting-architecture.md` | why two alerting paths |
| `docs/billing.md` | MRU billing (XR/Claim, per-tenant) |
| `docs/dashboard-panels.md` | panel-by-panel rationale |
| `docs/values-stakater-cloud-example.yaml` | the SAAP/UWM override set |
| `templates/prometheus/rules/<area>/` | alerts, one concern per file |
| `templates/grafana/` | dashboard CR, composite alerts (GrafanaAlertRuleGroup) |
| `tests/` | the whole validation harness (see `tests/README.md`) |
| `tests/reports/` | live deploy-validation history (06-12 → 06-16) |
