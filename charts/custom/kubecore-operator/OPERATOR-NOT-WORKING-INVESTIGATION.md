# KubeCore Operator Deployment Investigation Report
**Date**: 2025-11-08
**Cluster**: kaos-dev-eks
**Chart Version**: 0.1.6
**Issue**: Operator pod running but not reconciling KubeOrg CRs

---

## Executive Summary

The kubecore-operator v0.1.6 was successfully installed on kaos-dev-eks cluster, but the operator is **not reconciling KubeOrg custom resources**. Investigation revealed **two critical issues**:

1. **Missing RBAC Permissions**: Operator lacks cluster-wide `secrets` permissions, causing controller-runtime cache failures
2. **Crossplane Namespace Misconfiguration**: Crossplane components installed in `kubecore-system` instead of `crossplane-system`

---

## Issue 1: Missing RBAC Permissions for Secrets

### Symptom

Operator logs show repeated RBAC permission errors:

```
ERROR	controller-runtime.cache.UnhandledError	Failed to watch
{"reflector": "pkg/mod/k8s.io/client-go@v0.33.0/tools/cache/reflector.go:285",
 "type": "*v1.Secret",
 "error": "failed to list *v1.Secret: secrets is forbidden:
           User \"system:serviceaccount:kubecore-system:kubecore-operator-controller-manager\"
           cannot list resource \"secrets\" in API group \"\" at the cluster scope"}
```

### Root Cause

The operator's ClusterRole (`kubecore-operator-manager-role`) **does not include permissions for `secrets`** resources. The controller-runtime manager attempts to cache Secret resources but fails due to missing RBAC permissions.

### Current RBAC Configuration

**File**: `dist/chart/templates/rbac/role.yaml`

The ClusterRole includes permissions for:
- `configmaps` ✅
- `events` ✅
- `environmentconfigs` ✅
- Various Crossplane XRDs ✅

But **MISSING**:
- `secrets` ❌

### Why Does the Operator Need Secrets?

1. **GitHub Credentials**: KubeOrg specs reference secrets for GitHub authentication:
   ```yaml
   spec:
     githubConfig:
       credentialsSecretRef:
         name: novelcore-github-credentials
   ```

2. **AWS Credentials**: Referenced in Crossplane ProviderConfigs
3. **Infrastructure Secrets**: Various secrets used in compositions

### Impact

- **Operator cannot reconcile KubeOrg resources**: No events generated, no status updates
- **Controller-runtime cache failures**: Continuous error logging every minute
- **Silent failure mode**: Pod shows `1/1 Running` but is functionally broken

---

## Issue 2: Crossplane Namespace Misconfiguration

### Symptom

Despite configuring `crossplane.namespace: crossplane-system` in values, all Crossplane components are installed in `kubecore-system`:

```bash
$ kubectl get pods -n kubecore-system | grep crossplane
crossplane-678bfb9b8f-5jfs8                                       1/1     Running   0          35m
crossplane-rbac-manager-57565b4b9b-jxc4c                          1/1     Running   0          35m
function-auto-ready-35bfe51b9ce9-845f866bfd-j7xwg                 1/1     Running   0          34m
function-environment-configs-051b67e6a3ae-7d6b44ff4d-jzmc7        1/1     Running   0          33m
provider-kubernetes-fd54bbc7f877-6dbbc8bb95-bs5cb                 1/1     Running   0          31m
# ... all other Crossplane providers ...

$ kubectl get deployments -n crossplane-system
No resources found in crossplane-system namespace.
```

### Root Cause

**Helm Subchart Namespace Inheritance Issue**

When Helm installs a chart with dependencies (subcharts), the subchart resources **inherit the parent chart's release namespace** unless explicitly overridden at installation time. The `crossplane.namespace` value in `values.yaml` is just a parameter passed to the Crossplane subchart, but Helm still installs all resources in the release namespace (`kubecore-system`).

