# GitOps Promoter Helm Chart

A Helm chart for deploying [GitOps Promoter](https://github.com/argoproj-labs/gitops-promoter), a tool for promoting changes between environments in GitOps workflows.

## Overview

GitOps Promoter is a Kubernetes controller that automates the promotion of changes between different environments in a GitOps workflow. It integrates with ArgoCD and various SCM providers (GitHub, GitLab, etc.) to provide automated environment promotion capabilities.

## Prerequisites

- Kubernetes 1.20+
- Helm 3.8+
- ArgoCD (for GitOps functionality)

## Installation

### Add the Helm Repository

```bash
helm repo add novelcore https://novelcore.github.io/charts/
helm repo update
```

### Install the Chart

```bash
# Install with default values
helm install gitops-promoter novelcore/gitops-promoter

# Install with custom values
helm install gitops-promoter novelcore/gitops-promoter -f values.yaml

# Install in a specific namespace
helm install gitops-promoter novelcore/gitops-promoter --namespace gitops-promoter --create-namespace
```

## Configuration

### Basic Configuration

The following table lists the configurable parameters and their default values:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `namespace.create` | Create namespace if it doesn't exist | `true` |
| `namespace.name` | Namespace name (defaults to release namespace) | `""` |
| `controllerManager.image.repository` | Controller manager image repository | `quay.io/argoprojlabs/gitops-promoter` |
| `controllerManager.image.tag` | Controller manager image tag | `v0.22.6` |
| `controllerManager.replicaCount` | Number of controller manager replicas | `1` |
| `kubeRbacProxy.image.tag` | kube-rbac-proxy sidecar image tag | `v0.20.2` |
| `serviceAccount.create` | Create service account | `true` |
| `rbac.create` | Create RBAC resources | `true` |
| `services.metrics.enabled` | Enable metrics service | `true` |
| `services.webhookReceiver.enabled` | Enable webhook receiver service | `true` |
| `ingress.enabled` | Enable ingress for webhook receiver | `false` |
| `ingress.hostname` | Hostname for webhook ingress | `promoter-webhook.example.com` |
| `ingress.ingressClassName` | Ingress class name | `traefik-system` |
| `crds.install` | Install Custom Resource Definitions | `true` |
| `crds.keep` | Retained for compatibility; has no effect (CRDs live in `crds/`, which Helm never deletes) | `true` |

### Advanced Configuration

#### Custom Resource Definitions (CRDs)

The chart includes all 12 Custom Resource Definitions required by GitOps Promoter:

- `argocdcommitstatuses.promoter.argoproj.io`
- `changetransferpolicies.promoter.argoproj.io`
- `clusterscmproviders.promoter.argoproj.io`
- `commitstatuses.promoter.argoproj.io`
- `controllerconfigurations.promoter.argoproj.io`
- `gitcommitstatuses.promoter.argoproj.io`
- `gitrepositories.promoter.argoproj.io`
- `promotionstrategies.promoter.argoproj.io`
- `pullrequests.promoter.argoproj.io`
- `revertcommits.promoter.argoproj.io`
- `scmproviders.promoter.argoproj.io`
- `timedcommitstatuses.promoter.argoproj.io`

CRDs ship in the chart's `crds/` directory (`crds/promoter-crds.yaml`), so Helm installs them before any other resource. Helm never upgrades or deletes files in `crds/`: they are created on first install only and are preserved on uninstall. (`templates/crds.yaml` is disabled with `{{- if false }}`; the old hook-based installation is gone.) Upgrade CRDs by applying `crds/promoter-crds.yaml` yourself.

To manually remove CRDs after uninstalling the chart (this deletes every promoter resource), delete them by group:

```bash
kubectl get crd -o name | grep '\.promoter\.argoproj\.io$' | xargs kubectl delete
```

(`scripts/cleanup-gitops-promoter-crds.sh` carries an older CRD list and does not cover all 12; prefer the command above.)

#### Resource Management

```yaml
controllerManager:
  resources:
    limits:
      cpu: 500m
      memory: 512Mi
    requests:
      cpu: 10m
      memory: 256Mi

kubeRbacProxy:
  resources:
    limits:
      cpu: 500m
      memory: 128Mi
    requests:
      cpu: 5m
      memory: 64Mi
```

#### Security Configuration

```yaml
pod:
  securityContext:
    runAsNonRoot: true
    seccompProfile:
      type: RuntimeDefault
    fsGroup: 65532

controllerManager:
  securityContext:
    allowPrivilegeEscalation: false
    capabilities:
      drop:
        - ALL
    readOnlyRootFilesystem: true
    runAsNonRoot: true
    runAsUser: 65532
```

#### High Availability

```yaml
controllerManager:
  replicaCount: 3

hpa:
  enabled: true
  minReplicas: 2
  maxReplicas: 5
  targetCPUUtilizationPercentage: 80

podDisruptionBudget:
  enabled: true
  minAvailable: 1

pod:
  affinity:
    podAntiAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app.kubernetes.io/name: gitops-promoter
        topologyKey: kubernetes.io/hostname
```

#### Monitoring Integration

```yaml
monitoring:
  serviceMonitor:
    enabled: true
    interval: 30s
    scrapeTimeout: 10s
    labels:
      prometheus: kube-prometheus
```

#### Controller Configuration

Each controller has a `workQueue` (`maxConcurrentReconciles`, `rateLimiter`, `requeueDuration`); the defaults are in `values.yaml` under `controllerConfiguration.{argocdCommitStatus,changeTransferPolicy,commitStatus,promotionStrategy,pullRequest,gitCommitStatus,timedCommitStatus}`.

```yaml
controllerConfiguration:
  enabled: true
  argocdCommitStatus:
    watchLocalApplications: true
    workQueue:
      requeueDuration: 2m
  pullRequest:
    template:
      title: "Promote {{ trunc 7 .ChangeTransferPolicy.Status.Proposed.Dry.Sha }} to `{{ .ChangeTransferPolicy.Spec.ActiveBranch }}`"
      description: |
        ## 🚀 Promotion Summary
        This PR promotes changes from **{{ .ChangeTransferPolicy.Spec.ProposedBranch }}** to **{{ .ChangeTransferPolicy.Spec.ActiveBranch }}**.
        # ... (enhanced template with tables, links, and status checks)
```

#### Git fetch daemon (optional sidecar)

`gitFetchDaemon.enabled` (default `false`) adds a sidecar that runs `git fetch --all --prune` every `gitFetchDaemon.fetchIntervalSeconds` (default 300) so branches created by the Argo CD hydrator are discovered. It needs `gitFetchDaemon.secret.name`, a Secret holding a GitHub installation token (for example from an External Secrets `GithubAccessToken` generator).

#### Ingress Configuration

```yaml
ingress:
  enabled: true
  ingressClassName: "traefik-system"
  hostname: "promoter-webhook.kubecore.eu"
  path: "/"
  pathType: "Prefix"
  tls:
    enabled: true
    secretName: ""  # Defaults to hostname if empty
  annotations:
    cert-manager.io/cluster-issuer: "sys-prod-issuer"
```

## Usage Examples

### Basic Setup

1. **Install the chart:**
   ```bash
   helm install gitops-promoter novelcore/gitops-promoter --namespace gitops-promoter --create-namespace
   ```

2. **Create an SCM Provider** (GitHub App credentials in a Secret):
   ```yaml
   apiVersion: promoter.argoproj.io/v1alpha1
   kind: ScmProvider
   metadata:
     name: github-provider
     namespace: gitops-promoter
   spec:
     secretRef:
       name: github-app-credentials
     github:
       appID: 123456
       installationID: 7890123
   ```

3. **Create a Git Repository:**
   ```yaml
   apiVersion: promoter.argoproj.io/v1alpha1
   kind: GitRepository
   metadata:
     name: my-gitops-repo
     namespace: gitops-promoter
   spec:
     github:
       owner: your-org
       name: gitops-repo
     scmProviderRef:
       kind: ScmProvider
       name: github-provider
   ```

4. **Create a Promotion Strategy:**
   ```yaml
   apiVersion: promoter.argoproj.io/v1alpha1
   kind: PromotionStrategy
   metadata:
     name: my-promotion-strategy
     namespace: gitops-promoter
   spec:
     gitRepositoryRef:
       name: my-gitops-repo
     environments:
     - name: staging
       branch: staging
     - name: production
       branch: main
   ```

### Production Setup

```yaml
# values-production.yaml
controllerManager:
  replicaCount: 3
  resources:
    limits:
      cpu: 1000m
      memory: 1Gi
    requests:
      cpu: 100m
      memory: 512Mi

hpa:
  enabled: true
  minReplicas: 3
  maxReplicas: 10
  targetCPUUtilizationPercentage: 70

podDisruptionBudget:
  enabled: true
  minAvailable: 2

monitoring:
  serviceMonitor:
    enabled: true
    labels:
      prometheus: kube-prometheus

# Ingress for webhook receiver
ingress:
  enabled: true
  ingressClassName: "traefik-system"
  hostname: "promoter-webhook.kubecore.eu"
  tls:
    enabled: true
  annotations:
    cert-manager.io/cluster-issuer: "sys-prod-issuer"

# Enhanced controller configuration
controllerConfiguration:
  argocdCommitStatus:
    workQueue:
      requeueDuration: 2m
  pullRequest:
    template:
      title: "Promote {{ trunc 7 .ChangeTransferPolicy.Status.Proposed.Dry.Sha }} to `{{ .ChangeTransferPolicy.Spec.ActiveBranch }}`"

pod:
  nodeSelector:
    node-type: system
  tolerations:
  - key: node-type
    operator: Equal
    value: system
    effect: NoSchedule
```

## Upgrading

### Upgrading the Chart

```bash
# Update repository
helm repo update

# Upgrade the release
helm upgrade gitops-promoter novelcore/gitops-promoter

# Upgrade with new values
helm upgrade gitops-promoter novelcore/gitops-promoter -f values-new.yaml
```

### Upgrading GitOps Promoter Version

When a new version of GitOps Promoter is released:

Maintainers: run `./scripts/update-gitops-promoter.sh vX.Y.Z` (see `UPDATE_STRATEGY.md`), which refreshes `crds/`, the image tags and `Chart.yaml`, and bump the chart `version`. Consumers:

1. Check the [release notes](https://github.com/argoproj-labs/gitops-promoter/releases) for breaking changes
2. Upgrade to the new chart version (its `appVersion` is the promoter version), or pin the image yourself:
   ```yaml
   controllerManager:
     image:
       tag: "v0.22.6"  # example
   ```
3. Apply the new `crds/promoter-crds.yaml` (Helm does not upgrade `crds/`), then upgrade the release:
   ```bash
   helm upgrade gitops-promoter novelcore/gitops-promoter -f values.yaml
   ```

## Troubleshooting

### Common Issues

1. **Controller not starting:**
   ```bash
   kubectl logs -f deployment/gitops-promoter-controller-manager -n gitops-promoter -c manager
   ```

2. **RBAC issues:**
   ```bash
   kubectl get clusterroles | grep gitops-promoter
   kubectl describe clusterrole gitops-promoter-manager-role
   ```

3. **CRD issues:**
   ```bash
   kubectl get crd | grep promoter.argoproj.io
   kubectl describe crd promotionstrategies.promoter.argoproj.io
   ```

4. **Webhook not receiving events:**
   ```bash
   kubectl get svc -n gitops-promoter
   kubectl port-forward svc/gitops-promoter-webhook-receiver 3333:3333 -n gitops-promoter
   ```

### Debug Mode

`controllerManager.args` only exposes `healthProbeBindAddress`, `metricsBindAddress` and `leaderElect`; there is no log-level value. Extra environment variables go in `controllerManager.env` (the chart sets `GIT_HTTP_LOW_SPEED_LIMIT` and `GIT_HTTP_LOW_SPEED_TIME` there by default; keep them if you override the list).

## Uninstalling

```bash
# Uninstall the release
helm uninstall gitops-promoter

# Remove CRDs (if desired; Helm leaves them in place)
kubectl get crd -o name | grep '\.promoter\.argoproj\.io$' | xargs kubectl delete

# Remove namespace (if created by the chart)
kubectl delete namespace gitops-promoter
```

## Development

### Local Development

1. Clone the repository
2. Make changes to the chart
3. Test with:
   ```bash
   helm lint charts/custom/gitops-promoter
   helm template test charts/custom/gitops-promoter --debug
   ```

### Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## License

This chart is licensed under the Apache License 2.0. Apache-2.0 (see `artifacthub.io/license` in `Chart.yaml`; there is no LICENSE file in this chart).

## Support

- [GitOps Promoter Documentation](https://github.com/argoproj-labs/gitops-promoter/blob/main/README.md)
- [Issues](https://github.com/argoproj-labs/gitops-promoter/issues)
- [Discussions](https://github.com/argoproj-labs/gitops-promoter/discussions)

## Changelog

See `artifacthub.io/changes` in `Chart.yaml` for the current chart version's changes and
`git log -- charts/custom/gitops-promoter` for history. The chart was first released for
GitOps Promoter v0.10.2; `appVersion` in `Chart.yaml` is the promoter version it ships.
- Monitoring and scaling support