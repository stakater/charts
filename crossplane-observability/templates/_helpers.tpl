{{/*
Expand the name of the chart.
*/}}
{{- define "crossplane-observability.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "crossplane-observability.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "crossplane-observability.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "crossplane-observability.labels" -}}
helm.sh/chart: {{ include "crossplane-observability.chart" . }}
{{ include "crossplane-observability.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "crossplane-observability.selectorLabels" -}}
app.kubernetes.io/name: {{ include "crossplane-observability.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Namespace the monitoring objects are created in. Must match the namespace
Crossplane runs in, so UWM can resolve the metrics endpoints.
*/}}
{{- define "crossplane-observability.namespace" -}}
{{- .Values.global.namespace | default .Release.Namespace }}
{{- end }}

{{/*
The `job` label provider metrics carry, used by every provider-scoped rule expression.

Unset means "the PodMonitor this chart ships", whose job label prometheus-operator
derives as `<namespace>/<podmonitor-name>` — so it is computed here rather than
restated in values, because a hand-written guess at that string is wrong in a way
nothing catches: the rules render fine and silently match no series.

Set `crossplane.providers.job` explicitly only when some OTHER scrape already covers
the provider pods (a platform PodMonitor, a differently-relabelled job); then this
chart's own `providerPodMonitor` should stay disabled.
*/}}
{{- define "crossplane-observability.providersJob" -}}
{{- if .Values.crossplane.providers.job -}}
{{- .Values.crossplane.providers.job -}}
{{- else -}}
{{- printf "%s/%s-providers" (include "crossplane-observability.namespace" .) (include "crossplane-observability.fullname" .) -}}
{{- end -}}
{{- end }}

{{/*
The Grafana instance every CR this chart ships selects.

Unset means the Stakater Cloud convention (`app: grafana`). It is resolved here
rather than defaulted in values because `instanceSelector` is a MAP, and Helm
deep-merges maps: a non-empty values default UNIONS with a per-cluster override
instead of being replaced. Overriding `{dashboards: crossplane}` against a
default of `{app: grafana}` yields BOTH keys, and `matchLabels` is an AND — so
the CR selects no Grafana at all and the dashboard silently stops being imported.

Nulling the default key (`app: null`) is not a usable workaround: the KubeStack
addon pipeline deep-merges a cluster's EnvironmentConfigs with RFC-7386 merge-patch
semantics, which CONSUMES the null and drops the key before Helm ever sees it —
so the default is resurrected. Keeping the default out of values is the only form
that survives both merges.
*/}}
{{- define "crossplane-observability.grafana.instanceSelector" -}}
{{- if .Values.grafana.instanceSelector -}}
{{- toYaml .Values.grafana.instanceSelector -}}
{{- else -}}
matchLabels:
  app: grafana
{{- end -}}
{{- end }}
