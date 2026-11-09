# Helm Charts Repository - Cursor Agent Guide

## Repository Overview

This is a **Helm Charts Repository** that manages both **custom charts** and **external charts** from third-party repositories. The repository provides automated synchronization, packaging, and publishing of Helm charts to a private GitHub Pages-hosted Helm repository.

### Key Capabilities
- **Custom Chart Development**: Create and maintain organization-specific Helm charts
- **External Chart Curation**: Manually sync (`scripts/sync-chart.sh`) and manage external charts from upstream repositories
- **Automated CI/CD**: Argo Workflows validate PRs (`charts/validate`) and publish `main` (`charts/release`)
- **Security Scanning**: On-demand chart CVE scans via the `.claude/agents/chart-cve-*` agents (Trivy)
- **Chart Testing**: chart-testing (`ct lint`) plus per-chart test suites under `charts/custom/*/tests`

## Repository Structure

```
charts/
├── charts/
│   ├── custom/         # Organization-specific custom charts
│   └── external/       # Synced external charts from third parties
├── scripts/
│   ├── sync-chart.sh   # Manual chart synchronization script
│   ├── validate-charts.sh # Local validation of all charts
│   ├── update-gitops-promoter.sh # Custom updater for the gitops-promoter chart
│   └── synch-config.yaml # Record of tracked external charts (not read by sync-chart.sh)
├── hack/rules-and-dashboards/ # Generator for kubecore-observability-rules
├── (no .github/: CI runs in Argo Workflows, defined in novelcore/kaos)
├── init.sh            # Repository initialization script
└── README.md          # Main documentation
```

## Working with Custom Charts

### Creating a New Custom Chart

When a user wants to create a new custom chart:

1. **Navigate to custom charts directory**:
   ```bash
   cd charts/custom/
   ```

2. **Create new chart scaffold**:
   ```bash
   helm create <chart-name>
   ```

