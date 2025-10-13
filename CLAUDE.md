# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This is a Helm Charts Repository that manages both **custom charts** (organization-specific) and **external charts** (synced from upstream). Charts are automatically packaged and published to GitHub Pages at `https://novelcore.github.io/charts/`.

## Architecture Overview

### Two-Track Chart Management

1. **Custom Charts** (`charts/custom/`): Organization-developed charts like `gitops-promoter` and `argo-cd-with-rollouts`
2. **External Charts** (`charts/external/`): Curated third-party charts synced from upstream repos (Bitnami, Argo, etc.)

### Sync Metadata System

External charts include `syncMetadata` in their Chart.yaml to track:
- `source`: Original repository location
- `syncedAt`: Timestamp of last sync
- `syncedVersion`: Version that was synced

This allows tracking drift from upstream sources.

### CI/CD Automation

Three GitHub Actions workflows handle the full lifecycle:

1. **release-charts.yml**: Triggers on push to main, packages all charts and publishes to gh-pages branch
2. **sync-external-charts.yml**: Runs daily at 2 AM UTC, syncs charts based on `scripts/synch-config.yaml` config
3. **validate-charts.yml**: Runs on PRs, performs linting, security scanning with Trivy, and installation testing

## Common Commands

### Chart Development

```bash
# Create new custom chart
cd charts/custom/
helm create <chart-name>

# Lint chart
helm lint charts/custom/<chart-name>

# Dry-run test installation
helm install test-release charts/custom/<chart-name> --dry-run --debug

# Test with chart-testing tool
ct lint --charts charts/custom/<chart-name>

# Template rendering test
helm template test charts/custom/<chart-name>

# Update chart dependencies
helm dependency update charts/custom/<chart-name>

# Local validation script (validates all charts)
./scripts/validate-charts.sh
```

### External Chart Management

```bash
# Manual sync of external chart (latest version)
./scripts/sync-chart.sh <repo-name> <chart-name>

# Manual sync of specific version
./scripts/sync-chart.sh <repo-name> <chart-name> <version>
# Example: ./scripts/sync-chart.sh bitnami postgresql 12.1.5

# Update GitOps Promoter to new version (custom updater)
./scripts/update-gitops-promoter.sh v0.11.0
```

### Repository Initialization

```bash
# Initialize gh-pages branch for GitHub Pages hosting
./init.sh
```

## Key Configuration Files

### scripts/synch-config.yaml

Central configuration for external chart synchronization. Structure:

```yaml
repositories:
  - name: <repo-name>
    url: <helm-repo-url>

charts:
  - name: <chart-name>
    repository: <repo-name>
    version: "<version>"  # Empty string "" for latest

sync:
  preserveLocal: true
  createPR: true
  autoMerge: false
```

To add new external chart: add repository entry (if new), add chart entry, commit changes. Daily sync workflow will create PR with updates.

### ct.yaml

Configuration for chart-testing tool. Defines:
- Target branch: main
- Chart directories: `charts/custom`, `charts/external`
- Helm repos for dependencies
- Linting config: `.yamllint.yaml`

## Chart Standards

All custom charts must include:
- **Chart.yaml**: Proper semver version, appVersion, maintainers, keywords, home/sources URLs
- **values.yaml**: Extensively commented default values
- **templates/**: Kubernetes manifests with Helm templating
- **README.md**: Installation guide, configuration options, examples
- **NOTES.txt**: Post-install instructions displayed to users

## Special Chart: gitops-promoter

This custom chart wraps the GitOps Promoter from argoproj-labs. Special handling:

- **Custom update script**: `scripts/update-gitops-promoter.sh` downloads upstream manifests and converts to Helm templates
- **CRD management**: CRDs in `crds/` directory and `templates/crds.yaml` with Helm hooks
- **Backup on update**: Script creates timestamped backup before updating
- **Cleanup script**: `scripts/cleanup-gitops-promoter-crds.sh` for CRD removal

When updating: use the update script rather than manual edits, it handles version bumps, image updates, and manifest conversions automatically.

## Special Chart: argo-cd-with-rollouts

This custom chart bundles Argo CD with Argo Rollouts as a dependency:

- **Dependency**: Pulls argo-rollouts from `https://novelcore.github.io/charts/` (self-referential)
- **Conditional rollouts**: Enabled via `rollouts.enabled` in values
- **Sync metadata**: Tracks upstream argo-cd chart version from Argo Helm repo

## Workflow Patterns

### Adding External Chart

1. Edit `scripts/synch-config.yaml`
2. Add repository if not present
3. Add chart with name, repository, version
4. Commit and push
5. Either wait for daily sync or manually trigger workflow
6. Review PR created by sync workflow
7. Merge PR to trigger release workflow

### Updating Custom Chart

1. Make changes in `charts/custom/<chart-name>/`
2. Bump `version` in Chart.yaml (semver)
3. Update `appVersion` if application version changed
4. Test locally with lint and dry-run
5. Commit and push to main
6. Release workflow automatically packages and publishes

### Version Bumping Strategy

- **Chart version**: Semantic versioning for the Helm chart itself (template/config changes)
- **App version**: Version of the application being deployed
- Chart version increment: patch for fixes, minor for features, major for breaking changes

## Private Repository Access

Repository is private, requiring authentication:

```bash
# Add repository with GitHub token
helm repo add novelcore https://novelcore.github.io/charts/ \
  --username <github-username> \
  --password <github-token>

# Update and use
helm repo update
helm search repo novelcore
```

Token needs `repo` scope for private repository access.

## Dependencies and Tools

Required tools for local development:
- `helm` (v3.13.0+ recommended)
- `yq` (for YAML processing in scripts)
- `ct` (chart-testing tool, optional but recommended)
- `trivy` (for security scanning, optional)

All scripts include requirement checks and will error with helpful messages if tools are missing.

## Security Notes

- All charts are scanned with Trivy in CI/CD
- Never commit sensitive files: `.env`, `*.key`, `*.pem`, `secrets.yaml`
- External charts are reviewed via PR before merge
- GitHub secrets used for automation tokens

## Important File Locations

- Chart definitions: `charts/{custom,external}/*/Chart.yaml`
- Chart values: `charts/{custom,external}/*/values.yaml`
- External sync config: `scripts/synch-config.yaml`
- CI/CD workflows: `.github/workflows/*.yml`
- Helper scripts: `scripts/*.sh`
- Testing config: `ct.yaml`
- YAML linting: `.yamllint.yaml`
