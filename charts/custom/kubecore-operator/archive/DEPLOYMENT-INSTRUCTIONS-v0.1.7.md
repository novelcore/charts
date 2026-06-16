# KubeCore Operator v0.1.7 Deployment Instructions

**Date**: 2025-11-08
**Target Cluster**: kaos-dev-eks
**Chart Version**: 0.1.7
**Deployment Strategy**: Clean install with proper namespace separation

---

## Overview

This document provides step-by-step instructions for deploying kubecore-operator v0.1.7 with proper namespace separation. The deployment follows Option 1 approach:

1. Install Crossplane separately in `crossplane-system` namespace
2. Install External Secrets Operator separately in `external-secrets-system` namespace
3. Install kubecore-operator in `kubecore-system` namespace with subcharts disabled

---

## What's Fixed in v0.1.7

### Critical Fixes

1. **RBAC Permissions for Secrets** (CRITICAL)
   - Added cluster-wide read permissions for secrets (get, list, watch)
   - Fixes operator inability to access GitHub credentials
   - Resolves controller-runtime cache errors

2. **Namespace Configuration** (Architecture Improvement)
   - Documented Helm subchart namespace inheritance limitation
   - Provides proper installation strategy for namespace separation
   - Crossplane → `crossplane-system`
   - External Secrets → `external-secrets-system`
   - Operator → `kubecore-system`

---

## Prerequisites

- kubectl access to kaos-dev-eks cluster
- Helm 3.x installed
- Helm repositories configured:
  ```bash
  helm repo add crossplane-stable https://charts.crossplane.io/stable
  helm repo add external-secrets https://charts.external-secrets.io
  helm repo update
  ```

---

## Phase 1: Complete Cleanup of v0.1.6

### Step 1: Uninstall Existing Helm Release

```bash
# Uninstall the kubecore-operator release
helm uninstall kubecore-operator -n kubecore-system

# Wait for pods to terminate
kubectl wait --for=delete pod -l app.kubernetes.io/name=kubecore-operator -n kubecore-system --timeout=60s
```

**Expected Output**: Release uninstalled successfully

### Step 2: Delete All Crossplane Providers (from kubecore-system)

```bash
# Delete all providers
kubectl delete providers.pkg.crossplane.io --all --wait=false

# Remove finalizers if stuck
for provider in $(kubectl get providers.pkg.crossplane.io -o name); do
    kubectl patch $provider -p '{"metadata":{"finalizers":[]}}' --type=merge
done

# Verify deletion
kubectl get providers.pkg.crossplane.io
```

**Expected Output**: No resources found

### Step 3: Delete All Crossplane Functions

```bash
# Delete all functions
kubectl delete functions.pkg.crossplane.io --all --wait=false

# Remove finalizers if stuck
for func in $(kubectl get functions.pkg.crossplane.io -o name); do
    kubectl patch $func -p '{"metadata":{"finalizers":[]}}' --type=merge
done

# Verify deletion
kubectl get functions.pkg.crossplane.io
```

**Expected Output**: No resources found

### Step 4: Delete Crossplane ProviderConfigs

```bash
# List all ProviderConfigs
kubectl get providerconfigs --all-namespaces

# Delete Kubernetes ProviderConfig
kubectl delete providerconfig.kubernetes.crossplane.io kubesys-enhanced --ignore-not-found

# Delete AWS ProviderConfigs
kubectl delete providerconfig.aws.upbound.io aws-default --ignore-not-found

# Delete GitHub ProviderConfig (if exists)
kubectl delete providerconfig.github.upjet.crossplane.io --all --ignore-not-found
```

**Expected Output**: ProviderConfigs deleted

### Step 5: Delete Crossplane Core

```bash
# Delete Crossplane deployment and related resources
kubectl delete deployment crossplane -n kubecore-system --ignore-not-found
kubectl delete deployment crossplane-rbac-manager -n kubecore-system --ignore-not-found

# Delete Crossplane ClusterRoles and ClusterRoleBindings
kubectl delete clusterrole -l app=crossplane
kubectl delete clusterrolebinding -l app=crossplane

# Delete Crossplane ServiceAccounts
kubectl delete sa -n kubecore-system -l app=crossplane
```

