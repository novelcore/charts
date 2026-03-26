{{/*
Expand the name of the chart.
*/}}
{{- define "kubecore-ci-workflows.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kubecore-ci-workflows.fullname" -}}
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
{{- define "kubecore-ci-workflows.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kubecore-ci-workflows.labels" -}}
helm.sh/chart: {{ include "kubecore-ci-workflows.chart" . }}
{{ include "kubecore-ci-workflows.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kubecore
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kubecore-ci-workflows.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubecore-ci-workflows.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "kubecore-ci-workflows.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kubecore-ci-workflows.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the namespace name
*/}}
{{- define "kubecore-ci-workflows.namespace" -}}
{{- default .Release.Namespace .Values.workflow.namespace }}
{{- end }}
