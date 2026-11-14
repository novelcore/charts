#!/usr/bin/env bash
# Tests for the dataset pickers of an ML pipeline (PRD novelcore/kaos#1283 D-05, PRD novelcore/kaos#1911
# D-15): hera-enhance-commit offers the project's datasets, from kaos-lake's read-only catalog, on the form
# field of EVERY name a step declares in inputs= (the engine's step table), never fails the render when
# the catalog cannot be read, and records a digest of what it offered (dataset-sha) for ml-ci-reconcile's
# DATASET DRIFT. A field named `dataset` is no longer special. The chart adds no form field. The scripts
# under test are cut from the rendered chart and EXECUTED against a local fake catalog. Usage (from the
# repo root):
#
#   bash charts/custom/kubecore-ci-workflows/tests/dataset-choices/run.sh
#
# Needs helm, python3 + PyYAML. Exit status is the number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
WORK=$(mktemp -d)
trap 'kill "${SERVER:-0}" ${FLAKY:-} 2>/dev/null; rm -rf "$WORK"' EXIT
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
# steps INPUTS...: the engine's step table, one step per argument ("raw,labels" = a step with two inputs).
steps() { python3 -c "
import json, sys
print(json.dumps([{'name': f's{i}', 'kind': 'train', 'reads': [], 'inputs': [n for n in a.split(',') if n], 'needs': [], 'produces': []}
                  for i, a in enumerate(sys.argv[1:])]))" "$@" > "$WORK/steps.json"; }
run() { rm -f "$WORK/sha"; python3 "$WORK/datasets.py" "$WORK/wft.yaml" "$WORK/ctx.yaml" "$WORK/token" "$WORK/sha" "$WORK/steps.json"; }
sha() { cat "$WORK/sha" 2>/dev/null || echo "<absent>"; }
ALL="dataset-default@v3,dataset-default@latest,dataset-cars@v2,dataset-cars@v1,dataset-cars@latest"
# sha256 of the sorted choices, one per line
WANT_SHA=$(python3 -c "import hashlib; print(hashlib.sha256('\n'.join(sorted('$ALL'.split(','))).encode()).hexdigest())")
param() { python3 -c "import sys,yaml; p=[x for x in yaml.safe_load(open('$WORK/wft.yaml'))['spec']['arguments']['parameters'] if x['name']=='${1:-dataset}'][0]; print(p.get('value'), '|', ','.join(p.get('enum') or []))"; }
names() { python3 -c "import yaml; print(','.join(x['name'] for x in yaml.safe_load(open('$WORK/wft.yaml'))['spec']['arguments']['parameters']))"; }

wft "    - {name: dataset, value: dataset-default@latest}
"
ctx $PORT; steps dataset
run >/dev/null
expect_eq "$(param)" "dataset-default@latest | $ALL" \
  "default dataset first, versions newest first, then latest; the default stays what the app's config says (latest is resolved when the run starts)"

expect_eq "$(sha)" "$WANT_SHA" "the render records the digest of the sorted choices"
expect_eq "$(python3 -I "$WORK/dataset-choices.py" digest "http://127.0.0.1:$PORT/" "$WORK/token")" "$WANT_SHA" \
  "ml-ci-reconcile's digest of the same catalog is the digest the render recorded"

wft "    - {name: dataset, value: dataset-cars@v1}
"
run >/dev/null
expect_eq "$(param | cut -d'|' -f1)" "dataset-cars@v1 " "a default that names an offered version is kept"

# Several inputs, under any name: each one is a picker; a field no step declares as an input is not.
wft "    - {name: raw, value: dataset-cars@latest}
    - {name: labels, value: dataset-cars@v9}
    - {name: extra, value: dataset-missing@v1}
    - {name: dataset, value: free-text}
    - {name: train-epochs, value: '3'}
    - {name: config, value: ''}
"
steps "raw" "raw,labels" "extra" ""
out=$(run)
expect_eq "$(param raw)" "dataset-cars@latest | $ALL" "input raw: a picker, its default kept"
expect_eq "$(param labels)" "dataset-cars@latest | $ALL" "input labels: a version the catalog does not offer becomes the latest of the same dataset"
expect_eq "$(param extra)" "dataset-default@latest | $ALL" "input extra: a dataset the project does not have becomes the latest of the default dataset"
expect_eq "$(param dataset)" "free-text | " "a field named dataset that no step declares as an input is left alone"
expect_eq "$(param train-epochs)" "3 | " "an ordinary field is left alone"
expect_eq "$(names)" "raw,labels,extra,dataset,train-epochs,config" "the chart adds no form field and removes none (plan and pipeline-version stay the engine's to reserve)"
expect_eq "$(grep -cE '[&*]id[0-9]+' "$WORK/wft.yaml")" "0" "each picker carries its own list (no YAML alias between fields)"
expect_eq "$(sha)" "$WANT_SHA" "several inputs record the same digest: it is the catalog's choices"
case "$out" in *"extra (default dataset-default@latest), labels (default dataset-cars@latest), raw (default dataset-cars@latest)"*) PASSED=$((PASSED + 1)); echo "PASS: the log names every field it filled and its default";;
  *) FAILED=$((FAILED + 1)); echo "FAIL: the log does not name the fields: $out";; esac