### Step 6: Delete External Secrets Operator

```bash
# Delete ESO deployment
kubectl delete deployment external-secrets -n kubecore-system --ignore-not-found
kubectl delete deployment external-secrets-webhook -n kubecore-system --ignore-not-found
kubectl delete deployment external-secrets-cert-controller -n kubecore-system --ignore-not-found

# Delete ESO ClusterRoles and ClusterRoleBindings
kubectl delete clusterrole -l app.kubernetes.io/name=external-secrets
kubectl delete clusterrolebinding -l app.kubernetes.io/name=external-secrets
```

### Step 7: Delete All KubeCore CRDs

```bash
# Delete KubeCore operator CRDs
kubectl delete crd kubeorgs.schema.kubecore.io --ignore-not-found
kubectl delete crd kubepools.schema.kubecore.io --ignore-not-found
kubectl delete crd kubeprojects.schema.kubecore.io --ignore-not-found
kubectl delete crd kubeapps.kubecore.io --ignore-not-found

# Delete Crossplane XRDs
kubectl delete xrd --all

# Delete Crossplane CRDs
kubectl delete crd -l app=crossplane
```

**Expected Output**: CRDs deleted successfully

### Step 8: Delete Crossplane Compositions

```bash
# Delete all compositions
kubectl delete compositions.apiextensions.crossplane.io --all

# Remove finalizers if stuck
for comp in $(kubectl get compositions.apiextensions.crossplane.io -o name); do
    kubectl patch $comp -p '{"metadata":{"finalizers":[]}}' --type=merge
done
```

### Step 9: Clean Up Namespaces

```bash
# Delete crossplane-system namespace if it exists and is empty
kubectl delete namespace crossplane-system --ignore-not-found

# Delete external-secrets-system namespace if it exists
kubectl delete namespace external-secrets-system --ignore-not-found

# Verify kubecore-system namespace is clean
kubectl get all -n kubecore-system
```

**Expected Output**: Only namespace and default ServiceAccount remain

### Step 10: Verify Complete Cleanup

```bash
# Verify no Crossplane resources remain
kubectl get providers,functions,providerconfigs --all-namespaces
kubectl get compositions,xrd --all-namespaces
kubectl api-resources | grep crossplane

# Verify no External Secrets resources
kubectl get externalsecrets,secretstores --all-namespaces

# Verify no KubeCore CRs
kubectl get kubeorgs,kubepools,kubeprojects,kubeapps --all-namespaces
```

**Expected Output**: No resources found for all commands

---

## Phase 2: Fresh Installation with Proper Namespace Separation

### Step 1: Install Crossplane in crossplane-system Namespace

```bash
# Create namespace
kubectl create namespace crossplane-system

# Install Crossplane
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --version 2.1.0 \
  --wait

# Verify installation
kubectl get pods -n crossplane-system
kubectl get deployments -n crossplane-system
```

**Expected Output**:
```
NAME                                READY   STATUS    RESTARTS   AGE
crossplane-xxxxxxxxxx-xxxxx         1/1     Running   0          30s
crossplane-rbac-manager-xxxxx-xxx   1/1     Running   0          30s
```

**Wait**: Ensure both pods are Running before proceeding

### Step 2: Install External Secrets Operator

```bash
# Create namespace
kubectl create namespace external-secrets-system

# Install External Secrets Operator
helm install external-secrets external-secrets/external-secrets \
  --namespace external-secrets-system \
  --version 1.0.0 \
  --wait

# Verify installation
kubectl get pods -n external-secrets-system
kubectl get deployments -n external-secrets-system
```

**Expected Output**:
```
NAME                                        READY   STATUS    RESTARTS   AGE
external-secrets-xxxxxxxxxx-xxxxx           1/1     Running   0          30s
external-secrets-webhook-xxxxxx-xxxxx       1/1     Running   0          30s
external-secrets-cert-controller-xxxx-xxx   1/1     Running   0          30s
```

**Wait**: Ensure all pods are Running before proceeding

### Step 3: Verify Chart v0.1.7 is Available

