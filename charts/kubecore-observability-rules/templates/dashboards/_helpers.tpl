{{/*
GrafanaDashboard name helper
*/}}
{{- define "kubecore-observability-rules.dashboard.name" -}}
{{- $root := . }}
{{- if hasKey . "helm" }}
{{- $root = .helm }}
{{- end }}
{{- printf "%s-%s" (include "kubecore-observability-rules.fullname" $root) (.name | replace "_" "" | replace "." "-") | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
GrafanaDashboard labels helper
*/}}
{{- define "kubecore-observability-rules.dashboard.labels" -}}
{{- $root := . }}
{{- if hasKey . "helm" }}
{{- $root = .helm }}
{{- end }}
{{- $labels := dict }}
{{- if $root }}
{{- $labels = merge $labels (include "kubecore-observability-rules.labels" $root | fromYaml) }}
{{- if hasKey $root.Values "defaultDashboards" }}
{{- if hasKey $root.Values.defaultDashboards "labels" }}
{{- $labels = merge $labels (deepCopy $root.Values.defaultDashboards.labels) }}
{{- end }}
{{- end }}
{{- end }}
{{- toYaml $labels }}
{{- end }}

