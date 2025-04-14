{{/*
Allow the release namespace to be overridden
*/}}
{{- define "oadp-operator.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}
