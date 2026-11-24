#!/usr/bin/env bash
# A run never replaces a render made from a NEWER commit, and the first build leaves a complete record
# (PRD novelcore/kaos#1911 AC-13, AC-24).
#
#   bash charts/custom/kubecore-ci-workflows/tests/render-monotonic/run.sh
#
# The MONOTONIC functions, the record writer of hera-enhance-commit and the STAMPS block of
# patch-images are taken from the rendered chart and EXECUTED against real git repositories. Needs
# helm, yq v4, git, python3 with PyYAML. Exit status is the number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0
expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
helm template t "$CHART" --set github.org=acme > "$T/rendered.yaml" || { echo "FAIL: helm template"; exit 1; }
tpl() { yq "select(.metadata.name == \"ml-ci-build\") | .spec.templates[] | select(.name == \"$1\") | .container.args[0]" "$T/rendered.yaml"; }
tpl hera-enhance-commit > "$T/enhance.sh"
tpl patch-images > "$T/patch.sh"
sed -n '/MONOTONIC begin/,/MONOTONIC end/p' "$T/enhance.sh" | sed 's/^ *//' > "$T/mono.sh"
sed -n '/STAMPS begin/,/STAMPS end/p' "$T/patch.sh" > "$T/stamps.sh"
sed -n "/<<'IMGEOF'/,/^ *IMGEOF/p" "$T/enhance.sh" | sed '1d;$d' > "$T/record.py"
expect_eq "$([ -s "$T/mono.sh" ] && [ -s "$T/stamps.sh" ] && [ -s "$T/record.py" ] && echo yes)" "yes" "the chart carries the guard, the stamps and the record writer"
expect_eq "$(grep -c 'older_than_record' "$T/patch.sh")" "2" "patch-images asks the guard before it records last-built-sha"

# History of the app: c1 - c2 - c3, and "side": a branch off c1 (diverged from c3).
APP="$T/app"
git init -q "$APP"
g() { git -C "$APP" -c user.name=t -c user.email=t@t "$@"; }
echo 1 > "$APP/f"; g add -A; g commit -qm c1; C1=$(g rev-parse HEAD)
echo 2 > "$APP/f"; g add -A; g commit -qm c2; C2=$(g rev-parse HEAD)
echo 3 > "$APP/f"; g add -A; g commit -qm c3; C3=$(g rev-parse HEAD)
g checkout -q -b side "$C1"; echo s > "$APP/s"; g add -A; g commit -qm side; SIDE=$(g rev-parse HEAD)
g checkout -q -; g config uploadpack.allowAnySHA1InWant true

# older RUN REC [URL]: the guard's answer for a run of commit RUN and a recorded render REC
older() {
  sh -c '. "$1"; RUN_SHA="$2"; APP_REPO_URL="$4"; if older_than_record "$3"; then echo skip; else echo write; fi' \
    sh "$T/mono.sh" "$1" "$2" "${3:-$APP}" 2>/dev/null
}
expect_eq "$(older "$C1" "$C3")" "skip" "older run after newer render: skipped"
expect_eq "$(older "$C2" "$C3")" "skip" "one commit older: skipped"
expect_eq "$(older "$C3" "$C1")" "write" "newer run after older render: written"
expect_eq "$(older "$C3" "$C3")" "write" "the same commit again: written"
expect_eq "$(older "$C3" "")" "write" "nothing recorded yet: written"
expect_eq "$(older "$C3" "$SIDE")" "write" "diverged histories (force push): written, the safe default"
expect_eq "$(older "$C1" "$(printf 'a%.0s' $(seq 40))")" "write" "a recorded commit the app repository no longer has: written"
expect_eq "$(older "$C1" "$C3" "$T/nowhere")" "write" "app repository unreadable: written"
expect_eq "$(older "" "$C3")" "write" "a run with no commit (reconcile without sha): written"

