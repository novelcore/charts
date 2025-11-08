# KubeCore Operator Helm Chart - Critical Fixes Documentation

**Document Version:** 1.0
**Chart Versions Covered:** v0.1.5, v0.1.6
**Date:** November 8, 2025
**Author:** Platform Team

---

## Executive Summary

This document outlines the critical fixes implemented in the kubecore-operator Helm chart versions 0.1.5 and 0.1.6. These fixes resolved three major issues that prevented successful deployment:

1. **Missing Kubernetes ProviderConfig** (v0.1.5)
2. **Provider-kubernetes pod failure due to missing ServiceAccount** (v0.1.5)
3. **XRD YAML parsing errors** (v0.1.6)

All issues have been resolved and the chart is now fully functional with all 12 XRDs successfully installing.

---

## Version 0.1.5 - Critical Infrastructure Fixes

### Issue 1: Missing Kubernetes ProviderConfig

#### Problem Statement
The Helm chart was only creating the AWS ProviderConfig (`aws-default`) but not the Kubernetes ProviderConfig (`kubesys-enhanced`). This prevented the provider-kubernetes from functioning properly.

**Impact:** Medium-High
**Symptoms:**
- Only AWS ProviderConfig existed after installation
- Kubernetes provider could not manage cluster resources
- Manual ProviderConfig creation was required

#### Root Cause
The `templates/crossplane-providers/providerconfigs.yaml` file defined both ProviderConfigs but used Helm hooks with weight 20. The Kubernetes provider CRDs were installed asynchronously by the Crossplane package manager and weren't ready when the hooks executed, causing the Kubernetes ProviderConfig creation to fail silently.

#### Solution
**File Modified:** `templates/crossplane-providers/providerconfigs.yaml`

**Changes:**
1. **Removed Helm hooks** from both ProviderConfigs
2. Made ProviderConfigs regular resources instead of hook-based resources
3. Added explanatory comments about the timing issue

**Before:**
```yaml
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: kubesys-enhanced
  annotations:
    helm.sh/hook: post-install,post-upgrade
    helm.sh/hook-weight: "20"
spec:
  credentials:
    source: InjectedIdentity
```

**After:**
```yaml
# Note: Not using hooks because provider CRDs are installed asynchronously
# and may not be ready when hooks execute. Regular resources will be created
# after helm completes and will wait for CRDs to become available.
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: kubesys-enhanced
spec:
  credentials:
    source: InjectedIdentity
```

**Result:**
- Both Kubernetes and AWS ProviderConfigs now created successfully
- Resources wait naturally for CRDs to be available
- No manual intervention required

---

### Issue 2: Provider-kubernetes Pod Deployment Failure

#### Problem Statement
The provider-kubernetes pod was failing to deploy with the error:
```
Error creating: pods "provider-kubernetes-*" is forbidden:
error looking up service account kubecore-system/kubesys-admin:
serviceaccount "kubesys-admin" not found
```

**Impact:** Critical
**Symptoms:**
- provider-kubernetes pod in CrashLoopBackOff
- ReplicaSet showing failed pod creation events
- Kubernetes provider unable to start

#### Root Cause
The ServiceAccount `kubesys-admin` was only created in the `crossplane-system` namespace. However:
- **Provider pods run in the release namespace** (kubecore-system)
- **ServiceAccounts are namespace-scoped resources**
- The RuntimeConfig referenced the ServiceAccount but it didn't exist in the correct namespace

#### Solution
**File Modified:** `templates/crossplane-providers/runtime-config.yaml`

**Changes:**
1. Created `kubesys-admin` ServiceAccount in **both namespaces**:
   - kubecore-system (release namespace) - for provider pods
   - crossplane-system - for backward compatibility
2. Created separate ClusterRoleBindings for each namespace
3. Maintained the same cluster-admin permissions for both

