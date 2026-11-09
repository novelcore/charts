# Argo CD with Argo Rollouts

This is a custom Helm chart intended to combine Argo CD with Argo Rollouts (see the limitation below).

## Overview

This chart declares two dependencies (`Chart.yaml`):
- `redis-ha` 4.33.7 (condition `redis-ha.enabled`)
- `argo-rollouts` 2.40.3, taken from this repository's own index (`https://novelcore.github.io/charts/`, the synced chart in `charts/external/argo-rollouts`; condition `rollouts.enabled`)

and a `values.yaml` copied from the upstream argo-cd chart 8.2.5 (Argo CD v3.0.12, see `syncMetadata` in `Chart.yaml`).

**Current limitation.** The chart has no `templates/` directory, so rendering it produces only the dependency resources. It does not install Argo CD itself. Install Argo CD from the upstream `argo/argo-cd` chart (or `charts/external`) until the templates are restored, and use this chart, or `novelcore/argo-rollouts` directly, for Argo Rollouts.

## Installation

```bash
# Add the Novelcore repository
helm repo add novelcore https://novelcore.github.io/charts/
helm repo update

helm install argocd-with-rollouts novelcore/argo-cd-with-rollouts \
  --namespace argocd \
  --create-namespace
```

`rollouts.enabled` defaults to `true`.

## Configuration

### Enable/Disable Rollouts

```yaml
rollouts:
  enabled: true  # install the argo-rollouts dependency
```

### Customize Rollouts

Values for the dependency go under its chart name, `argo-rollouts` (not under `rollouts`). The `rollouts.controller.enabled` and `rollouts.dashboard.enabled` keys in `values.yaml` are not read by the dependency; the dashboard is off in the upstream chart unless you set `argo-rollouts.dashboard.enabled: true`.

```yaml
rollouts:
  enabled: true
argo-rollouts:
  controller:
    replicas: 1
    resources:
      limits:
        cpu: 500m
        memory: 512Mi
      requests:
        cpu: 250m
        memory: 256Mi
  dashboard:
    enabled: true
```

## Usage

### Access Argo CD (when installed by the upstream chart)

```bash
# Port forward to Argo CD server
kubectl port-forward svc/argocd-server -n argocd 8080:443

# Get initial admin password
kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath="{.data.password}" | base64 -d
```

### Access Argo Rollouts Dashboard

```bash
# Port forward to Rollouts dashboard (needs argo-rollouts.dashboard.enabled=true)
kubectl port-forward svc/argo-rollouts-dashboard -n argocd 3100:3100
```

## Notes

- Argo CD config in `values.yaml` includes `resource.customizations.ignoreResourceUpdates.*` entries for Rollouts (`argoproj.io_Rollout`), which only take effect when an Argo CD chart consumes these values.

## Support

For issues and questions:
- Create an issue in this repository
- Contact the Novelcore platform team
