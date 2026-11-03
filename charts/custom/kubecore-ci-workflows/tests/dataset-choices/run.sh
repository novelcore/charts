#!/usr/bin/env bash
# Tests for PRD novelcore/kaos#1283 D-05: hera-enhance-commit offers the project's datasets in
# the `dataset` dropdown from kaos-lake's read-only catalog, and never fails the render when the
# catalog cannot be read, and records a digest of what it offered (dataset-sha) for ml-ci-reconcile's
# DATASET DRIFT. The scripts under test are cut from the rendered chart and EXECUTED against a local
# fake catalog. Usage (from the repo root):
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
awk "/<<'DSEOF'/{f=1;next} /^ *DSEOF\$/{f=0} f" "$WORK/rendered.yaml" | sed 's/^        //' \
  | sed "s#/tmp/dataset-choices.py#$WORK/dataset-choices.py#" > "$WORK/datasets.py"
# The helper both steps use is the chart's own file, written to /tmp by each step.
cp "$CHART/files/dataset-choices.py" "$WORK/dataset-choices.py"
expect_eq "$(grep -c "cat > /tmp/dataset-choices.py" "$WORK/rendered.yaml")" "2" "hera-enhance-commit and check-drift write the same helper"
expect_eq "$(grep -c 'dc.read_catalog' "$WORK/datasets.py")" "1" "the dataset step is in hera-enhance-commit"
expect_eq "$(grep -c 'kaos/v1/catalog' "$CHART/files/dataset-choices.py")" "1" "and reads kaos-lake's catalog through the shared helper"
expect_eq "$(grep -c 'audience: "kaos-lake"' "$WORK/rendered.yaml")" "2" "hera-enhance-commit and ml-ci-reconcile's check-drift mount a kaos-lake audience token"

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
run() { rm -f "$WORK/sha"; python3 "$WORK/datasets.py" "$WORK/wft.yaml" "$WORK/ctx.yaml" "$WORK/token" "$WORK/sha"; }
sha() { cat "$WORK/sha" 2>/dev/null || echo "<absent>"; }
# sha256 of the sorted choices, one per line
WANT_SHA=$(python3 -c "import hashlib; print(hashlib.sha256('\n'.join(sorted(['dataset-default@v3','dataset-default@latest','dataset-cars@v2','dataset-cars@v1','dataset-cars@latest'])).encode()).hexdigest())")
param() { python3 -c "import sys,yaml; p=[x for x in yaml.safe_load(open('$WORK/wft.yaml'))['spec']['arguments']['parameters'] if x['name']=='dataset'][0]; print(p.get('value'), '|', ','.join(p.get('enum') or []))"; }

wft "    - {name: dataset, value: dataset-default@latest}
"
ctx $PORT
run >/dev/null
expect_eq "$(param)" "dataset-default@v3 | dataset-default@v3,dataset-default@latest,dataset-cars@v2,dataset-cars@v1,dataset-cars@latest" \
  "default dataset first, versions newest first, then latest; default = its newest version"

expect_eq "$(sha)" "$WANT_SHA" "the render records the digest of the sorted choices"
expect_eq "$(python3 -I "$WORK/dataset-choices.py" digest "http://127.0.0.1:$PORT/" "$WORK/token")" "$WANT_SHA" \
  "ml-ci-reconcile's digest of the same catalog is the digest the render recorded"

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
expect_eq "$(sha)" "<absent>" "and records nothing, so the last good record stays"
python3 "$WORK/dataset-choices.py" digest http://127.0.0.1:1/ "$WORK/token" >/dev/null 2>&1; rc=$?
expect_eq "$rc" "1" "the drift check's digest of an unreadable catalog fails (no drift) instead of printing one"
case "$out" in *"catalog not read"*) PASSED=$((PASSED + 1)); echo "PASS: it says why";; *) FAILED=$((FAILED + 1)); echo "FAIL: no reason printed: $out";; esac

wft "    - {name: data-ref, value: main}
"
ctx $PORT
run >/dev/null; rc=$?
expect_eq "$rc" "0" "a pipeline without a dataset parameter is left alone"
expect_eq "$(grep -c enum "$WORK/wft.yaml")" "0" "no enum added"
expect_eq "$(sha)" "none" "and records that the pipeline offers no dataset"

echo "pod-token-wrong" > "$WORK/token"
wft "    - {name: dataset, value: x}
"
run >/dev/null; rc=$?
expect_eq "$rc" "0" "a refused token never fails the render"
expect_eq "$(sha)" "<absent>" "and records nothing"

# A catalog with no dataset: the parameter stays free text, and "no dataset" is what is recorded.
echo pod-token > "$WORK/token"
printf '{"datasets": []}' > "$WORK/empty.json"
cat > "$WORK/empty.py" <<'PY'
import http.server, sys
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        self.send_response(200); self.end_headers(); self.wfile.write(open(sys.argv[2]).read().encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", int(sys.argv[1])), H).serve_forever()
PY
python3 "$WORK/empty.py" 18912 "$WORK/empty.json" & EMPTY=$!
sleep 1
ctx 18912
wft "    - {name: dataset, value: x}
"
run >/dev/null
expect_eq "$(param)" "x | " "an empty catalog leaves the parameter free text"
expect_eq "$(sha)" "$(python3 -c "import hashlib; print(hashlib.sha256(b'').hexdigest())")" "and records the digest of no choices (a later first dataset is drift)"
kill $EMPTY 2>/dev/null

# A deleted dataset leaves the enum on the next render: the choices come from the catalog alone.
ctx $PORT
wft "    - {name: dataset, value: dataset-cars@v1, enum: [dataset-gone@v1, dataset-cars@v1]}
"
run >/dev/null
expect_eq "$(param | cut -d'|' -f2 | grep -c gone)" "0" "a deleted dataset's entry is gone from the enum on the next render"

# ── pipeline-images records dataset-sha ──────────────────────────────────────
awk "/<<'IMGEOF'/{f=1;next} /^ *IMGEOF\$/{f=0} f" "$WORK/rendered.yaml" | sed 's/^        //' > "$WORK/images.py"
printf 'spec:\n  arguments:\n    parameters: []\n' > "$WORK/w.yaml"
images() { printf 'metadata:\n  namespace: ml-p\ndata:\n  last-built-sha: abc\n%s' "$1" > "$WORK/i.yaml"
           python3 "$WORK/images.py" "$WORK/w.yaml" "$WORK/i.yaml" app1 ctxsha enhref "$WORK/sha" >/dev/null
           python3 -c "import yaml; print(yaml.safe_load(open('$WORK/i.yaml'))['data'].get('dataset-sha', '<absent>'))"; }
printf 'cafe' > "$WORK/sha"
expect_eq "$(images '')" "cafe" "the render writes dataset-sha into pipeline-images"
expect_eq "$(images '  dataset-sha: old
')" "cafe" "and moves it when the datasets changed"
rm -f "$WORK/sha"
expect_eq "$(images '  dataset-sha: old
')" "old" "an unreadable catalog keeps the last good record"
expect_eq "$(images '')" "<absent>" "and records nothing where there was none"
printf 'none' > "$WORK/sha"
expect_eq "$(images '')" "none" "a pipeline without a dataset parameter records none"

echo "${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
