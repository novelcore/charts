# Helm Charts Repository - Cursor Agent Guide

## Repository Overview

This is a **Helm Charts Repository** that manages both **custom charts** and **external charts** from third-party repositories. The repository provides automated synchronization, packaging, and publishing of Helm charts to a private GitHub Pages-hosted Helm repository.

### Key Capabilities
- **Custom Chart Development**: Create and maintain organization-specific Helm charts
- **External Chart Curation**: Automatically sync and manage external charts from upstream repositories
- **Automated CI/CD**: Full automation for chart validation, packaging, and publishing
- **Security Scanning**: Built-in security scanning with Trivy
- **Chart Testing**: Comprehensive testing with chart-testing (ct) tool

## Repository Structure

```
charts/
├── charts/
│   ├── custom/         # Organization-specific custom charts
│   └── external/       # Synced external charts from third parties
├── scripts/
│   ├── sync-chart.sh   # Manual chart synchronization script
│   └── synch-config.yaml # External chart sync configuration
├── .github/workflows/  # CI/CD automation
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

External charts are managed through `scripts/synch-config.yaml` configuration file:

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

## CI/CD Workflows

### 1. Release Charts Workflow (`release-charts.yml`)

**Triggers**: Push to main branch affecting charts/, manual dispatch
**Purpose**: Package and publish all charts to GitHub Pages

**Process**:
- Packages all custom and external charts
- Updates Helm repository index
- Publishes to GitHub Pages at `https://novelcore.github.io/charts/`

### 2. Sync External Charts Workflow (`sync-external-charts.yml`)

**Triggers**: Daily at 2 AM UTC, manual dispatch with optional parameters
**Purpose**: Automatically sync external charts from upstream repositories

**Features**:
- Reads configuration from `synch-config.yaml`
- Creates pull requests for chart updates
- Supports syncing specific charts or all configured charts
- Adds sync metadata to Chart.yaml files

### 3. Validate Charts Workflow (`validate-charts.yml`)

**Triggers**: Pull requests and pushes affecting charts/
**Purpose**: Comprehensive chart validation and testing

**Validation Steps**:
- Chart linting with `helm lint`
- Chart testing with `ct` (chart-testing)
- Security scanning with Trivy
- Installation testing in kind cluster

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
   - Monitor sync workflow PRs
   - Review and merge sync updates

## Security Considerations

- **Private Repository**: Requires GitHub authentication for access
- **Security Scanning**: All charts scanned with Trivy for vulnerabilities
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
- Review workflow logs for specific errors

### Repository Access Issues
- Verify GitHub token has proper permissions
- Check if GitHub Pages is enabled
- Ensure repository visibility settings are correct

## Best Practices for Cursor Agent

1. **Always validate charts locally** before committing
2. **Use the sync script** for external chart management rather than manual copying
3. **Follow the established directory structure** strictly
4. **Include comprehensive documentation** for any new charts
5. **Test chart installations** in development environments
6. **Monitor CI/CD workflows** for any failures
7. **Keep sync configuration updated** with proper versions
8. **Review security scan results** and address vulnerabilities

## File Patterns to Recognize

- `charts/custom/**/Chart.yaml`: Custom chart definitions
- `charts/external/**/Chart.yaml`: External chart definitions (with syncMetadata)
- `scripts/synch-config.yaml`: External chart sync configuration
- `.github/workflows/*.yml`: CI/CD automation
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

This repository follows enterprise-grade practices for Helm chart management with full automation, security scanning, and proper versioning controls.