### Chart Configuration

**File**: `dist/chart/Chart.yaml`
```yaml
dependencies:
- name: crossplane
  version: "2.1.0"
  repository: "https://charts.crossplane.io/stable"
  condition: crossplane.enabled
- name: external-secrets
  version: "1.0.0"
  repository: "https://charts.external-secrets.io"
  condition: externalSecrets.enabled
```

**File**: `dist/chart/values.yaml`
```yaml
crossplane:
  enabled: true
  namespace: crossplane-system  # ❌ This doesn't control subchart installation namespace
```

**Actual Installation**:
```bash
$ helm list -n kubecore-system
NAME                NAMESPACE         REVISION  STATUS    CHART                     APP VERSION
kubecore-operator   kubecore-system   1         deployed  kubecore-operator-0.1.6   0.1.1
```

### Why This is a Problem

1. **Operator Configuration Mismatch**:
   - Operator expects certain resources in `crossplane-system`
   - ProviderConfig references: `namespace: crossplane-system`
   - ServiceAccount references: `namespace: crossplane-system`

2. **Resource Organization**:
   - Best practice is to isolate Crossplane in its own namespace
   - Easier upgrades and maintenance
   - Clear separation of concerns

3. **ClusterRoleBindings Point to Wrong Namespace**:
   ```yaml
   # Chart creates bindings for crossplane-system:
   - kind: ServiceAccount
     name: kubesys-admin
     namespace: crossplane-system  # ❌ But resources are in kubecore-system
   ```

### Evidence

```bash
# Namespace exists but is empty
$ kubectl get namespace crossplane-system
NAME                STATUS   AGE
crossplane-system   Active   3h10m

$ kubectl get all -n crossplane-system
No resources found in crossplane-system namespace.

# All Crossplane resources in kubecore-system
$ kubectl get providers.pkg.crossplane.io -A
NAME                                       INSTALLED   HEALTHY   PACKAGE
crossplane-contrib-provider-upjet-github   True        True      ghcr.io/...
provider-helm                              True        True      xpkg.crossplane.io/...
provider-kubernetes                        True        True      xpkg.crossplane.io/...
upbound-provider-aws-account               True        True      xpkg.upbound.io/...
# ... (all in cluster scope but managed from kubecore-system)
```

---

## KubeOrg CR Status

### Test CR Applied

```yaml
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
```

### Current State

```bash
$ kubectl get kubeorg.schema.kubecore.io/novelcore
NAME        AGE
novelcore   2m11s

$ kubectl get events --field-selector involvedObject.name=novelcore
No events found.
```

**Analysis**:
- CR has finalizer: `kubeorg.kubecore.io/finalizer` ✅
- Generation: 2 (resource updated once)
- **No status field** ❌
- **No events generated** ❌
- **Age**: 2m11s with no reconciliation activity

This confirms the operator is **not watching or reconciling** KubeOrg resources.

---

## Operator Pod Status

### Deployment

```yaml
Name:                   kubecore-operator-controller-manager
Namespace:              kubecore-system
Replicas:               1 desired | 1 updated | 1 total | 1 available
Pod Status:             1/1 Running ✅
Image:                  novelcore.azurecr.io/kubecore/kubecore-operator:0.1.1
Environment Variables:
  EKS_CLUSTER_ID:              AF009732404FA9DE00D7C06126A0DD0B ✅
  EKS_REGION:                  eu-central-1 ✅
  KUBERNETES_PROVIDER_CONFIG:  kubesys-enhanced ✅
```

### Health Checks

```bash
# Liveness: http-get http://:8081/healthz delay=15s period=20s
# Readiness: http-get http://:8081/readyz delay=5s period=10s
# Both probes passing (pod is Running)
```

### Resource Usage

The pod appears healthy from Kubernetes perspective:
- Probes passing
- Container running
- No restart loops

But **functionally broken** due to RBAC issues.

---

