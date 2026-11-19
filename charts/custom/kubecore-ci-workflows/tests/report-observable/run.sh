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
# A code written "000,503,201" is answered one per call, the last one for every later call.
kind=list; [ "$code" = "${LIST_CODE:-200}" ] || kind=post
n=$(cat "calls.$kind" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "calls.$kind"
code=$(printf '%s' "$code" | tr ',' '\n' | awk -v n="$n" '{ c = $0 } NR == n { print; f = 1; exit } END { if (!f) print c }')
if [ "$code" = 200 ]; then echo '[]' > "$out"; elif [ "${code#2}" != "$code" ]; then echo '{"id":1}' > "$out"; else echo '{"message":"Resource not accessible by integration"}' > "$out"; fi
printf '%s' "$code"
STUB
chmod +x "$T/bin/curl"
run() { ( cd "$T" && rm -f calls.list calls.post && PATH="$T/bin:$PATH" REPORT_RETRY_SLEEP=0 PR=1 SHA=abc MARKER='<!-- m -->' AUTH=a ACCEPT=b LIST=l CREATE=c EDIT=e LIST_CODE="$1" POST_CODE="$2" sh upsert.sh 2>&1 ); }
check() { if printf '%s' "$1" | grep -q -- "$2"; then PASSED=$((PASSED+1)); echo "PASS: $3"; else FAILED=$((FAILED+1)); echo "FAIL: $3 — got: $1"; fi; }
out=$(run 200 201); check "$out" "Posted report comment on PR #1$" "a 201 says Posted on PR #1 (not #11)"
out=$(run 200 403); check "$out" "FAILED, GitHub answered 403: Resource not accessible by integration" "a 403 on the post is logged with GitHub's message"
out=$(run 404 201); check "$out" "listing comments on PR #1 answered 404" "a failed list is logged, and the post still runs"
# A call GitHub did not answer, a 5xx or a 429 is tried again; an answer like a 403 is not.
out=$(run 200 000,503,201); check "$out" "Posted report comment on PR #1$" "a post with no answer, then a 503, then a 201 is posted"
check "$out" "GitHub answered 000 (attempt 1/5), retrying in 2s" "each retry is logged with what GitHub answered"
check "$(cat "$T/calls.post")" "^3$" "the post was tried three times"
out=$(run 000,200 201); check "$out" "Posted report comment on PR #1$" "a list with no answer is tried again before the post"
out=$(run 200 000); check "$out" "FAILED, GitHub answered 000" "a post never answered is logged as failed after five tries"
check "$(cat "$T/calls.post")" "^5$" "five tries, then it gives up"
out=$(run 200 403); check "$(cat "$T/calls.post")" "^1$" "a 403 is an answer: no second try"
echo "report-observable: ${PASSED} passed, ${FAILED} failed"; exit "$FAILED"
