{{/*
VMRule group key helper - normalizes group name from filename
*/}}
{{- define "kubecore-observability-rules.vmrule.groupKey" -}}
{{- $name := .name | replace "_" "-" | replace "." "-" | lower }}
{{- $name = trimSuffix "-rules" $name }}
{{- $name = trimSuffix "-exporter" $name }}
{{- $name }}
{{- end }}

{{/*
VMRule group name helper
*/}}
{{- define "kubecore-observability-rules.vmrule.groupName" -}}
{{- $root := . }}
{{- if hasKey . "helm" }}
{{- $root = .helm }}
{{- end }}
{{- $groupKey := include "kubecore-observability-rules.vmrule.groupKey" . }}
{{- printf "%s-%s" (include "kubecore-observability-rules.fullname" $root) $groupKey | trunc 63 | trimSuffix "-" }}
{{- end }}

