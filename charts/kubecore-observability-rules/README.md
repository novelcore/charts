# kubecore-observability-rules

KubeCore observability rules and dashboards from external sources.

This Helm chart automatically generates VMRule and GrafanaDashboard CRDs from external sources (kube-prometheus, VictoriaMetrics, community dashboards) following the victoriametrics-k8s-stack pattern.

## Features

- **Automatic Rule Generation**: Downloads and transforms alerting rules from kube-prometheus and VictoriaMetrics
- **Automatic Dashboard Generation**: Downloads and transforms dashboards from VictoriaMetrics and community sources
- **Gzip Support**: Large dashboards (>100KB) are automatically compressed using `gzipJson` field
- **Parameter Injection**: Rules support parameter injection (cluster, environment, namespace)
- **Hierarchical Configuration**: Global → group → rule level configuration support
- **Conditional Generation**: Rules and dashboards can be conditionally enabled/disabled

## Usage

### Basic Installation

```yaml
defaultRules:
  create: true
  clusterLabel: "cluster"
  clusterName: "my-cluster"
  
defaultDashboards:
  enabled: true
  defaultDatasource: "victoriametrics"
  instanceSelector:
    matchLabels:
      app: grafana
```

### Advanced Configuration

```yaml
defaultRules:
  create: true
  clusterLabel: "cluster"
  clusterName: "production-cluster"
  environment: "production"
  additionalGroupByLabels: ["region", "zone"]
  
  groups:
    kubernetes-nodes:
      create: true
      rules:
        NodeDown:
          create: true
          spec:
            for: 10m
            labels:
              severity: critical
  
defaultDashboards:
  enabled: true
  defaultTimezone: "utc"
  defaultDatasource: "victoriametrics"
  multicluster: false
  
  dashboards:
    victoriametrics-single-node:
      enabled: true
      folderRef: "observability"
    kubernetes-cluster:
      enabled: true
```

## Generated Files

The chart uses pre-generated files from `hack/rules-and-dashboards/main.go`:

- `files/rules/generated/*.yaml` - Alerting rules
- `files/dashboards/generated/*.yaml` - Grafana dashboards

These files are generated from external sources and committed to the repository.

## Regenerating Rules and Dashboards

To regenerate rules and dashboards from external sources:

```bash
cd hack/rules-and-dashboards
go run main.go
```

Or using Docker:

```bash
make hack
```

## Chart Publishing

The chart is automatically published to `ghcr.io/novelcore/charts` when changes are pushed to the `main` branch via the `release-charts.yml` workflow.

## Dependencies

- VictoriaMetrics Operator (for VMRule CRDs)
- Grafana Operator (for GrafanaDashboard CRDs)

