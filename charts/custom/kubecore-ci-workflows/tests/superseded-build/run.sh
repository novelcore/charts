#!/usr/bin/env bash
# A build of a commit that is OLDER than the commit already built does nothing.
#
# Two pushes seconds apart start two builds of one app. They take the app's build lock one after the
# other, in no promised order. When the older commit ran second it was built in full, the app's images
# and last-built-sha went BACK to it, and the head had to be built a third time (live 2026-11-14).
#
#   bash charts/custom/kubecore-ci-workflows/tests/superseded-build/run.sh
#
# The decision block of detect-steps is EXECUTED against real git histories. Needs helm, yq v4, git.
# Exit status is the number of failed assertions.
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
BASE_TMP=$(mktemp -d)
trap 'rm -rf "$BASE_TMP"' EXIT
RENDERED="${BASE_TMP}/rendered.yaml"
helm template t "$CHART" --set github.org=acme > "$RENDERED" || { echo "FAIL: helm template"; exit 1; }
tpl() { yq "select(.metadata.name == \"ml-ci-build\") | .spec.templates[] | select(.name == \"$1\")" "$RENDERED"; }
DS=$(tpl detect-steps | yq '.container.args[0]')

# ── the decision, executed ───────────────────────────────────────────────────
BLOCK="${BASE_TMP}/block.sh"
printf '%s\n' "$DS" | sed -n '/LAST-BUILT begin/,/LAST-BUILT end/p' > "$BLOCK"
expect_eq "$([ "$(wc -l < "$BLOCK")" -gt 30 ] && echo yes)" "yes" "detect-steps carries the last-built decision block"

# History: c1 - c2 - c3 on dev, and "other", a commit that is on no line with them.
REPO="${BASE_TMP}/repo"
git init -q "$REPO"
g() { git -C "$REPO" -c user.name=t -c user.email=t@t "$@"; }
mkdir -p "$REPO/steps/a" "$REPO/steps/b"
echo 1 > "$REPO/steps/a/f"; g add -A; g commit -qm c1; C1=$(g rev-parse HEAD)
echo 2 > "$REPO/steps/b/f"; g add -A; g commit -qm c2; C2=$(g rev-parse HEAD)
echo 3 > "$REPO/steps/a/f"; g add -A; g commit -qm c3; C3=$(g rev-parse HEAD)
g checkout -q --orphan other; echo x > "$REPO/x"; g add -A; g commit -qm other; OTHER=$(g rev-parse HEAD)

