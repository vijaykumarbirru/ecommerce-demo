{{/* Standard Kubernetes labels for a shop component. */}}
{{- define "ecommerce-common.labels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Values.image.tag | default .Values.global.imageTag | quote }}
app.kubernetes.io/part-of: ecommerce
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end }}

{{- define "ecommerce-common.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{- define "ecommerce-common.image" -}}
{{ .Values.image.repository }}:{{ .Values.image.tag | default .Values.global.imageTag }}
{{- end }}