```bash
# Check local chart directory
ls -la /Users/abstractversion/Documents/projects/kubecore/v3/kubecore-operator/.bin/charts/charts/custom/kubecore-operator/

# Verify Chart.yaml version
cat /Users/abstractversion/Documents/projects/kubecore/v3/kubecore-operator/.bin/charts/charts/custom/kubecore-operator/Chart.yaml | grep version

# Verify values-kaos-dev.yaml has subcharts disabled
cat /Users/abstractversion/Documents/projects/kubecore/v3/kubecore-operator/.bin/charts/charts/custom/kubecore-operator/values-kaos-dev.yaml | grep -A 2 "crossplane:" | head -5
```

**Expected Output**:
- Chart version: `0.1.7`
- `crossplane.enabled: false`
- `externalSecrets.enabled: false`

---

## Phase 3: Install KubeCore Operator v0.1.7

**STOP HERE**: Wait for user instructions on how to proceed with installation.

The following commands are prepared but should NOT be executed until user provides guidance:

```bash
# Example installation command (DO NOT RUN YET):
# helm install kubecore-operator \
#   /Users/abstractversion/Documents/projects/kubecore/v3/kubecore-operator/.bin/charts/charts/custom/kubecore-operator \
#   --namespace kubecore-system \
#   --create-namespace \
#   -f /Users/abstractversion/Documents/projects/kubecore/v3/kubecore-operator/.bin/charts/charts/custom/kubecore-operator/values-kaos-dev.yaml \
#   --wait
```

---

## Verification Checklist (After Installation)

### Namespace Verification

```bash
# Crossplane in crossplane-system
kubectl get pods -n crossplane-system | grep crossplane

# External Secrets in external-secrets-system
kubectl get pods -n external-secrets-system | grep external-secrets

# Operator in kubecore-system
kubectl get pods -n kubecore-system | grep kubecore-operator
```

### RBAC Verification

```bash
# Verify secrets permissions in ClusterRole
kubectl get clusterrole kubecore-operator-manager-role -o yaml | grep -A 5 secrets
```

**Expected Output**: Should show secrets with verbs: get, list, watch

### Operator Logs Verification

```bash
# Check operator logs for RBAC errors (should be none)
kubectl logs -n kubecore-system deployment/kubecore-operator-controller-manager --tail=50 | grep -i "forbidden\|rbac\|secret"
```

**Expected Output**: No RBAC errors related to secrets

### Crossplane Providers Installation

```bash
# The operator chart will install Crossplane providers via templates
# Wait for them to become healthy
kubectl get providers.pkg.crossplane.io

# Wait for all providers to show INSTALLED=True and HEALTHY=True
kubectl wait --for=condition=Healthy providers.pkg.crossplane.io --all --timeout=10m
```

### ProviderConfigs Verification

```bash
# Check Kubernetes ProviderConfig
kubectl get providerconfig.kubernetes.crossplane.io kubesys-enhanced -o yaml

# Check AWS ProviderConfig
kubectl get providerconfig.aws.upbound.io aws-default -o yaml
```

### XRDs Verification

```bash
# Verify all 12 XRDs are installed
kubectl get xrd

# Should show:
# - xawsnetworks.platform.kubecore.io
# - xawsproviders.aws.provider.platform.kubecore.io
# - xeks.platform.kubecore.io
# - xgithubapps.github.platform.kubecore.io
# - xgithubproviders.github.platform.kubecore.io
# - xgithubprojects.github.platform.kubecore.io
# - xk8sapps.k8s.platform.kubecore.io
# - xkubeapptemplates.platform.kubecore.io
# - xkubenvs.platform.kubecore.io
# - xkubesystems.platform.kubecore.io
# - xqualitygates.platform.kubecore.io
# - xqualitygatetemplates.platform.kubecore.io
```

---

## Testing the Operator

### Apply Test KubeOrg CR

```bash
# Create test KubeOrg
kubectl apply -f - <<EOF
apiVersion: schema.kubecore.io/v1beta1
kind: KubeOrg
metadata:
  name: novelcore
spec:
  awsConfig:
    accountId: "390844776145"
    primaryRegion: eu-central-1
    providerConfig: aws-default
    regions:
    - eu-central-1
    tags:
      CostCenter: engineering
      Environment: production
      ManagedBy: kubecore-operator
      Organization: novelcore
  githubConfig:
    credentialsSecretRef:
      name: novelcore-github-credentials
  network:
    dns:
      domain: v4.kubecore.eu
      enabled: true
    enabled: true
    multizone: true
EOF
```