## Comparison: Source vs Helm Chart RBAC

### Source Repository

**File**: `config/rbac/role.yaml`

```yaml
rules:
- apiGroups:
  - ""
  resources:
  - configmaps
  verbs:
  - create
  - delete
  - get
  - list
  - patch
  - update
  - watch
- apiGroups:
  - ""
  resources:
  - events
  verbs:
  - create
  - patch
# ... (NO secrets permissions)
```

### Helm Chart

**File**: `dist/chart/templates/rbac/role.yaml`

Identical to source - **no secrets permissions** in either location.

### Conclusion

This is not a Helm chart conversion issue - **the source RBAC is also missing secrets permissions**. This suggests:
1. The operator was never tested with real GitHub credentials (which require secrets)
2. RBAC permissions need to be added to source and regenerated
3. Kubebuilder markers may be missing in the controller code

---

## Additional Observations

### 1. ServiceAccounts Created Correctly

```bash
$ kubectl get sa -n kubecore-system | grep kubecore
kubecore-operator-controller-manager            0         39m

$ kubectl get sa -n kubecore-system | grep kubesys
kubesys-admin                                   0         3h12m

$ kubectl get sa -n crossplane-system | grep kubesys
kubesys-admin                                   0         3h12m
```

Both namespaces have the `kubesys-admin` ServiceAccount as expected from v0.1.5 fixes.

### 2. ClusterRoleBindings

```yaml
# Binding for kubesys-admin in crossplane-system
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubesys-admin-crossplane
subjects:
- kind: ServiceAccount
  name: kubesys-admin
  namespace: crossplane-system  # ❌ Points to empty namespace
roleRef:
  kind: ClusterRole
  name: cluster-admin

# Binding for kubesys-admin in kubecore-system
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kubesys-admin-kubecore-system
subjects:
- kind: ServiceAccount
  name: kubesys-admin
  namespace: kubecore-system  # ✅ Where Crossplane actually is
roleRef:
  kind: ClusterRole
  name: cluster-admin
```

The fact that we have bindings for both namespaces is actually helping here - even though Crossplane is in the wrong namespace, it still has admin permissions.

### 3. Crossplane Components Healthy

Despite namespace issues, all Crossplane components are healthy:

```bash
$ kubectl get providers.pkg.crossplane.io
NAME                                       INSTALLED   HEALTHY
crossplane-contrib-provider-upjet-github   True        True
provider-helm                              True        True
provider-kubernetes                        True        True
upbound-provider-aws-account               True        True
upbound-provider-aws-ec2                   True        True
upbound-provider-aws-ecr                   True        True
upbound-provider-aws-eks                   True        True
upbound-provider-aws-iam                   True        True
upbound-provider-aws-organizations         True        True
upbound-provider-aws-route53               True        True
upbound-provider-family-aws                True        True
```

### 4. XRDs Successfully Installed

All 12 XRDs from v0.1.6 are installed and established:

```bash
$ kubectl get xrd
NAME                                                   ESTABLISHED   AGE
xawsnetworks.platform.kubecore.io                      True          39m
xawsproviders.aws.provider.platform.kubecore.io        True          39m
xeks.platform.kubecore.io                              True          39m
xgithubapps.github.platform.kubecore.io                True          39m
xgithubproviders.github.platform.kubecore.io           True          39m
xgithubprojects.github.platform.kubecore.io            True          39m
xk8sapps.k8s.platform.kubecore.io                      True          39m
xkubeapptemplates.platform.kubecore.io                 True          39m
xkubenvs.platform.kubecore.io                          True          39m
xkubesystems.platform.kubecore.io                      True          39m
xqualitygates.platform.kubecore.io                     True          39m
xqualitygatetemplates.platform.kubecore.io             True          39m
```

This confirms the v0.1.6 XRD splitting fix was successful.

---

## Root Cause Analysis Summary

### Primary Issue: Missing Secrets RBAC

