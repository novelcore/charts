#!/bin/sh
# The status step's GitHub writes retry transient answers and fail loudly when
# they still fail. Each was a single `curl -s` with its HTTP status discarded:
# in kaos e2e-suite-devmove-g77qv (2026-10-14) the success step's Deployment
# lookup got no usable answer, logged "WARN: no argo-workflows-dev Deployment
# resolved ... skipped deployment status", exited 0, and Deployment
# 7054474542 stayed in_progress forever. A 404 is a brand-new repo the CI
# token does not reach yet (kaos e2e 1c114130, 2026-10-18): exit 75, and the
# terminal step creates a Deployment the pending step could not. Executes the rendered status script
# of ci-build, ci-rc-build and ml-ci-build against a stub curl (and a stub
# sleep that records the backoff). Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/r.yaml
#   sh charts/custom/kubecore-ci-workflows/tests/deployment-status-retry/run.sh /tmp/r.yaml
#
# Needs yq v4 and jq. STATUS_SHELL picks the shell (production: busybox sh).
# Exit status is the number of failed assertions.
set -u
RENDERED="$1"; FAILED=0; PASSED=0
SH="${STATUS_SHELL:-sh}"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"
       echo "  actual: $(printf '%s' "$1" | tail -8)" ;;
  esac
}
expect_not() {
  case "$1" in
    *"$2"*) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  must not contain: $2" ;;
    *) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
  esac
}

# curl stub. $T/plan lines: METHOD URL-SUBSTRING CODES [RETRY_AFTER]; the
# first matching line answers, its Nth call takes the Nth comma-separated
# code (the last repeats). 000 = transport failure; 200e = an empty list;
# 403s = a secondary rate limit. No match: 201 for POST, 200 [] for GET.
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/bin/sh
out=""; hdr=""; method=GET; url=""; data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;; -D) hdr="$2"; shift ;; -X) method="$2"; shift ;;
    -d) data="$2"; shift ;;
    -w|-H|--connect-timeout|--max-time) shift ;;
    -*) ;; *) url="$1" ;;
  esac; shift
done
code=""; ra=""; n=0
while read -r m sub codes rafter; do
  n=$((n + 1))
  [ "$m" = "$method" ] || continue
  case "$url" in *"$sub"*) ;; *) continue ;; esac
  c=$(cat "$STUB_DIR/count.$n" 2>/dev/null || echo 0); c=$((c + 1)); echo "$c" > "$STUB_DIR/count.$n"
  code=$(echo "$codes" | tr ',' '\n' | sed -n "${c}p"); [ -n "$code" ] || code=$(echo "$codes" | tr ',' '\n' | tail -1)
  ra="$rafter"; break
done < "$STUB_DIR/plan"
[ -n "$code" ] || { [ "$method" = POST ] && code=201 || code=200; }
echo "$method $url $code" >> "$STUB_DIR/calls"
[ -z "$data" ] || echo "$method $url $data" >> "$STUB_DIR/bodies"
if [ "$code" = 000 ]; then echo "curl: (7) Failed to connect to api.github.com port 443" >&2; printf '000'; exit 7; fi
: > "$hdr"; [ -n "$ra" ] && printf 'retry-after: %s\r\n' "$ra" >> "$hdr"
case "$code" in
  200e) echo '[]' > "$out"; code=200 ;;
  403s) echo '{"message":"You have exceeded a secondary rate limit."}' > "$out"; code=403 ;;
  2??) case "$method $url" in
         "GET "*'deployments?sha='*) echo '[{"id":7054474542}]' > "$out" ;;
         "GET "*'/statuses?'*) echo '[{"state":"success"}]' > "$out" ;;
         "GET "*) echo '[]' > "$out" ;;
         "POST "*'/deployments') echo '{"id":4242}' > "$out" ;;
         *) echo '{}' > "$out" ;;
       esac ;;
  403) echo '{"message":"Resource not accessible by integration"}' > "$out" ;;
  404) echo '{"message":"Not Found"}' > "$out" ;;
  *) echo '{"message":"Server Error"}' > "$out" ;;
