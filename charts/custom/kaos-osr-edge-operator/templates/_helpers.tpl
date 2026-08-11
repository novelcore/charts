{{/*
Expand the name of the chart.
*/}}
{{- define "kaos-osr-edge-operator.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kaos-osr-edge-operator.fullname" -}}
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
Namespace for generated references.
Always uses the Helm release namespace.
*/}}
{{- define "kaos-osr-edge-operator.namespaceName" -}}
{{- .Release.Namespace }}
{{- end }}

{{/*
Resource name with proper truncation for Kubernetes 63-character limit.
Takes a dict with:
  - .suffix: Resource name suffix (e.g., "metrics", "webhook")
  - .context: Template context (root context with .Values, .Release, etc.)
Dynamically calculates safe truncation to ensure total name length <= 63 chars.
*/}}
{{- define "kaos-osr-edge-operator.resourceName" -}}
{{- $fullname := include "kaos-osr-edge-operator.fullname" .context }}
{{- $suffix := .suffix }}
{{- $maxLen := sub 62 (len $suffix) | int }}
{{- if gt (len $fullname) $maxLen }}
{{- printf "%s-%s" (trunc $maxLen $fullname | trimSuffix "-") $suffix | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" $fullname $suffix | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}

{{/*
Read API ServiceAccount name (PRD-3 CON-08 — never the manager's).
*/}}
{{- define "kaos-osr-edge-operator.readApiServiceAccountName" -}}
{{- include "kaos-osr-edge-operator.resourceName" (dict "suffix" "readapi" "context" .) }}
{{- end }}

{{/*
Aggregation label carried by every member of the kaos-crd-reader ClusterRole.

KAOS-specific by design. rbac.authorization.k8s.io/aggregate-to-view must NEVER
be used here: it merges our CR read surface into the cluster's built-in `view`
ClusterRole, handing it to every `view` holder on the cluster.
*/}}
{{- define "kaos-osr-edge-operator.crdReaderAggregationLabel" -}}
kaos.io/aggregate-to-crd-reader
{{- end }}

{{/*
Marker label carried by every ClusterRole THIS CHART SHIPS as part of the OSR
read surface, whether or not it feeds the crd-reader aggregate.

Read that scope carefully — it is not "every ClusterRole that contributes to
what OSR can read". Nothing forces a third party to use this label, and an
attacker will not: labelling a ClusterRole kaos.io/aggregate-to-crd-reader
alone is enough for kube-controller-manager to merge its rules into the role
both OSR ServiceAccounts hold, and such an object carries this marker nowhere.

Two labels exist because they answer two different questions:

  kaos.io/aggregate-to-crd-reader   "will kube-controller-manager merge this
                                     into the shared aggregate?" — the
                                     MECHANISM, and the one an attacker needs
  kaos.io/osr-read-surface          "did the OSR chart ship this as read
                                     surface?" — provenance, ours to set

They were one label until the built-in read surface (namespaces, pods,
pods/log, configmaps, …) was added for the read API. That surface must NOT
reach the operator's ServiceAccount: the operator holds the outbound cloud
credential and has egress, and ConfigMaps are precisely where clients paste
credentials (the premise of PRD-3 AC-20). Giving egress and ConfigMap read to
the same identity is a worse combination than giving either alone, and the
operator's code never reads them.

So the built-in member carries only this marker and is bound directly to the
read API's ServiceAccount, while the API-group members carry both and feed the
aggregate that both ServiceAccounts hold.

Enumerating the read surface therefore takes BOTH label queries, and the
Kyverno policy selects on both. Neither is sufficient alone: this marker misses
anything the chart did not create, and the aggregation label misses the
directly-bound built-in role. docs/security/osr-rbac-audit.md §3 leads with
that pair and shows the measured consequence of querying only one — a cluster
where both ServiceAccounts held cluster-wide Secret read while the marker query
returned 0.
*/}}
{{- define "kaos-osr-edge-operator.readSurfaceLabel" -}}
kaos.io/osr-read-surface
{{- end }}

{{/*
Validate one API group name destined for an aggregation member ClusterRole.
Takes a dict with .group (the value) and .source (the values key it came from,
for the error message). Renders nothing on success; aborts the render on failure.

The rule is: the group must be a dotted DNS subdomain — at least two labels.
That single constraint is what makes an aggregation member structurally
incapable of granting Secrets, and it is why the member rules can safely use a
`resources: ['*']` wildcard:

  - The core group, where Secrets live, is the EMPTY STRING. It has no dot, so
    it can never be expressed here.
  - "*" matches neither the character class nor the required dot, so a wildcard
    apiGroup — the exact rule this whole design replaces — cannot be smuggled
    in through extraReadGroups.
  - Every real Kubernetes API group other than core is a DNS domain
    (cert-manager.io, karpenter.sh, gateway.networking.k8s.io), so nothing an
    operator legitimately needs is rejected.

Failing at TEMPLATE time rather than admission time is deliberate: a bad value
must never reach a cluster, and `helm template` is runnable by a reviewer with
no cluster access at all.
*/}}
{{- define "kaos-osr-edge-operator.validateAPIGroup" -}}
{{- $g := .group -}}
{{- if not (kindIs "string" $g) -}}
{{- fail (printf "%s: entry %v is not a valid API group name — it must be a string" .source $g) -}}
{{- end -}}
{{- if not (regexMatch "^[a-z0-9]([-a-z0-9]*[a-z0-9])?(\\.[a-z0-9]([-a-z0-9]*[a-z0-9])?)+$" $g) -}}
{{- fail (printf "%s: %q is not a valid API group name for an OSR read-aggregation member. It must be a dotted DNS subdomain such as \"cert-manager.io\". The core API group (\"\"), bare resource names, and any form of \"*\" are rejected on purpose: a wildcard or core-group entry would grant read access to Secrets and break PRD-1 CON-03 / PRD-3 AC-19 (kubectl auth can-i --as=<osr-sa> get secrets -A must answer \"no\")." .source $g) -}}
{{- end -}}
{{- end }}

{{/*
ServiceAccount name to use.
If serviceAccount.enable is false and serviceAccount.name is set, use that name.
Otherwise, use the standard resourceName helper with "controller-manager" suffix.
*/}}
{{- define "kaos-osr-edge-operator.serviceAccountName" -}}
{{- if and (not (.Values.serviceAccount.enable | default true)) .Values.serviceAccount.name }}
{{- .Values.serviceAccount.name }}
{{- else }}
{{- include "kaos-osr-edge-operator.resourceName" (dict "suffix" "controller-manager" "context" .) }}
{{- end }}
{{- end }}
