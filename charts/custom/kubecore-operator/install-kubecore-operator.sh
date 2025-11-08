#!/bin/bash
#
# KubeCore Operator Installation Script
# Version: 0.1.8
# Target Cluster: kaos-dev-eks
#
# This script performs a complete installation of the KubeCore Operator platform with proper namespace separation:
# 1. Crossplane in crossplane-system namespace
# 2. External Secrets Operator in external-secrets-system namespace
# 3. Crossplane providers, functions, and configs in crossplane-system namespace
# 4. KubeCore Operator in kubecore-system namespace (with XRDs only)
#

set -e  # Exit on error
set -o pipefail  # Exit on pipe failure

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Script directory
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CROSSPLANE_RESOURCES_DIR="${SCRIPT_DIR}/crossplane-resources"
CHART_DIR="${SCRIPT_DIR}/chart"

# Configuration
CROSSPLANE_VERSION="2.1.0"
ESO_VERSION="1.0.0"
OPERATOR_NAMESPACE="kubecore-system"
CROSSPLANE_NAMESPACE="crossplane-system"
ESO_NAMESPACE="external-secrets-system"

# Helm repo URLs
CROSSPLANE_REPO="https://charts.crossplane.io/stable"
ESO_REPO="https://charts.external-secrets.io"

# Functions
log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $1"
}

check_prerequisites() {
    log_info "Checking prerequisites..."

    # Check kubectl
    if ! command -v kubectl &> /dev/null; then
        log_error "kubectl is not installed or not in PATH"
        exit 1
    fi

    # Check helm
    if ! command -v helm &> /dev/null; then
        log_error "helm is not installed or not in PATH"
        exit 1
    fi

    # Check cluster connectivity
    if ! kubectl cluster-info &> /dev/null; then
        log_error "Cannot connect to Kubernetes cluster"
        exit 1
    fi

    log_success "All prerequisites met"
}

add_helm_repos() {
    log_info "Adding Helm repositories..."

    helm repo add crossplane-stable "${CROSSPLANE_REPO}" || true
    helm repo add external-secrets "${ESO_REPO}" || true
    helm repo update

    log_success "Helm repositories added and updated"
}

install_crossplane() {
    log_info "Installing Crossplane in ${CROSSPLANE_NAMESPACE} namespace..."

    # Create namespace
    kubectl create namespace "${CROSSPLANE_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    # Install Crossplane
    helm upgrade --install crossplane crossplane-stable/crossplane \
        --namespace "${CROSSPLANE_NAMESPACE}" \
        --version "${CROSSPLANE_VERSION}" \
        --wait \
        --timeout 10m

    # Wait for Crossplane pods
    log_info "Waiting for Crossplane pods to be ready..."
    kubectl wait --for=condition=Ready pods --all \
        -n "${CROSSPLANE_NAMESPACE}" \
        --timeout=5m

    log_success "Crossplane installed successfully"
}

install_external_secrets() {
    log_info "Installing External Secrets Operator in ${ESO_NAMESPACE} namespace..."

    # Create namespace
    kubectl create namespace "${ESO_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    # Install External Secrets Operator
    helm upgrade --install external-secrets external-secrets/external-secrets \
        --namespace "${ESO_NAMESPACE}" \
        --version "${ESO_VERSION}" \
        --wait \
        --timeout 5m

    # Wait for ESO pods
    log_info "Waiting for External Secrets Operator pods to be ready..."
    kubectl wait --for=condition=Ready pods --all \
        -n "${ESO_NAMESPACE}" \
        --timeout=5m

    log_success "External Secrets Operator installed successfully"
}

install_crossplane_runtime_config() {
    log_info "Installing Crossplane runtime configuration..."

    kubectl apply -f "${CROSSPLANE_RESOURCES_DIR}/configs/runtime-config.yaml"

    # Wait a bit for runtime config to be processed
    sleep 5

    log_success "Crossplane runtime configuration installed"
}

