{{/*
Expand the name of the chart.
*/}}
{{- define "kubecore-observability-rules.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
*/}}
{{- define "kubecore-observability-rules.fullname" -}}
{{- if hasKey .Values "fullnameOverride" }}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name (default "" .Values.nameOverride) }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- else }}
{{- $name := default .Chart.Name (default "" .Values.nameOverride) }}
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
{{- define "kubecore-observability-rules.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kubecore-observability-rules.labels" -}}
helm.sh/chart: {{ include "kubecore-observability-rules.chart" . }}
{{ include "kubecore-observability-rules.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kubecore-observability-rules.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubecore-observability-rules.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
VMRule name helper
*/}}
{{- define "kubecore-observability-rules.vmrule.name" -}}
{{- printf "%s-%s" (include "kubecore-observability-rules.fullname" .) (.name | replace "_" "" | replace "." "-") | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
VMRule labels helper
*/}}
{{- define "kubecore-observability-rules.vmrule.labels" -}}
{{- $root := . }}
{{- if hasKey . "helm" }}
{{- $root = .helm }}
{{- end }}
{{- $labels := dict }}
{{- $labels = merge $labels (include "kubecore-observability-rules.labels" $root | fromYaml) }}
{{- if hasKey $root.Values "defaultRules" }}
{{- if hasKey $root.Values.defaultRules "labels" }}
{{- $labels = merge $labels (deepCopy $root.Values.defaultRules.labels) }}
{{- end }}
{{- end }}
{{- toYaml $labels }}
{{- end }}

{{/*
GrafanaDashboard name helper
*/}}
{{- define "kubecore-observability-rules.dashboard.name" -}}
{{- $root := . }}
{{- if hasKey . "helm" }}
{{- $root = .helm }}
{{- end }}
{{- $name := .name | replace "_" "" | replace "." "-" }}
{{- printf "%s-%s" (include "kubecore-observability-rules.fullname" $root) $name | trunc 63 | trimSuffix "-" }}
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
{{- if and $root (hasKey $root "Chart") }}
{{- $labels = merge $labels (include "kubecore-observability-rules.labels" $root | fromYaml) }}
{{- if hasKey $root.Values "defaultDashboards" }}
{{- if hasKey $root.Values.defaultDashboards "labels" }}
{{- $labels = merge $labels (deepCopy $root.Values.defaultDashboards.labels) }}
{{- end }}
{{- end }}
{{- end }}
{{- toYaml $labels }}
{{- end }}

{{/*
Cluster label helper
*/}}
{{- define "kubecore-observability-rules.clusterLabel" -}}
{{- .Values.defaultRules.clusterLabel | default .Values.global.clusterLabel | default "cluster" }}
{{- end }}

{{/*
Group labels helper (for PromQL expressions)
*/}}
{{- define "kubecore-observability-rules.groupLabels" -}}
{{- $clusterLabel := include "kubecore-observability-rules.clusterLabel" . }}
{{- $additionalLabels := .Values.defaultRules.additionalGroupByLabels | default list }}
{{- $allLabels := append $additionalLabels $clusterLabel }}
{{- join "," (uniq $allLabels) }}
{{- end }}

