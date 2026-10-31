# CLAUDE.md

Stakater Helm charts. Most charts here are **observability** charts: they ship Grafana
dashboards, Prometheus `ServiceMonitor`/`PodMonitor`, and `PrometheusRule` alerts for a
specific workload (`<thing>-observability`). The rest are operator/instance charts
(`*-operator`, `*-instance`, `minio`, `matomo`, etc.).

These charts target **OpenShift** with the **grafana-operator** (dashboards as
`GrafanaDashboard` CRs) and **user-workload monitoring (UWM)** (Prometheus CRs scraped by
the cluster Prometheus / `thanos-ruler-user-workload`).

## Repo rules (from README — enforced by CI)

- **One chart per PR.** Touching more than one chart fails the pipeline.
- **The published version does NOT come from `Chart.yaml`.** On merge, the pipeline takes the
  highest existing `<chart>-X.Y.Z` git tag, adds one bump, and `sed`s that number into
  `Chart.yaml` inside the runner before `helm package` / `helm push` (see
  `.github/workflows/next_version.yaml`, `.github/scripts/next_semver.sh` and `push.yaml`). The
  bump is the PR label (`major` / `minor` / `patch`), and **defaults to `patch` when the PR has
  none**. So the `version:` you commit is overwritten and never published, and nothing fails if
  it is "unbumped". Keep it roughly in step for readability, but do not rely on it:
  committing `0.0.3` over a latest tag of `0.0.1` publishes `0.0.2`.
- **The tag lookup is a substring match.** `next_semver.sh` runs an unanchored
  `git tag -l | grep "<chart>"`, so a chart whose name is contained in another chart's name also
  considers that chart's tags and may bump from the wrong chart's version. Today this affects
  `slo-observability` (it also sees the `childshift-slo-observability-*` tags). As of 2026-10-02
  `slo-observability` is at 0.0.14 and `childshift-slo-observability` at 0.0.9, so the larger one
  wins and nothing is mis-versioned yet; it goes wrong as soon as the child chart's highest tag
  passes the other's (for example a `minor` release of it to 0.1.0 would make
  `slo-observability` bump from 0.1.0). Check this before naming a new chart, and prefer fixing
  the script to anchor on `^<chart>-<semver>$`.
- **Before pinning a chart version anywhere** (an ArgoCD `targetRevision`, a downstream
  version pin, a values file), read the version that was actually published, not the one in
  `Chart.yaml`. The authoritative evidence is that the push succeeded: the
  `Pushed: ghcr.io/stakater/charts/<chart>:X.Y.Z` line in the push job's `helm push` step, the
  GitHub release / git tag `<chart>-X.Y.Z`, or
  `helm show chart oci://ghcr.io/stakater/charts/<chart> --version X.Y.Z`. The `NEXT_VERSION`
  shown in the push job's step environment (and the `Show version` step of the `next-version`
  job) is only the version it *intended* to publish, not proof that it did.
  Testing from a local checkout or `helm package` of the source hides this: it renders fine
  and the registry pull then fails with `not found`.
- Use the `minor` / `major` label deliberately when a change warrants it; an unlabelled PR is a
  patch.
- Merge PRs with **Rebase and Merge** — *not* Merge. Plain Merge breaks the push pipeline.
- CI only lints. It does **not** render/deploy — test locally before opening a PR.
- `CODEOWNERS`: everything is owned by `@stakater/stakater-admin`.

## Local testing

```bash
cd <chart-name>
helm dependency update          # only if Chart.yaml has dependencies
helm template . -f values-local.yaml   # fast render check
# or against a cluster:
helm install <release> . -n <namespace>
helm delete  <release> -n <namespace>
```

Charts with a `Tiltfile` support Tilt for live dev against the cluster in
`tilt-settings.json` (deploys into the `grafana-operator` namespace by default):

```bash
tilt up                       # install + watch
tilt down -f Tiltfile-delete  # teardown
```