esac
printf '%s' "$code"
STUB
cat > "$T/bin/sleep" <<'STUB'
#!/bin/sh
printf '%s ' "$1" >> "$STUB_DIR/sleeps"
STUB
chmod +x "$T/bin/curl" "$T/bin/sleep"
printf 'ghs_FAKE_TOKEN_never_logged' > "$T/token"

# run WF STATE ENVIRONMENT, plan on stdin. Sets OUT, RC, CALLS, SLEEPS.
run() {
  rm -f "$T"/plan "$T"/calls "$T"/sleeps "$T"/bodies "$T"/count.*; cat > "$T/plan"; : > "$T/calls"; : > "$T/sleeps"
  sed -e "s#/etc/github-token/token#$T/token#g" \
      -e "s#{{workflow.parameters.repo_url}}#https://github.com/acme/app.git#g" \
      -e "s#{{workflow.parameters.commit_sha}}#abc123#g" \
      -e "s#{{workflow.parameters.branch}}#refs/heads/dev#g" \
      -e "s#{{workflow.parameters.event_type}}#push#g" \
      -e "s#{{workflow.namespace}}#ci#g; s#{{workflow.name}}#wf-1#g; s#{{workflow.uid}}#u-1#g" \
      -e "s#{{inputs.parameters.state}}#$2#g" \
      -e "s#{{inputs.parameters.description}}#desc#g" \
      -e "s#{{inputs.parameters.context}}#ctx#g" \
      -e "s#{{inputs.parameters.environment}}#$3#g" "$T/status-$1.sh" > "$T/run.sh"
  OUT=$(cd "$T" && PATH="$T/bin:$PATH" STUB_DIR="$T" "$SH" "$T/run.sh" 2>&1); RC=$?
  CALLS=$(cat "$T/calls"); SLEEPS=$(cat "$T/sleeps")
}

for wf in ci-build ci-rc-build ml-ci-build; do
  SEL="select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$wf\") | .spec.templates[] | select(.name == \"status\")"
  yq "$SEL | .container.args[0]" "$RENDERED" > "$T/status-$wf.sh"
  [ -s "$T/status-$wf.sh" ] || { FAILED=$((FAILED + 1)); echo "FAIL: $wf status template not found"; continue; }
  expect_has "$(yq "$SEL | .retryStrategy.expression" "$RENDERED")" 'lastRetry.exitCode == "75"' "$wf status: a new pod retries exit 75 (GitHub unavailable)"
  expect_not "$(cat "$T/status-$wf.sh")" "skipped deployment status" "$wf status: the silent WARN + exit 0 is gone"

  # The e2e-suite-devmove-g77qv case: the lookup answers 503 twice, then 200.
  run "$wf" success argo-workflows-dev <<'P'
GET deployments?sha= 503,503,200
P
  expect_eq "$RC" "0" "$wf success: 503, 503, 200 on the lookup → exit 0"
  expect_eq "$SLEEPS" "2 4 " "$wf success: backoff 2s then 4s"
  expect_has "$OUT" "answered HTTP 503 (attempt 1/5), retrying in 2s" "$wf success: each retry is logged with its HTTP status"
  expect_has "$CALLS" "POST https://api.github.com/repos/acme/app/deployments/7054474542/statuses 201" "$wf success: the resolved Deployment gets its terminal status"
  expect_has "$OUT" "Posted deployment argo-workflows-dev#7054474542 status: success" "$wf success: the post is reported"
  expect_not "$OUT" "ghs_FAKE_TOKEN" "$wf: the token never reaches the log"

  # GitHub stays down: 5 attempts, then exit 75 with the HTTP status.
  run "$wf" success argo-workflows-dev <<'P'
GET deployments?sha= 502
P
  expect_eq "$RC" "75" "$wf success: a lookup that stays 502 exits 75 (not a silent 0)"
  expect_eq "$SLEEPS" "2 4 8 16 " "$wf success: 5 attempts, backoff 2/4/8/16s"
  expect_has "$OUT" "still unavailable after 5 attempts (last HTTP 502)" "$wf success: the give-up names the HTTP status"
  expect_has "$OUT" "ERROR: argo-workflows-dev Deployment for abc123 not resolved — it stays in_progress (HTTP 502)" "$wf success: the stuck Deployment is named"
  expect_has "$OUT" "Posted commit status ctx=success" "$wf success: the commit status still went through"

  # An empty list (HTTP 200, no id) is retried: the list endpoint can lag the create.
  run "$wf" failure argo-workflows-dev <<'P'
