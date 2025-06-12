#!/bin/bash

# Initialize gh-pages branch with a proper index.yaml

set -e

echo "Initializing gh-pages branch for Helm repository..."

# Check if gh-pages branch exists
if git show-ref --verify --quiet refs/heads/gh-pages; then
    echo "gh-pages branch exists, switching to it..."
    git checkout gh-pages
else
    echo "Creating gh-pages branch..."
    git checkout --orphan gh-pages
    git reset --hard
fi

# Create a valid index.yaml with proper date
cat > index.yaml << EOF
apiVersion: v1
entries: {}
generated: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

# Create README for gh-pages
cat > README.md << EOF
# Novelcore Helm Charts Repository

This branch hosts the Helm chart packages and index.

Repository URL: https://novelcore.github.io/charts/
EOF

# Commit and push
git add index.yaml README.md
git commit -m "Initialize Helm repository" || echo "No changes to commit"

echo "Pushing gh-pages branch..."
git push origin gh-pages

# Switch back to main
git checkout main

echo "Done! gh-pages branch initialized."
echo "Next steps:"
echo "1. Wait 2-3 minutes for GitHub Pages to deploy"
echo "2. Check https://novelcore.github.io/charts/index.yaml"
echo "3. If you get 404, ensure GitHub Pages is enabled in repository settings"