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
g branch -M dev 2>/dev/null; g checkout -q -b side "$C1"; echo s > "$APP/s"; g add -A; g commit -qm side; SIDE=$(g rev-parse HEAD)
g checkout -q -; g config uploadpack.allowAnySHA1InWant true

# older RUN REC [URL]: the guard's answer for a run of commit RUN and a recorded render REC
older() {
  sh -c '. "$1"; RUN_SHA="$2"; APP_REPO_URL="$4"; APP_BRANCH=dev; if older_than_record "$3"; then echo skip; else echo write; fi' \
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

# The rewind: a force push moved the branch back to c1; the render recorded for c3 is no longer on it.
APP2="$T/app2"; git clone -q --bare "$APP" "$APP2"; git -C "$APP2" config uploadpack.allowAnySHA1InWant true
git -C "$APP2" update-ref refs/heads/dev "$C1"
expect_eq "$(older "$C1" "$C3" "$APP2")" "write" "the branch rewound to this commit: the recorded newer commit is gone, written"
expect_eq "$(older "$C1" "$C3" "$APP")" "skip" "the real race (the branch tip holds the recorded commit): skipped"
OUT=$(sh -c '. "$1"; RUN_SHA="$2"; APP_REPO_URL="$4"; APP_BRANCH=dev; older_than_record "$3"; echo rc=$?' sh "$T/mono.sh" "$C1" "$C3" "$APP2" 2>&1)
expect_eq "$(printf '%s' "$OUT" | grep -c 'history rewritten')" "1" "the log says the history was rewritten"
OUT=$(sh -c '. "$1"; RUN_SHA="$2"; APP_REPO_URL="$4"; APP_BRANCH=dev; older_than_record "$3"; echo rc=$?' sh "$T/mono.sh" "$C1" "$C3" "$T/nowhere" 2>&1)
expect_eq "$(printf '%s' "$OUT" | grep -c "could not read $C3 (recorded), $C1 (this run) or branch dev")" "1" "an unreadable app repository is said with the commits and git's own words"
OUT=$(sh -c '. "$1"; RUN_SHA="$2"; APP_REPO_URL="$4"; APP_BRANCH=dev; older_than_record "$3"; echo rc=$?' sh "$T/mono.sh" "$C1" "$C3" "$APP" 2>&1)
expect_eq "$(printf '%s' "$OUT" | grep -c "$C1 is older than the recorded $C3, which is on dev: skipping")" "1" "a guard that answered says so in the log"

# ---- the real flows: two clones of a bare gitops repository, a bare app repository -----------------
sed -n '/WRITE begin/,/WRITE end/p' "$T/enhance.sh" > "$T/enh-write.sh"
sed -n '/WRITE begin/,/WRITE end/p' "$T/patch.sh" > "$T/patch-write.sh"
expect_eq "$([ -s "$T/enh-write.sh" ] && [ -s "$T/patch-write.sh" ] && echo yes)" "yes" "both writers carry a WRITE block"
OR="$T/origin.git"
new_origin() {  # new_origin BASE_RENDER_SHA: a bare gitops repository with one app record on dev
  rm -rf "$OR" "$T/seed"; git init -q --bare -b dev "$OR"; git clone -q "$OR" "$T/seed" 2>/dev/null
  mkdir -p "$T/seed/kubeapps/app/dev"
  printf 'kind: ConfigMap\ndata:\n  context.yaml: "a: 1"\n' > "$T/seed/kubeapps/app/dev/pipeline-context.yaml"
  printf 'metadata:\n  namespace: ns\ndata:\n  last-built-sha: "%s"\n  render-sha: "%s"\n  engine-version: v1\n' "$1" "$1" > "$T/seed/kubeapps/app/dev/pipeline-images.yaml"
  printf '# base\n' > "$T/seed/kubeapps/app/dev/workflow-template.yaml"
  git -C "$T/seed" -c user.name=t -c user.email=t@t checkout -q -b dev 2>/dev/null
  git -C "$T/seed" -c user.name=t -c user.email=t@t add -A; git -C "$T/seed" -c user.name=t -c user.email=t@t commit -qm base
  git -C "$T/seed" push -q origin dev 2>/dev/null
}
clone_gitops() { rm -rf "$1"; git clone -q "$OR" "$1" 2>/dev/null; git -C "$1" checkout -q dev; }
live() { git -C "$T/seed" pull -q origin dev 2>/dev/null; head -1 "$T/seed/kubeapps/app/dev/$1"; }
# run_enhance SHA CLONE: hera-enhance-commit's write block for the run of commit SHA on the checkout CLONE
run_enhance() {
  ws="$T/ws-$1"; rm -rf "$ws"; mkdir -p "$ws/out"; printf '# render of %s\nspec: {templates: []}\n' "$1" > "$ws/out/workflow-template.yaml"
  sed -e "s#/workspace#$ws#g; s#/tmp/gitops#$2#g" "$T/enh-write.sh" > "$T/enh-run.sh"
  ENH_OUT=$(cd "$2" && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    GITOPS_DIR="$2/kubeapps/app/dev" CONTEXT_PATH="$2/kubeapps/app/dev/pipeline-context.yaml" APP_NAME=app \
    ENGINE_VERSION=v2 WFT_BYTES=10 GITOPS_BRANCH=dev ORG=acme GITOPS_REPO=g HOME="$T" sh -c '
      . "$1"; RUN_SHA="$2"; APP_REPO_URL="$3"; APP_BRANCH=dev; sleep() { :; }; . "$4"' sh "$T/mono.sh" "$1" "$APP" "$T/enh-run.sh" 2>&1)
  ENH_RC=$?
}
render_sha() { git -C "$T/seed" pull -q origin dev 2>/dev/null; yq e '.data."render-sha"' "$T/seed/kubeapps/app/dev/pipeline-images.yaml"; : ; }
render_sha_old() { live pipeline-images.yaml | yq e '.data."render-sha"' -; }

new_origin "$C1"; clone_gitops "$T/ca"; clone_gitops "$T/cb"
run_enhance "$C2" "$T/ca"
expect_eq "$ENH_RC $(render_sha) $(live workflow-template.yaml)" "0 $C2 # render of $C2" "the first run lands its render"
run_enhance "$C3" "$T/cb"
expect_eq "$ENH_RC $(render_sha) $(live workflow-template.yaml)" "0 $C3 # render of $C3" "older landed first, the newer run's push is rejected: it applies again, no conflict, the template is the newer one"
expect_eq "$(printf '%s' "$ENH_OUT" | grep -c 'push rejected')" "1" "the push really was rejected once"
expect_eq "$(printf '%s' "$ENH_OUT" | grep -c 'rebase failed')" "0" "no rebase is attempted"
expect_eq "$(git -C "$T/seed" log --format=%s | grep -c 'render WFT')" "2" "both renders are commits of the branch"

new_origin "$C1"; clone_gitops "$T/ca"; clone_gitops "$T/cb"
run_enhance "$C3" "$T/ca"
before=$(git -C "$OR" rev-parse dev)
run_enhance "$C2" "$T/cb"
expect_eq "$ENH_RC $(render_sha) $(live workflow-template.yaml)" "0 $C3 # render of $C3" "newer landed first: the older run's push is rejected, it skips, the template stays the newer one"
expect_eq "$(git -C "$OR" rev-parse dev)" "$before" "the gitops branch is unchanged by the older run"
expect_eq "$(printf '%s' "$ENH_OUT" | grep -c 'push rejected')" "1" "the push really was rejected"
expect_eq "$(printf '%s' "$ENH_OUT" | grep -c 'SUPERSEDED')" "1" "the log says it was superseded"
expect_eq "$(cat "$T/ws-$C2/report-extra.md" 2>/dev/null | grep -c 'Render skipped')" "1" "the run report says it too"

new_origin "$C1"; clone_gitops "$T/ca"; clone_gitops "$T/cb"; clone_gitops "$T/cc"
run_enhance "$C2" "$T/ca"
run_enhance "$C1" "$T/cb"
expect_eq "$ENH_RC $(render_sha)" "0 $C2" "three runs: the oldest, behind a landed render, skips"
run_enhance "$C3" "$T/cc"
expect_eq "$ENH_RC $(render_sha) $(live workflow-template.yaml)" "0 $C3 # render of $C3" "three runs: the newest lands last, whatever the order"

new_origin "$C3"; clone_gitops "$T/ca"
run_enhance "$C3" "$T/ca"
expect_eq "$ENH_RC $(render_sha)" "0 $C3" "the same commit again writes (and finds it current)"

# patch-images: last-built-sha moves forward only
# run_patch SHA CLONE
run_patch() {
  sed -e "s#/tmp/gitops#$2#g; s#/workspace#$T/wsp#g; s#{{workflow.parameters.commit_sha}}#$1#g; s#{{inputs.parameters.changed_steps}}#[]#g; s#{{workflow.parameters.build_registry_url}}##g; s#python3 -I /tmp/engine.py produced#echo ds; : #g; s#/tmp/changed.json#$T/changed.json#g" "$T/patch-write.sh" > "$T/patch-run.sh"
  PATCH_OUT=$(cd "$2" && GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t \
    IMAGES_PATH=./kubeapps/app/dev/pipeline-images.yaml APP_NAME=app IMAGE_TAG=t1 IMAGE_REPO=p/app REGISTRY=r GITOPS_BRANCH=dev ORG=acme GITOPS_REPO=g \
    KL_RECORD="${KLR:-}" KL_PREV="${KLP:-}" KL_COMPAT="${KLC:-}" ENGINE_COMPOSE= HOME="$T" sh -c '
      . "$1"; RUN_SHA="$2"; APP_REPO_URL="$3"; APP_BRANCH=dev; sleep() { :; }; . "$4"' sh "$T/mono.sh" "$1" "$APP" "$T/patch-run.sh" 2>&1)
  PATCH_RC=$?
}
last_built() { git -C "$T/seed" pull -q origin dev 2>/dev/null; yq e '.data."last-built-sha"' "$T/seed/kubeapps/app/dev/pipeline-images.yaml"; }
mkdir -p "$T/wsp"
new_origin "$C1"; clone_gitops "$T/ca"; clone_gitops "$T/cb"
run_patch "$C3" "$T/ca"
expect_eq "$PATCH_RC $(last_built)" "0 $C3" "patch-images records the first build"
run_patch "$C2" "$T/cb"
expect_eq "$PATCH_RC $(last_built)" "0 $C3" "an older run behind a recorded newer one: its push is rejected, last-built-sha stays on the newer commit"
new_origin "$C1"; clone_gitops "$T/ca"; clone_gitops "$T/cb"
run_patch "$C2" "$T/ca"
run_patch "$C3" "$T/cb"
expect_eq "$PATCH_RC $(last_built)" "0 $C3" "a newer run after an older one that landed: applied again onto it, recorded, no rebase conflict"
expect_eq "$(printf '%s' "$PATCH_OUT" | grep -c 'push rejected')" "1" "the push really was rejected"
expect_eq "$(printf '%s' "$PATCH_OUT" | grep -c 'rebase failed')" "0" "patch-images does not rebase"

# KAOS-LIB RECORD, compare-and-set (PRD novelcore/kaos#1911): a run that moved nothing writes back what IT
# read, so a render-only run (no build lock) racing a pin rebuild must not undo the rebuild's record.
OLDP="kaos-lib==0.2.0"; NEWP="kaos-lib==0.6.0"
klp() { git -C "$T/seed" pull -q origin dev 2>/dev/null; yq e '.data."kaos-lib-package"+" "+.data."kaos-lib-compat"' "$T/seed/kubeapps/app/dev/pipeline-images.yaml"; }
new_origin "$C1"; clone_gitops "$T/ca"; clone_gitops "$T/cb"
KLR="$OLDP" KLP="$OLDP" KLC=">=0.2" run_patch "$C2" "$T/ca"
expect_eq "$PATCH_RC $(klp)" "0 $OLDP >=0.2" "kaos-lib: a first record (nothing there) is written"
# the pin rebuild (it moved the spec) and a render-only run that read the OLD record before the rebuild landed
new_origin "$C1"; printf '  kaos-lib-package: "%s"\n  kaos-lib-compat: ">=0.2"\n' "$OLDP" >> "$T/seed/kubeapps/app/dev/pipeline-images.yaml"
git -C "$T/seed" -c user.name=t -c user.email=t@t commit -qam old-record; git -C "$T/seed" push -q origin dev 2>/dev/null
clone_gitops "$T/ca"; clone_gitops "$T/cb"
KLR="$NEWP" KLP="$OLDP" KLC=">=0.6" run_patch "$C2" "$T/ca"
expect_eq "$PATCH_RC $(klp)" "0 $NEWP >=0.6" "kaos-lib: the pin rebuild records the new spec"
KLR="$OLDP" KLP="$OLDP" KLC=">=0.2" run_patch "$C2" "$T/cb"
expect_eq "$PATCH_RC $(klp)" "0 $NEWP >=0.6" "kaos-lib: a render-only run that read the old record, its push rejected, does NOT write the old spec back over the rebuild's"
expect_eq "$(printf '%s' "$PATCH_OUT" | grep -c 'push rejected')" "1" "kaos-lib: the race was real (the push was rejected, the writes applied again)"
expect_eq "$(printf '%s' "$PATCH_OUT" | grep -c 'left at')" "1" "kaos-lib: the log says it left the record"
clone_gitops "$T/cb"
KLR="$OLDP" KLP="$OLDP" KLC=">=0.2" run_patch "$C2" "$T/cb"
expect_eq "$PATCH_RC $(klp)" "0 $NEWP >=0.6" "kaos-lib: ... also when the rebuild had landed before the run cloned"

clone_gitops "$T/cb"; git -C "$T/cb" pull -q origin dev
KLR="$NEWP" KLP="$NEWP" KLC=">=0.6" run_patch "$C3" "$T/cb"
expect_eq "$PATCH_RC $(klp)" "0 $NEWP >=0.6" "kaos-lib: a run that moved nothing and agrees with the record is harmless"

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
