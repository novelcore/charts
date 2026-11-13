#!/usr/bin/env bash
# Tests for the run-form seal wiring (PRD novelcore/kaos#1533, F-21, chart 0.15.0).
# Usage (from the repo root; the rendered file is optional, the test renders the chart itself without it):
#
#   bash charts/custom/kubecore-ci-workflows/tests/run-form-seal/run.sh [/tmp/rendered.yaml]
#
# Static: the order in hera-enhance-commit (merge) and hera-enhance-gate (PR), the env-sourced commit, the guard.
# Executed: the seal block runs against a stub engine (absent, failing, succeeding), so the skip, the
# fail-closed exit and the arguments are checked, not only the text. Needs helm, yq v4, python3.
# Exit status is the number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0
PASSED=0
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

expect_eq() {
  if [ "$1" = "$2" ]; then PASSED=$((PASSED + 1)); echo "PASS: $3"
  else FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi
}
expect_has() {
  case "$1" in
    *"$2"*) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
    *) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  expected to contain: $2"; echo "  actual: $(printf '%s' "$1" | tail -5)" ;;
  esac
}
expect_lacks() {
  case "$1" in
    *"$2"*) FAILED=$((FAILED + 1)); echo "FAIL: $3"; echo "  must not contain: $2" ;;
    *) PASSED=$((PASSED + 1)); echo "PASS: $3" ;;
  esac
}

RENDERED="${1:-}"
if [ -z "$RENDERED" ]; then RENDERED="${T}/rendered.yaml"; helm template t "$CHART" --set github.tokenSecretName=ci-token > "$RENDERED" || exit 1; fi

COMMIT="${T}/commit.src"; GATE="${T}/gate.src"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
    | .spec.templates[] | select(.name == "hera-enhance-commit") | .container.args[0]' "$RENDERED" > "$COMMIT"
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-pr-render")
    | .spec.templates[] | select(.name == "hera-enhance-gate") | .container.args[0]' "$RENDERED" > "$GATE"

line() { grep -n -F -m1 -- "$2" "$1" | cut -d: -f1; }
ordered() { # file, then anchors in the expected order
  local f="$1"; shift; local prev=0 n ok=yes
  for a in "$@"; do
    n=$(line "$f" "$a"); if [ -z "$n" ] || [ "$n" -le "$prev" ]; then ok="no: '$a' (line ${n:-missing}) is not after line $prev"; break; fi
    prev=$n
  done
  echo "$ok"
}

expect_eq "$(ordered "$COMMIT" 'python3 -m kubecore.enhance' "<<'DSEOF'" 'python3 -m kubecore.run_form seal' "<<'GATEEOF'" "<<'WFTSIZEEOF'" 'cp /workspace/out/workflow-template.yaml "$WFT_FILE"')" "yes" \
  "merge build: enhance, dataset fill, seal, GATE, size guard, copy to gitops"
expect_eq "$(ordered "$GATE" 'python3 -m kubecore.enhance' 'python3 -m kubecore.run_form seal' "<<'GATEEOF'")" "yes" \
  "PR render: enhance, seal, GATE"

# The commit is an env var of the step, never spliced into a script.
expect_eq "$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
  | .spec.templates[] | select(.name == "hera-enhance-commit") | .container.env[] | select(.name == "COMMIT_SHA") | .value' "$RENDERED")" \
  '{{workflow.parameters.commit_sha}}' "merge build: COMMIT_SHA comes from the workflow parameter through the env"
expect_eq "$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-pr-render")
  | .spec.templates[] | select(.name == "hera-enhance-gate") | .container.env[] | select(.name == "COMMIT_SHA") | .value' "$RENDERED")" \
  '{{workflow.parameters.commit_sha}}' "PR render: COMMIT_SHA is the PR head SHA through the env"

block() { awk '/^# RUN FORM/{on=1} on && /^# GATE[: ]/{on=0} on' "$1"; }
block "$COMMIT" > "${T}/seal-commit.sh"; block "$GATE" > "${T}/seal-gate.sh"
for w in commit gate; do
  b=$(cat "${T}/seal-${w}.sh")
  expect_has "$b" 'kubecore.run_form seal' "${w}: the seal block is there"
  expect_lacks "$b" '{{' "${w}: no workflow parameter is spliced into the seal"
  expect_lacks "$b" 'workflow.parameters' "${w}: the commit is not read from a parameter inside the script"
  expect_has "$b" '--source-commit "${COMMIT_SHA}"' "${w}: --source-commit takes the env var"
  expect_has "$b" '[ -f "${ENGINE_DIR}/kubecore/run_form.py" ]' "${w}: guarded by the engine having run_form.py"
  expect_has "$b" '( cd "${ENGINE_DIR}" && python3 -m kubecore.run_form seal' "${w}: runs from the engine directory"
  expect_lacks "$b" 'python3 -I' "${w}: not isolated mode (it would hide the engine directory)"