GET deployments?sha= 200e,200e,200
P
  expect_eq "$RC" "0" "$wf failure: [] twice, then the Deployment → exit 0"
  expect_eq "$SLEEPS" "2 4 " "$wf failure: empty lookups back off 2s then 4s"
  expect_has "$OUT" "lists no argo-workflows-dev Deployment for abc123 yet (lookup 1/5), retrying in 2s" "$wf failure: each empty lookup is logged"
  expect_has "$CALLS" "POST https://api.github.com/repos/acme/app/deployments/7054474542/statuses 201" "$wf failure: the late-listed Deployment gets its terminal status"
  # The e2e 1c114130 case: the pending step never created the Deployment
  # (404, a brand-new repo), so the list stays [] — the terminal step creates
  # it and posts its terminal status on it (it used to exit 75, three times).
  run "$wf" failure argo-workflows-dev <<'P'
GET deployments?sha= 200e
P
  expect_eq "$RC" "0" "$wf failure: still [] after 5 lookups creates the Deployment, exit 0"
  expect_eq "$SLEEPS" "2 4 8 16 " "$wf failure: 5 lookups (backoff 2/4/8/16s) before creating"
  expect_has "$OUT" "lists no argo-workflows-dev Deployment for abc123 after 5 lookups" "$wf failure: the missing Deployment is logged"
  expect_eq "$(grep -c 'POST https://api.github.com/repos/acme/app/deployments 201' "$T/calls")" "1" "$wf failure: exactly one Deployment is created"
  expect_has "$CALLS" "POST https://api.github.com/repos/acme/app/deployments/4242/statuses 201" "$wf failure: the failure status goes on the created Deployment"
  expect_has "$OUT" "Posted deployment argo-workflows-dev#4242 status: failure" "$wf failure: the post on the created Deployment is reported"
  run "$wf" success argo-workflows-dev <<'P'
GET deployments?sha= 200e
P
  expect_eq "$RC" "0" "$wf success: no Deployment ever listed → created, exit 0"
  expect_has "$CALLS" "POST https://api.github.com/repos/acme/app/deployments/4242/statuses 201" "$wf success: success posted on the created Deployment"
  expect_has "$(cat "$T/bodies")" 'POST https://api.github.com/repos/acme/app/deployments {"ref":"abc123","environment":"argo-workflows-dev","auto_merge":false,"required_contexts":[],"transient_environment":true,"description":"wf-1"}' "$wf success: the terminal create uses the pending step's payload"
  # The list lags, then shows the pending step's Deployment: no duplicate.
  run "$wf" success argo-workflows-dev <<'P'
GET deployments?sha= 200e,200e,200e,200
P
  expect_eq "$RC" "0" "$wf success: [] three times, then listed → exit 0"
  expect_not "$CALLS" "POST https://api.github.com/repos/acme/app/deployments 201" "$wf success: a lagging list creates no duplicate"
  expect_has "$CALLS" "POST https://api.github.com/repos/acme/app/deployments/7054474542/statuses 201" "$wf success: success posted on the listed Deployment"
  # The terminal create can fail like any write: still a retried 75.
  run "$wf" success argo-workflows-dev <<'P'
GET deployments?sha= 200e
POST /deployments 503
P
  expect_eq "$RC" "75" "$wf success: a terminal create that stays 503 exits 75"
  expect_has "$OUT" "argo-workflows-dev Deployment not created for abc123" "$wf success: the failed create is logged"

  # 429 with Retry-After: the header wins over the backoff.
  run "$wf" success argo-workflows-dev <<'P'
POST /statuses/abc123 429,201 7
P
  expect_eq "$RC" "0" "$wf: a 429 on the commit status is retried"
  expect_eq "$SLEEPS" "7 " "$wf: Retry-After 7 is honoured"

  # A secondary rate limit (403 + message) is retried, a plain 403 is not.
  run "$wf" success argo-workflows-dev <<'P'
