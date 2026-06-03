{{/*
Shared helpers. Per-service resources are named "<release>-<service>"; common
labels follow the Kubernetes recommended label set so the whole edition is
selectable as one app, and each service as a component.
*/}}

{{- define "mini-baas.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" -}}
{{- end -}}

{{- define "mini-baas.commonLabels" -}}
app.kubernetes.io/part-of: mini-baas
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ include "mini-baas.chart" . }}
mini-baas.io/edition: {{ .Values.edition | default "lean" | quote }}
{{- end -}}

{{/* selectorLabels: pass a dict {root, name} */}}
{{- define "mini-baas.selectorLabels" -}}
app.kubernetes.io/name: mini-baas
app.kubernetes.io/instance: {{ .root.Release.Name }}
app.kubernetes.io/component: {{ .name }}
{{- end -}}
