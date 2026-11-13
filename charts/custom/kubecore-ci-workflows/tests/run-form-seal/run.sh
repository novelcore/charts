#!/usr/bin/env bash
# Tests for the run-form seal wiring (PRD novelcore/kaos#1533, F-21, chart 0.15.0).
# Usage (from the repo root; the rendered file is optional, the test renders the chart itself without it):
#
#   bash charts/custom/kubecore-ci-workflows/tests/run-form-seal/run.sh [/tmp/rendered.yaml]
#
# Static: the order in hera-enhance-commit (merge) and hera-enhance-gate (PR), the env-sourced commit, no skip guard.
# Executed: the seal block runs against a stub python3 (failing, succeeding), so the fail-closed exit, the
# arguments and the embedded script are checked, not only the text. Needs helm, yq v4, python3.
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
if [ -z "$RENDERED" ]; then RENDERED="${T}/rendered.yaml"; helm template t "$CHART" > "$RENDERED" || exit 1; fi

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

expect_eq "$(ordered "$COMMIT" 'python3 -m kubecore.enhance' "<<'DSEOF'" 'run_form.py seal' "<<'GATEEOF'" "<<'WFTSIZEEOF'" 'cp /workspace/out/workflow-template.yaml "$WFT_FILE"')" "yes" \
  "merge build: enhance, dataset fill, seal, GATE, size guard, copy to gitops"
expect_eq "$(ordered "$GATE" 'python3 -m kubecore.enhance' 'run_form.py seal' "<<'GATEEOF'")" "yes" \
  "PR render: enhance, seal, GATE"

# The commit is an env var of the step, never spliced into a script.
expect_eq "$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
  | .spec.templates[] | select(.name == "hera-enhance-commit") | .container.env[] | select(.name == "COMMIT_SHA") | .value' "$RENDERED")" \
  '{{workflow.parameters.commit_sha}}' "merge build: COMMIT_SHA comes from the workflow parameter through the env"
expect_eq "$(yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-pr-render")
  | .spec.templates[] | select(.name == "hera-enhance-gate") | .container.env[] | select(.name == "COMMIT_SHA") | .value' "$RENDERED")" \
  '{{workflow.parameters.commit_sha}}' "PR render: COMMIT_SHA is the PR head SHA through the env"

# kubecore.enhance writes the trusted form data the seal reads (engine hook H3).
for w in commit gate; do
  S="$COMMIT"; [ "$w" = gate ] && S="$GATE"
  expect_has "$(grep -n -A6 'python3 -m kubecore.enhance' "$S" | head -8)" '--form-data /tmp/form-data.json' "${w}: kubecore.enhance is given --form-data /tmp/form-data.json"
done

