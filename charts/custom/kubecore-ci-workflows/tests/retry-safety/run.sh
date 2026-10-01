#!/usr/bin/env bash
# Tests for kubecore-operator#1379: every ML CI step retries a pod lost to a
# spot preemption, and the steps that write are safe to run twice. A retry
# runs the step again from the start, so a clone must survive its
# predecessor's partial checkout and a tag push must survive the tag its
# predecessor already pushed. Usage (from the repo root):
#
#   bash charts/custom/kubecore-ci-workflows/tests/retry-safety/run.sh
#
# The clone and tag scripts are EXECUTED against a local bare repo standing in
# for the app repo. Needs helm, yq v4, jq, git. Exit status is the number of
# failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0

expect_eq() {
  if [ "$1" = "$2" ]; then
    PASSED=$((PASSED + 1)); echo "PASS: $3"
  else
    FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"
  fi
}
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"
       echo "  actual: $(printf '%s' "$1" | tail -5)" ;;
  esac
}

BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT
RENDERED="${BASE_TMP}/rendered.yaml"
helm template t "$CHART" --set github.org=acme > "$RENDERED" || { echo "FAIL: helm template"; exit 1; }

# ── every ML step retries a preemption ───────────────────────────────────────

for wf in ml-ci-build ml-ci-pr-render; do
  MISSING=$(yq -o=json "select(.metadata.name == \"$wf\")" "$RENDERED" | jq -r '
    .spec.templates[] | select(.container)
    | select((.retryStrategy.expression // "" | test("imminent node shutdown") | not)
             or .retryStrategy.limit != "2" or (.retryStrategy.backoff.maxDuration != null))
    | .name' | tr '\n' ' ')
  expect_eq "${MISSING}" "" "$wf: every step retries a preemption (limit 2, no maxDuration)"
done

# ── fixtures: a bare "origin" with one commit on dev ─────────────────────────

new_origin() {
  T=$(mktemp -d "${BASE_TMP}/case-XXXX")
  printf 'token' > "$T/token"
  # No `git init -b`: the CI runner's git predates it (< 2.28).
  git init -q --bare "$T/origin.git" && git --git-dir="$T/origin.git" symbolic-ref HEAD refs/heads/dev
  git --git-dir="$T/origin.git" config uploadpack.allowReachableSHA1InWant true  # as GitHub
  git clone -q "$T/origin.git" "$T/seed" 2>/dev/null
  # A minimal Hera layout: ml-ci-build's clone refuses a repo with no ML frontend.
  ( cd "$T/seed" && git checkout -q -b dev && echo app > README.md && echo '# pipeline' > pipeline.py \
      && mkdir config && echo 'a: 1' > config/config.yaml && git add README.md pipeline.py config \
      && git -c user.name=t -c user.email=t@t commit -qm init && git push -q origin dev \
      && echo two > TWO && git add TWO && git -c user.name=t -c user.email=t@t commit -qm two \
      && git push -q origin dev )
  SHA=$(git --git-dir="$T/origin.git" rev-parse refs/heads/dev)
  OTHER=$(git --git-dir="$T/origin.git" rev-parse refs/heads/dev~1)
  mkdir -p "$T/workspace"
}

script() {  # script WORKFLOW TEMPLATE -> the step's script with placeholders filled
  yq "select(.metadata.name == \"$1\") | .spec.templates[] | select(.name == \"$2\") | .container.args[0]" "$RENDERED" \
    | sed -e "s#/tmp/tagrepo#$T/tagrepo#g" \
          -e "s#/workspace/#$T/workspace/#g" \
          -e "s#/etc/github-token/token#$T/token#g" \
          -e "s#{{inputs.parameters.new_version}}#1.2.3#g" \
          -e "s#{{inputs.parameters.image_tag}}#dev-v1.2.3-20261001-120000-abc1234#g" \
          -e "s#{{inputs.parameters.rc_tag}}#v1.2.3-rc.1#g" \
          -e "s#{{workflow.parameters.repo_url}}#file://$T/origin.git#g" \
          -e "s#{{workflow.parameters.branch}}#refs/heads/dev#g" \
          -e "s#{{workflow.parameters.commit_sha}}#${SHA}#g"
}

# ── clone survives its predecessor's partial checkout ────────────────────────

for wf in ml-ci-build ci-build ci-rc-build; do
  new_origin
  script "$wf" clone > "$T/clone.sh"
  mkdir -p "$T/workspace/repo/.git" && echo junk > "$T/workspace/repo/partial"  # a killed attempt's leftovers
  OUT=$(cd "$T" && sh "$T/clone.sh" 2>&1); RC=$?
  expect_eq "$RC" "0" "$wf/clone: a retry over a partial checkout succeeds"
  expect_eq "$(git -C "$T/workspace/repo" rev-parse HEAD 2>/dev/null)" "$SHA" "$wf/clone: lands on commit_sha"
  expect_eq "$([ -e "$T/workspace/repo/partial" ] && echo stale || echo clean)" "clean" "$wf/clone: no leftovers from the killed attempt"
done

# ── tag push survives the tag its predecessor already pushed ─────────────────

for wf in ml-ci-build ci-build ci-rc-build; do
  case "$wf" in ci-rc-build) TAG=v1.2.3-rc.1 ;; *) TAG=dev-v1.2.3-20261001-120000 ;; esac
  new_origin
  script "$wf" tag > "$T/tag.sh"
  OUT=$(cd "$T" && sh "$T/tag.sh" 2>&1); RC=$?
  expect_eq "$RC" "0" "$wf/tag: first attempt pushes"
  rm -rf "$T/tagrepo"  # a retry is a new pod: fresh /tmp
  OUT=$(cd "$T" && sh "$T/tag.sh" 2>&1); RC=$?
  expect_eq "$RC" "0" "$wf/tag: a retry after a successful push succeeds"
  expect_has "$OUT" "already present on ${SHA}" "$wf/tag: the retry recognises its own tag"
  expect_eq "$(git --git-dir="$T/origin.git" rev-parse "refs/tags/${TAG}^{commit}")" "$SHA" "$wf/tag: still on commit_sha"

  # A tag of the same name on ANOTHER commit is a real conflict, not a retry.
  new_origin
  git --git-dir="$T/origin.git" tag "$TAG" "$OTHER"
  script "$wf" tag > "$T/tag.sh"
  OUT=$(cd "$T" && sh "$T/tag.sh" 2>&1); RC=$?
  expect_eq "$RC" "1" "$wf/tag: refuses an existing tag on another commit"
  expect_has "$OUT" "already exists on another commit" "$wf/tag: says why"
done

echo "retry-safety: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