# An input with no form field: the engine gives every input a field of its own name, so this is a broken render.
wft "    - {name: raw, value: dataset-cars@latest}
"
steps "raw,labels"
out=$(run 2>&1); rc=$?
expect_eq "$rc" "1" "an input without a form field fails the render"
case "$out" in *"GATE FAIL: the pipeline declares the input 'labels' but its form has no field of that name"*) PASSED=$((PASSED + 1)); echo "PASS: it says which";;
  *) FAILED=$((FAILED + 1)); echo "FAIL: no reason printed: $out";; esac

wft "    - {name: dataset, value: dataset-default@latest}
"
steps dataset
ctx 1
out=$(run); rc=$?
expect_eq "$rc" "0" "an unreachable catalog never fails the render"
expect_eq "$(param)" "dataset-default@latest | " "and leaves the field free text"
expect_eq "$(sha)" "<absent>" "and records nothing, so the last good record stays"
python3 "$WORK/dataset-choices.py" digest http://127.0.0.1:1/ "$WORK/token" >/dev/null 2>&1; rc=$?
expect_eq "$rc" "1" "the drift check's digest of an unreadable catalog fails (no drift) instead of printing one"
case "$out" in *"catalog not read"*) PASSED=$((PASSED + 1)); echo "PASS: it says why";; *) FAILED=$((FAILED + 1)); echo "FAIL: no reason printed: $out";; esac

wft "    - {name: dataset, value: main}
"
ctx $PORT; steps "" ""
run >/dev/null; rc=$?
expect_eq "$rc" "0" "a pipeline whose steps declare no input is left alone"
expect_eq "$(grep -c enum "$WORK/wft.yaml")" "0" "no enum added, even on a field named dataset"
expect_eq "$(sha)" "none" "and records that the pipeline offers no dataset"

echo "pod-token-wrong" > "$WORK/token"
wft "    - {name: dataset, value: x}
"
steps dataset
run >/dev/null; rc=$?
expect_eq "$rc" "0" "a refused token never fails the render"
expect_eq "$(sha)" "<absent>" "and records nothing"

# A catalog with no dataset: the field stays free text, and "no dataset" is what is recorded.
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
expect_eq "$(param)" "x | " "an empty catalog leaves the field free text"
expect_eq "$(sha)" "$(python3 -c "import hashlib; print(hashlib.sha256(b'').hexdigest())")" "and records the digest of no choices (a later first dataset is drift)"
kill $EMPTY 2>/dev/null

# A deleted dataset leaves the enum on the next render: the choices come from the catalog alone.
ctx $PORT
wft "    - {name: dataset, value: dataset-cars@v1, enum: [dataset-gone@v1, dataset-cars@v1]}
"
run >/dev/null
expect_eq "$(param | cut -d'|' -f2 | grep -c gone)" "0" "a deleted dataset's entry is gone from the enum on the next render"

# The step table the picker reads is the one the enhance step wrote (kubecore-ci-workflows.platformEnhance).
ENHANCE=$(awk '/name: hera-enhance-commit$/{f=1} f' "$WORK/rendered.yaml")
P_STEPS=$(printf '%s\n' "$ENHANCE" | grep -n -m1 'engine.py steps --wft /workspace/out/workflow-template.yaml > /tmp/steps.json' | cut -d: -f1)
P_FILL=$(printf '%s\n' "$ENHANCE" | grep -n -m1 "<<'DSEOF'" | cut -d: -f1)
[ -n "$P_STEPS" ] && [ -n "$P_FILL" ] && [ "$P_STEPS" -lt "$P_FILL" ] \
  && { PASSED=$((PASSED + 1)); echo "PASS: hera-enhance-commit reads the step table of the enhanced WorkflowTemplate before it fills the pickers"; } \
  || { FAILED=$((FAILED + 1)); echo "FAIL: step table (${P_STEPS:-absent}) is not read before the pickers are filled (${P_FILL:-absent})"; }
