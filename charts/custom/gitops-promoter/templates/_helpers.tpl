{{/*
Expand the name of the chart.
*/}}
{{- define "gitops-promoter.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "gitops-promoter.fullname" -}}
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
{{- define "gitops-promoter.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "gitops-promoter.labels" -}}
helm.sh/chart: {{ include "gitops-promoter.chart" . }}
{{ include "gitops-promoter.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: promoter
{{- with .Values.commonLabels }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Selector labels
*/}}
{{- define "gitops-promoter.selectorLabels" -}}
app.kubernetes.io/name: {{ include "gitops-promoter.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Controller manager labels
*/}}
{{- define "gitops-promoter.controllerManagerLabels" -}}
{{ include "gitops-promoter.labels" . }}
app.kubernetes.io/component: manager
control-plane: controller-manager
{{- end }}

{{/*
Controller manager selector labels
*/}}
{{- define "gitops-promoter.controllerManagerSelectorLabels" -}}
control-plane: controller-manager
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "gitops-promoter.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (printf "%s-controller-manager" (include "gitops-promoter.fullname" .)) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the namespace name
*/}}
{{- define "gitops-promoter.namespace" -}}
{{- if .Values.namespace.name }}
{{- .Values.namespace.name }}
{{- else }}
{{- .Release.Namespace }}
{{- end }}
{{- end }}

{{/*
Create the controller manager deployment name
*/}}
{{- define "gitops-promoter.controllerManagerName" -}}
{{- printf "%s-controller-manager" (include "gitops-promoter.fullname" .) }}
{{- end }}

{{/*
Create the metrics service name
*/}}
{{- define "gitops-promoter.metricsServiceName" -}}
{{- if .Values.services.metrics.name }}
{{- printf "%s-%s" (include "gitops-promoter.fullname" .) .Values.services.metrics.name }}
{{- else }}
{{- printf "%s-controller-manager-metrics-service" (include "gitops-promoter.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Create the webhook receiver service name
*/}}
{{- define "gitops-promoter.webhookReceiverServiceName" -}}
{{- if .Values.services.webhookReceiver.name }}
{{- printf "%s-%s" (include "gitops-promoter.fullname" .) .Values.services.webhookReceiver.name }}
{{- else }}
{{- printf "%s-webhook-receiver" (include "gitops-promoter.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Create the controller configuration name
*/}}
{{- define "gitops-promoter.controllerConfigurationName" -}}
{{- if .Values.controllerConfiguration.name }}
{{- printf "%s-%s" (include "gitops-promoter.fullname" .) .Values.controllerConfiguration.name }}
{{- else }}
{{- printf "%s-controller-configuration" (include "gitops-promoter.fullname" .) }}
{{- end }}
{{- end }}

{{/*
Create image pull secrets
*/}}
{{- define "gitops-promoter.imagePullSecrets" -}}
{{- if .Values.global.imagePullSecrets }}
imagePullSecrets:
{{- range .Values.global.imagePullSecrets }}
  - name: {{ . }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Generate the controller manager image
*/}}
{{- define "gitops-promoter.controllerManagerImage" -}}
{{- printf "%s:%s" .Values.controllerManager.image.repository .Values.controllerManager.image.tag }}
{{- end }}

{{/*
Generate the kube-rbac-proxy image
*/}}
{{- define "gitops-promoter.kubeRbacProxyImage" -}}
{{- printf "%s:%s" .Values.kubeRbacProxy.image.repository .Values.kubeRbacProxy.image.tag }}
{{- end }}

{{/*
Common annotations
*/}}
{{- define "gitops-promoter.annotations" -}}
{{- with .Values.commonAnnotations }}
{{ toYaml . }}
{{- end }}
{{- end }}

{{/*
Create the ingress name
*/}}
{{- define "gitops-promoter.ingressName" -}}
{{- printf "%s-webhook-receiver" (include "gitops-promoter.fullname" .) }}
{{- end }}

{{/*
Create the ingress hostname
*/}}
{{- define "gitops-promoter.ingressHostname" -}}
{{- .Values.ingress.hostname }}
{{- end }}

{{/*
Create the TLS secret name
*/}}
{{- define "gitops-promoter.tlsSecretName" -}}
{{- if .Values.ingress.tls.secretName }}
{{- .Values.ingress.tls.secretName }}
{{- else }}
{{- .Values.ingress.hostname }}
{{- end }}
{{- end }}

{{/*
Validate required values
*/}}
{{- define "gitops-promoter.validateValues" -}}
{{- if not .Values.controllerManager.image.repository }}
{{- fail "controllerManager.image.repository is required" }}
{{- end }}
{{- if not .Values.controllerManager.image.tag }}
{{- fail "controllerManager.image.tag is required" }}
{{- end }}
{{- if not .Values.kubeRbacProxy.image.repository }}
{{- fail "kubeRbacProxy.image.repository is required" }}
{{- end }}
{{- if not .Values.kubeRbacProxy.image.tag }}
{{- fail "kubeRbacProxy.image.tag is required" }}
{{- end }}
{{- if and .Values.ingress.enabled (not .Values.ingress.hostname) }}
{{- fail "ingress.hostname is required when ingress is enabled" }}
{{- end }}
{{- end }}