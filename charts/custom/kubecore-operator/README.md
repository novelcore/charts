# kubecore-operator

A sophisticated Kubernetes operator that implements a four-layer framework architecture for provisioning and managing cloud infrastructure through Crossplane compositions.

## Introduction

The KubeCore Operator provides a complete platform for managing cloud infrastructure at scale, organizing resources into four logical layers:

- **Organization Layer** - Foundational infrastructure including AWS providers, GitHub integration, and network management
- **Cluster Layer** - Kubernetes clusters, node groups, and platform system components
- **Project Layer** - Application namespaces, GitOps repositories, and team management
- **Application Layer** - Individual application deployments, CI/CD pipelines, and application-specific resources

## Prerequisites

- Kubernetes 1.20+
- kubectl configured to access your cluster
- Helm 3.0+

## Installing the Chart

To install the chart with the release name `kubecore-operator`:

```bash
helm repo add novelcore https://novelcore.github.io/charts/
helm repo update
helm install kubecore-operator novelcore/kubecore-operator
```

## Uninstalling the Chart

To uninstall/delete the `kubecore-operator` deployment:

```bash
helm uninstall kubecore-operator
```

The command removes all the Kubernetes components associated with the chart and deletes the release.

**Note:** CRDs are kept by default (see `crd.keep` value). To remove CRDs, set `crd.keep=false` before uninstalling.

## Configuration

The following table lists the configurable parameters and their default values:

| Parameter | Description | Default |
|-----------|-------------|---------|
| `controllerManager.replicas` | Number of controller replicas | `1` |
| `controllerManager.container.image.repository` | Image repository | `controller` |
| `controllerManager.container.image.tag` | Image tag | `latest` |
| `controllerManager.container.resources.limits.cpu` | CPU limit | `500m` |
| `controllerManager.container.resources.limits.memory` | Memory limit | `128Mi` |
| `controllerManager.container.resources.requests.cpu` | CPU request | `10m` |
| `controllerManager.container.resources.requests.memory` | Memory request | `64Mi` |
| `rbac.enable` | Enable RBAC | `true` |
| `crd.enable` | Install CRDs | `true` |
| `crd.keep` | Keep CRDs on uninstall | `true` |
| `metrics.enable` | Enable metrics | `true` |
| `prometheus.enable` | Enable Prometheus ServiceMonitor | `false` |
| `certmanager.enable` | Enable cert-manager | `false` |
| `networkPolicy.enable` | Enable NetworkPolicies | `false` |
| `crossplane.enabled` | Install Crossplane dependency | `true` |
| `crossplane.namespace` | Crossplane namespace | `crossplane-system` |
| `crossplaneFunctions.enabled` | Install Crossplane functions | `true` |

### Example Custom Values

#### Fresh Installation (Default)
```yaml
controllerManager:
  replicas: 1
  container:
    image:
      repository: novelcore.azurecr.io/demo-project/kubecore-operator
      tag: v0.1.0

crossplane:
  enabled: true
  namespace: crossplane-system

crossplaneFunctions:
  enabled: true
```

#### Existing Cluster (Crossplane Already Installed)
```yaml
controllerManager:
  container:
    image:
      repository: novelcore.azurecr.io/demo-project/kubecore-operator
      tag: v0.1.0

crossplane:
  enabled: false  # Already installed

crossplaneFunctions:
  enabled: false  # Already installed
```

## Resource Types

The operator manages four Custom Resource Definitions:

### KubeOrg
Manages organization-level infrastructure:
- AWS infrastructure setup (IAM roles, OIDC providers, ECR repositories)
- GitHub provider integration and webhook configuration
- VPC networking and multi-region support

### KubePool
Manages cluster-level infrastructure:
- EKS cluster provisioning with auto-scaling node groups
- Platform system installations (ArgoCD, Crossplane, monitoring)
- Integration with organization-level networking and IAM

### KubeProject
Manages project-level resources:
- Kubernetes namespaces with resource quotas and limits
- GitHub repository and team management
- GitOps workflow setup and deployment pipelines
- Environment-specific configurations (dev, staging, production)

### KubeApp
Manages individual application deployments:
- Application repository creation from templates
- CI/CD pipeline configuration and webhooks
- Automated ECR → GitHub Actions credential synchronization
- Application-specific resource management
- Explicit environment selection with flexible targeting strategies

## Crossplane Integration

The chart includes Crossplane as a dependency and automatically installs required Crossplane functions:

- `function-go-templating` - Go template-based resource generation
- `function-auto-ready` - Automatic readiness condition management
- `function-patch-and-transform` - Advanced patching and transformation
- `function-sequencer` - Ordered resource creation
- `function-environment-configs` - Environment-specific configuration injection
- `function-extra-resources` - Extra resources configuration

## Troubleshooting

### Operator Pod Not Starting

Check the pod logs:
```bash
kubectl logs -n kubecore-operator-system deployment/kubecore-operator-controller-manager
```

### CRDs Not Installing

Verify CRD installation is enabled:
```bash
kubectl get crd | grep kubecore.io
```

If CRDs are missing, check the `crd.enable` value in your values.yaml.

### Crossplane Not Ready

Check Crossplane installation:
```bash
kubectl get pods -n crossplane-system
kubectl get providers -n crossplane-system
```

### Functions Not Installing

Verify functions are enabled:
```bash
kubectl get functions -n crossplane-system
```

Check the `crossplaneFunctions.enabled` value in your values.yaml.

## Support

For issues and questions:
- GitHub Issues: https://github.com/novelcore/kubecore-operator/issues
- Documentation: https://github.com/novelcore/kubecore-operator/blob/main/README.md


