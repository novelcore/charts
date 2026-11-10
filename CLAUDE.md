# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Purpose

This is a Helm Charts Repository that manages both **custom charts** (organization-specific) and **external charts** (synced from upstream). Charts are automatically packaged and published to GitHub Pages at `https://novelcore.github.io/charts/`.

## Architecture Overview

### Two-Track Chart Management

1. **Custom Charts** (`charts/custom/`): Organization-developed charts: `gitops-promoter`, `argo-cd-with-rollouts`, `kubecore-ci-workflows`, `kubecore-e2e-canary`, `kaos-osr-edge-operator` and `kubecore-operator` (a frozen snapshot, see below). `charts/kubecore-observability-rules/` is also first-party but sits outside `charts/custom` (so `ct.yaml` does not cover it).
2. **External Charts** (`charts/external/`): Curated third-party charts synced from upstream repos (Bitnami, Argo, etc.)

### Sync Metadata System

External charts include `syncMetadata` in their Chart.yaml to track:
- `source`: Original repository location
- `syncedAt`: Timestamp of last sync
- `syncedVersion`: Version that was synced

This allows tracking drift from upstream sources.

### CI/CD Automation

There are **no GitHub Actions** in this repository (platform rule: all CI runs in Argo Workflows). The pipeline lives in the `novelcore/kaos` repo, `kubetools/system/argo-workflows/ci/overlays/dev/charts-ci/`, and runs on the dev hub:

1. **charts-validate**: every open PR head gets a `charts/validate` commit status (pending, then success/failure) whose link opens the Argo run. It runs the chart test suites under `charts/custom/*/tests`, `ct lint` (with `check-version-increment: true`, so ANY change under `charts/custom/<chart>/` or `charts/external/<chart>/`, docs included, needs a `Chart.yaml` `version` bump), and renders every changed chart. A PR that reports no status has not been checked; wait for it.
2. **charts-release**: every commit on `main` gets a `charts/release` status; the run packages all charts, updates `gh-pages` (retention, `helm repo index`) and pushes `kubecore-observability-rules` to GHCR when a PAT is configured.
3. **External chart sync** is manual: `scripts/sync-chart.sh` (the old daily workflow never synced anything).

A poller (`charts-poll`, every 2 minutes) submits the runs, so a status can appear up to two minutes after a push or merge.

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

Record of which external charts and upstream repositories this repo tracks (`scripts/sync-chart.sh <repo> <chart> [version]` adds the repositories listed here, then syncs the named chart; the chart pins themselves are recorded here, not read from it). Structure:

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

To add new external chart: add repository entry (if new), add chart entry, run `helm repo add <name> <url>` locally, run `scripts/sync-chart.sh <repo> <chart> [version]` to pull it in, then open a PR.

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
- **CRD management**: the 12 CRDs live in `crds/promoter-crds.yaml` (Helm installs them first and never deletes them); `templates/crds.yaml` is disabled (`{{- if false }}`) and `crds.keep` has no effect
- **Backup on update**: Script creates a timestamped backup before updating (current chart 0.8.4, promoter v0.22.6)
- **Cleanup script**: `scripts/cleanup-gitops-promoter-crds.sh` for CRD removal (its CRD list matches the 12 CRDs in `crds/`)

When updating: use the update script rather than manual edits, it handles version bumps, image updates, and manifest conversions automatically.

## Special Chart: argo-cd-with-rollouts

This custom chart bundles Argo CD with Argo Rollouts as a dependency:

- **Dependency**: Pulls argo-rollouts from `https://novelcore.github.io/charts/` (self-referential) and redis-ha
- **Conditional rollouts**: Enabled via `rollouts.enabled` in values
- **Sync metadata**: Tracks upstream argo-cd chart version from Argo Helm repo
- **No templates**: the chart has no `templates/` directory, so it does not render Argo CD itself; its README still describes an Argo CD + Rollouts install, and `rollouts.controller.*`/`rollouts.dashboard.*` in values.yaml are not passed to the subchart (subchart values go under `argo-rollouts:`). `ct lint` cannot build its dependencies (redis-ha and novelcore repos are not in `ct.yaml`), so any edit under this directory fails `charts/validate` until that is fixed

## Special Chart: kubecore-ci-workflows