done
expect_has "$(cat "${T}/seal-commit.sh")" '--previous "${GITOPS_DIR}/workflow-template.yaml"' "merge build: passes --previous (the live template)"
expect_has "$(cat "${T}/seal-commit.sh")" 'if [ -f "${GITOPS_DIR}/workflow-template.yaml" ]' "merge build: --previous only when the live template exists"
expect_lacks "$(cat "${T}/seal-gate.sh")" '--previous' "PR render: no --previous"

# Executed against a stub engine. The stub records its arguments; STUB_FAIL makes it refuse.
mkstub() { # dir
  mkdir -p "$1/kubecore"; : > "$1/kubecore/__init__.py"
  cat > "$1/kubecore/run_form.py" <<'PYEOF'
import os, sys
open(os.environ["STUB_ARGS"], "w").write(" ".join(sys.argv[1:]))
if os.environ.get("STUB_FAIL"):
    print("GATE FAIL: run form: stub refusal", file=sys.stderr)
    sys.exit(1)
PYEOF
}
SHA=$(printf 'ab%.0s' $(seq 1 20))
run() { # script, env assignments...  -> sets OUT, RC
  local s="$1"; shift
  OUT=$(env "$@" sh -c "set -e; $(cat "$s"); echo REACHED-GATE" 2>&1); RC=$?
}
for w in commit gate; do
  S="${T}/seal-${w}.sh"; E="${T}/engine-${w}"; mkdir -p "$E/empty" "${T}/gitops"; mkstub "$E/with"
  A="${T}/args-${w}"; rm -f "$A"
  run "$S" ENGINE_DIR="$E/empty" COMMIT_SHA="$SHA" GITOPS_DIR="${T}/gitops" STUB_ARGS="$A"
  expect_eq "$RC" "0" "${w}: an engine without run_form.py continues"
  expect_has "$OUT" "the pinned engine has no kubecore/run_form.py; skipping the seal" "${w}: ...and logs one line"
  expect_eq "$([ -e "$A" ] && echo ran)" "" "${w}: ...without running anything"

  run "$S" ENGINE_DIR="$E/with" COMMIT_SHA="$SHA" GITOPS_DIR="${T}/gitops" STUB_ARGS="$A" STUB_FAIL=1
  expect_eq "$RC" "1" "${w}: a failing seal fails the step"
  expect_has "$OUT" "GATE FAIL: run form: stub refusal" "${w}: ...and prints the GATE FAIL text"
  expect_lacks "$OUT" "REACHED-GATE" "${w}: ...before the gate, the size guard and the copy"

  for bad in "" "ABCDEF$(printf 'a%.0s' $(seq 1 34))" "${SHA%?}" "${SHA}a" "${SHA%?};x" ; do
    rm -f "$A"
    run "$S" ENGINE_DIR="$E/with" COMMIT_SHA="$bad" GITOPS_DIR="${T}/gitops" STUB_ARGS="$A"
    expect_eq "$RC:$([ -e "$A" ] && echo ran)" "1:" "${w}: commit '${bad}' is refused before the seal runs"
  done

  rm -f "$A"; rm -f "${T}/gitops/workflow-template.yaml"
  run "$S" ENGINE_DIR="$E/with" COMMIT_SHA="$SHA" GITOPS_DIR="${T}/gitops" STUB_ARGS="$A"
  expect_eq "$RC" "0" "${w}: a good seal continues"
  expect_eq "$(cat "$A")" "seal --wft /workspace/out/workflow-template.yaml --source-commit ${SHA}" "${w}: arguments without a live template"
  : > "${T}/gitops/workflow-template.yaml"
  run "$S" ENGINE_DIR="$E/with" COMMIT_SHA="$SHA" GITOPS_DIR="${T}/gitops" STUB_ARGS="$A"
  if [ "$w" = commit ]; then
    expect_eq "$(cat "$A")" "seal --wft /workspace/out/workflow-template.yaml --source-commit ${SHA} --previous ${T}/gitops/workflow-template.yaml" "commit: --previous once the live template exists"
  else
    expect_eq "$(cat "$A")" "seal --wft /workspace/out/workflow-template.yaml --source-commit ${SHA}" "gate: never --previous"
  fi
  rm -f "${T}/gitops/workflow-template.yaml"
done

echo "run-form-seal: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