**Implementation:**
```yaml
---
# ServiceAccount for KubeSystem operations (in release namespace for provider pods)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubesys-admin
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "chart.labels" . | nindent 4 }}
---
# ServiceAccount for KubeSystem operations (in crossplane namespace for legacy compatibility)
apiVersion: v1
kind: ServiceAccount
metadata:
  name: kubesys-admin
  namespace: {{ .Values.crossplane.namespace }}
  labels:
    {{- include "chart.labels" . | nindent 4 }}
---
# ClusterRoleBinding to cluster-admin for platform management (release namespace)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubesys-admin-{{ .Release.Namespace }}
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: kubesys-admin
  namespace: {{ .Release.Namespace }}
---
# ClusterRoleBinding to cluster-admin for platform management (crossplane namespace)
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubesys-admin-crossplane
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: cluster-admin
subjects:
- kind: ServiceAccount
  name: kubesys-admin
  namespace: {{ .Values.crossplane.namespace }}
```

**Result:**
- provider-kubernetes pod successfully starts and runs
- ServiceAccount available in both namespaces
- No permission issues during provider operation

---

### Hook Execution Order Update

As part of the v0.1.5 fixes, we also updated the Helm hook execution order for better dependency management:

**Updated Order:**
- **Weight 5:** RuntimeConfig (ServiceAccounts, DeploymentRuntimeConfig)
- **Weight 10:** Functions (Crossplane functions)
- **Weight 15:** Providers (Crossplane providers)

**Rationale:**
1. ServiceAccounts must exist before provider pods start
2. Functions should be available before providers initialize
3. Providers should be installed last to ensure dependencies are ready

---

## Version 0.1.6 - XRD Installation Fix

### Issue 3: XRD YAML Parsing Error

#### Problem Statement
When attempting to install XRDs (Composite Resource Definitions), Helm failed with a YAML parsing error:

```
Error: YAML parse error on kubecore-operator/templates/crossplane-xrds/xrds.yaml:
error converting YAML to JSON: yaml: line 120: did not find expected key
```

**Impact:** Critical
**Symptoms:**
- Helm template rendering failed
- Chart installation/upgrade blocked
- XRDs could not be installed via Helm chart
- Required manual XRD installation

#### Root Cause Analysis

The original implementation attempted to merge all 12 XRD definitions into a single `xrds.yaml` template file using a Python script. The merge process caused **document separator concatenation** without proper newline handling.

**Specific Issue at Line 120:**
```yaml
                  ready:
                    type: boolean
                    description: "Whether the ClusterSecretStore is ready"---
apiVersion: apiextensions.crossplane.io/v2
```

The YAML document separator `---` was concatenated directly to the end of the description string, creating invalid YAML syntax. This happened because:
1. Original XRD files already had `---` separators
2. Merge script added additional separators
3. Newline handling was inconsistent
4. Helm label/annotation injection corrupted the YAML structure

**Additional Problems:**
- Complex nested OpenAPI v3 schemas sensitive to indentation
- Difficult to debug a single 110KB file with 2000+ lines
- Hard to maintain and update individual XRDs
- Single point of failure for all XRDs

#### Solution: Separate Template Files Approach

**Strategy:** Split the single merged file into 12 separate template files, one per XRD.

**Files Created:** `templates/crossplane-xrds/`

1. `xrd-awsprovider.yaml` - XAWSProvider
2. `xrd-githubprovider.yaml` - XGitHubProvider
3. `xrd-awsnetwork.yaml` - XAwsNetwork
4. `xrd-eks.yaml` - XEKS
5. `xrd-kubesystem.yaml` - XKubeSystem
6. `xrd-githubproject.yaml` - XGitHubProject
7. `xrd-kubenv.yaml` - XKubEnv
8. `xrd-githubapp.yaml` - XGitHubApp
9. `xrd-k8sapp.yaml` - XK8sApp
10. `xrd-kubeapptemplate.yaml` - XKubeAppTemplate
11. `xrd-qualitygate-instance.yaml` - XQualityGate
12. `xrd-qualitygate-template.yaml` - XQualityGateTemplate

**File Removed:**
- `templates/crossplane-xrds/xrds.yaml` (problematic merged file)

