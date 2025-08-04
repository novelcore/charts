# GitOps Promoter Chart Update Strategy

This document outlines the strategy for updating the GitOps Promoter Helm chart when new versions of the upstream GitOps Promoter are released.

## Overview

Since GitOps Promoter doesn't provide an official Helm chart, we maintain this custom chart that packages the upstream installation manifests. The update process involves:

1. Monitoring upstream releases
2. Downloading new installation manifests
3. Extracting and updating chart components
4. Testing and validating changes
5. Releasing the updated chart

## Update Process

### 1. Monitor Upstream Releases

Monitor the [GitOps Promoter releases](https://github.com/argoproj-labs/gitops-promoter/releases) for new versions.

### 2. Download New Installation Manifests

When a new version is released (e.g., v0.11.0), download the installation manifests:

```bash
# Download the new version manifests
curl -L https://github.com/argoproj-labs/gitops-promoter/releases/download/v0.11.0/install.yaml -o install-v0.11.0.yaml

# Compare with current version
diff charts/promoter.yaml install-v0.11.0.yaml
```

### 3. Update Chart Components

#### 3.1 Update Chart.yaml

```yaml
# Update the appVersion to match the new GitOps Promoter version
appVersion: "0.11.0"

# Increment the chart version (semantic versioning)
version: 0.2.0  # or 0.1.1 for patch updates

# Update annotations
annotations:
  artifacthub.io/changes: |
    - kind: changed
      description: Updated GitOps Promoter to v0.11.0
    - kind: added
      description: New feature X support
    - kind: fixed
      description: Fixed issue Y
  artifacthub.io/images: |
    - name: gitops-promoter
      image: quay.io/argoprojlabs/gitops-promoter:v0.11.0
    - name: kube-rbac-proxy
      image: quay.io/brancz/kube-rbac-proxy:v0.17.0  # Update if changed
```

#### 3.2 Update values.yaml

```yaml
controllerManager:
  image:
    tag: "v0.11.0"  # Update to new version

# Update any new configuration options
# Add new parameters if the new version introduces them
```

#### 3.3 Update Templates (if needed)

Review the new installation manifests for:
- New Kubernetes resources
- Changed resource specifications
- New RBAC permissions
- Updated container arguments
- New environment variables
- Changed port configurations

#### 3.4 Update CRDs (if needed)

If new Custom Resource Definitions are added or existing ones are modified:

1. Extract CRDs from the new install.yaml
2. Update the CRDs template or create separate CRD files
3. Ensure proper CRD lifecycle management

### 4. Testing and Validation

#### 4.1 Lint the Chart

```bash
helm lint charts/custom/gitops-promoter
```

#### 4.2 Template Validation

```bash
helm template test charts/custom/gitops-promoter --debug > test-output.yaml
kubectl apply --dry-run=client -f test-output.yaml
```

#### 4.3 Integration Testing

```bash
# Create a test cluster (kind, minikube, etc.)
kind create cluster --name gitops-promoter-test

# Install the updated chart
helm install test-release charts/custom/gitops-promoter --namespace test --create-namespace

# Verify deployment
kubectl get pods -n test
kubectl logs -f deployment/test-release-controller-manager -n test -c manager

# Test basic functionality
kubectl apply -f test-resources/
```

#### 4.4 Upgrade Testing

```bash
# Install previous version
helm install test-release novelcore/gitops-promoter --version 0.1.0

# Upgrade to new version
helm upgrade test-release charts/custom/gitops-promoter

# Verify upgrade succeeded
kubectl get pods -n test
```

### 5. Documentation Updates

#### 5.1 Update README.md

- Update version references
- Add new configuration options
- Update examples if needed
- Add migration notes for breaking changes

#### 5.2 Update CHANGELOG

Create or update CHANGELOG.md:

```markdown
## [0.2.0] - 2024-01-15

### Changed
- Updated GitOps Promoter to v0.11.0
- Updated kube-rbac-proxy to v0.18.0

### Added
- New configuration option for webhook timeout
- Support for custom pull request templates

### Fixed
- Fixed issue with RBAC permissions for new CRDs
```

### 6. Release Process

#### 6.1 Version Bump

Ensure all version references are updated:
- Chart.yaml (version and appVersion)
- values.yaml (image tags)
- README.md (examples and documentation)

#### 6.2 Commit Changes

```bash
git add -A
git commit -m "feat: update GitOps Promoter to v0.11.0

- Update GitOps Promoter to v0.11.0
- Add support for new webhook configuration
- Update CRDs with latest schemas
- Bump chart version to 0.2.0"
```

#### 6.3 Create Release

The CI/CD pipeline will automatically:
1. Package the chart
2. Update the Helm repository index
3. Publish to GitHub Pages

## Automation Opportunities

### 1. Automated Monitoring

Create a GitHub Action to monitor upstream releases:

```yaml
name: Monitor GitOps Promoter Releases
on:
  schedule:
    - cron: '0 0 * * *'  # Daily check
  workflow_dispatch:

jobs:
  check-releases:
    runs-on: ubuntu-latest
    steps:
    - name: Check for new releases
      run: |
        # Script to check for new releases and create issues
```

### 2. Semi-Automated Updates

Create a script to assist with updates:

```bash
#!/bin/bash
# scripts/update-promoter.sh

NEW_VERSION=$1
if [ -z "$NEW_VERSION" ]; then
  echo "Usage: $0 <new-version>"
  exit 1
fi

echo "Updating GitOps Promoter to $NEW_VERSION"

# Download new manifests
curl -L "https://github.com/argoproj-labs/gitops-promoter/releases/download/$NEW_VERSION/install.yaml" -o "install-$NEW_VERSION.yaml"

# Update Chart.yaml
sed -i "s/appVersion: .*/appVersion: \"$NEW_VERSION\"/" charts/custom/gitops-promoter/Chart.yaml

# Update values.yaml
sed -i "s/tag: .*/tag: \"$NEW_VERSION\"/" charts/custom/gitops-promoter/values.yaml

echo "Update complete. Please review changes and test."
```

## Breaking Changes Handling

When upstream introduces breaking changes:

1. **Document Migration Path**: Create migration guide
2. **Update Chart Major Version**: Follow semantic versioning
3. **Provide Backwards Compatibility**: When possible
4. **Clear Communication**: Update all documentation

## Best Practices

1. **Always Test**: Never release without testing
2. **Document Changes**: Keep detailed changelogs
3. **Semantic Versioning**: Follow semver for chart versions
4. **Security Review**: Check for security implications
5. **Performance Impact**: Assess resource requirement changes
6. **Rollback Plan**: Always have a rollback strategy

## Contact

For questions about the update process:
- Create an issue in the charts repository
- Contact the platform team
- Review the GitOps Promoter upstream documentation