expect_eq "$(printf '%s\n' "$ENHANCE" | grep -c '/tmp/dataset-sha /tmp/steps.json <<')" "1" "and hands it to the picker step"

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
expect_eq "$(images '')" "none" "a pipeline whose steps declare no input records none"

# ── shared datasets (PRD novelcore/kaos#1533 F-23, AC-30) ───────────────────
# kaos-lake (pkg/kaos/sharing/peers.go) already qualifies the name: `bob/dataset-gamma` with owner `bob`; a bare name
# plus owner (dataset-zeta) is also accepted. Neither may be double-prefixed.
# A shared dataset is listed after the project's own as <owner>/<dataset>, with owner set and default false.
cat > "$WORK/shared.json" <<'JSON'
{"datasets": [
  {"name": "dataset-cars", "versions": [{"tag": "v2", "commit": "c2"}, {"tag": "v1", "commit": "c1"}]},
  {"name": "dataset-zeta", "owner": "bob", "default": false, "versions": [{"tag": "v1", "commit": "z1"}]},
  {"name": "dataset-default", "default": true, "versions": [{"tag": "v3", "commit": "c3"}]},
  {"name": "dataset-b", "owner": "acme", "default": false, "versions": [{"tag": "v1", "commit": "b1"}]},
  {"name": "dataset-alpha", "owner": "bob", "default": false, "versions": [{"tag": "v2", "commit": "a2"}]},
  {"name": "bob/dataset-gamma", "owner": "bob", "default": false, "versions": [{"tag": "v1", "commit": "g1"}]}
]}
JSON
python3 "$WORK/empty.py" 18913 "$WORK/shared.json" & SHARED=$!
sleep 1
SH_ALL="dataset-default@v3,dataset-default@latest,dataset-cars@v2,dataset-cars@v1,dataset-cars@latest,bob/dataset-zeta@v1,bob/dataset-zeta@latest,bob/dataset-alpha@v2,bob/dataset-alpha@latest,bob/dataset-gamma@v1,bob/dataset-gamma@latest,acme/dataset-b@v1,acme/dataset-b@latest"
ctx 18913; steps dataset
wft "    - {name: dataset, value: dataset-gone@v1}
"
run >/dev/null
expect_eq "$(param)" "dataset-default@latest | $SH_ALL" \
  "own datasets first (default first), then shared grouped by owner in catalog order; an unoffered default falls back to the own default, never a shared one"
wft "    - {name: dataset, value: bob/dataset-zeta@v1}
"
run >/dev/null
expect_eq "$(param | cut -d'|' -f1)" "bob/dataset-zeta@v1 " "a shared dataset the config names is kept as the default"
wft "    - {name: dataset, value: bob/dataset-alpha@v9}
"
run >/dev/null
expect_eq "$(param | cut -d'|' -f1)" "bob/dataset-alpha@latest " "a shared dataset with an unoffered version becomes its own latest"
SH_SHA=$(python3 -c "import hashlib; print(hashlib.sha256('\n'.join(sorted('$SH_ALL'.split(','))).encode()).hexdigest())")
expect_eq "$(sha)" "$SH_SHA" "the digest includes the shared refs, so a share or unshare re-renders"
expect_eq "$(python3 -I "$WORK/dataset-choices.py" digest "http://127.0.0.1:18913/" "$WORK/token")" "$SH_SHA" "and ml-ci-reconcile computes the same digest"
expect_eq "$(param | grep -c 'bob/bob/')" "0" "a name the catalog already qualified is not prefixed twice (no bob/bob/...)"
kill $SHARED 2>/dev/null

