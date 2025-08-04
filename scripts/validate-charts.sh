#!/bin/bash
# Local chart validation script
# Alternative to chart-testing for local development

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

print_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
print_warn() { echo -e "${YELLOW}[WARN]${NC} $1"; }
print_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Function to validate a single chart
validate_chart() {
    local chart_path=$1
    local chart_name=$(basename "$chart_path")
    
    print_info "Validating chart: $chart_name"
    
    # Check if Chart.yaml exists
    if [ ! -f "$chart_path/Chart.yaml" ]; then
        print_error "Chart.yaml not found in $chart_path"
        return 1
    fi
    
    # Helm lint
    print_info "Running helm lint on $chart_name"
    if ! helm lint "$chart_path"; then
        print_error "Helm lint failed for $chart_name"
        return 1
    fi
    
    # Template generation test
    print_info "Testing template generation for $chart_name"
    if ! helm template test "$chart_path" > /dev/null; then
        print_error "Template generation failed for $chart_name"
        return 1
    fi
    
    # Dependency update (if Chart.lock exists)
    if [ -f "$chart_path/Chart.lock" ]; then
        print_info "Updating dependencies for $chart_name"
        if ! helm dependency update "$chart_path"; then
            print_warn "Dependency update failed for $chart_name"
        fi
    fi
    
    print_info "✅ Chart $chart_name validation passed"
    return 0
}

# Main validation function
main() {
    local failed_charts=()
    local total_charts=0
    
    print_info "Starting chart validation"
    
    # Add helm repositories
    print_info "Adding helm repositories"
    helm repo add stable https://charts.helm.sh/stable > /dev/null 2>&1 || true
    helm repo add bitnami https://charts.bitnami.com/bitnami > /dev/null 2>&1 || true
    helm repo add crossplane-stable https://charts.crossplane.io/stable > /dev/null 2>&1 || true
    helm repo update > /dev/null 2>&1
    
    # Validate custom charts
    if [ -d "charts/custom" ]; then
        print_info "Validating custom charts"
        for chart in charts/custom/*/; do
            if [ -d "$chart" ] && [ -f "$chart/Chart.yaml" ]; then
                total_charts=$((total_charts + 1))
                if ! validate_chart "$chart"; then
                    failed_charts+=("$(basename "$chart")")
                fi
            fi
        done
    fi
    
    # Validate external charts
    if [ -d "charts/external" ]; then
        print_info "Validating external charts"
        for chart in charts/external/*/; do
            if [ -d "$chart" ] && [ -f "$chart/Chart.yaml" ]; then
                total_charts=$((total_charts + 1))
                if ! validate_chart "$chart"; then
                    failed_charts+=("$(basename "$chart")")
                fi
            fi
        done
    fi
    
    # Summary
    print_info "Validation Summary:"
    print_info "  Total charts: $total_charts"
    print_info "  Passed: $((total_charts - ${#failed_charts[@]}))"
    print_info "  Failed: ${#failed_charts[@]}"
    
    if [ ${#failed_charts[@]} -eq 0 ]; then
        print_info "🎉 All charts passed validation!"
        return 0
    else
        print_error "❌ Failed charts: ${failed_charts[*]}"
        return 1
    fi
}

# Run main function
main "$@"