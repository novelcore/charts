#!/bin/sh
# A new app's first push can reach CI before the project's CI token covers the
# new repository (kaos PRD 738 F-59 scopes the token to the project's existing
# repos; the scope catches up ~1 min after the repo exists, while the push
# webhook is already live). GitHub then answers the clone "Repository not
# found" and the build failed for good (kaos e2e-suite-mn8rc, 2026-10-09:
# clone at 19:12:48, re-scoped token pushed 19:12:52). The clone must exit 75
# on exactly that answer, and its retryStrategy must retry exit 75: a retry is
# a new pod, which mounts the re-scoped token. Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/r.yaml
#   sh charts/custom/kubecore-ci-workflows/tests/clone-token-scope/run.sh /tmp/r.yaml
#
# Needs yq v4. Exit status is the number of failed assertions.
set -u
RENDERED="$1"; FAILED=0; PASSED=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"
       echo "  actual: $(printf '%s' "$1" | tail -5)" ;;
  esac
}

# git stub: GIT_STUB_CLONE picks how `git clone` fails, the way GitHub answers.
mkdir -p "$T/bin"
cat > "$T/bin/git" <<'STUB'
#!/bin/sh
for a in "$@"; do
  if [ "$a" = clone ]; then
    case "${GIT_STUB_CLONE}" in
      not-found)
        echo "Cloning into '/workspace/repo'..." >&2
        echo "remote: Repository not found." >&2
        echo "fatal: repository 'https://github.com/acme/app.git/' not found" >&2
        exit 128 ;;
      no-branch)
        echo "fatal: Remote branch dev not found in upstream origin" >&2
        exit 128 ;;
    esac
  fi
done
exit 0
STUB
chmod +x "$T/bin/git"
printf 'token' > "$T/token"
mkdir -p "$T/workspace"

for wf in ci-build ml-ci-build; do
  SEL="select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$wf\") | .spec.templates[] | select(.name == \"clone\")"
  EXPR=$(yq "$SEL | .retryStrategy.expression" "$RENDERED")
  expect_has "$EXPR" 'lastRetry.exitCode == "75"' "$wf clone retries exit 75 (token not yet scoped to the repo)"
  expect_has "$EXPR" 'imminent node shutdown' "$wf clone still retries a preemption"
  expect_eq "$(yq "$SEL | .retryStrategy.limit" "$RENDERED")" "2" "$wf clone is still bounded by limit 2"

  yq "$SEL | .container.args[0]" "$RENDERED" \
    | sed -e "s#/workspace/#$T/workspace/#g" -e "s#/etc/github-token/token#$T/token#g" \
          -e "s#{{workflow.parameters.repo_url}}#https://github.com/acme/app.git#g" \
          -e "s#{{workflow.parameters.branch}}#refs/heads/dev#g" \
          -e "s#{{workflow.parameters.commit_sha}}#abc123#g" > "$T/clone-$wf.sh"

  out=$(cd "$T" && PATH="$T/bin:$PATH" GIT_STUB_CLONE=not-found sh "$T/clone-$wf.sh" 2>&1); rc=$?
  expect_eq "$rc" "75" "$wf clone: GitHub's 'Repository not found' exits 75 (retried)"
  expect_has "$out" "remote: Repository not found." "$wf clone: GitHub's own answer is still logged"

  out=$(cd "$T" && PATH="$T/bin:$PATH" GIT_STUB_CLONE=no-branch sh "$T/clone-$wf.sh" 2>&1); rc=$?
  expect_eq "$rc" "128" "$wf clone: any other clone failure keeps git's exit code (not retried)"
  expect_has "$out" "Remote branch dev not found" "$wf clone: the other failure is logged"
done

echo "clone-token-scope: ${PASSED} passed, ${FAILED} failed"; exit "$FAILED"