POST /statuses/abc123 403s,201
P
  expect_eq "$RC.$SLEEPS" "0.2 " "$wf: a 403 secondary rate limit is retried"
  run "$wf" success argo-workflows-dev <<'P'
POST /statuses/abc123 403
P
  expect_eq "$RC.$SLEEPS" "1." "$wf: a plain 403 is not retried and exits 1"
  expect_has "$OUT" "answered HTTP 403: {\"message\":\"Resource not accessible by integration\"}" "$wf: GitHub's message is logged"
  expect_has "$OUT" "Posted deployment argo-workflows-dev#7054474542 status: success" "$wf: a failed commit status does not skip the Deployment"

  # Transport failure (curl exit 7, no HTTP answer) is retried.
  run "$wf" success argo-workflows-dev <<'P'
POST /statuses/abc123 000,201
P
  expect_eq "$RC.$SLEEPS" "0.2 " "$wf: a transport failure is retried"

  # pending: create retried; a failing stale-listing stays a WARN.
  run "$wf" pending argo-workflows-dev <<'P'
GET deployments?environment= 500
POST /deployments/ 201
POST /deployments 500,201
P
  expect_eq "$RC" "0" "$wf pending: a failed stale listing is best-effort, a 500 on create is retried"
  expect_has "$OUT" "WARN: argo-workflows-dev Deployments not listed (HTTP 500)" "$wf pending: the listing failure is logged"
  expect_has "$CALLS" "POST https://api.github.com/repos/acme/app/deployments/4242/statuses 201" "$wf pending: the created Deployment goes in_progress"

  # A brand-new repo the CI token does not reach yet answers 404 (kaos e2e
  # 1c114130, ml-ci-build-6mfoi): exit 75, retried in a new pod, at once
  # (an in-pod retry would reuse the same token).
  run "$wf" pending argo-workflows-dev <<'P'
POST /statuses/abc123 404
GET deployments?environment= 404
POST /deployments 404
P
  expect_eq "$RC" "75" "$wf pending: 404 on all three calls exits 75 (retried), not 1"
  expect_eq "$SLEEPS" "" "$wf pending: a 404 is not retried in the pod"
  expect_has "$OUT" "the CI token does not reach this repository yet" "$wf pending: the 404 is explained"
  expect_has "$OUT" "ERROR: argo-workflows-dev Deployment not created for abc123 (HTTP 404)" "$wf pending: the failed create is named"
  run "$wf" success argo-workflows-dev <<'P'
GET deployments?sha= 404
P
  expect_eq "$RC" "75" "$wf success: a 404 lookup exits 75 (retried)"
  expect_not "$CALLS" "POST https://api.github.com/repos/acme/app/deployments 201" "$wf success: a 404 lookup never creates a Deployment"
  # Other refusals stay exit 1.
  run "$wf" pending argo-workflows-dev <<'P'
POST /statuses/abc123 403
POST /deployments 403
P
  expect_eq "$RC.$SLEEPS" "1." "$wf pending: 403 stays exit 1, not retried"
  for c in 401 422; do
    run "$wf" pending argo-workflows-dev <<P
POST /statuses/abc123 $c
P
    expect_eq "$RC" "1" "$wf pending: $c on the commit status stays exit 1"
  done

  # environment "" = statuses only.
  run "$wf" success "" <<'P'
P
  expect_eq "$RC" "0" "$wf: no environment posts the commit status only"
  expect_not "$CALLS" "deployments" "$wf: no environment touches no Deployment"
done

# Every caller runs the status step with continueOn failed: reporting never
# turns a build red, stops its gitops-notify, or skips the exit handler's run-report.
for wf in ci-build ci-rc-build ml-ci-build ml-ci-rc-build; do
  N=$(yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$wf\") | .. | select(type == \"!!map\" and ((.template == \"status\" and (has(\"clusterScope\") | not)) or .templateRef.template == \"status\")) | .continueOn.failed" "$RENDERED" | sort | uniq -c | tr -s ' ')
  expect_eq "$N" " 3 true" "$wf: all 3 status callers run with continueOn failed"
done

echo "deployment-status-retry: ${PASSED} passed, ${FAILED} failed"; exit "$FAILED"