Argo ClusterWorkflowTemplates for the platform CI (`ml-ci-build`, `ml-ci-reconcile`, `ml-ci-pr-render`, service-app templates, janitors). It is rolled out by the kubecore-operator, not installed by hand: `internal/operators/kubepool/phases/syncing_tools.go` in `novelcore/kubecore-operator` pins an exact chart version (currently 0.12.151, equal to this chart's `Chart.yaml` on `main`, kubecore-operator#1732). Pin bumps in the operator are manual PRs, so a chart version that is newer than the operator's pin is not yet deployed. Because of that lockstep, avoid docs-only bumps of this chart.

- `platformEnhancer.repo` / `platformEnhancer.ref` (values.yaml): the `hera-pipeline-template` commit (full 40-char sha) whose `kubecore/` enhancer `ml-ci-build` and `ml-ci-pr-render` run for every app (kubecore-operator#1161). Moving `ref` rolls an enhancer change out to all apps: each app's `ml-ci-reconcile` sees its recorded `enhancer-ref` differ and re-renders within a poll, no push needed (kubecore-operator#1199). Current pin: `032e00af2a56391083123c93cfcbdd293ee5fdc9` (0.12.149: the checkpoint helper ships once per app as the ConfigMap `{app}-ckpt-helper` instead of inside every step); previous pin `b61f049e19c5fdb90c46deecde08b60f19bb1aeb` (charts#201, 0.12.145: the enhancer refuses client-set `serviceAccountName`, `podSpecPatch` and reserved template names, D-79 F-37).
- Platform pipeline engine (0.12.151, PRD-HPC-1461 D-79 F-50/F-51, release 1 of 2): a platform change to rendering or enhancing must never need a commit in a client app repository, so CI can render and enhance with ONE engine release (`kaos-pipeline-engine`: an image and a wheel, built by kaos-hpc-operator at the controller's version) instead of the app's vendored `kubecore/`. The operator writes `engine: {version, image, wheel, wheelSha256, mode}` into every ML app's gitops `pipeline-context.yaml` (kubecore-operator#1752); the mode is `legacy` (today's path, byte for byte), `shadow` or `engine`. `files/engine.py` (data only, `python3 -I`; pytest in `tests/engine`) decides in `detect-steps` (merge) and `detect-engine` (PR render): the mode actually used (an app is HELD at `legacy` with a reason when the pin has no wheel, no schema profile can be told, or its `steps/compose_and_validate/Dockerfile` is not the platform's, `CustomComposeDockerfile`), the schema profile (git blob sha of the app's vendored `derive_tree.py` against the wheel's `known-vendored.json`; unknown blob: the template from the `pyproject.toml` name; otherwise none), `vendored` (`pristine|modified|absent`) and `compose_dockerfile`. The decision is an immutable Argo parameter: nothing the untrusted render writes is read back for a decision. A wheel that does not download or whose sha256 differs from the context FAILS the build (the live WorkflowTemplate stays: stale, not broken); legacy never fetches anything and never fails. Mode `engine`: `hera-render-engine` (tokenless, same trust boundary as `hera-render`) runs the app's `pipeline.py` in the engine image through `python -I -m kaos_engine.render` (the app's vendored `kubecore/` is never imported; no `pip install -e .`: only pyproject dependencies the engine lacks are installed, under the engine's own versions as constraints), and `hera-enhance-commit`/`hera-enhance-gate` enhance from the engine wheel (download, sha256, unzip, no pip) instead of the GitHub tarball of `platformEnhancer.ref`, then stamp the WFT (annotation `platform.kubecore.io/engine-version` and `spec.workflowMetadata.labels["platform.kubecore.io/engine"]`, the label the removal gate counts on running Workflows). Mode `shadow`: the legacy render is committed; the engine render is enhanced by the wheel and compared as parsed YAML (`engine-shadow: equal|differs:<n>|failed`). `{app}-pipeline-images` records `engine-mode` (effective mode), `engine-version` (engine mode only), `engine-shadow` (shadow only) and `engine-vendored` (shadow/engine); an app with no engine block is not touched. `enhancer-ref` keeps being recorded while legacy/shadow and is left alone in engine mode (`ml-ci-reconcile` skips ENHANCER DRIFT for a recorded `engine-mode: engine`). The PR render passes `engine_image` through and warns on the `pipeline-lint` status and comment when an engine-mode app edited its vendored `kubecore/` (ignored). Compose, the raw WorkflowTemplate record and the per-engine-version reconcile guard are release 2. Tests: `tests/engine` (pytest), `tests/engine-ci` (scripts executed against a fixture wheel, stubs and a loopback server), `tests/pipeline-lint`, `tests/enhancer-drift`; `tests/engine-ci/real-engine.sh` is an opt-in local run against a real engine wheel and real template checkouts (no Docker).
- `wftSize.limitKiB` (values.yaml, 0.12.149, default 900): `ml-ci-build`'s `hera-enhance-commit` and `ml-ci-pr-render`'s `hera-enhance-gate` fail a render whose `workflow-template.yaml` is over this many KiB, naming the biggest templates (etcd's object limit is ~1.5 MiB). The size is recorded as `wft-bytes` in `{app}-pipeline-images` and shown in the PR status. The merge build also commits `ckpt-helper.yaml` (the helper ConfigMap the enhancer writes) beside the WFT, staging it only when it exists or is tracked (0.12.150: an unconditional `git add -A -- ckpt-helper.yaml` exits 128 for an app without the helper and failed every such first build); Argo CD applies the whole app directory, with server-side apply since kubecore-operator's ml ApplicationSet sets it (the 256 KiB last-applied annotation no longer applies). Test: `tests/wft-size/run.sh`.
- `pipelineLint` (values.yaml, 0.12.146-0.12.148, PRD-CONSOLE-1682): `ml-ci-pr-render` runs the kaos-lib pipeline linter for Hera apps only and posts the advisory `pipeline-lint` commit status plus one PR comment (updated in place); it is in no ruleset. The pin is an exact kaos-lib wheel URL + sha256 + `rulesetVersion` (now 0.4.0rc22, rule set 1.2.0, which includes the Dockerfile doctor L-D01..L-D08). Resumability comes from platform evidence (`hpc.resumableSteps` in the gitops `pipeline-context.yaml`), not imports. Bump the wheel and sha256 together; `tests/pipeline-lint/run.sh` checks them.
- HPC (Slurm) steps render with the controller-only follower template `hpc-follower` (formerly `meluxina-run`; the in-pod Slurm submitter was retired in 0.12.144, AC-12). Renders carry no Slurm token or submitter.
- `ci.reconcileDeadlineSeconds`, the ci-sync wait on the per-app build lock and the other mechanics are in `charts/custom/kubecore-ci-workflows/README.md`.
- Tests: 19 suites, each `charts/custom/kubecore-ci-workflows/tests/<suite>/run.sh` (render guards, check-drift against stubs, `connections` golden files via pytest, `enhancer-drift`, `sync-wait` incl. a kind-based Argo run). `scripts/check-borrowed-template-params.py` (run from the repo root) fails when a workflow that borrows a template via `templateRef` does not declare the workflow parameters that template reads.

## Special Chart: kubecore-operator (frozen snapshot)

`charts/custom/kubecore-operator` was last refreshed by "chore: update kubecore-operator chart to v0.108.6" (2026-10-13) and has not been refreshed since. The current operator chart (`dist/chart` in `novelcore/kubecore-operator`) is built by the dev hub's Argo `ci-operator` and published as an OCI chart to the dev registry; prod installs it by digest through the kaos `release/prod` branch. Do not edit this directory to track the operator (it would need a version bump and would not reach any cluster); its README and values describe 0.108.6 and lag the operator chart (for example it has no `HPC_*` env documentation, no `brokerAuth`/`podGuard`, and `values.schema.json` still lists `crossplane`/`crossplaneFunctions` values that no longer exist: Crossplane and its functions are managed separately by kaos; compositions arrive through the `compositions.package` Configuration). `archive/` there holds 2025-11 investigation notes about chart 0.1.5 to 0.1.7 on EKS and is obsolete.

## Special Chart: kubecore-e2e-canary and kaos-osr-edge-operator

`kubecore-e2e-canary` (see its README) is an e2e-only fault-injection Deployment rendered by the operator behind `--enable-e2e-faults`. `kaos-osr-edge-operator` (0.4.1) is the OSR edge operator chart; it has no README yet.

## Special Chart: kubecore-observability-rules

Lives in `charts/kubecore-observability-rules/` (not under `charts/custom`). VMRule and GrafanaDashboard files are generated by `hack/rules-and-dashboards` (`make -C hack/rules-and-dashboards hack-local` or `hack`) and committed. `charts/release` pushes it to GHCR when a package token is configured.

## Workflow Patterns

### Adding External Chart

1. Edit `scripts/synch-config.yaml`
2. Add repository if not present
3. Add chart with name, repository, version
4. `helm repo add <name> <url>` (the script does not read the config)
5. Run `scripts/sync-chart.sh <repo> <chart> [version]` on a branch and open a PR
6. Wait for the `charts/validate` status, then merge the PR to trigger `charts-release`

### Updating Custom Chart

1. Make changes in `charts/custom/<chart-name>/`
2. Bump `version` in Chart.yaml (semver)
3. Update `appVersion` if application version changed
4. Test locally with lint, template and the chart's own test suites
5. Open a PR to `main` (the trunk) and wait for `charts/validate` to report success
6. On merge, `charts-release` automatically packages and publishes to GitHub Pages

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

- Never commit sensitive files: `.env`, `*.key`, `*.pem`, `secrets.yaml`
- External charts are reviewed via PR before merge
- CI credentials are the org GitHub App token mounted in the Argo CI pods; none live in this repository

## Important File Locations

- Chart definitions: `charts/{custom,external}/*/Chart.yaml`
- Chart values: `charts/{custom,external}/*/values.yaml`
- External sync config: `scripts/synch-config.yaml`
- CI/CD: Argo Workflows, defined in `novelcore/kaos` (`kubetools/system/argo-workflows/ci/overlays/dev/charts-ci/`)
- Helper scripts: `scripts/*.sh`
- Testing config: `ct.yaml`
- YAML linting: `.yamllint.yaml`
