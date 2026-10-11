{{/* Labels shared by every object. */}}
{{- define "e2e-canary.labels" -}}
app.kubernetes.io/name: kubecore-e2e-canary
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kubecore-e2e
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version }}
{{- end -}}

{{- define "e2e-canary.selector" -}}
app.kubernetes.io/name: kubecore-e2e-canary
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{/* readyAfter as unix seconds; 0 when empty (ready immediately). A non-RFC3339 value
     fails the render: a typo must never quietly mean "ready now". */}}
{{- define "e2e-canary.readyAfterEpoch" -}}
{{- if .Values.readyAfter -}}
{{- mustToDate "2006-01-02T15:04:05Z07:00" .Values.readyAfter | unixEpoch -}}
{{- else -}}
0
{{- end -}}
{{- end -}}

{{- define "e2e-canary.image" -}}
{{- if .Values.image.digest -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}@{{ .Values.image.digest }}
{{- else -}}
{{ .Values.image.repository }}:{{ .Values.image.tag }}
{{- end -}}
{{- end -}}
