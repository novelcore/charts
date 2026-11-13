#!/usr/bin/env bash
# The build records every step image with its digest, on Artifact Registry too (PRD kaos#1911, D-52).
# Usage (from the repo root; needs helm, yq v4):
#
#   bash charts/custom/kubecore-ci-workflows/tests/digest-pin/run.sh
#
# Why: a run that starts from a later step compares each reused step's image by digest. The
# digest-pin block of patch-images only knew the in-cluster registry (user and password from
# ci-registry-auth); on Artifact Registry it printed "skipped", the record kept tags, and every
# such run was refused on dev. The block is EXECUTED here against a stub curl.
# Exit status = number of failed assertions.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
CHART="${HERE}/../.."
FAILED=0; PASSED=0
expect_eq() { if [ "$1" = "$2" ]; then PASSED=$((PASSED+1)); echo "PASS: $3"; else FAILED=$((FAILED+1)); echo "FAIL: $3"; echo "  expected: $2"; echo "  actual:   $1"; fi; }
expect_has() { case "$1" in *"$2"*) PASSED=$((PASSED+1)); echo "PASS: $3";; *) FAILED=$((FAILED+1)); echo "FAIL: $3"; echo "  expected to contain: $2"; echo "  actual: $1";; esac; }
expect_lacks() { case "$1" in *"$2"*) FAILED=$((FAILED+1)); echo "FAIL: $3"; echo "  must not contain: $2";; *) PASSED=$((PASSED+1)); echo "PASS: $3";; esac; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
helm template t "$CHART" --set github.org=acme --set github.tokenSecretName=tok > "$T/rendered.yaml" || { echo "FAIL: helm template"; exit 1; }
yq 'select(.kind == "ClusterWorkflowTemplate" and .metadata.name == "ml-ci-build")
    | .spec.templates[] | select(.name == "patch-images") | .container.args[0]' "$T/rendered.yaml" \
  | awk '/=+ digest-pin-on-build/{on=1} on; on && /^ *# =+$/{exit}' \
  | sed 's|/etc/registry-auth|${AUTH_DIR}|g' > "$T/block.sh"
expect_has "$(cat "$T/block.sh")" 'for KEY in' "the digest-pin block is found in patch-images"

# A stub curl: answers the metadata server and the registry, and writes down every call.
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$CALLS"
url="${!#}"
case "$url" in
  http://metadata.google.internal/*) [ "${NO_TOKEN:-}" = 1 ] && exit 22; echo '{"access_token":"tok-123","expires_in":3599,"token_type":"Bearer"}' ;;
  */manifests/gone-1) exit 22 ;;
  */manifests/*) printf 'HTTP/2 200\r\nDocker-Content-Digest: sha256:%s\r\n\r\n' "$(printf '%s' "${url##*/}" | sha256sum | cut -c1-64)" ;;
esac
STUB
chmod +x "$T/bin/curl"
run() {  # run <build registry url> <auth dir>
  : > "$T/calls"
  sed "s|{{workflow.parameters.build_registry_url}}|$1|" "$T/block.sh" > "$T/run.sh"
  PATH="$T/bin:$PATH" CALLS="$T/calls" AUTH_DIR="$2" IMAGES_PATH="$T/images.yaml" IMAGE_REPO=demo sh -e "$T/run.sh" 2>&1
}
seed() {
  cat > "$T/images.yaml" <<YEOF
apiVersion: v1
kind: ConfigMap
metadata: {name: demo-pipeline-images}
data:
  last-built-sha: aaaa
  engine-version: 0.1.0
  produced-datasets: clean
  context-sha: 6a7d4e53
  prep: $1/demo:prep-1
  old: $1/demo:gone-1
YEOF
}
digest() { printf 'sha256:%s' "$(printf '%s' "$1" | sha256sum | cut -c1-64)"; }

# ── Artifact Registry: no ci-registry-auth, the token comes from the metadata server ─────────
GAR=europe-west1-docker.pkg.dev/proj/org
seed "$GAR"
OUT=$(run "$GAR" "$T/none")
expect_eq "$(yq '.data.prep' "$T/images.yaml")" "$GAR/demo:prep-1@$(digest prep-1)" "Artifact Registry: a built step is recorded with its digest"
expect_eq "$(yq '.data.old' "$T/images.yaml")" "$GAR/demo:old-latest@$(digest old-latest)" "Artifact Registry: a pruned tag is resolved from the step's latest tag"
expect_eq "$(yq '.data["last-built-sha"] + " " + .data["produced-datasets"]' "$T/images.yaml")" "aaaa clean" "Artifact Registry: keys that are not images are left alone"
expect_lacks "$OUT" "context-sha" "Artifact Registry: the context hash is not taken for an image (no warning about it)"
expect_has "$(cat "$T/calls")" "https://europe-west1-docker.pkg.dev/v2/proj/org/demo/manifests/prep-1" "Artifact Registry: asks the registry host over https, with the project and repository in the path"
expect_has "$(cat "$T/calls")" "-u oauth2accesstoken:tok-123" "Artifact Registry: authenticates with the service account's token"
expect_lacks "$OUT" "tok-123" "Artifact Registry: the token is not printed"
cp "$T/images.yaml" "$T/first.yaml"; run "$GAR" "$T/none" >/dev/null
expect_eq "$(cmp -s "$T/first.yaml" "$T/images.yaml" && echo same)" "same" "Artifact Registry: a second pass changes nothing"

seed "$GAR"
OUT=$(NO_TOKEN=1 run "$GAR" "$T/none")
expect_has "$OUT" "WARN digest-pin: no token from the metadata server" "Artifact Registry without a token: says so"
expect_has "$OUT" "cannot start from a later step" "Artifact Registry without a token: the warning names what stops working"
expect_eq "$(yq '.data.prep' "$T/images.yaml")" "$GAR/demo:prep-1" "Artifact Registry without a token: the record is left as it was, the build does not fail"

# ── the in-cluster registry: unchanged ───────────────────────────────────────────────────────
mkdir -p "$T/auth"; printf 'u' > "$T/auth/username"; printf 'p' > "$T/auth/password"
seed "reg.svc:5000"
run "reg.svc:5000" "$T/auth" >/dev/null
expect_eq "$(yq '.data.prep' "$T/images.yaml")" "reg.svc:5000/demo:prep-1@$(digest prep-1)" "in-cluster registry: a built step is recorded with its digest"
expect_has "$(cat "$T/calls")" "-u u:p" "in-cluster registry: authenticates with ci-registry-auth"
expect_has "$(cat "$T/calls")" "http://reg.svc:5000/v2/demo/manifests/prep-1" "in-cluster registry: the same URL as before"
expect_lacks "$(cat "$T/calls")" "metadata.google.internal" "in-cluster registry: the metadata server is not asked"

echo; echo "passed: $PASSED, failed: $FAILED"; exit "$FAILED"
