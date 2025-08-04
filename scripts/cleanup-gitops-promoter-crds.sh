#!/bin/bash
# GitOps Promoter CRD Cleanup Script
# Use this script to manually remove GitOps Promoter CRDs when experiencing installation conflicts

set -e

echo "🧹 Cleaning up GitOps Promoter CRDs..."

# List of GitOps Promoter CRDs
CRDS=(
  "argocdcommitstatuses.promoter.argoproj.io"
  "changetransferpolicies.promoter.argoproj.io"
  "commitstatuses.promoter.argoproj.io"
  "promotionstrategies.promoter.argoproj.io"
  "proposedcommits.promoter.argoproj.io"
  "pullrequests.promoter.argoproj.io"
  "revertcommits.promoter.argoproj.io"
  "scmrepositories.promoter.argoproj.io"
  "scmproviders.promoter.argoproj.io"
  "scmrepositories.promoter.argoproj.io"
)

# Check if any CRDs exist
echo "🔍 Checking for existing GitOps Promoter CRDs..."
existing_crds=()
for crd in "${CRDS[@]}"; do
  if kubectl get crd "$crd" >/dev/null 2>&1; then
    existing_crds+=("$crd")
    echo "  ✓ Found: $crd"
  fi
done

if [ ${#existing_crds[@]} -eq 0 ]; then
  echo "✅ No GitOps Promoter CRDs found. Nothing to clean up."
  exit 0
fi

echo ""
echo "⚠️  Found ${#existing_crds[@]} GitOps Promoter CRDs"
echo "⚠️  This will permanently delete the CRDs and ALL associated custom resources!"
echo ""
read -p "Are you sure you want to continue? (yes/no): " confirm

if [ "$confirm" != "yes" ]; then
  echo "❌ Cleanup cancelled."
  exit 1
fi

# Delete CRDs
echo ""
echo "🗑️  Deleting GitOps Promoter CRDs..."
for crd in "${existing_crds[@]}"; do
  echo "  Deleting: $crd"
  kubectl delete crd "$crd" --ignore-not-found=true
done

echo ""
echo "✅ GitOps Promoter CRDs cleanup completed!"
echo "💡 You can now reinstall the GitOps Promoter Helm chart."