block() { awk '/^# RUN FORM/{on=1} on && /^# GATE[: ]/{on=0} on' "$1"; }
block "$COMMIT" > "${T}/seal-commit.sh"; block "$GATE" > "${T}/seal-gate.sh"
# the shell of the block, without the embedded script (python text legitimately mentions kubecore.run_form, --previous ...)
shell_of() { awk "/<<'RUNFORMPYEOF'/{skip=1; print; next} skip && /^RUNFORMPYEOF\$/{skip=0} !skip" "$1" | grep -v '^ *#'; }
shell_of "${T}/seal-commit.sh" > "${T}/shell-commit.sh"; shell_of "${T}/seal-gate.sh" > "${T}/shell-gate.sh"
for w in commit gate; do
  b=$(cat "${T}/shell-${w}.sh")
  expect_has "$b" 'python3 -I /tmp/kaos-run-form/run_form.py seal' "${w}: the seal runs from the chart-owned file in isolated mode"
  expect_lacks "$b" 'kubecore.run_form' "${w}: no engine module"
  expect_lacks "$b" 'ENGINE_DIR' "${w}: no engine directory in the seal (D10 guard gone)"
  expect_lacks "$b" 'skipping the seal' "${w}: no skip branch"
  expect_lacks "$b" 'python3 -m' "${w}: not run as a module"
  expect_lacks "$b" '{{' "${w}: no workflow parameter is spliced into the seal"
  expect_lacks "$b" 'workflow.parameters' "${w}: the commit is not read from a parameter inside the script"
  expect_has "$b" '--source-commit "${COMMIT_SHA}"' "${w}: --source-commit takes the env var"
  expect_has "$b" '--engine "${ENGINE_VERSION}"' "${w}: --engine takes the enhance's engine version"
  expect_has "$b" '--wft /workspace/out/workflow-template.yaml' "${w}: --wft"
  expect_has "$b" '--context /tmp/context.yaml' "${w}: --context"
  expect_has "$b" '--form-data /tmp/form-data.json' "${w}: --form-data"
  expect_has "$b" '--steps /tmp/steps.json' "${w}: --steps"
  expect_has "$b" '--config-dir /workspace/repo/config' "${w}: --config-dir"
  expect_eq "$(awk '/^\(/{in_sub=1} /^\)/{in_sub=0} /set --/ && !in_sub {n++} END{print n+0}' "${T}/shell-${w}.sh")" "0" "${w}: no set -- outside a subshell"
  expect_has "$(awk '/^\(/{in_sub=1} /^\)/{in_sub=0} /set --/ && in_sub {print}' "${T}/shell-${w}.sh")" 'set --' "${w}: the arguments are built inside a subshell"
  expect_eq "$(grep -c 'cd ' "${T}/shell-${w}.sh")" "0" "${w}: never cds anywhere (not into the checkout, not into the engine)"
done
expect_has "$(cat "${T}/shell-commit.sh")" '--previous "${GITOPS_DIR}/workflow-template.yaml"' "merge build: passes --previous (the live template)"
expect_has "$(cat "${T}/shell-commit.sh")" '[ -f "${GITOPS_DIR}/workflow-template.yaml" ]' "merge build: --previous only when the live template exists"
expect_lacks "$(cat "${T}/shell-gate.sh")" '--previous' "PR render: no --previous"
# no Argo template tag in the embedded script: Argo would try to resolve it (and fail the step)
expect_eq "$(grep -c '{{' "${CHART}/files/run_form.py")" "0" "files/run_form.py holds no {{ (Argo template tag)"

