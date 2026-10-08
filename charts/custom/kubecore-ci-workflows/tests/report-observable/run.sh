#!/bin/sh
# The ML report step's comment upsert must say what GitHub answered: it used to print
# "Posted report comment" whatever came back (e2e-suite-ml-xwrpm, 2026-10-08).
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/r.yaml
#   sh charts/custom/kubecore-ci-workflows/tests/report-observable/run.sh /tmp/r.yaml
set -u
RENDERED="$1"; FAILED=0; PASSED=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build") | .spec.templates[] | select(.name == "report") | .container.args[0]' "$RENDERED" \
  | sed -n '/^TARGET=/,/^esac$/p' > "$T/upsert.sh"
[ -s "$T/upsert.sh" ] || { echo "FAIL: upsert block not found"; exit 1; }
mkdir -p "$T/bin"
# curl stub: LIST_CODE / POST_CODE choose the answers; the body is written to -o.
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
out=""; code=200; while [ $# -gt 0 ]; do case "$1" in -o) out="$2"; shift;; -X) code="${POST_CODE:-201}";; esac; shift; done
[ "$code" = 200 ] && code="${LIST_CODE:-200}"
if [ "$code" = 200 ]; then echo '[]' > "$out"; elif [ "${code#2}" != "$code" ]; then echo '{"id":1}' > "$out"; else echo '{"message":"Resource not accessible by integration"}' > "$out"; fi
printf '%s' "$code"
STUB
chmod +x "$T/bin/curl"
run() { ( cd "$T" && PATH="$T/bin:$PATH" PR=1 SHA=abc MARKER='<!-- m -->' AUTH=a ACCEPT=b LIST=l CREATE=c EDIT=e LIST_CODE="$1" POST_CODE="$2" sh upsert.sh 2>&1 ); }
check() { if printf '%s' "$1" | grep -q -- "$2"; then PASSED=$((PASSED+1)); echo "PASS: $3"; else FAILED=$((FAILED+1)); echo "FAIL: $3 — got: $1"; fi; }
out=$(run 200 201); check "$out" "Posted report comment on PR #1$" "a 201 says Posted on PR #1 (not #11)"
out=$(run 200 403); check "$out" "FAILED, GitHub answered 403: Resource not accessible by integration" "a 403 on the post is logged with GitHub's message"
out=$(run 404 201); check "$out" "listing comments on PR #1 answered 404" "a failed list is logged, and the post still runs"
echo "report-observable: ${PASSED} passed, ${FAILED} failed"; exit "$FAILED"