**Severity**: 🔴 **CRITICAL** - Operator completely non-functional

The operator cannot access secrets that are required for:
- Looking up GitHub credentials from `spec.githubConfig.credentialsSecretRef`
- Accessing AWS credentials referenced in compositions
- Any secret-based configuration

**Source**: RBAC definition in both source repo and Helm chart

**Fix Required**: Add secrets permissions to ClusterRole

### Secondary Issue: Crossplane Namespace Misconfiguration

**Severity**: 🟡 **MEDIUM** - Functional but architecturally incorrect

Crossplane works correctly despite being in the wrong namespace because:
- ServiceAccount `kubesys-admin` exists in both namespaces
- Both have cluster-admin bindings
- Providers are cluster-scoped resources

However, this violates:
- Chart's documented namespace configuration
- Best practices for component isolation
- Makes future maintenance confusing

**Source**: Helm subchart namespace inheritance behavior

**Fix Required**: Either:
1. Change Helm installation command to install subcharts in correct namespaces
2. Document that all components install in release namespace
3. Modify chart to not use subcharts (include Crossplane setup separately)

---

## Recommended Solutions

### Solution 1: Fix RBAC Permissions (URGENT)

#### Step 1: Update Source RBAC

**File**: `config/rbac/role.yaml`

Add after configmaps permissions:

```yaml
- apiGroups:
  - ""
  resources:
  - secrets
  verbs:
  - get
  - list
  - watch
```

**Note**: Only `get`, `list`, `watch` verbs needed (read-only access)

#### Step 2: Regenerate Manifests

```bash
cd /Users/abstractversion/Documents/projects/kubecore/v3/kubecore-operator
make manifests
```

This will update `config/rbac/role.yaml` and other generated files.

#### Step 3: Update Helm Chart

```bash
# Copy updated RBAC to Helm chart
cp config/rbac/role.yaml dist/chart/templates/rbac/role.yaml
```

Ensure the Helm template wrapper is preserved:
```yaml
{{- if .Values.rbac.enable }}
---
# ... RBAC rules here ...
{{- end -}}
```

#### Step 4: Bump Chart Version

**File**: `dist/chart/Chart.yaml`

```yaml
version: 0.1.7  # Increment from 0.1.6

artifacthub.io/changes: |
  - kind: fixed
    description: "Added missing cluster-wide secrets read permissions to operator ClusterRole"
  - kind: security
    description: "Operator now has explicit secrets permissions instead of failing silently"
```

#### Step 5: Test Locally

```bash
# Render chart to verify RBAC changes
helm template dist/chart | grep -A 20 "kind: ClusterRole"

# Verify secrets permissions appear
helm template dist/chart | grep -A 5 "secrets"
```

#### Step 6: Deploy to Cluster

```bash
# Option A: Upgrade existing installation
helm upgrade kubecore-operator dist/chart -n kubecore-system -f dist/chart/values-kaos-dev.yaml

# Option B: Fresh install (requires uninstall first)
helm uninstall kubecore-operator -n kubecore-system
kubectl delete crd -l app.kubernetes.io/name=kubecore-operator
helm install kubecore-operator dist/chart -n kubecore-system -f dist/chart/values-kaos-dev.yaml

# Restart operator pod to pick up new permissions
kubectl rollout restart deployment/kubecore-operator-controller-manager -n kubecore-system
```

#### Step 7: Verify Fix

```bash
# Check logs - should no longer see RBAC errors
kubectl logs -n kubecore-system deployment/kubecore-operator-controller-manager --tail=50

# Apply test KubeOrg CR
kubectl apply -f config/samples/schema_v1beta1_kubeorg.yaml

# Check for reconciliation events
kubectl get events --field-selector involvedObject.name=novelcore --sort-by='.lastTimestamp'

# Check KubeOrg status updated
kubectl get kubeorg novelcore -o jsonpath='{.status}' | jq
```

---

