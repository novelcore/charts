#!/bin/sh
# Render assertions for the tooling steps: ci-reconcile and ml-ci-reconcile
# check-drift, ml-autoscaler-healer, ml-nodepool-janitor and
# ml-compute-catalog-probe. Their tools must be baked into pinned images, and
# their pods must not be BestEffort. These steps used to run
# `gcloud components install kubectl` at start-up with no requests. On a busy
# system node that took 9-18 minutes before ~5s of logic, and it held up a new
# ML app's first build. Usage (from the repo root):
#
#   helm template t charts/custom/kubecore-ci-workflows > /tmp/rendered.yaml
#   sh charts/custom/kubecore-ci-workflows/tests/tooling-images/run.sh /tmp/rendered.yaml
#
# Needs yq v4 on PATH. Exit status is the number of failed assertions.
set -u
RENDERED="$1"
FAILED=0
PASSED=0
ok() { PASSED=$((PASSED + 1)); echo "PASS: $1"; }
ko() { FAILED=$((FAILED + 1)); echo "FAIL: $1"; }

# The step template of a CWT: the one template that runs a container.
tpl() {
  yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$1\")
      | .spec.templates[] | select(.container != null) | $2" "$RENDERED"
}

for cwt in ci-reconcile ml-ci-reconcile ml-autoscaler-healer ml-nodepool-janitor ml-compute-catalog-probe; do
  img=$(tpl "$cwt" '.container.image')
  [ -n "$img" ] || { ko "$cwt: step template found"; continue; }
  # An exact version tag starts with a dotted number (1.36.4, 585.0.0-alpine);
  # floating tags (alpine, latest, slim) and untagged images fail.
  case "${img##*:}" in
    [0-9]*.[0-9]*) ok "$cwt: image '$img' is pinned to an exact version" ;;
    *) ko "$cwt: image '$img' is pinned to an exact version" ;;
  esac
  script=$(tpl "$cwt" '.container.args[0]')
  case "$script" in
    *"components install"*|*"apk add"*|*"apt-get"*|*"pip install"*)
      ko "$cwt: script installs nothing at start-up" ;;
    *) ok "$cwt: script installs nothing at start-up" ;;
  esac
  for r in cpu memory; do
    v=$(tpl "$cwt" ".container.resources.requests.$r")
    if [ -n "$v" ] && [ "$v" != "null" ]; then ok "$cwt: requests $r ($v)"
    else ko "$cwt: requests $r"; fi
  done
done

# The gcloud image has no kubectl: it comes from the pinned init container.
for cwt in ml-autoscaler-healer ml-nodepool-janitor ml-compute-catalog-probe; do
  init=$(tpl "$cwt" '.initContainers[] | select(.name == "kubectl-bin") | .image')
  case "${init##*:}" in
    [0-9]*.[0-9]*) ok "$cwt: kubectl-bin init container uses a pinned image ($init)" ;;
    *) ko "$cwt: kubectl-bin init container uses a pinned image (got '$init')" ;;
  esac
  mnt=$(tpl "$cwt" '.container.volumeMounts[] | select(.name == "kubectl-bin") | .mountPath')
  vol=$(tpl "$cwt" '.volumes[] | select(.name == "kubectl-bin") | .emptyDir')
  script=$(tpl "$cwt" '.container.args[0]')
  if [ "$mnt" = "/opt/kubectl-bin" ] && [ -n "$vol" ] && [ "$vol" != "null" ]; then
    case "$script" in
      *'export PATH="/opt/kubectl-bin:${PATH}"'*) ok "$cwt: step mounts kubectl-bin and puts it on PATH" ;;
      *) ko "$cwt: step puts /opt/kubectl-bin on PATH" ;;
    esac
  else
    ko "$cwt: step mounts the kubectl-bin emptyDir at /opt/kubectl-bin (mount='$mnt')"
  fi
done

echo "tooling-images: ${PASSED} passed, ${FAILED} failed"
exit "$FAILED"