# The race: the gitops repository moves between this run's clone and its push.
OR="$T/origin.git"; git init -q --bare -b dev "$OR"
W="$T/w"; git clone -q "$OR" "$W" 2>/dev/null
wg() { git -C "$W" -c user.name=t -c user.email=t@t "$@"; }
wg checkout -q -b dev 2>/dev/null
mkdir -p "$W/kubeapps/app/dev"
printf 'data:\n  render-sha: "%s"\n' "$C1" > "$W/kubeapps/app/dev/pipeline-images.yaml"
wg add -A; wg commit -qm start; wg push -q origin dev 2>/dev/null
git clone -q --depth=1 --branch dev "$OR" "$T/gitops-x" && mv "$T/gitops-x" "$T/gitops"
# newer run Y lands its render while the run for c2 still renders
printf 'data:\n  render-sha: "%s"\n' "$C3" > "$W/kubeapps/app/dev/pipeline-images.yaml"
wg commit -qam "render y"; wg push -q origin dev 2>/dev/null
OUT=$(sh -c '
  . "$1"; RUN_SHA="$2"; APP_REPO_URL="$3"
  rm -rf /tmp/gitops; cp -r "$4" /tmp/gitops
  git -C /tmp/gitops fetch -q origin dev
  R=$(recorded_at origin/dev kubeapps/app/dev/pipeline-images.yaml render-sha)
  echo "recorded=$R"; if older_than_record "$R"; then echo skip; else echo write; fi
  rm -rf /tmp/gitops' sh "$T/mono.sh" "$C2" "$APP" "$T/gitops" 2>/dev/null)
expect_eq "$(printf '%s\n' "$OUT" | tr '\n' ' ')" "recorded=$C3 skip " "lost push race: the guard asked again on the fetched branch skips"
OUT=$(sh -c '
  . "$1"; RUN_SHA="$2"; APP_REPO_URL="$3"
  rm -rf /tmp/gitops; cp -r "$4" /tmp/gitops
  git -C /tmp/gitops fetch -q origin dev
  R=$(recorded_at origin/dev kubeapps/app/dev/pipeline-images.yaml render-sha)
  if older_than_record "$R"; then echo skip; else echo write; fi
  rm -rf /tmp/gitops' sh "$T/mono.sh" "$C3" "$APP" "$T/gitops" 2>/dev/null)
expect_eq "$OUT" "write" "lost push race to an OLDER render: written"

# The record writer: render-sha moves with every render, the other stamps as before.
printf 'metadata:\n  namespace: ns\ndata:\n  last-built-sha: "x"\n' > "$T/img.yaml"
printf 'metadata:\n  namespace: ns\nspec:\n  arguments: {parameters: []}\n  templates: []\n' > "$T/wft.yaml"
python3 - "$T/wft.yaml" "$T/img.yaml" app ctx1 v1 100 "$C2" < "$T/record.py" >/dev/null
expect_eq "$(yq e '.data."render-sha"+" "+.data."engine-version"+" "+.data."wft-bytes"+" "+.data."context-sha"' "$T/img.yaml")" "$C2 v1 100 ctx1" "a render stamps its commit with engine, context and size"
python3 - "$T/wft.yaml" "$T/img.yaml" app ctx1 v1 100 "$C3" < "$T/record.py" >/dev/null 2>&1
expect_eq "$(yq e '.data."render-sha"' "$T/img.yaml")" "$C3" "an unchanged render still records the newer commit"

# Defect 2: the images file did not exist at render time; patch-images stamps what it lacks.
mkdir -p "$T/ws/out"
printf 'render-sha=%s\ncontext-sha=ctx9\nengine-version=v9\nwft-bytes=321\n' "$C3" > "$T/ws/out/render-stamp"
sed "s#/workspace/#$T/ws/#g" "$T/stamps.sh" > "$T/stamps-run.sh"
printf 'data:\n  last-built-sha: "%s"\n  engine-version: "kept"\n' "$C3" > "$T/img2.yaml"
IMAGES_PATH="$T/img2.yaml" sh -c '. "$0"' "$T/stamps-run.sh" >/dev/null 2>&1
expect_eq "$(yq e '.data."render-sha"+" "+.data."engine-version"+" "+.data."wft-bytes"+" "+.data."context-sha"' "$T/img2.yaml")" "$C3 kept 321 ctx9" "a record without stamps is completed; a key with a value is not overwritten"
rm -f "$T/ws/out/render-stamp"
printf 'data:\n  last-built-sha: "x"\n' > "$T/img3.yaml"
IMAGES_PATH="$T/img3.yaml" sh -c '. "$0"' "$T/stamps-run.sh" >/dev/null 2>&1
expect_eq "$(yq e '.data | keys | join(",")' "$T/img3.yaml")" "last-built-sha" "a run that rendered nothing adds no stamp"

echo "passed: ${PASSED}, failed: ${FAILED}"
exit "$FAILED"