#### Template Structure

Each XRD template follows this consistent structure:

```yaml
{{- if .Values.crossplaneXRDs.enabled }}
---
apiVersion: apiextensions.crossplane.io/v2
kind: CompositeResourceDefinition
metadata:
  name: <xrd-name>
  labels:
    {{- include "chart.labels" . | nindent 4 }}
spec:
  # XRD specification from original definition.yaml
  ...
{{- end }}
```

**Key Features:**
1. **Conditional rendering** with `{{- if .Values.crossplaneXRDs.enabled }}`
2. **Proper Helm labels** injected using template include
3. **Clean YAML structure** preserved from source files
4. **No document separator issues** - single document per file
5. **Easy to maintain** - each XRD can be updated independently

#### Automation Script

Created a bash script to generate templates from source XRD definitions:

```bash
#!/bin/bash
# Script: /tmp/create_xrd_templates.sh

create_xrd_template() {
    local source_file=$1
    local output_file=$2

    cat > "$output_file" << TEMPLATE
{{- if .Values.crossplaneXRDs.enabled }}
TEMPLATE

    # Add the original content with label injection
    awk '
    BEGIN { in_metadata=0; added_labels=0 }
    /^---$/ { next }  # Skip document separators
    /^apiVersion:/ { print "---"; print; next }
    /^metadata:/ { in_metadata=1; print; next }
    in_metadata && /^  name:/ {
        print
        if (!added_labels) {
            print "  labels:"
            print "    {{- include \"chart.labels\" . | nindent 4 }}"
            added_labels=1
        }
        in_metadata=0
        next
    }
    { print }
    ' "$source_file" >> "$output_file"

    echo "{{- end }}" >> "$output_file"
}
```

**Benefits:**
- Automated generation from canonical source files
- Consistent label injection
- Proper YAML structure preservation
- Repeatable process for future updates

#### Configuration Changes

**File:** `values.yaml`

**Before (v0.1.5):**
```yaml
crossplaneXRDs:
  # NOTE: XRD auto-installation temporarily disabled in v0.1.5 due to YAML parsing issue
  # Will be fixed in v0.1.6. XRDs must be installed manually for now if needed.
  enabled: false
```

**After (v0.1.6):**
```yaml
crossplaneXRDs:
  # Enable installation of Crossplane XRDs
  # Set to false if XRDs are already installed in your cluster
  enabled: true
```

**Changes:**
1. Enabled XRDs by default
2. Removed temporary YAML parsing issue note
3. Simplified documentation

**File:** `values-kaos-dev.yaml`

```yaml
# Enable Crossplane XRDs
crossplaneXRDs:
  enabled: true
```

#### Verification Results

After implementing the fix:

```bash
# Test chart rendering
$ helm template test . --set crossplaneXRDs.enabled=true | grep -c "kind: CompositeResourceDefinition"
12

# Verify all XRDs render correctly
$ helm template test . --set crossplaneXRDs.enabled=true | grep "kind: CompositeResourceDefinition" -A 2
kind: CompositeResourceDefinition
metadata:
  name: xawsnetworks.platform.kubecore.io
--
kind: CompositeResourceDefinition
metadata:
  name: xawsproviders.aws.provider.platform.kubecore.io
# ... (all 12 XRDs listed)
```

**Installation Verification:**

```bash
$ kubectl get xrd | grep -c "kubecore.io\|github.platform"
12

$ kubectl get xrd
NAME                                              ESTABLISHED   OFFERED   AGE
xawsnetworks.platform.kubecore.io                 True          True      7m17s
xawsproviders.aws.provider.platform.kubecore.io   True          True      7m17s
xeks.platform.kubecore.io                         True          True      7m17s
xgithubapps.github.platform.kubecore.io           True          True      7m17s
xgithubprojects.github.platform.kubecore.io       True          True      7m17s
xgithubproviders.github.platform.kubecore.io      True          True      7m17s
xk8sapp.k8s.platform.kubecore.io                  True          True      7m17s
xkubeapptemplates.platform.kubecore.io            True          True      7m16s
xkubenvs.platform.kubecore.io                     True          True      7m16s
xkubesystems.platform.kubecore.io                 True          True      7m16s
xqualitygates.platform.kubecore.io                True          True      7m16s
xqualitygatetemplates.platform.kubecore.io        True          True      7m16s
```