# A project with no dataset of its own: the fallback never picks a shared dataset (the value stays as it is).
printf '{"datasets": [{"name": "dataset-zeta", "owner": "bob", "default": false, "versions": [{"tag": "v1", "commit": "z1"}]}]}' > "$WORK/only-shared.json"
python3 "$WORK/empty.py" 18914 "$WORK/only-shared.json" & ONLYSH=$!
sleep 1
ctx 18914
wft "    - {name: dataset, value: dataset-gone@v1}
"
run >/dev/null
expect_eq "$(param)" "dataset-gone@v1 | bob/dataset-zeta@v1,bob/dataset-zeta@latest" "no own dataset: the fallback never picks a shared one; the shared ref is still offered"
kill $ONLYSH 2>/dev/null

# ── the catalog read retries a transient failure, never a final one ─────────
# A fake catalog answering the first FAILS requests with CODE, then 200; every request is counted in $WORK/hits.
cat > "$WORK/flaky.py" <<'PY'
import http.server, json, sys
port, code, fails, hits = int(sys.argv[1]), int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        n = len(open(hits).read().split()) + 1
        open(hits, "a").write("x\n")
        bad = n <= fails
        self.send_response(code if bad else 200)
        self.end_headers()
        self.wfile.write(json.dumps({"datasets": [{"name": "dataset-cars", "versions": [{"tag": "v1"}]}]}).encode())
    def log_message(self, *a): pass
http.server.HTTPServer(("127.0.0.1", port), H).serve_forever()
PY
echo pod-token > "$WORK/token"
flaky() { : > "$WORK/hits"; [ -z "${FLAKY:-}" ] || kill "$FLAKY" 2>/dev/null; python3 "$WORK/flaky.py" 18915 "$1" "$2" "$WORK/hits" & FLAKY=$!; sleep 1
          OUT=$(python3 -I "$WORK/dataset-choices.py" digest http://127.0.0.1:18915/ "$WORK/token" 2>&1); RC=$?; HITS=$(wc -l < "$WORK/hits" | tr -d ' '); }
CARS_SHA=$(python3 -c "import hashlib; print(hashlib.sha256(b'dataset-cars@latest\ndataset-cars@v1').hexdigest())")
flaky 503 2
expect_eq "$RC/$HITS/$OUT" "0/3/$CARS_SHA" "a catalog that answers 503 twice is read on the third attempt"
flaky 503 1
expect_eq "$RC/$HITS/$OUT" "0/2/$CARS_SHA" "a catalog that answers 503 once is read on the second attempt"
flaky 503 99
expect_eq "$RC/$HITS" "1/3" "a catalog that keeps answering 503 is tried three times, then the read fails"
case "$OUT" in *"catalog not read (HTTPError"*) PASSED=$((PASSED + 1)); echo "PASS: and says why";; *) FAILED=$((FAILED + 1)); echo "FAIL: no reason printed: $OUT";; esac
for code in 401 403 404; do
  flaky $code 99
  expect_eq "$RC/$HITS" "1/1" "a $code is final: one attempt, no retry"
done
: > "$WORK/hits"
OUT=$(python3 -I "$WORK/dataset-choices.py" digest http://127.0.0.1:1/ "$WORK/token" 2>&1); RC=$?
expect_eq "$RC" "1" "a refused connection is retried and then fails"
kill $FLAKY 2>/dev/null
# the timeout itself is retried: a server that never answers within the timeout, then answers
python3 - "$WORK/dataset-choices.py" <<'PY'
import importlib.util, io, sys, urllib.request, socket, json, time
spec = importlib.util.spec_from_file_location("dc", sys.argv[1]); dc = importlib.util.module_from_spec(spec); spec.loader.exec_module(dc)
calls, naps = [], []
dc.time.sleep = naps.append
class R(io.BytesIO):
    def __enter__(self): return self
    def __exit__(self, *a): pass
def fake(req, timeout):
    calls.append(timeout)
    if len(calls) < 3: raise socket.timeout("timed out")
    return R(json.dumps({"datasets": [{"name": "a"}]}).encode())
urllib.request.urlopen = fake
import tempfile; t = tempfile.NamedTemporaryFile("w", delete=False); t.write("tok"); t.close()
got = dc.read_catalog("http://x", t.name)
assert got == [{"name": "a"}] and len(calls) == 3 and naps == [2, 4], (got, calls, naps)
print("timeouts retried: 3 calls, pauses", naps)
PY
expect_eq "$?" "0" "a read timeout is retried (pauses 2s then 4s), then succeeds"

echo "${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
