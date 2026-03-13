#!/usr/bin/env bash

# Deploy Konflux for Local Development (Minikube + Docker)
#
# This script provides a one-command local development deployment of Konflux
# on a Minikube cluster using the Docker driver. It's designed for LOCAL
# DEVELOPMENT CONVENIENCE ONLY.
#
# For production deployments on real clusters, see docs/operator-deployment.md
#
# What this script does:
#  1. Creates a Minikube cluster with Docker driver
#  2. Deploys the Konflux operator
#  3. Applies a Konflux CR configuration
#  4. Creates secrets for GitHub integration
#
# Prerequisites:
#  - minikube, kubectl, docker
#  - kustomize (only for 'local' install method)
#  - Configuration file: scripts/deploy-local.env
#
# Usage:
#   ./scripts/minikube/deploy-local.sh [konflux-cr-file]
#
# By default, uses operator/config/samples/konflux_v1alpha1_konflux.yaml
#
# Example:
#   cp scripts/deploy-local.env.template scripts/deploy-local.env
#   # Edit deploy-local.env with your secrets
#   ./scripts/minikube/deploy-local.sh
#
# Operator Installation Methods (OPERATOR_INSTALL_METHOD):
#   release (default) - Install from latest GitHub release
#   local             - Install from current checkout using kustomize
#   build             - Build operator image locally and install (for operator developers)
#   none              - Skip operator install and Konflux CR (for running operator locally)

set -euo pipefail

trap 'echo ""; echo "ERROR: Deployment failed. The Minikube cluster may still be running."; echo "       Fix the issue and rerun this script to retry."; echo "       To delete the cluster: minikube -p ${MINIKUBE_PROFILE:-konflux} delete"' ERR

# Determine the absolute path of the repository root
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" &> /dev/null && pwd)
REPO_ROOT=$(dirname "$(dirname "$SCRIPT_DIR")")

# Optional: Load environment configuration from file if it exists
# Shares the same env file as the Kind-based deploy-local.sh
ENV_FILE="${REPO_ROOT}/scripts/deploy-local.env"
if [ -f "${ENV_FILE}" ]; then
    echo "Loading configuration from ${ENV_FILE}"
    # shellcheck disable=SC1090
    source "${ENV_FILE}"
fi

# Validate REQUIRED variables
GITHUB_APP_ID="${GITHUB_APP_ID:?GitHub App ID is required. Set GITHUB_APP_ID}"
WEBHOOK_SECRET="${WEBHOOK_SECRET:?Webhook secret is required. Set WEBHOOK_SECRET}"

# Validate that at least one private key option is provided
if [ -z "${GITHUB_PRIVATE_KEY:-}" ] && [ -z "${GITHUB_PRIVATE_KEY_PATH:-}" ]; then
    echo "ERROR: GitHub private key is required" >&2
    echo "" >&2
    echo "Set one of:" >&2
    echo "  - GITHUB_PRIVATE_KEY (literal key content)" >&2
    echo "  - GITHUB_PRIVATE_KEY_PATH (path to .pem file)" >&2
    exit 1
fi

# Validate private key file exists if path is provided
if [ -n "${GITHUB_PRIVATE_KEY_PATH:-}" ] && [ ! -f "${GITHUB_PRIVATE_KEY_PATH}" ]; then
    echo "ERROR: GitHub private key file not found: ${GITHUB_PRIVATE_KEY_PATH}" >&2
    exit 1
fi

# Optional variables with defaults
MINIKUBE_PROFILE="${MINIKUBE_PROFILE:-konflux}"
MINIKUBE_MEMORY_MB="${MINIKUBE_MEMORY_MB:-max}"
MINIKUBE_CPUS="${MINIKUBE_CPUS:-max}"
MINIKUBE_DISK_SIZE="${MINIKUBE_DISK_SIZE:-100g}"
REGISTRY_HOST_PORT="${REGISTRY_HOST_PORT:-5001}"
ENABLE_REGISTRY_PORT="${ENABLE_REGISTRY_PORT:-1}"
INSTALL_METHOD="${OPERATOR_INSTALL_METHOD:-release}"
OPERATOR_IMAGE="${OPERATOR_IMAGE:-quay.io/konflux-ci/konflux-operator:latest}"