install_crossplane_providers() {
    log_info "Installing Crossplane providers..."

    # Install AWS providers
    kubectl apply -f "${CROSSPLANE_RESOURCES_DIR}/providers/aws-providers.yaml"

    # Install Kubernetes provider
    kubectl apply -f "${CROSSPLANE_RESOURCES_DIR}/providers/kubernetes-provider.yaml"

    # Install GitHub provider
    kubectl apply -f "${CROSSPLANE_RESOURCES_DIR}/providers/github-provider.yaml"

    # Install Helm provider
    kubectl apply -f "${CROSSPLANE_RESOURCES_DIR}/providers/helm-provider.yaml"

    log_info "Waiting for providers to install (this may take several minutes)..."

    # Wait for providers to be installed and healthy
    # Note: We wait up to 15 minutes as providers need to download and install
    local max_wait=900  # 15 minutes
    local waited=0
    local interval=10

    while [ $waited -lt $max_wait ]; do
        local installed_count=$(kubectl get providers.pkg.crossplane.io -o json | jq '[.items[] | select(.status.conditions[]? | select(.type=="Installed" and .status=="True"))] | length')
        local healthy_count=$(kubectl get providers.pkg.crossplane.io -o json | jq '[.items[] | select(.status.conditions[]? | select(.type=="Healthy" and .status=="True"))] | length')
        local total_count=$(kubectl get providers.pkg.crossplane.io -o json | jq '.items | length')

        log_info "Providers status: ${healthy_count}/${total_count} healthy, ${installed_count}/${total_count} installed"

        if [ "$healthy_count" -eq "$total_count" ] && [ "$total_count" -gt "0" ]; then
            log_success "All providers are installed and healthy"
            break
        fi

        sleep $interval
        waited=$((waited + interval))
    done

    if [ $waited -ge $max_wait ]; then
        log_warn "Providers did not become healthy within ${max_wait} seconds"
        log_warn "Continuing anyway - you may need to check provider status manually"
        kubectl get providers.pkg.crossplane.io
    fi
}

install_crossplane_functions() {
    log_info "Installing Crossplane functions..."

    kubectl apply -f "${CROSSPLANE_RESOURCES_DIR}/functions/crossplane-functions.yaml"

    log_info "Waiting for functions to install..."

    # Wait for functions to be installed and healthy
    local max_wait=300  # 5 minutes
    local waited=0
    local interval=10

    while [ $waited -lt $max_wait ]; do
        local installed_count=$(kubectl get functions.pkg.crossplane.io -n "${CROSSPLANE_NAMESPACE}" -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[]? | select(.type=="Installed" and .status=="True"))] | length' || echo "0")
        local healthy_count=$(kubectl get functions.pkg.crossplane.io -n "${CROSSPLANE_NAMESPACE}" -o json 2>/dev/null | jq '[.items[] | select(.status.conditions[]? | select(.type=="Healthy" and .status=="True"))] | length' || echo "0")
        local total_count=$(kubectl get functions.pkg.crossplane.io -n "${CROSSPLANE_NAMESPACE}" -o json 2>/dev/null | jq '.items | length' || echo "0")

        log_info "Functions status: ${healthy_count}/${total_count} healthy, ${installed_count}/${total_count} installed"

        if [ "$healthy_count" -eq "$total_count" ] && [ "$total_count" -gt "0" ]; then
            log_success "All functions are installed and healthy"
            break
        fi

        sleep $interval
        waited=$((waited + interval))
    done

    if [ $waited -ge $max_wait ]; then
        log_warn "Functions did not become healthy within ${max_wait} seconds"
        log_warn "Continuing anyway - you may need to check function status manually"
        kubectl get functions.pkg.crossplane.io -n "${CROSSPLANE_NAMESPACE}"
    fi
}