**Result:**
- All 12 XRDs successfully installed
- All XRDs reached "Established" status
- No YAML parsing errors
- Helm ownership correctly set with labels

---

## Complete XRD List

The following 12 XRDs are now successfully installed via the Helm chart:

| XRD | API Group | Purpose |
|-----|-----------|---------|
| **XAWSProvider** | aws.provider.platform.kubecore.io | AWS infrastructure provisioning (ECR, IAM, OIDC) |
| **XGitHubProvider** | github.platform.kubecore.io | GitHub provider configuration and integration |
| **XAwsNetwork** | platform.kubecore.io | VPC, subnets, NAT gateways, Route53 |
| **XEKS** | platform.kubecore.io | EKS cluster provisioning and management |
| **XKubeSystem** | platform.kubecore.io | Platform system components (ArgoCD, Crossplane, etc.) |
| **XGitHubProject** | github.platform.kubecore.io | Project repositories, teams, permissions |
| **XKubEnv** | platform.kubecore.io | Kubernetes environments (namespaces, quotas, node groups) |
| **XGitHubApp** | github.platform.kubecore.io | Application repositories, CI/CD, webhooks |
| **XK8sApp** | k8s.platform.kubecore.io | Application deployments, GitOps, ECR integration |
| **XKubeAppTemplate** | platform.kubecore.io | Application template definitions |
| **XQualityGate** | platform.kubecore.io | Quality gate instances (per-app webhooks) |
| **XQualityGateTemplate** | platform.kubecore.io | Quality gate templates (workflow templates) |

---

## Chart Version History

### v0.1.5 (November 8, 2025)

**Focus:** Infrastructure and provider fixes

**Changes:**
- ✅ Fixed kubesys-admin ServiceAccount creation in release namespace
- ✅ Added duplicate ServiceAccount in crossplane-system for compatibility
- ✅ Removed Helm hooks from ProviderConfigs
- ✅ Updated hook execution order (RuntimeConfig: 5, Functions: 10, Providers: 15)
- ❌ XRDs temporarily disabled due to YAML parsing issue

**Files Modified:**
- `Chart.yaml` - Version bump, changelog
- `templates/crossplane-providers/runtime-config.yaml` - ServiceAccount fixes
- `templates/crossplane-providers/providerconfigs.yaml` - Removed hooks
- `values.yaml` - Updated comments
- `values-kaos-dev.yaml` - Configuration updates

### v0.1.6 (November 8, 2025)

**Focus:** XRD installation fix

**Changes:**
- ✅ Fixed XRD YAML parsing issue
- ✅ Split XRDs into 12 separate template files
- ✅ Enabled XRDs by default
- ✅ Added all 12 XRD definitions to Helm chart

**Files Created:**
- 12 XRD template files in `templates/crossplane-xrds/`

**Files Removed:**
- `templates/crossplane-xrds/xrds.yaml` (problematic merged file)

**Files Modified:**
- `Chart.yaml` - Version bump to 0.1.6, updated changelog
- `values.yaml` - Enabled XRDs by default
- `values-kaos-dev.yaml` - Enabled XRDs

---

## Deployment Verification Checklist

After deploying the chart, verify the following:

### 1. Operator Components
```bash
# Operator pod running
kubectl get pods -n kubecore-system | grep kubecore-operator-controller-manager
# Expected: 1/1 Running

# All Crossplane components running
kubectl get pods -n kubecore-system
```

### 2. ServiceAccounts
```bash
# ServiceAccount in release namespace
kubectl get serviceaccount kubesys-admin -n kubecore-system
# Expected: kubesys-admin exists

# ServiceAccount in crossplane namespace
kubectl get serviceaccount kubesys-admin -n crossplane-system
# Expected: kubesys-admin exists
```

