{{/* vim: set filetype=mustache: */}}
{{/*
Expand the name of the chart.
*/}}
{{- define "tenant-operator.name" -}}
{{- default .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "tenant-operator.fullname" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "tenant-operator.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{/*
Common labels
*/}}
{{- define "tenant-operator.labels" -}}
helm.sh/chart: {{ include "tenant-operator.chart" . }}
{{ include "tenant-operator.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end -}}

{{/*
Selector labels
*/}}
{{- define "tenant-operator.selectorLabels" -}}
app.kubernetes.io/name: {{ include "tenant-operator.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/*
Create the name of the service account to use
*/}}
{{- define "tenant-operator.serviceAccountName" -}}
    {{ default (include "tenant-operator.fullname" .) .Values.operator.serviceAccount.name }}
{{- end -}}

{{- define "db.host" -}}
{{- include "tenant-operator.fullname" . }}{{- print "-postgresql" "." .Release.Namespace ".svc." .Values.postgresql.clusterDomain }}
{{- end -}}

{{- define "db.dialect" -}}
{{- if .Values.postgresql.enabled }}
{{- print "postgres" -}}
{{- else }}
{{- .Values.server.db.dialect }}
{{- end }}
{{- end -}}

{{- define "db.dsn" -}}
{{- if .Values.postgresql.enabled }}
{{- printf "host=%s user=%s password=%s dbname=%s port=%g sslmode=disable TimeZone=%s" (include "db.host" .) .Values.postgresql.auth.username .Values.postgresql.auth.password .Values.postgresql.auth.database .Values.postgresql.primary.service.ports.postgresql .Values.postgresql.timeZone }}
{{- else }}
{{- .Values.server.db.dsn }}
{{- end }}
{{- end -}}
