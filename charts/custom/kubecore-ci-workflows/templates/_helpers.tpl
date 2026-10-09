{{/*
Expand the name of the chart.
*/}}
{{- define "kubecore-ci-workflows.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
We truncate at 63 chars because some Kubernetes name fields are limited to this (by the DNS naming spec).
If release name contains chart name it will be used as a full name.
*/}}
{{- define "kubecore-ci-workflows.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Create chart name and version as used by the chart label.
*/}}
{{- define "kubecore-ci-workflows.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels
*/}}
{{- define "kubecore-ci-workflows.labels" -}}
helm.sh/chart: {{ include "kubecore-ci-workflows.chart" . }}
{{ include "kubecore-ci-workflows.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
app.kubernetes.io/part-of: kubecore
{{- end }}

{{/*
Selector labels
*/}}
{{- define "kubecore-ci-workflows.selectorLabels" -}}
app.kubernetes.io/name: {{ include "kubecore-ci-workflows.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
Create the name of the service account to use
*/}}
{{- define "kubecore-ci-workflows.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "kubecore-ci-workflows.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}

{{/*
Create the namespace name
*/}}
{{- define "kubecore-ci-workflows.namespace" -}}
{{- default .Release.Namespace .Values.workflow.namespace }}
{{- end }}

{{/*
User-managed CI secrets (kaos PRD 695, spec section 6.2) for the service
build-push steps of ci-build and ci-rc-build.

The operator renders two ExternalSecrets in {project}-ci, where these
workflows run: {project}-ci-secrets (KubeProject.spec.ci.secretBindings) and
{project}-{app}-ci-secrets (KubeApp secretBindings.ci; the app secret is
namespaced by project to avoid colliding with the project secret when an app
is named like its project). Their keys are p_{name}_{KEY} / o_{name}_{KEY}.
Both are OPTIONAL: a project or app with no CI bindings has no such Secret,
the kubelet mounts an empty directory, and the build is exactly what it was
before.

The raw Secrets are mounted ONLY into the ci-secrets-prep init container. The
kaniko container sees the laid-out copy on a memory-backed emptyDir at
/kaniko/secrets, which kaniko never snapshots into a layer.
*/}}
{{- define "kubecore-ci-workflows.ciSecretsVolumes" -}}
- name: ci-secrets-project
  secret:
    secretName: "{{`{{workflow.parameters.project_name}}`}}-ci-secrets"
    optional: true
- name: ci-secrets-app
  secret:
    secretName: "{{`{{workflow.parameters.project_name}}`}}-{{`{{workflow.parameters.app_name}}`}}-ci-secrets"
    optional: true
- name: kaniko-secrets
  emptyDir:
    medium: Memory
    sizeLimit: 16Mi
{{- end }}

{{/*
ci-secrets-prep init container: lays out /kaniko/secrets and writes
/kaniko/.docker/config.json (platform push credential + user registries).
It replaces the docker-config block the kaniko container used to run inline;
see files/ci-secrets-prep.sh and tests/ci-secrets-prep/run.sh. Runs as root
so the files it writes carry the same ownership kaniko (root) had before.
*/}}
{{- define "kubecore-ci-workflows.ciSecretsPrepInitContainer" -}}
- name: ci-secrets-prep
  image: {{ .Values.ciSecretsPrep.image | default "mikefarah/yq:4.44.3" }}
  command: [sh, -c]
  securityContext:
    runAsUser: 0
    runAsGroup: 0
  env:
  - name: REGISTRY
    value: {{ .Values.registry.internalUrl | quote }}
  - name: REGISTRY_TYPE
    value: "{{`{{workflow.parameters.registry_type}}`}}"
  - name: IMAGE_REPO
    value: "{{`{{workflow.parameters.image_repo}}`}}"
  args:
  - |
{{ .Files.Get "files/ci-secrets-prep.sh" | indent 4 }}
  volumeMounts:
  - name: ci-secrets-project
    mountPath: /etc/ci-secrets/project
    readOnly: true
  - name: ci-secrets-app
    mountPath: /etc/ci-secrets/app
    readOnly: true
  - name: registry-auth
    mountPath: /etc/registry-auth
    readOnly: true
  - name: kaniko-secrets
    mountPath: /kaniko/secrets
  - name: kaniko-config
    mountPath: /kaniko/.docker
{{- end }}

{{/*
The platform enhancer pin (platformEnhancer.ref), refused unless it is a full
commit sha (kubecore-operator#1199). ml-ci-build records it as the enhancer an
app was rendered with, and ml-ci-reconcile re-renders an app whose record
differs from it, labelling the build with it. A branch or tag would move under
the same name, so drift could never be seen, and a "/" in it is not a valid
label value, which would reject every reconcile-submitted build.
*/}}
{{- define "kubecore-ci-workflows.enhancerRef" -}}
{{- $ref := toString .Values.platformEnhancer.ref -}}
{{- if not (regexMatch "^[0-9a-f]{40}$" $ref) -}}
{{- fail (printf "platformEnhancer.ref must be a full 40-character commit sha, got %q" $ref) -}}
{{- end -}}
{{- $ref -}}
{{- end }}

{{/*
Run the pinned platform enhancer (kubecore-operator#1161) on the raw Hera WFT,
isolated from the app checkout (kubecore-operator#1375). Used by the two
token-holding Hera steps, hera-enhance-commit (merge) and hera-enhance-gate (PR).

The enhancer is unpacked OUTSIDE the workspace and run from there with nothing
of the app's on sys.path. /workspace/repo is developer-controlled: hera-render
just ran untrusted pipeline.py against it with write access (and on a PR it is
the PR head, possibly a fork). Installing it (`pip install -e`) or importing
from it (PYTHONPATH) ran that code next to the GitHub App token. The enhancer
needs only the standard library and PyYAML, and reads its inputs as data.

Caller: PyYAML installed, /tmp/context.yaml written, CATALOG_ARG set, the raw
WFT at /workspace/out/raw-workflow-template.yaml. Writes
/workspace/out/workflow-template.yaml. Fails loud: rendering with unknown
enhancer code is not an option.
*/}}
{{- define "kubecore-ci-workflows.platformEnhance" -}}
python3 - <<'OVERLAYEOF'
import io, os, shutil, tarfile, urllib.request
repo, ref = "{{ .Values.platformEnhancer.repo }}", "{{ .Values.platformEnhancer.ref }}"
req = urllib.request.Request(f"https://api.github.com/repos/{repo}/tarball/{ref}",
                             headers={"Accept": "application/vnd.github+json", "User-Agent": "kubecore-ci"})
tok = open("/etc/github-token/token").read().strip() if os.path.exists("/etc/github-token/token") else ""
if tok:
    req.add_header("Authorization", f"Bearer {tok}")
with urllib.request.urlopen(req, timeout=60) as r:
    tb = tarfile.open(fileobj=io.BytesIO(r.read()), mode="r:gz")
dst = "/tmp/kubecore-enhancer/kubecore"
shutil.rmtree(dst, ignore_errors=True); os.makedirs(dst)
n = 0
for m in tb.getmembers():
    parts = m.name.split("/", 1)
    if len(parts) < 2 or not parts[1].startswith("kubecore/") or "/local-dev/" in parts[1] + "/":
        continue
    rel = parts[1][len("kubecore/"):]
    if not rel or "__pycache__" in rel:
        continue
    out = os.path.join(dst, rel)
    if m.isdir():
        os.makedirs(out, exist_ok=True)
    elif m.isfile():
        os.makedirs(os.path.dirname(out), exist_ok=True)
        with tb.extractfile(m) as src, open(out, "wb") as f:
            f.write(src.read())
        n += 1
if n == 0:
    raise SystemExit(f"platform enhancer: no kubecore/ files in {repo}@{ref}")
print(f"platform enhancer: {repo}@{ref[:12]} ({n} files) unpacked to /tmp/kubecore-enhancer")
OVERLAYEOF
( cd /tmp/kubecore-enhancer && python3 -m kubecore.enhance \
    --raw /workspace/out/raw-workflow-template.yaml \
    --context /tmp/context.yaml \
    $CATALOG_ARG \
    --output /workspace/out/workflow-template.yaml )
{{- end }}

{{/*
Create and push an annotated tag on workflow.parameters.commit_sha from a FRESH
repository (kubecore-operator#1375). Never from /workspace/repo: earlier steps
ran developer code with write access to that checkout (pipeline.py in
hera-render, Dockerfile RUN in the image build), and a hook or .git/config
entry planted there would run on this push, next to the token.

Caller: TOKEN, TAG and TAG_MESSAGE set; image has git; gitAuth included (the
token reaches git as a header, the URL below carries none).
*/}}
{{- define "kubecore-ci-workflows.pushTag" -}}
{{ include "kubecore-ci-workflows.gitAuth" . }}
REPO_URL="{{`{{workflow.parameters.repo_url}}`}}"
COMMIT="{{`{{workflow.parameters.commit_sha}}`}}"
rm -rf /tmp/tagrepo
git init -q /tmp/tagrepo
cd /tmp/tagrepo
git config user.name "KubeCore CI"
git config user.email "ci@kubecore.io"
# A retried attempt may find the tag its predecessor already pushed (#1379):
# the same commit is success, another commit is a real conflict.
EXISTING=$(git ls-remote "${REPO_URL}" "refs/tags/${TAG}^{}" "refs/tags/${TAG}" | head -1 | cut -f1)
if [ -n "${EXISTING}" ]; then
  git fetch -q --depth=1 "${REPO_URL}" "refs/tags/${TAG}:refs/tags/${TAG}"
  if [ "$(git rev-parse "refs/tags/${TAG}^{commit}")" != "${COMMIT}" ]; then
    echo "Tag ${TAG} already exists on another commit"; exit 1
  fi
  echo "Tagged: ${TAG} (already present on ${COMMIT})"
else
  git fetch -q --depth=1 "${REPO_URL}" "${COMMIT}"
  git tag -a "${TAG}" -m "${TAG_MESSAGE}" "${COMMIT}"
  git push -q "${REPO_URL}" "refs/tags/${TAG}"
  echo "Tagged: ${TAG}"
fi
{{- end }}

{{/*
GitHub auth for git that never writes the token to disk (kaos PRD 738 F-20).

The token used to ride in the clone URL (https://x-access-token:TOKEN@github.com/…),
and git persists a clone URL as remote.origin.url in .git/config. /workspace/repo
is the kaniko build context, so a Dockerfile `RUN cat .git/config` read a live
org GitHub App token, and `COPY . .` baked it into an image layer pushed to the
registry. Every step that cloned that way left the token behind.

Now every URL is token-free and `git` is a shell function that hands the token
to the one git process it starts, as an HTTP Authorization header in
GIT_CONFIG_* environment variables (git >= 2.31; every CI image ships 2.45+).
Nothing reaches .git/config, nothing is exported to the script's other
children, and fetch/push from a clone keep working because each call
re-authenticates. The header is scoped to https://github.com/ only.

git_assert_no_token DIR fails the step if DIR/.git/config holds a credential
of any form — a guard against a future edit reintroducing the URL form.

Caller: TOKEN set (empty = unauthenticated git, as before).
*/}}
{{- define "kubecore-ci-workflows.gitAuth" -}}
# git with the GitHub App token as a per-process header (PRD 738 F-20): the
# token never lands in .git/config. URLs below are plain https://github.com/…
git() {
  if [ -n "${TOKEN:-}" ]; then
    env GIT_CONFIG_COUNT=1 \
      GIT_CONFIG_KEY_0="http.https://github.com/.extraheader" \
      GIT_CONFIG_VALUE_0="Authorization: Basic $(printf 'x-access-token:%s' "${TOKEN}" | base64 | tr -d '\n')" \
      git "$@"
  else
    env git "$@"
  fi
}
git_assert_no_token() {
  _gcfg="$1/.git/config"
  [ -f "${_gcfg}" ] || return 0
  if grep -qiE 'x-access-token|extraheader|://[^/@[:space:]]+@' "${_gcfg}" \
     || { [ -n "${TOKEN:-}" ] && grep -qF -- "${TOKEN}" "${_gcfg}"; }; then
    echo "FATAL: ${_gcfg} holds a GitHub credential (PRD 738 F-20)" >&2
    exit 1
  fi
}
{{- end }}

{{/*
Build pods: no Kubernetes ServiceAccount token in the build container
(kaos PRD 738 F-20).

The kaniko container runs the tenant's Dockerfile, so whatever it can read, a
`RUN` step can read. It needs no Kubernetes API access: its registry auth is a
docker config file, GAR auth is GKE Workload Identity (the metadata server,
not a token mount). Argo's own executor still needs the pod SA's token — the
`init` container and the `wait` sidecar create/patch WorkflowTaskResults; the
emissary in the main container talks to no API.

Argo's built-in route (template automountServiceAccountToken: false +
executor.serviceAccountName) needs a long-lived `<sa>.service-account-token`
Secret for the executor SA in every project CI namespace — the operator creates
one only for ML apps' hera-render-exec. So instead this patch turns automount
off for the whole pod and mounts a projected, short-lived token of the SAME
pod ServiceAccount into Argo's `init` and `wait` containers only, at the
standard path: exactly the volume the kubelet would have mounted everywhere.
The main (build) container gets nothing. No Secret, no new SA, no new RBAC.
*/}}
{{- define "kubecore-ci-workflows.buildPodSpecPatch" -}}
{{- if .Values.buildPods.isolateServiceAccountToken }}
podSpecPatch: |
  automountServiceAccountToken: false
  volumes:
  - name: kubecore-executor-sa-token
    projected:
      defaultMode: 420
      sources:
      - serviceAccountToken:
          path: token
          expirationSeconds: 3607
      - configMap:
          name: kube-root-ca.crt
          items:
          - key: ca.crt
            path: ca.crt
      - downwardAPI:
          items:
          - path: namespace
            fieldRef:
              apiVersion: v1
              fieldPath: metadata.namespace
  initContainers:
  - name: init
    volumeMounts:
    - name: kubecore-executor-sa-token
      mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      readOnly: true
  containers:
  - name: wait
    volumeMounts:
    - name: kubecore-executor-sa-token
      mountPath: /var/run/secrets/kubernetes.io/serviceaccount
      readOnly: true
{{- end }}
{{- end }}

{{/*
The clone of a just-created app repository can run before the project's CI
token covers it (kaos PRD 738 F-59): the token is scoped to the project's
repositories that already exist, and the re-scope reaches the pool ~1 min after
the repository does — while its push webhook is already live. GitHub answers
that clone "Repository not found" (kaos e2e-suite-mn8rc, 2026-10-09: the first
push's clone ran 4s before the re-scoped token landed, and the build failed).

git_clone exits 75 (EX_TEMPFAIL) on exactly that answer so cloneRetry retries
it in a NEW pod, which mounts the re-scoped token; every other clone failure
keeps git's own exit code and is not retried. GitHub's answer is always logged.

Caller: the gitAuth wrapper defined (git_clone calls git through it).
*/}}
{{- define "kubecore-ci-workflows.gitClone" -}}
git_clone() {
  _rc=0
  _out=$(git clone "$@" 2>&1) || _rc=$?
  printf '%s\n' "${_out}"
  if [ "${_rc}" -ne 0 ] && printf '%s' "${_out}" | grep -q "Repository not found"; then
    echo "The CI token does not reach this repository yet: a new app's repository joins the project's CI token scope about a minute after it is created. Exiting 75 so the step retries with the re-scoped token." >&2
    exit 75
  fi
  return "${_rc}"
}
{{- end }}

{{/*
preemptionRetry plus exit 75: git_clone's "the CI token does not reach this
repository yet" (see gitClone). Same limit and backoff (30s, then 60s), so the
clone gets ~90s for the token to catch up.
*/}}
{{- define "kubecore-ci-workflows.cloneRetry" -}}
retryStrategy:
  limit: "2"
  retryPolicy: Always
  expression: 'lastRetry.status == "Error" or lastRetry.message matches "imminent node shutdown" or lastRetry.exitCode == "75"'
  backoff:
    duration: "30s"
    factor: "2"
{{- end }}

{{/*
Retry a step whose pod was lost to the infrastructure (kubecore-operator#1379):
an Argo Error, or a pod killed by a spot preemption ("imminent node shutdown").
Same policy as ci-build's steps; a genuine failure (non-zero exit with any
other message) is NOT retried. No backoff.maxDuration: Argo counts it from the
first attempt's start, so a cap cancels the retry of any step that ran past it
(kubecore-operator#1377). Every step using it must be safe to re-run.
*/}}
{{- define "kubecore-ci-workflows.preemptionRetry" -}}
retryStrategy:
  limit: "2"
  retryPolicy: Always
  expression: 'lastRetry.status == "Error" or lastRetry.message matches "imminent node shutdown"'
  backoff:
    duration: "30s"
    factor: "2"
{{- end }}