`tilt-settings.json` (repo root) holds the shared `allow_k8s_contexts` and
`default_registry`. Tilt charts each carry `values-local.yaml` (often empty) as the
Tilt-only values overlay.

---

## Building a new observability chart — the method (docs → capture → tests → templates)

New charts follow a docs-first, test-gated method: why → stories → approval gate → plan →
red → green → verify → audit. Reference executions in this repo: **`kcp-observability`**
and **`crossplane-observability`** (roadmap + full offline test gate); `oadp-observability`
adds the component and kind-e2e layers. The archetypes further below describe the chart
*layout*; this section is the **order of work — never start by writing templates.**

### 1. Docs first — the why (`docs/roadmap.md`)

- Start from the vision/value prop: who is on-call for this workload, and what should page
  them? A story that doesn't ladder up to that gets questioned, not built.
- `docs/roadmap.md` is organized **by user story** (copy kcp's shape). Each story:
  *"As an SRE, I want X, because Y"* → **Metric(s) → SLI → SLO (SLA candidate or
  internal) → Alert → Dashboard panel**.
- Stories carry the lifecycle **📝 Draft → 👍 Approved → 🔨 In progress → ✅ Done**.
  Approval is a **human gate** — never build an unapproved story; killing a weak Draft is
  the method working, not a failure.
- Numeric targets are placeholders until 2–4 weeks of live baseline — say so in the doc.
- This repo is **public**: no internal ticket ids, customer names, internal repo names or
  paths, or cluster internals in docs or commit messages. Internal story maps and
  validation specifics live in a private repo; the chart keeps generic docs (oadp is the
  precedent).

### 2. Metric reality — capture before you believe

Draft the roadmap from upstream docs, then **capture live `/metrics` from a real cluster**
into `tests/fixtures/*.txt` (provenance + label shapes in `tests/fixtures/README.md` or
`tests/METRICS-CAPTURE.md`), regenerate `tests/metrics-allowlist.captured.txt` with
`tests/generate-allowlist.sh`, and **revise the roadmap against the capture**. Every
metric a rule or panel uses is tagged:

- **[captured]** — in the fixtures, exact labels verified;
- **[documented]** / **[ksm]** — absent from fixtures by nature (kube-state-metrics,
  lazily-registered counters): allowlisted in `tests/metrics-allowlist.documented.txt`
  **with a citation**;
- **[absent]** — looked for and not there on this version: defer the story or rebuild it
  on a captured signal. **Never faked.**

### 3. Tests — the chart's pyramid (`tests/`)

Build behind `tests/validate.sh` (copy kcp's; every layer fails the script):

1. `helm lint` + `helm template` (defaults AND everything-enabled);
2. `promtool check rules` on the rendered rules — PromQL parses;
3. `promtool test rules tests/unit/rules.test.yaml` — **unit tests: every alert fires and
   resolves on synthetic series**. Write the test first (red → green);
4. metric-reality gate (`tests/check_metrics.py`) — every metric referenced by a rule or
   panel is captured or documented-with-citation; recording-rule refs resolve;
5. dashboard JSON — valid, unique panel ids, every panel query parses;
6. `kubeconform -strict` against the CRD schemas vendored in `tests/schemas/`.

Then, where the chart warrants it:

- **component** (`tests/component/`) — when the chart ships a workload of its own
  (oadp's state exporter);
- **e2e** (`tests/e2e/`) — kind + kube-prometheus + the real workload; scenarios drive
  **every alert to fire and resolve** (oadp is the reference);
- **deploy validation** — before release, validate read-only against a real cluster and
  commit a dated report to `tests/reports/validation-<cluster>-<date>.md`
  (procedure in `tests/DEPLOY-VALIDATION.md`).

### 4. Only then: templates

Bootstrap the layout (archetypes below) and build **one approved story at a time**, each
alert and panel tracing back to its story in the roadmap.

---

## Bootstrapping a new observability chart

Pick the archetype that matches what you're shipping. **When in doubt, copy the closest
existing chart and adapt it** rather than writing from scratch — every chart shares the
same `_helpers.tpl` and naming conventions.

### Archetype A — dashboard-only (most common)

Just a Grafana dashboard, no metrics/alerts. Reference: **`haproxy-observability`**,
`falco-observability`, `tekton-observability`.

```
<thing>-observability/
├── .gitkeep
├── .helmignore                 # standard Helm boilerplate (copy verbatim)
├── Chart.yaml                  # type: application, version 0.0.1, appVersion "0.0.1"
├── README.md                   # deps + tilt up / tilt down
├── Tiltfile                    # name=<chart>, namespace=grafana-operator
├── Tiltfile-delete             # one line: include('Tiltfile')
├── values.yaml                 # nameOverride/fullnameOverride/namespaceOverride + grafana.*
├── values-local.yaml           # Tilt overlay (usually empty)
└── templates/
    ├── _helpers.tpl            # standard helpers, names prefixed with chart name
    └── grafana/dashboards/
        ├── dashboard-definition-configmap.yaml   # ConfigMap holding the dashboard JSON
        └── <thing>-dashboard.yaml                # GrafanaDashboard CR -> configMapRef
```

### Archetype B — full observability (dashboard + monitors + rules)

Metrics scraping and alerting. References: **`kcp-observability`** / **`crossplane-observability`**
(full method: `docs/roadmap.md` + `tests/` gate — the standard for new charts),
**`openbao-observability`** (cleanest minimal template structure), also
`postgres-observability`, `redis-observability`, `rabbitmq-observability`.

```
<thing>-observability/
├── .helmignore
├── Chart.yaml
├── README.md                   # full: prerequisites, config table, alert table, dashboard panels
├── values.yaml
├── (Tiltfile / Tiltfile-delete / values-local.yaml — optional; openbao has them, postgres/redis don't)
├── docs/
│   └── roadmap.md                      # the stories/why (method §1) + any guides, values examples
├── tests/                              # validate.sh, unit/, fixtures/, allowlists, schemas/ (method §2–3)
├── files/                              # optional: large dashboard JSON loaded via .Files.Get
│   └── <thing>_grafana_dashboard.json
└── templates/
    ├── _helpers.tpl
    ├── grafana/
    │   └── <thing>-dashboard.yaml      # GrafanaDashboard CR
    └── prometheus/
        ├── monitors/
        │   └── <thing>-servicemonitor.yaml   # ServiceMonitor (or PodMonitor)
        └── rules/<thing>/
            └── <alert>.yaml            # ONE PrometheusRule per file, one alert per file
```

### Steps

These are the layout mechanics only — the order of work (roadmap → capture → tests →
templates, with the approval gate) is the method section above.

1. **Copy the closest reference chart** to `<thing>-observability/`.
2. **Rename the helper namespace** in `templates/_helpers.tpl`: every `define` is prefixed
   with the chart name (`<thing>-observability.name`, `.fullname`, `.chart`, `.namespace`,
   `.labels`, `.selectorLabels`). Find/replace the old chart name → new one across the whole
   chart directory (templates reference these helpers by name).
3. **`Chart.yaml`**: set `name`, `description`; start `version: 0.0.1`, `appVersion: "0.0.1"`,
   `type: application`.
4. **`values.yaml`**: keep `nameOverride`/`fullnameOverride`/`namespaceOverride` and the
   `grafana:` block (see conventions below). For archetype B add `prometheus.monitors.*`
   and `prometheus.rules.*` toggles.
5. **Dashboard**: see "Dashboard conventions" below for the two embedding styles.
6. **Rules** (B): one alert per file under `templates/prometheus/rules/<thing>/`, each gated
   by its own `enabled` value (see "Alert conventions").
7. **`README.md`**: dashboard-only charts get a short one (deps + tilt). Full charts get the
   openbao-style README: prerequisites, a config table, an alert table, and a panel-by-panel
   dashboard table.
8. **Gate before the PR**: `./tests/validate.sh` green (archetype B — all six layers), or at
   minimum `helm template . -f values-local.yaml` producing valid YAML (archetype A).

---

## Conventions

### Naming & helpers

`_helpers.tpl` is identical across charts except for the chart-name prefix in each
`define`. Templates use `{{ include "<thing>-observability.namespace" . }}`,
`{{ include "<thing>-observability.labels" . | nindent 4 }}`, etc. Don't invent new helper
names — reuse the standard set.

`.namespace` resolves to `.Values.namespaceOverride | default .Release.Namespace`
(dashboard-only charts) or `.Values.global.namespace | default .Release.Namespace`
(openbao). The monitoring objects must land in the **workload's** namespace so UWM can
resolve the scrape targets and any TLS secrets.

### `grafana:` values block (every chart)

```yaml
grafana:
  folder: "<Thing> Observability"        # Grafana folder the dashboard lands in
  allowCrossNamespaceImport: true        # let a Grafana in another ns import it
  instanceSelector:
    matchLabels:
      app: "grafana"                     # SAAP convention; override per-cluster if labelled differently
  datasources:
    - inputName: "DS_PROMETHEUS"
      datasourceName: Prometheus
```

### Dashboard conventions

The dashboard is always a `grafana.integreatly.org/v1beta1` `GrafanaDashboard` CR with
labels `grafana_dashboard: "true"` and `grafanaDashboard: grafana-operator`, plus
`folder` / `allowCrossNamespaceImport` / `instanceSelector` / `datasources` from values.
Two ways to supply the JSON — pick one:

- **Inline ConfigMap (archetype A):** a `ConfigMap` (`dashboard-definition-configmap.yaml`)
  holds the JSON under `data.json`, and the CR references it via
  `spec.configMapRef: { name: <name>-definition, key: json }`.
- **`files/` + `.Files.Get` (archetype B / large dashboards):** put the JSON in
  `files/<thing>_grafana_dashboard.json` and inline it with
  `json: |-{{ .Files.Get "files/..." | indent 4 }}`. Gate on `grafana.dashboard.enabled`.

**Grafana template variables in the JSON must be escaped** so Helm doesn't try to render
them: write `{{` `}}` around them, e.g.
`"legendFormat": "Route: {{`` {{ route }} ``}}"`. Copy the escaping pattern from an existing
dashboard JSON.

### Monitor conventions (archetype B)

`ServiceMonitor`/`PodMonitor` are `monitoring.coreos.com/v1`. Wrap the whole template in
`{{- if and (.Values.prometheus.monitors.serviceMonitor) (.Values.prometheus.monitors.serviceMonitor.enabled) }}`
and **default `enabled: false`** so installing the chart doesn't start scraping until the
operator opts in. Name via the `.fullname` helper; carry the standard `.labels`.

### Alert conventions (archetype B)

- **One `PrometheusRule` per file**, one alert per file, under
  `templates/prometheus/rules/<thing>/<alert>.yaml`.
- Each file is gated by its own value:
  `{{- if and (.Values.prometheus.rules.<thing>.<alert>) (.Values.prometheus.rules.<thing>.<alert>.enabled) }}`,
  and reads `for` / `severity` / thresholds from that value block.
- Metadata labels: `role: alert-rules`, the standard `.labels` helper, then merge in
  `.Values.prometheus.rules.labels` (for Alertmanager routing / `ruleSelector` matching).
- Escape Prometheus/Go templating in annotations the same way as dashboards:
  `summary: "... {{`` {{ $labels.pod }} ``}} ..."`.
- `values.yaml` exposes a per-alert block (`enabled`, `for`/`window`, `severity`,
  thresholds) under `prometheus.rules.<thing>.<alert>` — see `openbao-observability/values.yaml`.