### Monitor Reconciliation

```bash
# Watch KubeOrg status
kubectl get kubeorg novelcore -w

# Check events (should now have events!)
kubectl get events --field-selector involvedObject.name=novelcore --sort-by='.lastTimestamp'

# Check phase progression
kubectl get kubeorg novelcore -o jsonpath='{.status.phase}'

# Expected phases: Reconciling → Syncing → Reporting → Ready
```

### Verify Child Resources Created

```bash
# Check EnvironmentConfig
kubectl get environmentconfig novelcore-aws-config

# Check XAWSProvider
kubectl get xawsprovider novelcore-aws-provider

# Check XGithubProvider (if GitHub config provided)
kubectl get xgithubprovider novelcore-github-provider

# Check XAwsNetwork
kubectl get xawsnetwork
```

---

## Troubleshooting

### Operator Pod Not Starting

```bash
# Check pod status
kubectl get pods -n kubecore-system

# Check pod logs
kubectl logs -n kubecore-system deployment/kubecore-operator-controller-manager

# Check pod describe for events
kubectl describe pod -n kubecore-system -l app.kubernetes.io/name=kubecore-operator
```

### RBAC Errors Still Appearing

```bash
# Verify ClusterRole has secrets permissions
kubectl get clusterrole kubecore-operator-manager-role -o yaml | grep -A 10 "secrets"

# Verify ClusterRoleBinding exists
kubectl get clusterrolebinding kubecore-operator-manager-rolebinding

# Check ServiceAccount
kubectl get sa -n kubecore-system kubecore-operator-controller-manager
```

### Crossplane Providers Not Healthy

```bash
# Check provider status
kubectl get providers.pkg.crossplane.io -o wide

# Check provider logs
kubectl logs -n crossplane-system deployment/provider-kubernetes-xxxx

# Check provider configuration
kubectl describe provider.pkg.crossplane.io provider-kubernetes
```

### XRDs Not Established

```bash
# Check XRD status
kubectl get xrd -o wide

# Check specific XRD
kubectl describe xrd xawsproviders.aws.provider.platform.kubecore.io

# Verify Crossplane is healthy
kubectl get pods -n crossplane-system
```

---

## Rollback Procedure

If v0.1.7 installation fails:

```bash
# Uninstall v0.1.7
helm uninstall kubecore-operator -n kubecore-system

# The Crossplane and ESO installations can remain (they're separate)
# They won't be affected by operator uninstall

# If needed, reinstall v0.1.6 (not recommended - RBAC issue remains)
# Or fix the issue and reinstall v0.1.7
```

---

## Summary of Changes

### Files Modified
- `config/rbac/role.yaml` - Added secrets RBAC marker
- `internal/operators/kubeorg/reconciler.go` - Added secrets RBAC marker
- `dist/chart/Chart.yaml` - Bumped to v0.1.7, updated changelog
- `dist/chart/templates/rbac/role.yaml` - Added secrets permissions
- `dist/chart/values.yaml` - Documented namespace behavior
- `dist/chart/values-kaos-dev.yaml` - Disabled subcharts, added installation notes

### New Files Created
- `dist/chart/OPERATOR-NOT-WORKING-INVESTIGATION.md` - Detailed investigation report
- `dist/chart/DEPLOYMENT-INSTRUCTIONS-v0.1.7.md` - This document

### Git Commits
- Source repo: Pending commit of RBAC marker changes
- Charts repo: Committed and pushed v0.1.7 (commit b1a7fdf)

---

## Next Steps

**Current Status**: Chart v0.1.7 is published and ready for deployment.

**Waiting For**: User instructions on how to proceed with the installation of kubecore-operator after Crossplane and ESO are installed in their respective namespaces.

**DO NOT PROCEED** with Phase 3 installation commands until user provides guidance.

---

**Document Version**: 1.0
**Last Updated**: 2025-11-08
**Author**: Claude Code
**Review Status**: Ready for user review
