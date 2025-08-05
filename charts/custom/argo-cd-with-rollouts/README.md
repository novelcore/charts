# Argo CD with Argo Rollouts

This is a custom Helm chart that combines Argo CD with Argo Rollouts for a complete GitOps and progressive delivery solution.

## Overview

This chart installs:
- **Argo CD**: Declarative GitOps continuous delivery tool for Kubernetes
- **Argo Rollouts**: Advanced deployment strategies for Kubernetes

## Features

- ✅ Argo CD with all standard features
- ✅ Argo Rollouts controller and dashboard
- ✅ Pre-configured resource customizations for Rollouts
- ✅ Single installation for both tools
- ✅ Consistent versioning and management

## Installation

```bash
# Add the Novelcore repository
helm repo add novelcore https://novelcore.github.io/charts/
helm repo update

# Install Argo CD with Rollouts
helm install argocd-with-rollouts novelcore/argo-cd-with-rollouts \
  --namespace argocd \
  --create-namespace \
  --set rollouts.enabled=true
```

## Configuration

### Enable/Disable Rollouts

```yaml
rollouts:
  enabled: true  # Enable Argo Rollouts
controller:
    enabled: true  # Enable Rollouts controller
  dashboard:
    enabled: true  # Enable Rollouts dashboard
```

### Customize Rollouts Configuration

```yaml
rollouts:
  enabled: true
controller:
    # All argo-rollouts controller values can be configured here
    replicaCount: 1
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
      requests:
        cpu: 250m
        memory: 256Mi
  dashboard:
    # All argo-rollouts dashboard values can be configured here
    replicaCount: 1
  ingress:
    enabled: true
      className: nginx
```

## Usage

### Access Argo CD

```bash
# Port forward to Argo CD server
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Access Argo Rollouts Dashboard

```bash
# Port forward to Rollouts dashboard
kubectl port-forward svc/argo-rollouts-dashboard -n argocd 3100:3100
```

## Benefits

1. **Unified Installation**: Install both Argo CD and Rollouts in one command
2. **Version Compatibility**: Ensures compatible versions of both tools
3. **Simplified Management**: Single chart to manage both tools
4. **Pre-configured**: Rollouts are already configured to work with Argo CD

## Differences from Standard Argo CD

This chart extends the standard Argo CD chart with:
- Argo Rollouts as a dependency
- Pre-configured resource customizations for Rollouts
- Simplified installation for both tools
- Consistent versioning

## Support

For issues and questions:
- Create an issue in this repository
- Contact the Novelcore platform team