# decide HEAD LAST_BUILT EVENT: runs the block; sets SUP (superseded), CH (changed files), OUT.
decide() {
  git -C "$REPO" checkout -q --detach "$1"
  printf 'data:\n  last-built-sha: "%s"\n' "$2" > "${BASE_TMP}/images.yaml"
  sed "s/{{workflow.parameters.event_type}}/$3/g" "$BLOCK" > "${BASE_TMP}/run.sh"
  OUT=$( cd "$REPO" && IMAGES_PATH="${BASE_TMP}/images.yaml" WFT_SRC_RE='^pipeline\.py$' sh -c '
    set -eu
    SUPERSEDED=false
    CHANGED_FILES="untouched"
    . "$1"
    printf "\nSUP=%s\nCH=%s\n" "$SUPERSEDED" "$(printf "%s" "$CHANGED_FILES" | tr "\n" ",")"
  ' sh "${BASE_TMP}/run.sh" 2>&1 )
  SUP=$(printf '%s\n' "$OUT" | sed -n 's/^SUP=//p')
  CH=$(printf '%s\n' "$OUT" | sed -n 's/^CH=//p')
}

decide "$C2" "$C3" push
expect_eq "$SUP" "true" "older commit, newer one already built: superseded"
expect_eq "$(printf '%s' "$OUT" | grep -c "SUPERSEDED: ${C2} is an ancestor of last-built-sha ${C3}")" "1" "...and the log says which commit and why"
decide "$C1" "$C3" push
expect_eq "$SUP" "true" "two commits behind the built one: superseded"
decide "$C1" "$C3" pr_merged
expect_eq "$SUP" "true" "a merge event of an older commit is superseded as well"

decide "$C3" "$C2" push
expect_eq "$SUP|$CH" "false|steps/a/f" "newer commit than the built one: built, with the diff since the built commit"
decide "$C3" "$C3" push
expect_eq "$SUP|$CH" "false|untouched" "the built commit pushed again: not superseded, decided as before"
decide "$C3" "$C3" reconcile
expect_eq "$SUP|$CH" "false|" "a reconcile of the built commit: not superseded, rebuilds no step"
decide "$C2" "$C3" reconcile
expect_eq "$SUP" "false" "a reconcile is never superseded: it is the backstop and always renders"
decide "$C2" "" push
expect_eq "$SUP|$CH" "false|untouched" "no built commit yet (first build): built"
decide "$C2" "$OTHER" push
expect_eq "$SUP" "false" "the built commit is on another line of history (rewritten branch): built"
decide "$C2" "0123456789012345678901234567890123456789" push
expect_eq "$SUP" "false" "the built commit is not in the clone: unknown is never a reason to skip"
decide "$C2" "\$(touch ${BASE_TMP}/PWNED); touch ${BASE_TMP}/PWNED" push
expect_eq "$SUP|$([ -e "${BASE_TMP}/PWNED" ] && echo pwned || echo clean)" "false|clean" "a malformed recorded commit is data, never run, and never a reason to skip"

# ── what a superseded run writes and what it skips ───────────────────────────
TAIL="${BASE_TMP}/tail.sh"
printf '%s\n' "$DS" | sed -n '/printf .%s. "\$SUPERSEDED" > \/tmp\/superseded/,/^fi$/p' > "$TAIL"
expect_eq "$([ "$(wc -l < "$TAIL")" -ge 7 ] && echo yes)" "yes" "detect-steps writes the superseded outcome"
W="${BASE_TMP}/w"; mkdir -p "$W"
write_case() {
  rm -f "$W"/*
  printf '[{"name":"a"}]' > "$W/changed_steps.json"; printf true > "$W/has_changes"; printf true > "$W/wft_changed"; printf v1 > "$W/engine_compose"
  sed "s#/tmp/#$W/#g" "$TAIL" > "${BASE_TMP}/tail-run.sh"
  SUPERSEDED=$1 LAST_BUILT=$C3 sh "${BASE_TMP}/tail-run.sh"
}
write_case true
expect_eq "$(cat "$W/superseded")|$(cat "$W/changed_steps.json")|$(cat "$W/has_changes")|$(cat "$W/wft_changed")|$(cat "$W/engine_compose")" "true|[]|false|false|" \
  "superseded: no step to build, no render, no compose image"
expect_eq "$(cat "$W/status_description")" "Not built: a newer commit of this branch ($(printf '%s' "$C3" | cut -c1-8)) is already built" "superseded: the commit status says why nothing was built"
write_case false
expect_eq "$(cat "$W/superseded")|$(cat "$W/changed_steps.json")|$(cat "$W/has_changes")|$(cat "$W/wft_changed")|$(cat "$W/engine_compose")|$([ -e "$W/status_description" ] && echo set || echo unset)" \
  'false|[{"name":"a"}]|true|true|v1|unset' "not superseded: every output is left as decided"

out() { tpl detect-steps | yq ".outputs.parameters[] | select(.name == \"$1\") | .valueFrom.$2"; }
expect_eq "$(out superseded default)|$(out status_description default)" "false|ML build succeeded" \
  "a detect step that ends before the decision reports not superseded and the usual status text"
RUN=$(tpl ml-ci-run)
when_of() { printf '%s\n' "$RUN" | yq ".steps[][] | select(.name == \"$1\") | .when"; }
NOT_SUP='{{steps.detect-steps.outputs.parameters.superseded}} != true'
for s in patch-images render-hera; do
  case "$(when_of "$s")" in *"&& ${NOT_SUP}") r=yes ;; *) r=no ;; esac
  expect_eq "$r" "yes" "$s is skipped for a superseded commit (last-built-sha and the template stay on the newer one)"
done
for s in build-push tag; do
  case "$(when_of "$s")" in *'{{steps.detect-steps.outputs.parameters.has_changes}} == true'*) r=yes ;; *) r=no ;; esac
  expect_eq "$r" "yes" "$s runs only with changes, and a superseded run reports none"
done
expect_eq "$(printf '%s\n' "$RUN" | yq '.steps[][] | select(.name == "status") | .arguments.parameters[] | select(.name == "description") | .value')" \
  '{{steps.detect-steps.outputs.parameters.status_description}}' "the final commit status carries the text detect-steps decided"

echo
echo "passed: ${PASSED}  failed: ${FAILED}"
exit "$FAILED"