3. **Follow chart development standards**:
   - Include comprehensive `README.md`
   - Define all configurable values in `values.yaml` with comments
   - Include `NOTES.txt` for post-installation instructions
   - Follow [Helm best practices](https://helm.sh/docs/chart_best_practices/)
   - Ensure chart passes `helm lint` validation

4. **Test locally before committing**:
   ```bash
   helm lint charts/custom/<chart-name>
   helm install test-release charts/custom/<chart-name> --dry-run --debug
   ct lint --charts charts/custom/<chart-name>
   ```

### Custom Chart Standards

All custom charts MUST include:
- **Chart.yaml**: Proper metadata with version, description, maintainers
- **values.yaml**: Well-documented default values with comments
- **templates/**: Kubernetes manifests with proper templating
- **README.md**: Installation and configuration documentation
- **NOTES.txt**: Post-installation instructions and helpful information

## Working with External Charts

### Understanding External Chart Sync

`scripts/synch-config.yaml` records the tracked external charts (the sync script does not read it; run `helm repo add` for the upstream repo first):

```yaml
repositories:
  - name: bitnami
    url: https://charts.bitnami.com/bitnami
  - name: crossplane-stable
    url: https://charts.crossplane.io/stable

charts:
  - name: crossplane
    repository: crossplane-stable
    version: "1.20.0"  # Specific version or empty for latest
```

### Adding New External Charts

When a user wants to add a new external chart:

1. **Edit the sync configuration**:
   ```bash
   # Edit scripts/synch-config.yaml
   # Add repository if not already present
   # Add chart configuration
   ```

2. **Repository entry format**:
   ```yaml
   repositories:
   - name: <repo-name>
     url: <helm-repo-url>
   ```

3. **Chart entry format**:
   ```yaml
   charts:
   - name: <chart-name>
     repository: <repo-name>
     version: "<version>"  # Leave empty for latest
   ```

### Manual Chart Synchronization

For immediate sync needs, use the sync script:

```bash
# Sync latest version
./scripts/sync-chart.sh <repo-name> <chart-name>

# Sync specific version
./scripts/sync-chart.sh <repo-name> <chart-name> <version>

# Example
./scripts/sync-chart.sh bitnami postgresql 12.1.5
```

## CI/CD

There are no GitHub Actions. CI runs in Argo Workflows (defined in `novelcore/kaos`,
`kubetools/system/argo-workflows/ci/overlays/dev/charts-ci/`) and reports as commit statuses.

- `charts/validate` on every open PR: chart test suites, `ct lint` (version-increment check: any change under a chart directory needs a `Chart.yaml` version bump), render of changed charts. Merge only after it reports success.
- `charts/release` on every commit on `main`: package all charts, update `gh-pages` and the index at
  `https://novelcore.github.io/charts/`, push `kubecore-observability-rules` to GHCR when a token exists.
- External chart sync is manual (`scripts/sync-chart.sh`); there is no scheduled job.

## Repository Usage Patterns

### For End Users (Chart Consumers)

```bash
# Add the repository
helm repo add novelcore https://novelcore.github.io/charts/ \
  --username <github-username> \
  --password <github-token>

# Update repository index
helm repo update

# Search for charts
helm search repo novelcore

# Install a chart
helm install my-release novelcore/<chart-name>
```

### For Chart Developers

1. **Custom Chart Development**:
   - Create in `charts/custom/`
   - Follow established standards
   - Test locally before committing
   - CI/CD handles packaging and publishing

2. **External Chart Management**:
   - Update `synch-config.yaml`
   - Use manual sync for immediate needs
   - Review and merge the PRs you open for sync updates

## Security Considerations

- **Private Repository**: Requires GitHub authentication for access
- **Security Scanning**: on-demand chart CVE scans via the `.claude/agents/chart-cve-*` agents (Trivy)
- **Credential Management**: Never commit sensitive files (*.pem, *.key, secrets.yaml)
- **Access Control**: Use GitHub Personal Access Tokens or GitHub Apps

## Troubleshooting Common Issues

### Chart Sync Issues
- Verify repository URLs in `synch-config.yaml`
- Check if upstream chart exists and version is valid
- Ensure helm repositories are accessible

### Build Failures
- Check chart lint errors: `helm lint charts/<type>/<chart-name>`
- Verify all dependencies are available
- Open the Argo run linked from the `charts/validate` status for specific errors

### Repository Access Issues
- Verify GitHub token has proper permissions
- Check if GitHub Pages is enabled
- Ensure repository visibility settings are correct

## Best Practices for Cursor Agent

1. **Always validate charts locally** before committing
2. **Use the sync script** for external chart management rather than manual copying (add the Helm repo first; the script does not read `synch-config.yaml`)
3. **Follow the established directory structure** strictly
4. **Include comprehensive documentation** for any new charts
5. **Test chart installations** in development environments
6. **Monitor the `charts/validate` / `charts/release` statuses** (Argo runs) for any failures
7. **Keep sync configuration updated** with proper versions
8. **Review security scan results** and address vulnerabilities

## File Patterns to Recognize

- `charts/custom/**/Chart.yaml`: Custom chart definitions
- `charts/external/**/Chart.yaml`: External chart definitions (with syncMetadata)
- `scripts/synch-config.yaml`: External chart sync configuration
- CI/CD: Argo Workflows in `novelcore/kaos` (`kubetools/system/argo-workflows/ci/overlays/dev/charts-ci/`)
- `*.tgz`: Packaged chart files (ignored in git)
- `values.yaml`: Chart configuration files

## Commands Reference

```bash
# Chart development
helm create <chart-name>
helm lint <chart-path>
helm package <chart-path>
helm install <release> <chart-path> --dry-run

# Repository management
./scripts/sync-chart.sh <repo> <chart> [version]
helm repo index . --url <base-url>

# Testing
ct lint --charts <chart-path>
ct install --charts <chart-path>
```

This repository packages and publishes charts automatically from `main` and gates PRs on `charts/validate`.