install_provider_configs() {
    log_info "Installing Crossplane ProviderConfigs..."

    # Check if AWS secret exists
    if ! kubectl get secret aws-secret -n "${CROSSPLANE_NAMESPACE}" &> /dev/null; then
        log_warn "AWS secret 'aws-secret' not found in ${CROSSPLANE_NAMESPACE} namespace"
        log_warn "Please create it before applying ProviderConfigs:"
        log_warn "  kubectl create secret generic aws-secret \\"
        log_warn "    --from-file=credentials=~/.aws/credentials \\"
        log_warn "    --namespace ${CROSSPLANE_NAMESPACE}"
        log_warn ""
        log_warn "Skipping ProviderConfig installation - you'll need to apply them manually later"
        log_warn "File location: ${CROSSPLANE_RESOURCES_DIR}/configs/provider-configs.yaml"
        return
    fi

    kubectl apply -f "${CROSSPLANE_RESOURCES_DIR}/configs/provider-configs.yaml"

    # Wait a bit for provider configs to be processed
    sleep 5

    log_success "ProviderConfigs installed"
}

install_kubecore_operator() {
    log_info "Installing KubeCore Operator in ${OPERATOR_NAMESPACE} namespace..."

    # Create namespace
    kubectl create namespace "${OPERATOR_NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

    # Install operator chart
    helm upgrade --install kubecore-operator "${CHART_DIR}" \
        --namespace "${OPERATOR_NAMESPACE}" \
        -f "${CHART_DIR}/values-kaos-dev.yaml" \
        --wait \
        --timeout 5m

    # Wait for operator pods
    log_info "Waiting for KubeCore Operator pods to be ready..."
    kubectl wait --for=condition=Ready pods \
        -l app.kubernetes.io/name=kubecore-operator \
        -n "${OPERATOR_NAMESPACE}" \
        --timeout=5m

    log_success "KubeCore Operator installed successfully"
}

verify_installation() {
    log_info "Verifying installation..."

    echo ""
    log_info "Crossplane Namespace (${CROSSPLANE_NAMESPACE}):"
    kubectl get pods -n "${CROSSPLANE_NAMESPACE}"

    echo ""
    log_info "External Secrets Namespace (${ESO_NAMESPACE}):"
    kubectl get pods -n "${ESO_NAMESPACE}"

    echo ""
    log_info "Operator Namespace (${OPERATOR_NAMESPACE}):"
    kubectl get pods -n "${OPERATOR_NAMESPACE}"

    echo ""
    log_info "Crossplane Providers:"
    kubectl get providers.pkg.crossplane.io

    echo ""
    log_info "Crossplane Functions:"
    kubectl get functions.pkg.crossplane.io -n "${CROSSPLANE_NAMESPACE}"

    echo ""
    log_info "Crossplane XRDs:"
    kubectl get xrd

    echo ""
    log_success "Installation verification complete!"
}

print_next_steps() {
    echo ""
    echo "================================================================================================"
    log_success "KubeCore Operator Platform Installed Successfully!"
    echo "================================================================================================"
    echo ""
    echo "Next Steps:"
    echo ""
    echo "1. Verify RBAC permissions for secrets:"
    echo "   kubectl get clusterrole kubecore-operator-manager-role -o yaml | grep -A 5 secrets"
    echo ""
    echo "2. Check operator logs for any errors:"
    echo "   kubectl logs -n ${OPERATOR_NAMESPACE} deployment/kubecore-operator-controller-manager --tail=50"
    echo ""
    echo "3. Apply a test KubeOrg resource:"
    echo "   kubectl apply -f ${SCRIPT_DIR}/chart/examples/kubeorg-sample.yaml"
    echo ""
    echo "4. Monitor reconciliation:"
    echo "   kubectl get kubeorg -w"
    echo ""
    echo "5. Check events:"
    echo "   kubectl get events --sort-by='.lastTimestamp'"
    echo ""
    echo "================================================================================================"
}

# Main execution
main() {
    log_info "Starting KubeCore Operator installation..."
    log_info "Target configuration:"
    log_info "  - Crossplane namespace: ${CROSSPLANE_NAMESPACE}"
    log_info "  - ESO namespace: ${ESO_NAMESPACE}"
    log_info "  - Operator namespace: ${OPERATOR_NAMESPACE}"
    echo ""

    check_prerequisites
    add_helm_repos
    install_crossplane
    install_external_secrets
    install_crossplane_runtime_config
    install_crossplane_providers
    install_crossplane_functions
    install_provider_configs
    install_kubecore_operator
    verify_installation
    print_next_steps
}

# Run main function
main "$@"