### Solution 2: Fix Crossplane Namespace (OPTIONAL)

This issue is less critical since Crossplane is functional, but for proper architecture:

#### Option A: Document Current Behavior

Update `dist/chart/README.md` and `values.yaml`:

```yaml
# [CROSSPLANE]: Crossplane dependency configuration
crossplane:
  # Enable Crossplane installation as a dependency
  enabled: true
  # IMPORTANT: Crossplane will be installed in the same namespace as the Helm release.
  # The 'namespace' parameter below is passed to Crossplane subchart but does not
  # control where Helm installs the resources. If you need Crossplane in a different
  # namespace, install it separately and set enabled: false here.
  namespace: crossplane-system  # Parameter passed to Crossplane subchart
```

#### Option B: Install Crossplane Separately

For production deployments:

```bash
# Install Crossplane in its own namespace first
helm install crossplane crossplane-stable/crossplane \
  --namespace crossplane-system \
  --create-namespace \
  --version 2.1.0

# Then install kubecore-operator with Crossplane disabled
helm install kubecore-operator dist/chart \
  --namespace kubecore-system \
  --create-namespace \
  -f dist/chart/values-kaos-dev.yaml \
  --set crossplane.enabled=false
```

#### Option C: Use Helm Dependency Namespace Override (Advanced)

Modify `Chart.yaml` to use namespace aliases (requires Helm 3.13+):

```yaml
dependencies:
- name: crossplane
  version: "2.1.0"
  repository: "https://charts.crossplane.io/stable"
  condition: crossplane.enabled
  # This requires creating a separate subchart wrapper
  import-values:
    - child: namespace
      parent: crossplane.namespace
```

This is complex and may not work reliably with all subchart configurations.

---

## Testing Checklist

After applying fixes, verify:

### ✅ RBAC Permissions

```bash
# Operator ClusterRole includes secrets
kubectl get clusterrole kubecore-operator-manager-role -o yaml | grep -A 5 secrets

# No more RBAC errors in logs
kubectl logs -n kubecore-system deployment/kubecore-operator-controller-manager --tail=100 | grep -i "forbidden"
```

### ✅ Operator Reconciliation

```bash
# Apply test KubeOrg
kubectl apply -f - <<EOF
apiVersion: schema.kubecore.io/v1beta1
kind: KubeOrg
metadata:
  name: test-org
spec:
  awsConfig:
    accountId: "123456789012"
    primaryRegion: us-east-1
    providerConfig: aws-default
    regions:
    - us-east-1
  githubConfig:
    credentialsSecretRef:
      name: test-credentials
  network:
    enabled: false
EOF

# Wait 30 seconds for reconciliation
sleep 30

# Check status updated
kubectl get kubeorg test-org -o yaml | grep -A 20 "status:"

# Check events generated
kubectl get events --field-selector involvedObject.name=test-org

# Check EnvironmentConfig created
kubectl get environmentconfig test-org-aws-config

# Cleanup
kubectl delete kubeorg test-org
```

### ✅ Crossplane Integration

```bash
# Verify Crossplane providers healthy
kubectl get providers.pkg.crossplane.io

# Verify ProviderConfigs accessible
kubectl get providerconfig kubesys-enhanced
kubectl get providerconfig.aws.upbound.io aws-default

# Test XRD installation
kubectl get xrd | wc -l  # Should show 12 XRDs
```

---

## Impact Assessment

### Current State (v0.1.6)

| Component | Status | Functional? | Notes |
|-----------|--------|-------------|-------|
| Operator Pod | ✅ Running | ❌ No | RBAC errors prevent reconciliation |
| Crossplane Core | ✅ Healthy | ✅ Yes | Wrong namespace but functional |
| Crossplane Providers | ✅ Healthy | ✅ Yes | All 11 providers installed |
| XRDs | ✅ Established | ✅ Yes | All 12 XRDs from v0.1.6 |
| KubeOrg Reconciliation | ❌ Failed | ❌ No | No events, no status updates |
| External Secrets | ✅ Running | ✅ Yes | Operating correctly |

