{{/*
Allow the release namespace to be overridden
*/}}
{{- define "oadp-instance.namespace" -}}
{{- default .Release.Namespace .Values.namespaceOverride -}}
{{- end -}}
