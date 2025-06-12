#!/bin/bash
# Script to manually sync a specific chart from an external repository

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to print colored output
print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Check if required tools are installed
check_requirements() {
    local missing_tools=()
    
    command -v helm >/dev/null 2>&1 || missing_tools+=("helm")
    command -v yq >/dev/null 2>&1 || missing_tools+=("yq")
    
    if [ ${#missing_tools[@]} -ne 0 ]; then
        print_error "Missing required tools: ${missing_tools[*]}"
        print_info "Please install missing tools and try again"
        exit 1
    fi
}

# Function to sync a chart
sync_chart() {
    local repo_name=$1
    local chart_name=$2
    local version=${3:-""}
    local target_dir="charts/external/${chart_name}"
    
    print_info "Syncing ${repo_name}/${chart_name} version ${version:-latest}"
    
    # Create temp directory
    local temp_dir=$(mktemp -d)
    trap "rm -rf $temp_dir" EXIT
    
    # Pull the chart
    if [ -z "$version" ]; then
        helm pull "${repo_name}/${chart_name}" --untar --untardir "$temp_dir"
    else
        helm pull "${repo_name}/${chart_name}" --version "${version}" --untar --untardir "$temp_dir"
    fi
    
    # Check if chart was pulled successfully
    if [ ! -d "$temp_dir/${chart_name}" ]; then
        print_error "Failed to pull chart ${repo_name}/${chart_name}"
        exit 1
    fi
    
    # Create target directory
    mkdir -p "$target_dir"
    
    # Check if we're updating an existing chart
    if [ -f "$target_dir/Chart.yaml" ]; then
        local current_version=$(yq eval '.version' "$target_dir/Chart.yaml")
        local new_version=$(yq eval '.version' "$temp_dir/${chart_name}/Chart.yaml")
        print_info "Updating chart from version $current_version to $new_version"
    fi
    
    # Copy chart files
    cp -r "$temp_dir/${chart_name}"/* "$target_dir/"
    
    # Add sync metadata
    yq eval -i ".syncMetadata.source = \"${repo_name}/${chart_name}\"" "$target_dir/Chart.yaml"
    yq eval -i ".syncMetadata.syncedAt = \"$(date -u +%Y-%m-%dT%H:%M:%SZ)\"" "$target_dir/Chart.yaml"
    yq eval -i ".syncMetadata.syncedVersion = \"${version:-latest}\"" "$target_dir/Chart.yaml"
    
    print_info "Successfully synced ${chart_name} to ${target_dir}"
}

# Main function
main() {
    # Check requirements
    check_requirements
    
    # Parse arguments
    if [ $# -lt 2 ]; then
        echo "Usage: $0 <repo-name> <chart-name> [version]"
        echo "Example: $0 bitnami postgresql 12.1.5"
        exit 1
    fi
    
    local repo_name=$1
    local chart_name=$2
    local version=${3:-""}
    
    # Load repositories from sync-config.yaml if it exists
    if [ -f "sync-config.yaml" ]; then
        print_info "Loading repositories from sync-config.yaml"
        while IFS=' ' read -r name url; do
            helm repo add "$name" "$url" >/dev/null 2>&1 || true
        done < <(yq eval '.repositories[] | .name + " " + .url' sync-config.yaml)
    fi
    
    # Update helm repos
    print_info "Updating Helm repositories"
    helm repo update >/dev/null 2>&1
    
    # Check if repository exists
    if ! helm repo list | grep -q "^${repo_name}"; then
        print_error "Repository '${repo_name}' not found"
        print_info "Available repositories:"
        helm repo list
        exit 1
    fi
    
    # Sync the chart
    sync_chart "$repo_name" "$chart_name" "$version"
    
    print_info "Done! Chart synced successfully."
    print_info "Don't forget to commit and push the changes."
}

# Run main function
main "$@"