### 3. Providers
```bash
# All providers installed and healthy
kubectl get providers.pkg.crossplane.io -n crossplane-system
# Expected: provider-kubernetes, provider-helm, provider-github all True/True

# Provider pods running
kubectl get pods -n kubecore-system | grep provider
# Expected: All provider pods Running
```

### 4. ProviderConfigs
```bash
# Kubernetes ProviderConfig
kubectl get providerconfigs.kubernetes.crossplane.io kubesys-enhanced
# Expected: kubesys-enhanced exists

# AWS ProviderConfig
kubectl get providerconfigs.aws.upbound.io aws-default
# Expected: aws-default exists
```

### 5. XRDs
```bash
# All XRDs installed
kubectl get xrd | grep -c "kubecore.io\|github.platform"
# Expected: 12

# All XRDs established
kubectl get xrd | grep "kubecore.io\|github.platform"
# Expected: All show "True" in ESTABLISHED column
```

---

## Troubleshooting Guide

### Issue: Provider-kubernetes pod not starting

**Symptoms:**
- No provider-kubernetes pod in kubecore-system namespace
- Provider shows INSTALLED=True but HEALTHY=False

**Diagnosis:**
```bash
kubectl describe provider.pkg.crossplane.io provider-kubernetes -n crossplane-system
```

**Common Causes:**
1. **ServiceAccount missing:** Check if kubesys-admin exists in kubecore-system
2. **CRD ownership conflicts:** Old ProviderRevision may have ownership
3. **RuntimeConfig issues:** DeploymentRuntimeConfig may not reference correct SA

**Solutions:**
```bash
# Check ServiceAccount
kubectl get sa kubesys-admin -n kubecore-system

# Check for old ProviderRevisions
kubectl get providerrevision | grep provider-kubernetes

# Remove CRD ownership if needed
kubectl patch crd providerconfigs.kubernetes.crossplane.io --type=json \
  -p='[{"op": "remove", "path": "/metadata/ownerReferences"}]'

# Delete and let provider recreate
kubectl delete providerrevision <old-revision>
```

### Issue: ProviderConfig not created

**Symptoms:**
- ProviderConfig missing after installation
- Provider pods failing to find configuration

**Diagnosis:**
```bash
# Check if ProviderConfig is in Helm manifest
helm get manifest kubecore-operator -n kubecore-system | grep -A 10 "kind: ProviderConfig"

# Check provider CRD exists
kubectl get crd providerconfigs.kubernetes.crossplane.io
```

**Common Causes:**
1. **Provider CRDs not ready:** ProviderConfig created before CRDs installed
2. **Helm timing issues:** Resources applied in wrong order

**Solutions:**
```bash
# Wait for provider CRDs
kubectl wait --for condition=established crd/providerconfigs.kubernetes.crossplane.io --timeout=120s

# Manually create ProviderConfig if needed
kubectl apply -f - <<EOF
apiVersion: kubernetes.crossplane.io/v1alpha1
kind: ProviderConfig
metadata:
  name: kubesys-enhanced
spec:
  credentials:
    source: InjectedIdentity
EOF
```

### Issue: XRD not establishing

**Symptoms:**
- XRD shows ESTABLISHED=False
- Composite resources cannot be created

**Diagnosis:**
```bash
kubectl describe xrd <xrd-name>
kubectl get events --all-namespaces | grep <xrd-name>
```

**Common Causes:**
1. **YAML syntax errors:** Invalid OpenAPI schema
2. **API conflicts:** Another XRD with same group/kind
3. **Webhook issues:** Crossplane webhook not responding

**Solutions:**
```bash
# Validate XRD locally
helm template test . --set crossplaneXRDs.enabled=true | kubectl apply --dry-run=server -f -

# Check Crossplane webhook
kubectl get pods -n crossplane-system | grep crossplane

# Delete and recreate XRD
kubectl delete xrd <xrd-name>
kubectl apply -f templates/crossplane-xrds/xrd-<name>.yaml
```

