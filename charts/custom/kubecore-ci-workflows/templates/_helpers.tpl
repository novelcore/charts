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

{{/*
User-managed CI secrets (kaos PRD 695, spec section 6.2) for the service
build-push steps of ci-build and ci-rc-build.

The operator renders two ExternalSecrets in {project}-ci, where these
workflows run: {project}-ci-secrets (KubeProject.spec.ci.secretBindings) and
{project}-{app}-ci-secrets (KubeApp secretBindings.ci; the app secret is
namespaced by project to avoid colliding with the project secret when an app
is named like its project). Their keys are p_{name}_{KEY} / o_{name}_{KEY}.
Both are OPTIONAL: a project or app with no CI bindings has no such Secret,
the kubelet mounts an empty directory, and the build is exactly what it was
before.

The raw Secrets are mounted ONLY into the ci-secrets-prep init container. The
kaniko container sees the laid-out copy on a memory-backed emptyDir at
/kaniko/secrets, which kaniko never snapshots into a layer.
*/}}
{{- define "kubecore-ci-workflows.ciSecretsVolumes" -}}
- name: ci-secrets-project
  secret:
    secretName: "{{`{{workflow.parameters.project_name}}`}}-ci-secrets"
    optional: true
- name: ci-secrets-app
  secret:
    secretName: "{{`{{workflow.parameters.project_name}}`}}-{{`{{workflow.parameters.app_name}}`}}-ci-secrets"
    optional: true
- name: kaniko-secrets
  emptyDir:
    medium: Memory
    sizeLimit: 16Mi
{{- end }}

{{/*
ci-secrets-prep init container: lays out /kaniko/secrets and writes
/kaniko/.docker/config.json (platform push credential + user registries).
It replaces the docker-config block the kaniko container used to run inline;
see files/ci-secrets-prep.sh and tests/ci-secrets-prep/run.sh. Runs as root
so the files it writes carry the same ownership kaniko (root) had before.
*/}}
{{- define "kubecore-ci-workflows.ciSecretsPrepInitContainer" -}}
- name: ci-secrets-prep
  image: {{ .Values.ciSecretsPrep.image | default "mikefarah/yq:4.44.3" }}
  command: [sh, -c]
  securityContext:
    runAsUser: 0
    runAsGroup: 0
  env:
  - name: REGISTRY
    value: {{ .Values.registry.internalUrl | quote }}
  - name: REGISTRY_TYPE
    value: "{{`{{workflow.parameters.registry_type}}`}}"
  - name: IMAGE_REPO
    value: "{{`{{workflow.parameters.image_repo}}`}}"
  args:
  - |
{{ .Files.Get "files/ci-secrets-prep.sh" | indent 4 }}
  volumeMounts:
  - name: ci-secrets-project
    mountPath: /etc/ci-secrets/project
    readOnly: true
  - name: ci-secrets-app
    mountPath: /etc/ci-secrets/app
    readOnly: true
  - name: registry-auth
    mountPath: /etc/registry-auth
    readOnly: true
  - name: kaniko-secrets
    mountPath: /kaniko/secrets
  - name: kaniko-config
    mountPath: /kaniko/.docker
{{- end }}
