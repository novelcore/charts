#!/bin/sh
# Render assertions for EVERY container the chart runs: each container,
# script and initContainer of every ClusterWorkflowTemplate, WorkflowTemplate
# and CronWorkflow, plus the step images render-wft writes into an ML app's
# pipeline WorkflowTemplate. Each must:
#   - run an image pinned to an exact version (x.y.z, optionally v-prefixed and
#     suffixed): floating tags (alpine, latest, slim, 3.20) and untagged images
#     fail;
#   - request cpu and memory (no BestEffort pods);
#   - install nothing when it starts (apk add, apt-get, pip install,
#     gcloud components install, a binary download from GitHub releases),
#     unless ALLOW below names the step with a reason.
# The tooling steps used to run `gcloud components install kubectl`, `apk add`
# or `pip install` at start-up with no requests. On a busy system node that
# took 9-18 minutes before ~5s of logic, and it held up a new ML app's first
# build. Usage (from the repo root):
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

# Steps allowed to install at start-up: "<owner>/<template>/<container>" and
# the reason. Every entry must still match a rendered step (a stale entry
# fails), so the list cannot silently outlive its step.
ALLOW='ml-ci-build/hera-render/main|pip install -e . installs the app repo'"'"'s own pyproject.toml (hera, hydra and whatever the developer pins) before running pipeline.py. Those dependencies are the developer'"'"'s and change per app, so no platform image can carry them; the step is tokenless and its image is pinned.'

allowed() {
  printf '%s\n' "$ALLOW" | while IFS='|' read -r key reason; do
    [ "$key" = "$1" ] && { printf '%s' "$reason"; break; }
  done
}

INSTALL_RE='apk add|apt-get|pip3? install|components install|releases/download'

# One line per container: owner<TAB>template<TAB>container<TAB>image<TAB>cpu<TAB>memory.
# Templates without a container (steps/dag) are skipped; a script template is
# reported like a container.
LIST=$(yq -r '
  select(.kind == "ClusterWorkflowTemplate" or .kind == "WorkflowTemplate" or .kind == "CronWorkflow")
  | .metadata.name as $o
  | (.spec.templates // .spec.workflowSpec.templates)[]
  | .name as $t
  | ( [(.container // .script) | select(. != null) | . * {"name": "main"}]
      + (.initContainers // []) )[]
  | [$o, $t, .name, (.image // ""),
     (.resources.requests.cpu // "" | tostring), (.resources.requests.memory // "" | tostring)]
  | @tsv' "$RENDERED" | grep -v '^---$')

N=$(printf '%s\n' "$LIST" | grep -c .)
[ "$N" -ge 40 ] && ok "found $N containers to check" || ko "found only $N containers (expected >= 40)"

TAB=$(printf '\t')
pinned() {
  case "$1" in *:*) ;; *) return 1 ;; esac
  # tag = text after the last ':' (a registry port has no '/' after it)
  tag=${1##*:}
  case "$tag" in */*) return 1 ;; esac
  printf '%s' "$tag" | grep -Eq '^v?[0-9]+\.[0-9]+\.[0-9]+([-+._][A-Za-z0-9._-]+)?$'
}

script_of() {
  yq -r "select(.metadata.name == \"$1\")
    | (.spec.templates // .spec.workflowSpec.templates)[] | select(.name == \"$2\")
    | ( [(.container // .script) | select(. != null) | . * {\"name\": \"main\"}]
        + (.initContainers // []) )[] | select(.name == \"$3\")
    | ((.args // []) + (.command // []) + [.source // \"\"]) | join(\"\n\")" "$RENDERED" | grep -v '^---$'
}

# A step's script without its comment lines: a comment that mentions an
# install is not one.
code_of() { script_of "$@" | grep -v '^[[:space:]]*#'; }

printf '%s\n' "$LIST" | grep . > "${TMPDIR:-/tmp}/tooling-images.$$"
while IFS="$TAB" read -r owner tmpl cname img cpu mem; do
  id="$owner/$tmpl/$cname"
  if pinned "$img"; then ok "$id: image '$img' is pinned"
  else ko "$id: image '$img' is pinned to an exact version"; fi
  if [ -n "$cpu" ] && [ -n "$mem" ]; then ok "$id: requests cpu=$cpu memory=$mem"
  else ko "$id: requests cpu and memory (cpu='$cpu' memory='$mem')"; fi
  hits=$(code_of "$owner" "$tmpl" "$cname" | grep -Eo "$INSTALL_RE" | sort -u | tr '\n' ' ')
  if [ -z "$hits" ]; then
    ok "$id: installs nothing at start-up"
  else
    reason=$(allowed "$id")
    if [ -n "$reason" ]; then ok "$id: allow-listed install ($hits): $reason"
    else ko "$id: installs at start-up: $hits"; fi
  fi
done < "${TMPDIR:-/tmp}/tooling-images.$$"
rm -f "${TMPDIR:-/tmp}/tooling-images.$$"

# Every allow-list entry names a step that exists AND still installs.
printf '%s\n' "$ALLOW" | while IFS='|' read -r key reason; do
  o=${key%%/*}; rest=${key#*/}; t=${rest%%/*}; c=${rest#*/}
  if code_of "$o" "$t" "$c" | grep -Eq "$INSTALL_RE"; then ok "allow-list entry $key is still needed"
  else echo "FAIL: allow-list entry $key matches no installing step: remove it"; exit 1; fi
done || FAILED=$((FAILED + 1))

# The step images render-wft writes into the app's pipeline WorkflowTemplate
# (create/destroy-nodegroups, the stockout guard, meluxina-run, hpc-burst) are
# Python literals inside the render-wft script.
RW=$(script_of ml-ci-build render-wft main)
GEN=$(printf '%s\n' "$RW" | sed -n "s/.*'image': '\([^']*\)'.*/\1/p")
[ -n "$GEN" ] && ok "render-wft writes literal step images" || ko "render-wft step images found"
for g in $GEN; do
  if pinned "$g"; then ok "render-wft generated image '$g' is pinned"
  else ko "render-wft generated image '$g' is pinned to an exact version"; fi
done
# The nodegroup steps run gcloud on a CI node: they carry requests too.
NG=$(printf '%s\n' "$RW" | grep -A1 "'image': '[^']*cloud-sdk" | grep -c "'resources': {\"requests\":{\"cpu\":\"[^\"]*\",\"memory\":\"[^\"]*\"}}")
[ "$NG" -eq 2 ] && ok "create/destroy-nodegroups request cpu and memory" \
  || ko "create/destroy-nodegroups request cpu and memory (found $NG of 2)"

# The gcloud image has no kubectl: it comes from the pinned init container.
tpl() {
  yq "select(.kind == \"ClusterWorkflowTemplate\" and .metadata.name == \"$1\")
      | .spec.templates[] | select(.container != null) | $2" "$RENDERED"
}
for cwt in ml-autoscaler-healer ml-nodepool-janitor ml-compute-catalog-probe; do
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
