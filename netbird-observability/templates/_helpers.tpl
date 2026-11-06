{{/*
Expand the name of the chart.
*/}}
{{- define "netbird-observability.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "netbird-observability.fullname" -}}
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
{{- define "netbird-observability.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "netbird-observability.labels" -}}
helm.sh/chart: {{ include "netbird-observability.chart" . }}
{{ include "netbird-observability.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "netbird-observability.selectorLabels" -}}
app.kubernetes.io/name: {{ include "netbird-observability.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Namespace the monitoring objects are created in. Must be the namespace the NetBird
instance runs in, so UWM can resolve the scrape targets. Defaults to the release namespace.
*/}}
{{- define "netbird-observability.namespace" -}}
{{- .Values.namespaceOverride | default .Release.Namespace }}
{{- end }}

{{/*
The Grafana instance every CR this chart ships selects.

Unset means the Stakater Cloud convention (`app: grafana`). It is resolved here rather
than defaulted in values because `instanceSelector` is a MAP, and Helm deep-merges maps:
a non-empty values default UNIONS with a per-cluster override instead of being replaced,
matchLabels is an AND, and the CR then selects no Grafana at all — the dashboard silently
stops being imported. Keeping the default out of values is the only form that survives
both Helm's and the addon pipeline's merges.
*/}}
{{- define "netbird-observability.grafana.instanceSelector" -}}
{{- if .Values.grafana.instanceSelector -}}
{{- toYaml .Values.grafana.instanceSelector -}}
{{- else -}}
matchLabels:
  app: grafana
{{- end -}}
{{- end }}

{{/*
Prometheus job labels of the three scrape targets. UWM/prometheus-operator set
job=<Service name>, and the chart names its metrics Services with these FIXED names so the
job label is identical across every instance in the fleet — rules and dashboard queries
must never depend on the release name. One NetBird instance per namespace is assumed.
*/}}
{{- define "netbird-observability.managementJob" -}}
{{- .Values.netbird.management.jobName }}
{{- end }}
{{- define "netbird-observability.signalJob" -}}
{{- .Values.netbird.signal.jobName }}
{{- end }}
{{- define "netbird-observability.relayJob" -}}
{{- .Values.netbird.relay.jobName }}
{{- end }}