---

## Best Practices

### 1. Installation Order

**Recommended sequence:**
1. Install chart with all components enabled
2. Wait for Crossplane to be ready
3. Wait for providers to install CRDs
4. ProviderConfigs will be created automatically
5. XRDs will be installed and established

### 2. Upgrade Strategy

**For upgrades:**
```bash
# Update Helm repository
helm repo update novelcore

# Verify new version
helm search repo novelcore/kubecore-operator --versions

# Upgrade with values file
helm upgrade kubecore-operator novelcore/kubecore-operator \
  --version <version> \
  --namespace kubecore-system \
  --values values-<environment>.yaml
```

### 3. Disabling Components

**If components are already installed:**

```yaml
# values.yaml overrides
crossplane:
  enabled: false  # If Crossplane already installed

crossplaneProviders:
  enabled: false  # If providers already installed

crossplaneFunctions:
  enabled: false  # If functions already installed

crossplaneXRDs:
  enabled: false  # If XRDs already installed
```

### 4. Custom Values

**Environment-specific configuration:**

```yaml
# values-production.yaml
controllerManager:
  container:
    env:
      EKS_CLUSTER_ID: "YOUR-32-CHAR-CLUSTER-ID"
      EKS_REGION: "us-east-1"

crossplaneProviders:
  providerConfigs:
    aws:
      secretRef:
        name: aws-secret-prod
        namespace: crossplane-system
```

---

## Testing Procedures

### Pre-Deployment Testing

```bash
# 1. Template rendering
helm template test . --values values-kaos-dev.yaml > /tmp/rendered.yaml

# 2. Verify all resources
grep -c "^kind:" /tmp/rendered.yaml

# 3. Check for YAML errors
kubectl apply --dry-run=server -f /tmp/rendered.yaml

# 4. Validate XRDs specifically
helm template test . --set crossplaneXRDs.enabled=true | \
  grep -A 100 "kind: CompositeResourceDefinition"
```

### Post-Deployment Testing

```bash
# 1. Wait for all pods
kubectl wait --for=condition=Ready pods --all -n kubecore-system --timeout=300s

# 2. Check provider health
kubectl get providers -n crossplane-system

# 3. Verify XRD establishment
kubectl get xrd

# 4. Test creating a composite resource
kubectl apply -f config/samples/
```

---

## Migration Guide

### From v0.1.4 to v0.1.5

**Before upgrading:**
1. Backup existing ProviderConfigs (will be recreated)
2. Note any custom provider configurations

**Upgrade command:**
```bash
helm upgrade kubecore-operator novelcore/kubecore-operator \
  --version 0.1.5 \
  --namespace kubecore-system \
  --values values-<env>.yaml
```

**Post-upgrade verification:**
- Check provider-kubernetes pod status
- Verify both ProviderConfigs exist
- Confirm ServiceAccounts in both namespaces

### From v0.1.5 to v0.1.6

**Before upgrading:**
1. XRDs will be installed for the first time
2. Ensure no manual XRDs conflict with chart XRDs

**Upgrade command:**
```bash
helm upgrade kubecore-operator novelcore/kubecore-operator \
  --version 0.1.6 \
  --namespace kubecore-system \
  --values values-<env>.yaml
```

**Post-upgrade verification:**
- Count XRDs: `kubectl get xrd | grep -c "kubecore.io"`
- Check establishment status: `kubectl get xrd`
- Verify no YAML parsing errors in Helm output

### Clean Installation (Recommended)

For the most reliable deployment, especially when upgrading from 0.1.4:

```bash
# 1. Uninstall old version (CRDs will be kept)
helm uninstall kubecore-operator -n kubecore-system

# 2. Clean up conflicting resources if needed
kubectl delete providerrevision --all

# 3. Fresh install
helm install kubecore-operator novelcore/kubecore-operator \
  --version 0.1.6 \
  --namespace kubecore-system \
  --create-namespace \
  --values values-<env>.yaml
```

