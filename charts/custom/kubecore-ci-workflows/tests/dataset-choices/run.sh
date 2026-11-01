#!/usr/bin/env bash
# Tests for PRD novelcore/kaos#1283 D-05: hera-enhance-commit offers the project's datasets in
# the `dataset` dropdown from kaos-lake's read-only catalog, and never fails the render when the
# catalog cannot be read. The script under test is cut from the rendered chart and EXECUTED
# against a local fake catalog. Usage (from the repo root):
#
#   bash charts/custom/kubecore-ci-workflows/tests/dataset-choices/run.sh
#
# Needs helm, python3 + PyYAML. Exit status is the number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
WORK=$(mktemp -d)
trap 'kill "${SERVER:-0}" 2>/dev/null; rm -rf "$WORK"' EXIT
FAILED=0
PASSED=0
expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}

helm template t "$CHART" > "$WORK/rendered.yaml"
awk "/<<'DSEOF'/{f=1;next} /^ *DSEOF\$/{f=0} f" "$WORK/rendered.yaml" | sed 's/^        //' > "$WORK/datasets.py"
expect_eq "$(grep -c 'kaos/v1/catalog' "$WORK/datasets.py")" "1" "the dataset step is in hera-enhance-commit"
expect_eq "$(grep -c 'audience: "kaos-lake"' "$WORK/rendered.yaml")" "1" "the step mounts a kaos-lake audience token"

cat > "$WORK/catalog.py" <<'PY'
import http.server, json, sys
BODY = {"datasets": [
    {"name": "dataset-cars", "versions": [{"tag": "v2", "commit": "c2"}, {"tag": "v1", "commit": "c1"}]},
    {"name": "dataset-default", "default": True, "versions": [{"tag": "v3", "commit": "c3"}]},
]}
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        ok = self.path == "/kaos/v1/catalog" and self.headers.get("Authorization") == "Bearer pod-token"
        self.send_response(200 if ok else 401)
        self.end_headers()
        self.wfile.write(json.dumps(BODY if ok else {"message": "no"}).encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
PORT=18911
python3 "$WORK/catalog.py" $PORT & SERVER=$!
sleep 1
echo pod-token > "$WORK/token"
wft() { printf 'spec:\n  arguments:\n    parameters:\n%s  templates: []\n' "$1" > "$WORK/wft.yaml"; }
ctx() { printf 'lakefs:\n  endpoint: http://127.0.0.1:%s/\n' "$1" > "$WORK/ctx.yaml"; }
run() { python3 "$WORK/datasets.py" "$WORK/wft.yaml" "$WORK/ctx.yaml" "$WORK/token"; }
param() { python3 -c "import sys,yaml; p=[x for x in yaml.safe_load(open('$WORK/wft.yaml'))['spec']['arguments']['parameters'] if x['name']=='dataset'][0]; print(p.get('value'), '|', ','.join(p.get('enum') or []))"; }

wft "    - {name: dataset, value: dataset-default@latest}
"
ctx $PORT
run >/dev/null
expect_eq "$(param)" "dataset-default@v3 | dataset-default@v3,dataset-default@latest,dataset-cars@v2,dataset-cars@v1,dataset-cars@latest" \
  "default dataset first, versions newest first, then latest; default = its newest version"

wft "    - {name: dataset, value: dataset-cars@v1}
"
run >/dev/null
expect_eq "$(param | cut -d'|' -f1)" "dataset-cars@v1 " "a default that is still offered is kept"

wft "    - {name: dataset, value: dataset-default@latest}
"
ctx 1
out=$(run); rc=$?
expect_eq "$rc" "0" "an unreachable catalog never fails the render"
expect_eq "$(param)" "dataset-default@latest | " "and leaves the parameter free text"
case "$out" in *"catalog not read"*) PASSED=$((PASSED + 1)); echo "PASS: it says why";; *) FAILED=$((FAILED + 1)); echo "FAIL: no reason printed: $out";; esac

wft "    - {name: data-ref, value: main}
"
ctx $PORT
run >/dev/null; rc=$?
expect_eq "$rc" "0" "a pipeline without a dataset parameter is left alone"
expect_eq "$(grep -c enum "$WORK/wft.yaml")" "0" "no enum added"

echo "pod-token-wrong" > "$WORK/token"
wft "    - {name: dataset, value: x}
"
run >/dev/null; rc=$?
expect_eq "$rc" "0" "a refused token never fails the render"

echo "${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
