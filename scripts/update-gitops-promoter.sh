#!/bin/bash
# Script to update GitOps Promoter chart to a new version
# Usage: ./update-gitops-promoter.sh <new-version>

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if version argument is provided
if [ $# -ne 1 ]; then
    print_error "Usage: $0 <new-version>"
    print_info "Example: $0 v0.11.0"
    exit 1
fi

NEW_VERSION=$1
CHART_DIR="charts/custom/gitops-promoter"
INSTALL_FILE="install-${NEW_VERSION}.yaml"

# Remove 'v' prefix if present for consistency
VERSION_NUMBER=${NEW_VERSION#v}

print_info "Updating GitOps Promoter chart to version $NEW_VERSION"

# Check if chart directory exists
if [ ! -d "$CHART_DIR" ]; then
    print_error "Chart directory $CHART_DIR not found"
    exit 1
fi

# Download new installation manifests
print_info "Downloading installation manifests for $NEW_VERSION"
DOWNLOAD_URL="https://github.com/argoproj-labs/gitops-promoter/releases/download/${NEW_VERSION}/install.yaml"

if ! curl -fsSL "$DOWNLOAD_URL" -o "$INSTALL_FILE"; then
    print_error "Failed to download installation manifests from $DOWNLOAD_URL"
    print_info "Please check if the version exists: https://github.com/argoproj-labs/gitops-promoter/releases"
    exit 1
fi

print_info "Downloaded $INSTALL_FILE successfully"

# Extract current versions for comparison
CURRENT_APP_VERSION=$(yq eval '.appVersion' "$CHART_DIR/Chart.yaml")
CURRENT_CHART_VERSION=$(yq eval '.version' "$CHART_DIR/Chart.yaml")

print_info "Current app version: $CURRENT_APP_VERSION"
print_info "Current chart version: $CURRENT_CHART_VERSION"
print_info "New app version: $VERSION_NUMBER"

# Check if this is actually a new version
if [ "$CURRENT_APP_VERSION" = "$VERSION_NUMBER" ]; then
    print_warn "Chart is already at version $VERSION_NUMBER"
    read -p "Continue anyway? (y/N): " -n 1 -r
    echo
    if [[ ! $REPLY =~ ^[Yy]$ ]]; then
        print_info "Update cancelled"
        rm -f "$INSTALL_FILE"
        exit 0
    fi
fi

# Backup current chart
BACKUP_DIR="backup-$(date +%Y%m%d-%H%M%S)"
print_info "Creating backup in $BACKUP_DIR"
cp -r "$CHART_DIR" "$BACKUP_DIR"

# Update Chart.yaml
print_info "Updating Chart.yaml"

# Calculate new chart version (increment patch version)
NEW_CHART_VERSION=$(echo "$CURRENT_CHART_VERSION" | awk -F. '{$NF = $NF + 1;} 1' | sed 's/ /./g')

# Update Chart.yaml
yq eval -i ".appVersion = \"$VERSION_NUMBER\"" "$CHART_DIR/Chart.yaml"
yq eval -i ".version = \"$NEW_CHART_VERSION\"" "$CHART_DIR/Chart.yaml"

# Update the release notes link in annotations
yq eval -i ".annotations.\"artifacthub.io/links\" = \"- name: GitOps Promoter Documentation\n  url: https://github.com/argoproj-labs/gitops-promoter/blob/main/README.md\n- name: Release Notes\n  url: https://github.com/argoproj-labs/gitops-promoter/releases/tag/$NEW_VERSION\"" "$CHART_DIR/Chart.yaml"

# Update the image in annotations
yq eval -i ".annotations.\"artifacthub.io/images\" = \"- name: gitops-promoter\n  image: quay.io/argoprojlabs/gitops-promoter:$NEW_VERSION\n- name: kube-rbac-proxy\n  image: quay.io/brancz/kube-rbac-proxy:v0.17.0\"" "$CHART_DIR/Chart.yaml"

# Update values.yaml
print_info "Updating values.yaml"
yq eval -i ".controllerManager.image.tag = \"$NEW_VERSION\"" "$CHART_DIR/values.yaml"

# Check for image changes in the new manifests
print_info "Checking for image changes in new manifests"
NEW_PROMOTER_IMAGE=$(grep -E "image: quay.io/argoprojlabs/gitops-promoter:" "$INSTALL_FILE" | head -1 | awk '{print $2}' || echo "")
NEW_RBAC_PROXY_IMAGE=$(grep -E "image: quay.io/brancz/kube-rbac-proxy:" "$INSTALL_FILE" | head -1 | awk '{print $2}' || echo "")

if [ -n "$NEW_PROMOTER_IMAGE" ]; then
    EXTRACTED_VERSION=$(echo "$NEW_PROMOTER_IMAGE" | cut -d: -f2)
    if [ "$EXTRACTED_VERSION" != "$NEW_VERSION" ]; then
        print_warn "Version mismatch: expected $NEW_VERSION, found $EXTRACTED_VERSION in manifests"
    fi
fi

if [ -n "$NEW_RBAC_PROXY_IMAGE" ]; then
    RBAC_PROXY_VERSION=$(echo "$NEW_RBAC_PROXY_IMAGE" | cut -d: -f2)
    CURRENT_RBAC_VERSION=$(yq eval '.kubeRbacProxy.image.tag' "$CHART_DIR/values.yaml")
    
    if [ "$RBAC_PROXY_VERSION" != "$CURRENT_RBAC_VERSION" ]; then
        print_info "Updating kube-rbac-proxy version from $CURRENT_RBAC_VERSION to $RBAC_PROXY_VERSION"
        yq eval -i ".kubeRbacProxy.image.tag = \"$RBAC_PROXY_VERSION\"" "$CHART_DIR/values.yaml"
        
        # Update Chart.yaml annotations as well
        yq eval -i ".annotations.\"artifacthub.io/images\" = \"- name: gitops-promoter\n  image: quay.io/argoprojlabs/gitops-promoter:$NEW_VERSION\n- name: kube-rbac-proxy\n  image: quay.io/brancz/kube-rbac-proxy:$RBAC_PROXY_VERSION\"" "$CHART_DIR/Chart.yaml"
    fi
fi

# Show diff of important changes
print_info "Comparing with previous installation manifests"
if [ -f "charts/promoter.yaml" ]; then
    echo "=== Key Differences ==="
    # Show CRD changes
    if diff -u <(grep -A 5 -B 5 "kind: CustomResourceDefinition" charts/promoter.yaml) <(grep -A 5 -B 5 "kind: CustomResourceDefinition" "$INSTALL_FILE") > /dev/null; then
        print_info "✅ No CRD changes detected"
    else
        print_warn "⚠️  CRD changes detected - manual review required"
    fi
    
    # Show RBAC changes
    if diff -u <(grep -A 10 -B 2 "kind: ClusterRole" charts/promoter.yaml) <(grep -A 10 -B 2 "kind: ClusterRole" "$INSTALL_FILE") > /dev/null; then
        print_info "✅ No major RBAC changes detected"
    else
        print_warn "⚠️  RBAC changes detected - manual review required"
    fi
    
    # Show Deployment changes
    if diff -u <(grep -A 20 -B 2 "kind: Deployment" charts/promoter.yaml) <(grep -A 20 -B 2 "kind: Deployment" "$INSTALL_FILE") > /dev/null; then
        print_info "✅ No major Deployment changes detected"
    else
        print_warn "⚠️  Deployment changes detected - manual review required"
    fi
fi

# Update the reference installation file
print_info "Updating reference installation file"
cp "$INSTALL_FILE" charts/promoter.yaml

# Validate the chart
print_info "Validating updated chart"
if helm lint "$CHART_DIR" > /dev/null 2>&1; then
    print_info "✅ Chart validation passed"
else
    print_error "❌ Chart validation failed"
    helm lint "$CHART_DIR"
    print_info "Backup available in $BACKUP_DIR"
    exit 1
fi

# Template test
print_info "Testing chart templating"
if helm template test "$CHART_DIR" > /dev/null 2>&1; then
    print_info "✅ Chart templating successful"
else
    print_error "❌ Chart templating failed"
    helm template test "$CHART_DIR"
    print_info "Backup available in $BACKUP_DIR"
    exit 1
fi

# Cleanup
rm -f "$INSTALL_FILE"

print_info "✅ Update completed successfully!"
print_info "Summary of changes:"
print_info "  - App version: $CURRENT_APP_VERSION → $VERSION_NUMBER"
print_info "  - Chart version: $CURRENT_CHART_VERSION → $NEW_CHART_VERSION"
print_info "  - Backup created: $BACKUP_DIR"

print_warn "Next steps:"
print_info "1. Review the changes: git diff"
print_info "2. Test the updated chart in a development environment"
print_info "3. Update README.md if needed"
print_info "4. Commit the changes: git add -A && git commit -m 'feat: update GitOps Promoter to $NEW_VERSION'"
print_info "5. Push and let CI/CD handle the release"

print_info "Manual review may be required for:"
print_info "  - CRD schema changes"
print_info "  - New RBAC permissions"
print_info "  - New configuration options"
print_info "  - Breaking changes (check release notes)"