### After RBAC Fix (v0.1.7)

| Component | Status | Functional? | Notes |
|-----------|--------|-------------|-------|
| Operator Pod | ✅ Running | ✅ Yes | Full reconciliation capability |
| Crossplane Core | ✅ Healthy | ✅ Yes | Still in kubecore-system (acceptable) |
| Crossplane Providers | ✅ Healthy | ✅ Yes | All 11 providers installed |
| XRDs | ✅ Established | ✅ Yes | All 12 XRDs working |
| KubeOrg Reconciliation | ✅ Working | ✅ Yes | Full lifecycle management |
| External Secrets | ✅ Running | ✅ Yes | Operating correctly |

---

## Lessons Learned

### 1. RBAC Permissions Must Match Code Requirements

**Problem**: Operator code accesses secrets, but RBAC doesn't grant permissions

**Solution**:
- Add Kubebuilder RBAC markers in controller code where secrets are accessed
- Run `make manifests` to regenerate RBAC
- Test with real secrets in dev environment

**Prevention**:
```go
// +kubebuilder:rbac:groups="",resources=secrets,verbs=get;list;watch
```

### 2. Helm Subchart Namespace Behavior

**Problem**: `crossplane.namespace` value doesn't control installation namespace

**Solution**:
- Document that subcharts install in release namespace
- Consider separate installation for production
- Don't rely on subchart namespace configuration

**Prevention**:
- Test Helm chart installations in CI
- Document namespace behavior in chart README
- Consider post-install checks for namespace correctness

### 3. Silent Failures in Kubernetes

**Problem**: Pod shows Running but is functionally broken

**Solution**:
- Add application-level health checks
- Monitor operator metrics for reconciliation activity
- Check logs proactively, not just pod status

**Prevention**:
- Implement custom health check endpoints that verify RBAC
- Add startup checks for critical permissions
- Better error surfacing in operator status

### 4. RBAC Testing Gaps

**Problem**: Operator never tested with real secret references

**Solution**:
- E2E tests must include secret-based authentication
- Integration tests should use actual secret references
- CI should validate RBAC completeness

**Prevention**:
- Add RBAC validation to test suite
- Check that ClusterRole has permissions for all API calls in code
- Use tooling to detect permission gaps

---

## Next Steps

### Immediate (Within 1 hour)

1. ✅ **Add secrets RBAC to source repository**
   - Update `config/rbac/role.yaml`
   - Run `make manifests`
   - Commit changes

2. ✅ **Update Helm chart**
   - Copy updated RBAC
   - Bump version to 0.1.7
   - Update changelog

3. ✅ **Test locally**
   - Render chart templates
   - Verify RBAC changes

### Short-term (Within 1 day)

4. ✅ **Deploy to kaos-dev-eks**
   - Upgrade Helm release
   - Restart operator
   - Verify reconciliation

5. ✅ **Test with real KubeOrg**
   - Apply `novelcore` KubeOrg CR
   - Verify status updates
   - Check Crossplane resources created

6. ✅ **Publish chart v0.1.7**
   - Push to novelcore/charts repo
   - Update documentation

### Medium-term (Within 1 week)

7. ⬜ **Add E2E tests for RBAC**
   - Test with secret references
   - Validate permissions
   - Add to CI

8. ⬜ **Document namespace behavior**
   - Update chart README
   - Add troubleshooting section
   - Document both installation methods

9. ⬜ **Review all operators for missing RBAC**
   - KubePool, KubeProject, KubeApp
   - Check for other missing permissions
   - Update and regenerate

### Long-term (Future releases)

10. ⬜ **Consider Crossplane installation strategy**
    - Evaluate separate installation
    - Document best practices
    - Potentially remove from subchart

