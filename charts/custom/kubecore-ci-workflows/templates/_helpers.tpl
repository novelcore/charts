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
Write .kubecore/dataset-config.yaml into the APP repo (kubecore-operator#1347).
Shared by BOTH ML render frontends: render-wft (kubeline) and
hera-enhance-commit (Hera). It lived only in render-wft, so no Hera app ever
got the file and the kubecore-dataset CLI had no lakeFS URL and no browser
login client_id. The caller must set CONTEXT_PATH (the gitops
pipeline-context.yaml), APP_NAME, PROJECT_NAME and BRANCH, and have the app
repo cloned with a push-capable token at /tmp/apprepo.
*/}}
{{- define "kubecore-ci-workflows.datasetConfigWrite" -}}
# ── Write .kubecore/dataset-config.yaml into the APP repo ─────────────
# The kubecore-dataset CLI (in each app repo) auto-discovers its lakeFS
# URL/repo/namespace/probe AND its browser-login OIDC settings from this
# file, so NOTHING is hardcoded per app
# — every kubeapp gets its OWN correct values. Sourced from the same
# pipeline-context the WFT is rendered from. Idempotent: only commits when
# the content changes. Skipped silently if the app repo has no external URL
# yet (baseDns absent) so a partially-configured pool never fails the render.
DATASET_CFG=$(CONTEXT_PATH="$CONTEXT_PATH" APP_NAME="$APP_NAME" PROJECT_NAME="$PROJECT_NAME" python3 - <<'CFGEOF'
import os, yaml
# pipeline-context.yaml is a ConfigMap; the real context is a YAML STRING
# under data['context.yaml'] — unwrap it exactly like the main render does
# (render_wft.py: ctx = yaml.safe_load(raw_cm['data']['context.yaml'])).
# Reading the ConfigMap top-level finds no 'lakefs' key → the config-write
# was silently skipping on EVERY app, so no app ever got its real config.
raw = yaml.safe_load(open(os.environ['CONTEXT_PATH'])) or {}
if isinstance(raw, dict) and 'data' in raw and 'context.yaml' in (raw.get('data') or {}):
    ctx = yaml.safe_load(raw['data']['context.yaml']) or {}
else:
    ctx = raw  # already-unwrapped context (defensive)
lakefs = ctx.get('lakefs', {}) or {}
url = lakefs.get('externalUrl', '') or ''
if not url:
    print('')  # no external URL yet — skip
else:
    cfg = {
        'lakefsUrl': url,
        'repo': lakefs.get('repository', os.environ['PROJECT_NAME']),
        'namespace': ctx.get('namespace', 'ml-%s' % os.environ['PROJECT_NAME']),
        'probeCron': lakefs.get('datasetProbeCron', '%s-dataset-catalog-probe' % os.environ['APP_NAME']),
    }
    # PKCE browser login (#1347). Without these the CLI has no client_id,
    # cannot start a browser login, and falls back to the manual cookie
    # paste — so this is the link that actually removes the paste.
    # Only emitted when the operator has provisioned the public OIDC app
    # (the composition omits lakefs.cli until then); half-written config
    # would strand the CLI worse than no config.
    cli = lakefs.get('cli', {}) or {}
    if cli.get('oidcIssuer') and cli.get('oidcClientId'):
        cfg['oidcIssuer'] = cli['oidcIssuer']
        cfg['oidcClientId'] = cli['oidcClientId']
        if cli.get('oidcProjectId'):
            cfg['oidcProjectId'] = cli['oidcProjectId']
    print('# Per-app dataset config — read by the kubecore-dataset CLI (nothing hardcoded).')
    print('# Rendered by render-wft from this app pipeline-context. Do not edit by hand.')
    print(yaml.safe_dump(cfg, default_flow_style=False, sort_keys=True).rstrip())
CFGEOF
)
if [ -n "$DATASET_CFG" ] && [ -d /tmp/apprepo ]; then
  mkdir -p /tmp/apprepo/.kubecore
  printf '%s\n' "$DATASET_CFG" > /tmp/apprepo/.kubecore/dataset-config.yaml
  ( cd /tmp/apprepo
    git config user.email "ci@kubecore.io" 2>/dev/null || true
    git config user.name "kubecore-ci" 2>/dev/null || true
    git checkout -B "${BRANCH}" 2>/dev/null || git checkout "${BRANCH}" 2>/dev/null || true
    git add .kubecore/dataset-config.yaml
    if git diff --cached --quiet; then
      echo "dataset-config: .kubecore/dataset-config.yaml already current in app repo"
    else
      git commit -m "chore(dataset): sync .kubecore/dataset-config.yaml (lakeFS URL/repo, CLI OIDC)" >/dev/null 2>&1 || true
      git pull --rebase origin "${BRANCH}" >/dev/null 2>&1 || true
      if git push origin "HEAD:${BRANCH}" 2>/dev/null; then
        echo "dataset-config: pushed .kubecore/dataset-config.yaml to the app repo"
      else
        echo "dataset-config: could not push dataset-config to app repo (non-fatal)"
      fi
    fi
  )
else
  echo "dataset-config: skipping dataset-config write (no external lakeFS URL in pipeline-context yet)"
fi
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

Caller: TOKEN, TAG and TAG_MESSAGE set; image has git.
*/}}
{{- define "kubecore-ci-workflows.pushTag" -}}
REPO_URL=$(echo "{{`{{workflow.parameters.repo_url}}`}}" | sed "s|https://|https://x-access-token:${TOKEN}@|")
COMMIT="{{`{{workflow.parameters.commit_sha}}`}}"
rm -rf /tmp/tagrepo
git init -q /tmp/tagrepo
cd /tmp/tagrepo
git config user.name "KubeCore CI"
git config user.email "ci@kubecore.io"
git fetch -q --depth=1 "${REPO_URL}" "${COMMIT}"
git tag -a "${TAG}" -m "${TAG_MESSAGE}" "${COMMIT}"
git push -q "${REPO_URL}" "refs/tags/${TAG}"
echo "Tagged: ${TAG}"
{{- end }}