# Export variables for child scripts
export MINIKUBE_PROFILE MINIKUBE_MEMORY_MB MINIKUBE_CPUS MINIKUBE_DISK_SIZE
export REGISTRY_HOST_PORT ENABLE_REGISTRY_PORT
export GITHUB_PRIVATE_KEY="${GITHUB_PRIVATE_KEY:-}" GITHUB_APP_ID WEBHOOK_SECRET
export QUAY_TOKEN="${QUAY_TOKEN:-}" QUAY_ORGANIZATION="${QUAY_ORGANIZATION:-}"

# Get Konflux CR file path (precedence, high->low: command-line arg, env var, default)
KONFLUX_CR="${1:-${KONFLUX_CR:-}}"

# Auto-select e2e CR when Quay credentials are configured but no explicit CR specified
if [ -n "${QUAY_TOKEN:-}" ] && [ -n "${QUAY_ORGANIZATION:-}" ] && [ -z "${KONFLUX_CR}" ]; then
    KONFLUX_CR="${REPO_ROOT}/operator/config/samples/konflux-e2e.yaml"
    echo ""
    echo "INFO: Auto-selecting konflux-e2e.yaml because QUAY_TOKEN/QUAY_ORGANIZATION are set"
    echo "      This CR enables image-controller required for Quay integration"
    echo "      To use a different CR, set KONFLUX_CR environment variable or pass as argument"
    echo ""
else
    KONFLUX_CR="${KONFLUX_CR:-${REPO_ROOT}/operator/config/samples/konflux_v1alpha1_konflux.yaml}"
fi

