# Novelcore Helm Charts Repository

This repository contains Helm charts for the Novelcore organization, including both custom charts and curated external charts.

## Repository URL

```bash
https://novelcore.github.io/charts/
```
## Usage

### Adding the Repository

```bash
# For public access (if repository is public)
helm repo add novelcore https://novelcore.github.io/charts/
helm repo update

# For private access (using GitHub token)
helm repo add novelcore https://novelcore.github.io/charts/ \
  --username YOUR_GITHUB_USERNAME \
  --password YOUR_GITHUB_TOKEN
helm repo update
```

### Installing Charts

```bash
# Search for available charts
helm search repo novelcore

# Install a chart
helm install my-release novelcore/CHART_NAME

# Install with custom values
helm install my-release novelcore/CHART_NAME -f values.yaml
```

## Repository Structure

```
├── charts/
│   ├── custom/         # Custom Novelcore charts
│   └── external/       # Synced external charts
├── scripts/           # Utility scripts
├── scripts/synch-config.yaml   # External chart sync configuration
└── ct.yaml           # Chart testing configuration
```

## For Chart Developers

### Creating a New Custom Chart

1. Create your chart in the `charts/custom/` directory:
   ```bash
   cd charts/custom/
   helm create my-chart
   ```

2. Develop and test your chart locally
3. Commit and push to main branch
4. The CI/CD pipeline will automatically package and publish your chart

### Chart Standards

All charts should follow these standards:
- Include comprehensive `README.md`
- Define all configurable values in `values.yaml` with comments
- Include `NOTES.txt` for post-installation instructions
- Follow [Helm best practices](https://helm.sh/docs/chart_best_practices/)
- Pass `helm lint` validation

### Testing Charts Locally

```bash
# Lint your chart
helm lint charts/custom/my-chart

# Test installation in a local cluster
helm install test-release charts/custom/my-chart --dry-run --debug

# Use chart-testing tool
ct lint --charts charts/custom/my-chart
```

## Syncing External Charts

External charts are synced by hand; there is no scheduled job.

### Manual Sync

To manually sync a specific chart:

```bash
# Sync latest version
./scripts/sync-chart.sh bitnami postgresql

# Sync specific version
./scripts/sync-chart.sh bitnami postgresql 12.1.5
```

### Adding New External Charts

1. Edit `scripts/synch-config.yaml`
2. Add the repository (if not already present) and chart details
3. Run `scripts/sync-chart.sh` and open a PR

## CI/CD

CI runs in Argo Workflows (the repository has no GitHub Actions). It is defined in `novelcore/kaos`
under `kubetools/system/argo-workflows/ci/overlays/dev/charts-ci/` and reports as commit statuses.

### `charts/validate` (every open PR)
- Runs the chart test suites, `ct lint` and renders every changed chart
- The status link opens the run in the Argo Workflows UI

### `charts/release` (every commit on `main`)
- Packages all charts, updates the Helm repository index and publishes to GitHub Pages
- Pushes `kubecore-observability-rules` to GHCR when a package token is configured

### External charts
- Synced by hand with `scripts/sync-chart.sh`; there is no scheduled job

A poller submits the runs every 2 minutes, so a status can take up to two minutes to appear.

## Private Repository Access

Since this is a private repository, users need to authenticate:

### Using Personal Access Token (Recommended)

1. Create a GitHub Personal Access Token with `repo` scope
2. Use it as password when adding the Helm repository:
   ```bash
   helm repo add novelcore https://novelcore.github.io/charts/ \
     --username YOUR_GITHUB_USERNAME \
     --password YOUR_GITHUB_TOKEN
   ```

### Using GitHub App

For production use, consider creating a GitHub App with read access to the repository.

## Security

- All charts are scanned for security vulnerabilities using Trivy
- External charts are reviewed before syncing
- GitHub secrets are used for sensitive operations

## Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Submit a pull request

All PRs must pass:
- Chart linting
- Security scanning
- Installation testing (if applicable)

## License

[Specify your license here]

## Support

For issues and questions:
- Create an issue in this repository
- Contact the Novelcore platform team