# Executed against a stub python3 that records its arguments; STUB_FAIL makes it refuse. The block's heredoc writes the
# script to the (redirected) /tmp/kaos-run-form, which must be byte-identical to files/run_form.py.
mkdir -p "${T}/bin"
cat > "${T}/bin/python3" <<'PYEOF'
#!/bin/sh
printf '%s' "$*" > "$STUB_ARGS"
if [ -n "${STUB_FAIL:-}" ]; then echo "GATE FAIL: run form: stub refusal" >&2; exit 1; fi
PYEOF
chmod +x "${T}/bin/python3"
SHA=$(printf 'ab%.0s' $(seq 1 20))
run() { # script, env assignments...  -> sets OUT, RC
  local s="$1"; shift
  OUT=$(env PATH="${T}/bin:${PATH}" "$@" sh -c "set -e; $(sed "s#/tmp/kaos-run-form#${T}/rf#g" "$s"); echo REACHED-GATE" 2>&1); RC=$?
}
for w in commit gate; do
  S="${T}/seal-${w}.sh"; mkdir -p "${T}/gitops"
  A="${T}/args-${w}"; rm -f "$A"; rm -rf "${T}/rf"
  run "$S" COMMIT_SHA="$SHA" ENGINE_VERSION=0.17.0 GITOPS_DIR="${T}/gitops" STUB_ARGS="$A"
  expect_eq "$RC" "0" "${w}: a good seal continues"
  expect_eq "$([ "$(cat "${T}/rf/run_form.py")" = "$(cat "${CHART}/files/run_form.py")" ] && echo same)" "same" "${w}: the block writes files/run_form.py (up to the trailing newline)"

  run "$S" COMMIT_SHA="$SHA" ENGINE_VERSION=0.17.0 GITOPS_DIR="${T}/gitops" STUB_ARGS="$A" STUB_FAIL=1
  expect_eq "$RC" "1" "${w}: a failing seal fails the step"
  expect_has "$OUT" "GATE FAIL: run form: stub refusal" "${w}: ...and prints the GATE FAIL text"
  expect_lacks "$OUT" "REACHED-GATE" "${w}: ...before the gate, the size guard and the copy"

  for bad in "" "ABCDEF$(printf 'a%.0s' $(seq 1 34))" "${SHA%?}" "${SHA}a" "${SHA%?};x" ; do
    rm -f "$A"
    run "$S" COMMIT_SHA="$bad" ENGINE_VERSION=0.17.0 GITOPS_DIR="${T}/gitops" STUB_ARGS="$A"
    expect_eq "$RC:$([ -e "$A" ] && echo ran)" "1:" "${w}: commit '${bad}' is refused before the seal runs"
  done

  # a workflow parameter named in the environment is the only commit source: a literal in the script is never used
  rm -f "$A"; rm -f "${T}/gitops/workflow-template.yaml"
  run "$S" COMMIT_SHA="$SHA" ENGINE_VERSION=0.17.0 GITOPS_DIR="${T}/gitops" STUB_ARGS="$A"
  expect_eq "$(cat "$A")" "-I ${T}/rf/run_form.py seal --wft /workspace/out/workflow-template.yaml --context /tmp/context.yaml --form-data /tmp/form-data.json --steps /tmp/steps.json --config-dir /workspace/repo/config --engine 0.17.0 --source-commit ${SHA}" "${w}: arguments without a live template"
  : > "${T}/gitops/workflow-template.yaml"
  run "$S" COMMIT_SHA="$SHA" ENGINE_VERSION=0.17.0 GITOPS_DIR="${T}/gitops" STUB_ARGS="$A"
  if [ "$w" = commit ]; then
    expect_eq "$(cat "$A")" "-I ${T}/rf/run_form.py seal --wft /workspace/out/workflow-template.yaml --context /tmp/context.yaml --form-data /tmp/form-data.json --steps /tmp/steps.json --config-dir /workspace/repo/config --engine 0.17.0 --source-commit ${SHA} --previous ${T}/gitops/workflow-template.yaml" "commit: --previous once the live template exists"
  else
    expect_lacks "$(cat "$A")" "--previous" "gate: never --previous"
  fi
  rm -f "${T}/gitops/workflow-template.yaml"
  # the positional parameters of the step's shell are not touched by building the arguments
  OUT=$(env PATH="${T}/bin:${PATH}" COMMIT_SHA="$SHA" ENGINE_VERSION=0.17.0 GITOPS_DIR="${T}/gitops" STUB_ARGS="$A" \
        sh -c "set -e; set -- keep me; $(sed "s#/tmp/kaos-run-form#${T}/rf#g" "$S"); echo \"\$*\"" 2>&1)
  expect_has "$OUT" "keep me" "${w}: the step's own positional parameters survive the seal block"
done

# The seal module itself (files/run_form.py): unit, golden, fail-closed, parity and limit tests. Needs python3 + PyYAML;
# jsonschema and RUN_FORM_OSR_DIR (a kaos-osr-edge-operator checkout, with go) add the schema and Go-consumer checks.
if UT=$(python3 -m unittest discover -s "${HERE}" -p 'test_*.py' 2>&1); then
  PASSED=$((PASSED + 1)); echo "PASS: seal module tests ($(printf '%s' "$UT" | grep -E '^(Ran|OK)' | tr '\n' ' '))"
else
  FAILED=$((FAILED + 1)); echo "FAIL: seal module tests"; printf '%s\n' "$UT" | tail -40
fi

echo "run-form-seal: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