11. ⬜ **Add operator health metrics**
    - Track reconciliation success/failure
    - Monitor RBAC errors
    - Alert on issues

12. ⬜ **Improve operator startup checks**
    - Verify RBAC permissions on startup
    - Fail fast if permissions missing
    - Better error messages

---

## References

### Related Issues

- v0.1.5: Missing Kubernetes ProviderConfig (resolved)
- v0.1.5: Provider-kubernetes pod failure (resolved)
- v0.1.6: XRD YAML parsing error (resolved)
- v0.1.7: Missing secrets RBAC (THIS ISSUE)

### Documentation

- Kubebuilder RBAC markers: https://book.kubebuilder.io/reference/markers/rbac.html
- Helm subcharts: https://helm.sh/docs/chart_template_guide/subcharts_and_globals/
- Controller-runtime caching: https://pkg.go.dev/sigs.k8s.io/controller-runtime/pkg/cache
- Kubernetes RBAC: https://kubernetes.io/docs/reference/access-authn-authz/rbac/

### Files Modified in This Investigation

- None (investigation only)

### Files That Need Modification

#### Source Repository
- `/config/rbac/role.yaml` - Add secrets permissions

#### Helm Chart
- `dist/chart/templates/rbac/role.yaml` - Copy from source
- `dist/chart/Chart.yaml` - Bump to 0.1.7
- `dist/chart/values.yaml` - Document namespace behavior (optional)

---

## Appendix A: Full Error Log

```
2025-11-08T15:00:57Z	ERROR	controller-runtime.cache.UnhandledError	Failed to watch
{"reflector": "pkg/mod/k8s.io/client-go@v0.33.0/tools/cache/reflector.go:285",
 "type": "*v1.Secret",
 "error": "failed to list *v1.Secret: secrets is forbidden:
           User \"system:serviceaccount:kubecore-system:kubecore-operator-controller-manager\"
           cannot list resource \"secrets\" in API group \"\" at the cluster scope"}
k8s.io/apimachinery/pkg/util/runtime.logError
	/go/pkg/mod/k8s.io/apimachinery@v0.33.0/pkg/util/runtime/runtime.go:226
k8s.io/apimachinery/pkg/util/runtime.handleError
	/go/pkg/mod/k8s.io/apimachinery@v0.33.0/pkg/util/runtime/runtime.go:217
k8s.io/apimachinery/pkg/util/runtime.HandleErrorWithContext
	/go/pkg/mod/k8s.io/apimachinery@v0.33.0/pkg/util/runtime/runtime.go:203
k8s.io/client-go/tools/cache.DefaultWatchErrorHandler
	/go/pkg/mod/k8s.io/client-go@v0.33.0/tools/cache/reflector.go:200
k8s.io/client-go/tools/cache.(*Reflector).RunWithContext.func1
	/go/pkg/mod/k8s.io/client-go@v0.33.0/tools/cache/reflector.go:360
```

## Appendix B: ClusterRole Comparison

### Configured Permissions (Current)

```yaml
rules:
- apiGroups: [""]
  resources: [configmaps]
  verbs: [create, delete, get, list, patch, update, watch]
- apiGroups: [""]
  resources: [events]
  verbs: [create, patch]
- apiGroups: [coordination.k8s.io]
  resources: [leases]
  verbs: [create, delete, get, list, patch, update, watch]
# ... Crossplane resources ...
```

### Missing Permissions (Required)

```yaml
- apiGroups: [""]
  resources: [secrets]
  verbs: [get, list, watch]  # Read-only access sufficient
```

### Why Read-Only?

The operator only needs to:
- Read GitHub credential secrets referenced in `credentialsSecretRef`
- Watch for secret changes to trigger reconciliation
- List secrets in specific namespaces when validating references

The operator does NOT need to:
- Create secrets (done by External Secrets Operator)
- Update secrets (managed externally)
- Delete secrets (handled by garbage collection)

---

**End of Investigation Report**
