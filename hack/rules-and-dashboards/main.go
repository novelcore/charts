package main

import (
	"bytes"
	"compress/gzip"
	"encoding/base64"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"log"
	"net/http"
	"os"
	"path/filepath"
	"regexp"
	"strings"

	"github.com/VictoriaMetrics/metricsql"
	"gopkg.in/yaml.v2"
)

var chartsDir = flag.String("charts.dir", "../../charts", "path to charts dir")
var chartName = flag.String("chart.name", "kubecore-observability-rules", "name of the chart")

func targetDir(charts, chart, targetType string) string {
	return filepath.Join(
		charts,
		chart,
		"files",
		targetType,
		"generated",
	)
}

var ruleHeaders = `{{- $Values := (.helm).Values | default .Values }}
{{- $runbookUrl := ($Values.defaultRules).runbookUrl | default "https://runbooks.prometheus-operator.dev/runbooks" }}
{{- $clusterLabel := ($Values.defaultRules).clusterLabel | default ($Values.global).clusterLabel | default "cluster" }}
{{- $additionalGroupByLabels := append ($Values.defaultRules).additionalGroupByLabels $clusterLabel }}
{{- $groupLabels := join "," (uniq $additionalGroupByLabels) }}
{{- $clusterName := ($Values.defaultRules).clusterName | default "" }}
{{- $environment := ($Values.defaultRules).environment | default "" }}
{{- $namespace := ($Values.defaultRules).namespace | default "" }}
`

var dashboardHeaders = `{{- $Values := (.helm).Values | default .Values }}
{{- $multicluster := ($Values.defaultDashboards).multicluster | default false }}
{{- $defaultDatasource := ($Values.defaultDashboards).defaultDatasource | default "prometheus" }}
{{- $clusterLabel := ($Values.defaultDashboards).clusterLabel | default ($Values.global).clusterLabel | default "cluster" }}
{{- $clusterName := ($Values.defaultDashboards).clusterName | default "" }}
`

type source struct {
	url     string
	kind    string
	snippet string
	charts  []string
}

