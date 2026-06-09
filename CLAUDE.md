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
- **Bump `version:` in `Chart.yaml`** whenever you change a chart. The push pipeline
  publishes by version; an unbumped version fails publish.
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

Metrics scraping and alerting. Reference: **`openbao-observability`** (the most modern,
best-documented chart — use it as the template), also `postgres-observability`,
`redis-observability`, `rabbitmq-observability`.

```
<thing>-observability/
├── .helmignore
├── Chart.yaml
├── README.md                   # full: prerequisites, config table, alert table, dashboard panels
├── values.yaml
├── (Tiltfile / Tiltfile-delete / values-local.yaml — optional; openbao has them, postgres/redis don't)
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
8. Render with `helm template . -f values-local.yaml` (or `helm template .`) and confirm it
   produces valid YAML before opening the PR.

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