# Convert relative path to absolute (if not already absolute)
if [[ "${KONFLUX_CR}" != /* ]]; then
    KONFLUX_CR="${REPO_ROOT}/${KONFLUX_CR}"
fi

if [ ! -f "${KONFLUX_CR}" ]; then
    echo "ERROR: Konflux CR file not found: ${KONFLUX_CR}"
    echo ""
    echo "Usage: $0 [konflux-cr-file]"
    exit 1
fi

echo "========================================="
echo "Konflux Local Development Deployment"
echo "  (Minikube + Docker)"
echo "========================================="
echo ""
echo "Configuration:"
echo "  Environment: ${ENV_FILE}"
echo "  Konflux CR:  ${KONFLUX_CR}"
echo "  Profile:     ${MINIKUBE_PROFILE}"
echo ""

# Ensure a namespace exists: in 'none' mode, pre-create it immediately;
# otherwise wait up to 60 s for the operator to create it.
wait_or_create_namespace() {
    local ns="$1"
    local method="$2"
    if [ "${method}" = "none" ]; then
        echo "Pre-creating namespace: ${ns}"
        kubectl create namespace "${ns}" --dry-run=client -o yaml | kubectl apply -f -
    else
        echo "Waiting for namespace: ${ns}"
        local timeout=60
        while ! kubectl get namespace "${ns}" &> /dev/null && [ $timeout -gt 0 ]; do
            sleep 2
            timeout=$((timeout - 2))
        done
        if [ $timeout -le 0 ]; then
            echo "WARNING: Namespace ${ns} not created after 60 seconds"
            return 1
        fi
    fi
}

# For 'build' method, build the operator image before creating the cluster
if [ "${INSTALL_METHOD}" = "build" ]; then
    echo "========================================="
    echo "Building operator image (before cluster)"
    echo "========================================="
    cd "${REPO_ROOT}/operator"
    OPERATOR_IMG="localhost/konflux-operator:local"
    make docker-build IMG="${OPERATOR_IMG}"
    cd "${REPO_ROOT}"
    echo ""
fi

# Step 1: Setup Minikube cluster
echo "========================================="
echo "Step 1: Creating Minikube cluster"
echo "========================================="
"${SCRIPT_DIR}/setup-minikube-local-cluster.sh"

# Step 2: Deploy dependencies
echo ""
echo "========================================="
echo "Step 2: Deploying dependencies"
echo "========================================="
echo "Installing Tekton, cert-manager, and other prerequisites..."

# Pre-configure Smee channel if specified
if [ -n "${SMEE_CHANNEL:-}" ]; then
    echo "Configuring Smee channel: ${SMEE_CHANNEL}"
    SMEE_DIR="${REPO_ROOT}/dependencies/smee"
    sed "s|https://smee.io/CHANNELID|${SMEE_CHANNEL}|g" \
        "${SMEE_DIR}/smee-channel-id.tpl" \
        > "${SMEE_DIR}/smee-channel-id.yaml"
fi

# Skip components managed by the operator
SKIP_DEX=true \
SKIP_KONFLUX_INFO=true \
SKIP_CLUSTER_ISSUER=true \
SKIP_INTERNAL_REGISTRY=true \
"${REPO_ROOT}/deploy-deps.sh"

# Step 3: Deploy Konflux operator
echo ""
echo "========================================="
echo "Step 3: Deploying Konflux operator"
echo "========================================="
echo "Using installation method: ${INSTALL_METHOD}"

case "${INSTALL_METHOD}" in
    local)
        echo "Installing from current commit using kustomize..."
        cd "${REPO_ROOT}/operator"

        make deploy IMG="${OPERATOR_IMAGE}"

        # Reset kustomization changes to avoid leaving modified files
        git checkout config/manager/kustomization.yaml 2>/dev/null || true
        cd "${REPO_ROOT}"
        ;;

    build)
        echo "Loading operator image into Minikube cluster..."
        cd "${REPO_ROOT}/operator"
        minikube -p "${MINIKUBE_PROFILE}" image load "${OPERATOR_IMG}"

        echo "Installing CRDs..."
        make install

        echo "Deploying operator..."
        make deploy IMG="${OPERATOR_IMG}"
        cd "${REPO_ROOT}"
        ;;

    release)
        echo "Installing from latest GitHub release..."
        RELEASE_URL="https://github.com/konflux-ci/konflux-ci/releases/latest/download/install.yaml"
        echo "Downloading: ${RELEASE_URL}"
        kubectl apply -f "${RELEASE_URL}"
        ;;

    none)
        echo "Skipping operator installation (OPERATOR_INSTALL_METHOD=none)"
        echo "You will need to run the operator manually after deployment completes:"
        echo "  cd operator && make install && make run"
        ;;

    *)
        echo "ERROR: Invalid OPERATOR_INSTALL_METHOD: ${INSTALL_METHOD}"
        echo "Valid options: local, build, release, none"
        exit 1
        ;;
esac

if [ "${INSTALL_METHOD}" != "none" ]; then
    # Step 4: Wait for operator to be ready
    echo ""
    echo "========================================="
    echo "Step 4: Waiting for operator"
    echo "========================================="
    echo "Waiting for operator deployment..."
    kubectl wait --for=condition=Available \
        deployment/konflux-operator-controller-manager \
        -n konflux-operator \
        --timeout=5m

    echo "Operator is ready"

    # Step 5: Apply Konflux CR
    echo ""
    echo "========================================="
    echo "Step 5: Applying Konflux configuration"
    echo "========================================="
    echo "Applying: ${KONFLUX_CR}"
    kubectl apply -f "${KONFLUX_CR}"
else
    echo ""
    echo "========================================="
    echo "Steps 4-5: Skipped (operator not installed)"
    echo "========================================="
fi

# Step 6: Create secrets for GitHub integration
echo ""
echo "========================================="
echo "Step 6: Creating GitHub integration secrets"
echo "========================================="
echo "Creating Pipelines-as-Code secrets..."

for ns in pipelines-as-code build-service integration-service; do
    if ! wait_or_create_namespace "${ns}" "${INSTALL_METHOD}"; then
        echo "         Secrets will need to be created manually"
        continue
    fi

    echo "Creating secret in ${ns}..."
    if [ -n "${GITHUB_PRIVATE_KEY_PATH:-}" ] && [ -f "${GITHUB_PRIVATE_KEY_PATH}" ]; then
        kubectl -n "$ns" create secret generic pipelines-as-code-secret \
            --from-file=github-private-key="${GITHUB_PRIVATE_KEY_PATH}" \
            --from-literal github-application-id="$GITHUB_APP_ID" \
            --from-literal webhook.secret="$WEBHOOK_SECRET" \
            --dry-run=client -o yaml | kubectl apply -f -
    else
        kubectl -n "$ns" create secret generic pipelines-as-code-secret \
            --from-literal github-private-key="$GITHUB_PRIVATE_KEY" \
            --from-literal github-application-id="$GITHUB_APP_ID" \
            --from-literal webhook.secret="$WEBHOOK_SECRET" \
            --dry-run=client -o yaml | kubectl apply -f -
    fi
done

echo "Secrets created"

# Step 6b: Create image-controller secret (optional)
if [ -n "${QUAY_TOKEN:-}" ] && [ -n "${QUAY_ORGANIZATION:-}" ]; then
    echo ""
    echo "Creating image-controller Quay secret..."

    if ! wait_or_create_namespace "image-controller" "${INSTALL_METHOD}"; then
        echo "         Secret will need to be created manually"
    else
        echo "Creating secret in image-controller..."
        kubectl -n image-controller create secret generic quaytoken \
            --from-literal=quaytoken="${QUAY_TOKEN}" \
            --from-literal=organization="${QUAY_ORGANIZATION}" \
            --dry-run=client -o yaml | kubectl apply -f -
        echo "Image-controller secret created"

        # Wait for image-controller pods to be ready (skip in 'none' mode)
        if [ "${INSTALL_METHOD}" != "none" ]; then
            echo "Waiting for image-controller pods to be ready..."
            if kubectl wait --for=condition=Ready --timeout=240s \
                -l control-plane=controller-manager -n image-controller pod 2>/dev/null; then
                echo "Image-controller is ready"
            else
                echo "WARNING: Image-controller pods did not become ready within 4 minutes"
                echo "         This may cause E2E test failures"
            fi
        fi
    fi
elif [ -n "${QUAY_TOKEN:-}" ] || [ -n "${QUAY_ORGANIZATION:-}" ]; then
    echo ""
    echo "WARNING: Both QUAY_TOKEN and QUAY_ORGANIZATION must be set to create image-controller secret"
    echo "         Image-controller secret not created"
fi

if [ "${INSTALL_METHOD}" != "none" ]; then
    # Step 7: Wait for Konflux to be ready
    echo ""
    echo "========================================="
    echo "Step 7: Waiting for Konflux to be ready"
    echo "========================================="
    echo "This may take several minutes..."

    if ! kubectl wait --for=condition=Ready=True konflux konflux --timeout=15m 2>/dev/null; then
        echo ""
        echo "WARNING: Konflux CR did not become Ready within 15 minutes"
        echo "         This may be normal if deploying all components"
        echo "         Check status with: kubectl get konflux konflux -o yaml"
        echo ""
        echo "To monitor progress:"
        echo "  kubectl get pods -A"
        echo "  kubectl get konflux konflux -o jsonpath='{.status.conditions}'"
    else
        echo "Konflux is ready"
    fi
else
    echo ""
    echo "========================================="
    echo "Step 7: Skipped (operator not installed)"
    echo "========================================="
fi

# Final status
echo ""
echo "========================================="
echo "Deployment Complete!"
echo "========================================="
echo ""

if [ "${INSTALL_METHOD}" = "none" ]; then
    echo "Minikube cluster and dependencies are ready."
    echo ""
    echo "Next steps - run the operator:"
    echo "  cd operator"
    echo "  make install   # Install CRDs"
    echo "  make run       # Run the operator locally"
    echo ""
    echo "Then, in another terminal, apply the Konflux CR:"
    echo "  kubectl apply -f ${KONFLUX_CR}"
    echo ""
else
    echo "Konflux is now running on your local Minikube cluster"
    echo ""
    echo "Access the UI:"
    echo "  https://localhost:9443"
    echo ""
    echo "Demo user credentials:"
    echo "  user1@konflux.dev / password"
    echo "  user2@konflux.dev / password"
    echo ""
fi

if [[ "${ENABLE_REGISTRY_PORT:-1}" -eq 1 ]]; then
    echo "Internal registry:"
    echo "  localhost:${REGISTRY_HOST_PORT:-5001}"
    echo ""
fi

echo "Useful minikube commands:"
echo "  minikube -p ${MINIKUBE_PROFILE} status      # Check cluster status"
echo "  minikube -p ${MINIKUBE_PROFILE} dashboard    # Open Kubernetes dashboard"
echo "  minikube -p ${MINIKUBE_PROFILE} delete       # Delete the cluster"
echo ""