var sources = []source{
	// Rules from kube-prometheus
	{
		url:  "https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/kubernetesControlPlane-prometheusRule.yaml",
		kind: "rules",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/kubePrometheus-prometheusRule.yaml",
		kind: "rules",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/kubeStateMetrics-prometheusRule.yaml",
		kind: "rules",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/nodeExporter-prometheusRule.yaml",
		kind: "rules",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/alertmanager-prometheusRule.yaml",
		kind: "rules",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	// VictoriaMetrics rules
	{
		url:  "https://raw.githubusercontent.com/VictoriaMetrics/VictoriaMetrics/master/deployment/docker/rules/alerts-health.yml",
		kind: "rules",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/VictoriaMetrics/VictoriaMetrics/master/deployment/docker/rules/alerts-vmagent.yml",
		kind: "rules",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/VictoriaMetrics/VictoriaMetrics/master/deployment/docker/rules/alerts-vmalert.yml",
		kind: "rules",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/VictoriaMetrics/VictoriaMetrics/master/deployment/docker/rules/alerts.yml",
		kind: "rules",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/VictoriaMetrics/operator/master/config/alerting/vmoperator-rules.yaml",
		kind: "rules",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	// Dashboards from VictoriaMetrics
	{
		url:  "https://raw.githubusercontent.com/VictoriaMetrics/VictoriaMetrics/master/dashboards/victoriametrics.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/VictoriaMetrics/VictoriaMetrics/master/dashboards/vmagent.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/VictoriaMetrics/VictoriaMetrics/master/dashboards/victoriametrics-cluster.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/VictoriaMetrics/VictoriaMetrics/master/dashboards/vmalert.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/VictoriaMetrics/VictoriaMetrics/master/dashboards/operator.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/VictoriaMetrics/VictoriaMetrics/master/dashboards/backupmanager.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	// Dashboards from kube-prometheus
	{
		url:  "https://raw.githubusercontent.com/prometheus-operator/kube-prometheus/main/manifests/grafana-dashboardDefinitions.yaml",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	// Community dashboards
	{
		url:  "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-system-coredns.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-views-global.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-views-namespaces.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-views-pods.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-system-api-server.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
	{
		url:  "https://raw.githubusercontent.com/dotdc/grafana-dashboards-kubernetes/master/dashboards/k8s-views-nodes.json",
		kind: "dashboards",
		charts: []string{
			"kubecore-observability-rules",
		},
	},
}

type ruleCRD struct {
	Spec ruleSpec `yaml:"spec"`
}

type ruleSpec struct {
	Groups []ruleGroup `yaml:"groups"`
}

type ruleGroup struct {
	Name  string         `yaml:"name" json:"name"`
	Rules []rule         `yaml:"rules" json:"rules"`
	XXX   map[string]any `yaml:",inline"`
}

type rule struct {
	Rule        string            `yaml:"rule,omitempty" json:"rule,omitempty"`
	Alert       string            `yaml:"alert,omitempty" json:"alert,omitempty"`
	Expr        string            `yaml:"expr" json:"expr"`
	For         string            `yaml:"for,omitempty" json:"for,omitempty"`
	Labels      map[string]string `yaml:"labels,omitempty" json:"labels,omitempty"`
	Annotations map[string]string `yaml:"annotations,omitempty" json:"annotations,omitempty"`
	XXX         map[string]any    `yaml:",inline"`
}

func (r *rule) Name() string {
	if len(r.Rule) > 0 {
		return r.Rule
	}
	return r.Alert
}

var re = regexp.MustCompile("[ /-]+")

func main() {
	yaml.FutureLineWrap()

	for _, src := range sources {
		log.Printf("generating %s from %q", src.kind, src.url)
		var raw []byte
		var err error

		if strings.HasPrefix(src.url, "http://") || strings.HasPrefix(src.url, "https://") {
			resp, err := http.Get(src.url)
			if err != nil {
				log.Printf("skipping the file: %s", err)
				continue
			}
			defer resp.Body.Close()
			if resp.StatusCode != http.StatusOK {
				log.Printf("skipping the file, response code %d not equals 200", resp.StatusCode)
				continue
			}
			raw, err = io.ReadAll(resp.Body)
			if err != nil {
				log.Printf("error reading response body: %s", err)
				continue
			}
		} else {
			content, err := os.ReadFile(src.url)
			if err != nil {
				log.Printf("error reading file: %s", err)
				continue
			}
			raw = content
		}

		resources, err := collectResources(raw, &src)
		if err != nil {
			log.Printf("failed to collect resources: %s", err)
			continue
		}

		for n, data := range resources {
			if err := toFile(n, data, &src); err != nil {
				log.Printf("failed to create %s: %s", src.kind, err)
			}
		}
	}
}

func collectResources(raw []byte, src *source) (map[string][]byte, error) {
	switch src.kind {
	case "dashboards":
		return collectDashboards(raw, src)
	case "rules":
		return collectRules(raw, src)
	default:
		return nil, fmt.Errorf("unsupported source kind %q", src.kind)
	}
}

func collectRules(raw []byte, src *source) (map[string][]byte, error) {
	groups := make(map[string]*ruleGroup)
	ext := filepath.Ext(src.url)
	switch ext {
	case ".yml", ".yaml":
		var rr ruleCRD
		if err := yaml.Unmarshal(raw, &rr); err != nil {
			return nil, fmt.Errorf("failed to unmarshal yaml %s CRD: %w", src.kind, err)
		}
		if len(rr.Spec.Groups) == 0 {
			if err := yaml.Unmarshal(raw, &rr.Spec); err != nil {
				return nil, fmt.Errorf("failed to unmarshal yaml %s CRD: %w", src.kind, err)
			}
		}
		for _, g := range rr.Spec.Groups {
			groups[g.Name] = &g
		}
	default:
		return nil, fmt.Errorf("%s file extension %q is not supported", src.kind, ext)
	}

	resources := make(map[string][]byte)
	for n, g := range groups {
		// Process rules in the group
		for i := range g.Rules {
			r := &g.Rules[i]
			// Patch runbook URLs
			for ak, av := range r.Annotations {
				if strings.HasPrefix(av, "https://runbooks.prometheus-operator.dev/runbooks") {
					r.Annotations[ak] = strings.ReplaceAll(av, "https://runbooks.prometheus-operator.dev/runbooks", "{{ $runbookUrl }}")
				}
				if strings.Contains(av, "$labels.cluster") {
					r.Annotations[ak] = strings.ReplaceAll(av, "$labels.cluster", "$labels.{{ $clusterLabel }}")
				}
			}
			// Patch expressions to inject cluster labels
			expr, args := patchExpr(r.Expr, "rules")
			if len(args) > 0 {
				expr = fmt.Sprintf("{{ printf %q %s }}", expr, args)
			}
			r.Expr = expr

			// Add condition field
			if r.XXX == nil {
				r.XXX = make(map[string]any)
			}
			r.XXX["condition"] = true
		}

		// Add condition to group
		if g.XXX == nil {
			g.XXX = make(map[string]any)
		}
		g.XXX["condition"] = true

		data, err := yaml.Marshal(g)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal rule: %w", err)
		}
		resources[n] = escape(data)
	}
	return resources, nil
}

func collectDashboards(raw []byte, src *source) (map[string][]byte, error) {
	rawResources := make(map[string][]byte)
	ext := filepath.Ext(src.url)
	switch ext {
	case ".yml", ".yaml":
		// Handle dashboard CRD format
		var rd struct {
			Items []struct {
				Data map[string]string `yaml:"data" json:"data"`
			} `yaml:"items" json:"items"`
		}
		if err := yaml.Unmarshal(raw, &rd); err != nil {
			return nil, fmt.Errorf("failed to unmarshal yaml %s CRD: %w", src.kind, err)
		}
		for _, d := range rd.Items {
			for k, v := range d.Data {
				name := strings.TrimSuffix(k, filepath.Ext(k))
				rawResources[name] = []byte(v)
			}
		}
	case ".json":
		k := filepath.Base(src.url)
		name := strings.TrimSuffix(k, ext)
		rawResources[name] = raw
	default:
		return nil, fmt.Errorf("%s file extension %q is not supported", src.kind, ext)
	}

	resources := make(map[string][]byte)
	for n, v := range rawResources {
		var d map[string]any
		if err := json.Unmarshal(v, &d); err != nil {
			return nil, fmt.Errorf("failed to unmarshal dashboard: %w", err)
		}

		// Extract title for naming
		if title, ok := d["title"].(string); ok && len(title) > 0 {
			n = re.ReplaceAllString(strings.ToLower(title), "-")
		}

		// Patch dashboard
		patchDashboard(&d, n)

		// Compress large dashboards (>100KB)
		jsonBytes, err := json.Marshal(d)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal dashboard JSON: %w", err)
		}

		if len(jsonBytes) > 100000 {
			// Compress and base64 encode
			var buf bytes.Buffer
			gz := gzip.NewWriter(&buf)
			if _, err := gz.Write(jsonBytes); err != nil {
				return nil, fmt.Errorf("failed to compress dashboard: %w", err)
			}
			if err := gz.Close(); err != nil {
				return nil, fmt.Errorf("failed to close gzip writer: %w", err)
			}
			gzipB64 := base64.StdEncoding.EncodeToString(buf.Bytes())
			// Add gzipJson field to dashboard
			d["gzipJson"] = gzipB64
		}

		data, err := yaml.Marshal(&d)
		if err != nil {
			return nil, fmt.Errorf("failed to marshal dashboard: %w", err)
		}
		resources[n] = escape(data)
	}
	return resources, nil
}

func patchExpr(expr, kind string) (string, string) {
	if len(expr) == 0 {
		return expr, ""
	}
	e, err := metricsql.ParseWithVars(expr, true)
	if err != nil {
		log.Printf("failed to parse expression %q: %s", expr, err)
		return expr, ""
	}

	var args []string
	substitutions := map[string]string{
		"VAR__groupLabels":  `$groupLabels`,
		"VAR__clusterLabel": `$clusterLabel`,
	}

	// Visit all expressions and replace cluster labels
	metricsql.VisitAll(e, func(ex metricsql.Expr) {
		switch t := ex.(type) {
		case *metricsql.AggrFuncExpr:
			// Add cluster label to group by
			if t.Modifier.Op == "" {
				t.Modifier.Op = "by"
			}
			if t.Modifier.Op == "by" || t.Modifier.Op == "on" {
				var found bool
				for i := range t.Modifier.Args {
					if t.Modifier.Args[i] == "cluster" {
						found = true
						t.Modifier.Args[i] = "VAR__groupLabels"
					}
				}
				if !found {
					t.Modifier.Args = append(t.Modifier.Args, "VAR__groupLabels")
				}
			}
		case *metricsql.MetricExpr:
			// Replace cluster label filters
			for i := range t.LabelFilterss {
				for j := range t.LabelFilterss[i] {
					f := &t.LabelFilterss[i][j]
					if f.Label == "cluster" {
						f.Label = "VAR__clusterLabel"
					}
				}
			}
		}
	})

	result := string(e.AppendString(nil))
	search := result
	for {
		idx := strings.Index(search, "VAR__")
		if idx < 0 {
			break
		}
		search = search[idx:]
		for subst, val := range substitutions {
			if strings.HasPrefix(search, subst) {
				search = search[len(subst):]
				args = append(args, val)
				break
			}
		}
	}

	for subst := range substitutions {
		result = strings.ReplaceAll(result, subst, "%s")
	}
	return result, strings.Join(args, " ")
}

func patchDashboard(d *map[string]any, name string) {
	(*d)["editable"] = false
	if timezone, ok := (*d)["timezone"].(string); !ok || timezone == "" {
		(*d)["timezone"] = `{{ default "utc" ($Values.defaultDashboards).defaultTimezone }}`
	} else {
		(*d)["timezone"] = fmt.Sprintf(`{{ default %q ($Values.defaultDashboards).defaultTimezone }}`, timezone)
	}

	// Add tags
	if tags, ok := (*d)["tags"].([]any); ok {
		tags = append(tags, "kubecore-observability")
		(*d)["tags"] = tags
	} else {
		(*d)["tags"] = []any{"kubecore-observability"}
	}

	// Add condition
	(*d)["condition"] = true
}

type replacement struct {
	from []byte
	to   []byte
}

var replacements = []replacement{
	{
		from: []byte("{{"),
		to:   []byte("{{`{{"),
	},
	{
		from: []byte("}}"),
		to:   []byte("}}`}}"),
	},
	{
		from: []byte("{{`{{"),
		to:   []byte("{{`{{`}}"),
	},
	{
		from: []byte("}}`}}"),
		to:   []byte("{{`}}`}}"),
	},
	{
		from: []byte("<<"),
		to:   []byte("{{"),
	},
	{
		from: []byte(">>"),
		to:   []byte("}}"),
	},
}

func escape(v []byte) []byte {
	for _, r := range replacements {
		v = bytes.ReplaceAll(v, r.from, r.to)
	}
	return v
}

func toFile(name string, data []byte, src *source) error {
	for _, chart := range src.charts {
		dest := targetDir(*chartsDir, chart, src.kind)
		name = name + ".yaml"
		filename := filepath.Join(dest, name)
		if err := os.MkdirAll(dest, os.ModePerm); err != nil {
			return fmt.Errorf("failed to create dir: %w", err)
		}
		f, err := os.OpenFile(filename, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, 0644)
		if err != nil {
			return fmt.Errorf("failed to open file: %w", err)
		}
		var header string
		if src.kind == "rules" {
			header = ruleHeaders
		} else {
			header = dashboardHeaders
		}
		if _, err = f.WriteString(header); err != nil {
			return fmt.Errorf("failed to write header to file: %w", err)
		}
		if _, err = f.Write(data); err != nil {
			return fmt.Errorf("failed to write data to file: %w", err)
		}
		f.Close()
	}
	return nil
}