---

## Known Issues and Limitations

### Issue: CRD Ownership Conflicts After Uninstall

**Description:** If you uninstall and reinstall the chart quickly, provider CRDs may retain ownership references from the old ProviderRevision.

**Workaround:**
```bash
# Remove CRD ownership before reinstalling
kubectl patch crd providerconfigs.kubernetes.crossplane.io --type=json \
  -p='[{"op": "remove", "path": "/metadata/ownerReferences"}]'
```

**Status:** Known limitation of Crossplane provider lifecycle

---

### Issue: XRDs Take Time to Establish

**Description:** XRDs may show ESTABLISHED=False for 10-30 seconds after installation.

**Expected Behavior:** This is normal - Crossplane webhook needs to validate and process the XRD schemas.

**Status:** Not an issue - normal behavior

---

## Architecture Diagrams

### Component Installation Flow

```
1. Helm Install
   ↓
2. Operator Deployment
   ↓
3. Crossplane Installation (dependency)
   ↓
4. External Secrets Operator (dependency)
   ↓
5. RuntimeConfig & ServiceAccounts (hook weight 5)
   ↓
6. Crossplane Functions (hook weight 10)
   ↓
7. Crossplane Providers (hook weight 15)
   ↓
   [Providers install CRDs asynchronously]
   ↓
8. ProviderConfigs (regular resources, wait for CRDs)
   ↓
9. XRDs (regular resources)
   ↓
10. System Ready
```

### Resource Relationships

```
┌─────────────────────────────────────────────┐
│           kubecore-operator                  │
│              (Helm Chart)                    │
└──────────────┬──────────────────────────────┘
               │
       ┌───────┴───────┐
       │               │
   Crossplane    External Secrets
       │               │
       ├───────────────┴─────────────┐
       │                             │
   Providers                   Functions
   ├── kubernetes                   │
   ├── helm                    ├── go-templating
   ├── github                  ├── patch-and-transform
   └── aws family              └── etc.
       │
       ├─ ProviderConfigs
       │  ├── kubesys-enhanced (kubernetes)
       │  └── aws-default (aws)
       │
       └─ CRDs (auto-installed)
          └─ XRDs (Helm templates)
             ├── XAWSProvider
             ├── XGitHubProvider
             ├── XEKS
             └── ... (12 total)
```

---

## References

### Chart Repository
- **GitHub:** https://github.com/novelcore/charts
- **Helm Repository:** https://novelcore.github.io/charts

### Source Code
- **Operator:** https://github.com/novelcore/kubecore-operator
- **Compositions:** `/compositions/apis/` directory

### Related Documentation
- Crossplane Providers: https://docs.crossplane.io/latest/concepts/providers/
- Helm Chart Hooks: https://helm.sh/docs/topics/charts_hooks/
- Kubernetes ServiceAccounts: https://kubernetes.io/docs/tasks/configure-pod-container/configure-service-account/
- Composite Resource Definitions: https://docs.crossplane.io/latest/concepts/composite-resource-definitions/

---

## Changelog Summary

### v0.1.6 (November 8, 2025)
- **Fixed:** XRD YAML parsing issue by splitting into separate template files
- **Added:** All 12 XRD definitions to Helm chart
- **Changed:** Enabled XRDs by default in values.yaml

### v0.1.5 (November 8, 2025)
- **Fixed:** kubesys-admin ServiceAccount creation in release namespace
- **Fixed:** Added duplicate ServiceAccount in crossplane-system for compatibility
- **Fixed:** Removed Helm hooks from ProviderConfigs
- **Changed:** Updated hook execution order
- **Added:** XRD template structure (disabled due to YAML issue)

---

## Contact and Support

For questions, issues, or contributions:

- **Email:** platform@novelcore.io
- **GitHub Issues:** https://github.com/novelcore/kubecore-operator/issues
- **Team:** Novelcore Platform Team

---

**Document End**
