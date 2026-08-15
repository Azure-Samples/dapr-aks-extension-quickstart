#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." && pwd)"

ACTION="${1:-}"
if [[ -n "${ACTION}" ]]; then
    shift
fi

SUBSCRIPTION="${AZURE_SUBSCRIPTION_ID:-}"
RESOURCE_GROUP="${AKS_RESOURCE_GROUP:-}"
CLUSTER="${AKS_CLUSTER_NAME:-}"
NAMESPACE="${K8S_NAMESPACE:-dapr-quickstart}"
LOCAL_PORT="${LOCAL_PORT:-8080}"
PORT_FORWARD_PID=""
CONFIG_FILE=""
NAMESPACE_OWNER_KEY="samples.azure.com/managed-by"
NAMESPACE_OWNER_VALUE="dapr-aks-extension-quickstart"

if [[ -t 1 && -z "${NO_COLOR:-}" ]] || [[ "${FORCE_COLOR:-0}" == "1" ]]; then
    COLOR_RESET=$'\033[0m'
    COLOR_BOLD=$'\033[1m'
    COLOR_BLUE=$'\033[34m'
    COLOR_CYAN=$'\033[36m'
    COLOR_GREEN=$'\033[32m'
    COLOR_YELLOW=$'\033[33m'
    COLOR_RED=$'\033[31m'
else
    COLOR_RESET=""
    COLOR_BOLD=""
    COLOR_BLUE=""
    COLOR_CYAN=""
    COLOR_GREEN=""
    COLOR_YELLOW=""
    COLOR_RED=""
fi

usage() {
    cat <<'EOF'
Usage:
  ./scripts/quickstart.sh deploy \
    [--config .env] \
    [--subscription <subscription-id>] \
    [--resource-group <aks-resource-group>] \
    [--cluster <aks-cluster-name>] \
    [--namespace dapr-quickstart] [--local-port 8080]

  ./scripts/quickstart.sh verify \
    [--config .env] [--namespace dapr-quickstart] [--local-port 8080]

  ./scripts/quickstart.sh cleanup \
    [--config .env] \
    [--subscription <subscription-id>] \
    [--resource-group <aks-resource-group>] \
    [--cluster <aks-cluster-name>] \
    [--namespace dapr-quickstart]

Command-line options override values loaded from the config file or environment.
EOF
}

fail() {
    printf '%s[%s] [ERROR]%s %s\n' \
        "${COLOR_BOLD}${COLOR_RED}" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${COLOR_RESET}" "$*" >&2
    exit 1
}

step() {
    echo
    printf '%s[%s] [STEP]%s %s%s%s\n' \
        "${COLOR_BOLD}${COLOR_CYAN}" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${COLOR_RESET}" \
        "${COLOR_BOLD}" "$*" "${COLOR_RESET}"
}

info() {
    printf '%s[%s] [INFO]%s %s\n' \
        "${COLOR_BLUE}" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${COLOR_RESET}" "$*"
}

success() {
    printf '%s[%s] [SUCCESS]%s %s\n' \
        "${COLOR_BOLD}${COLOR_GREEN}" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${COLOR_RESET}" "$*"
}

warn() {
    printf '%s[%s] [WARNING]%s %s\n' \
        "${COLOR_BOLD}${COLOR_YELLOW}" "$(date -u +'%Y-%m-%dT%H:%M:%SZ')" "${COLOR_RESET}" "$*"
}

require_command() {
    command -v "$1" >/dev/null 2>&1 || fail "Required command '$1' was not found."
}

require_value() {
    local option="$1"
    local value="$2"
    [[ -n "${value}" ]] || fail "${option} is required for deploy."
}

validate_namespace() {
    case "${NAMESPACE}" in
        default|kube-system|kube-public|kube-node-lease|dapr-system)
            fail "Namespace '${NAMESPACE}' is not allowed. Use a dedicated quickstart namespace."
            ;;
    esac

    [[ "${NAMESPACE}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] \
        || fail "Namespace '${NAMESPACE}' is not a valid Kubernetes namespace name."
}

validate_local_port() {
    [[ "${LOCAL_PORT}" =~ ^[0-9]+$ ]] \
        && ((LOCAL_PORT >= 1 && LOCAL_PORT <= 65535)) \
        || fail "Local port '${LOCAL_PORT}' must be between 1 and 65535."
}

connect_cluster() {
    require_command az
    require_command kubectl
    require_value "--subscription" "${SUBSCRIPTION}"
    require_value "--resource-group" "${RESOURCE_GROUP}"
    require_value "--cluster" "${CLUSTER}"

    az account set --subscription "${SUBSCRIPTION}"
    az aks get-credentials \
        --resource-group "${RESOURCE_GROUP}" \
        --name "${CLUSTER}" \
        --overwrite-existing >/dev/null
    success "Connected kubectl context: $(kubectl config current-context)"
}

ensure_namespace() {
    local owner

    if kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        owner="$(kubectl get namespace "${NAMESPACE}" \
            -o go-template="{{ index .metadata.labels \"${NAMESPACE_OWNER_KEY}\" }}")"
        [[ "${owner}" == "${NAMESPACE_OWNER_VALUE}" ]] \
            || fail "Namespace '${NAMESPACE}' already exists and isn't owned by this quickstart. Choose another namespace."
        success "Reusing quickstart-owned namespace: ${NAMESPACE}"
        return
    fi

    kubectl create namespace "${NAMESPACE}"
    kubectl label namespace "${NAMESPACE}" \
        "${NAMESPACE_OWNER_KEY}=${NAMESPACE_OWNER_VALUE}" >/dev/null
    success "Created quickstart-owned namespace: ${NAMESPACE}"
}

load_config() {
    local config_file="$1"
    local key
    local value

    [[ -f "${config_file}" ]] || fail "Config file '${config_file}' was not found."

    while IFS='=' read -r key value || [[ -n "${key}" ]]; do
        key="${key#"${key%%[![:space:]]*}"}"
        key="${key%"${key##*[![:space:]]}"}"

        [[ -z "${key}" || "${key}" == \#* ]] && continue
        [[ -n "${value+x}" ]] || fail "Invalid config line for '${key}'. Expected KEY=VALUE."

        value="${value%$'\r'}"
        value="${value#"${value%%[![:space:]]*}"}"
        value="${value%"${value##*[![:space:]]}"}"
        if [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
            value="${value:1:${#value}-2}"
        fi

        case "${key}" in
            AZURE_SUBSCRIPTION_ID)
                SUBSCRIPTION="${value}"
                ;;
            AKS_RESOURCE_GROUP)
                RESOURCE_GROUP="${value}"
                ;;
            AKS_CLUSTER_NAME)
                CLUSTER="${value}"
                ;;
            K8S_NAMESPACE)
                NAMESPACE="${value}"
                ;;
            LOCAL_PORT)
                LOCAL_PORT="${value}"
                ;;
            *)
                fail "Unknown config key '${key}' in ${config_file}."
                ;;
        esac
    done <"${config_file}"
}

cleanup_port_forward() {
    if [[ -n "${PORT_FORWARD_PID}" ]] && kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
        kill "${PORT_FORWARD_PID}"
        wait "${PORT_FORWARD_PID}" 2>/dev/null || true
    fi
}

trap cleanup_port_forward EXIT

args=("$@")
for ((index = 0; index < ${#args[@]}; index++)); do
    if [[ "${args[index]}" == "--config" ]]; then
        ((index + 1 < ${#args[@]})) || fail "--config requires a value."
        CONFIG_FILE="${args[index + 1]}"
        load_config "${CONFIG_FILE}"
        index=$((index + 1))
    fi
done

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)
            [[ $# -ge 2 ]] || fail "$1 requires a value."
            CONFIG_FILE="${2:-}"
            shift 2
            ;;
        --subscription)
            [[ $# -ge 2 ]] || fail "$1 requires a value."
            SUBSCRIPTION="${2:-}"
            shift 2
            ;;
        --resource-group)
            [[ $# -ge 2 ]] || fail "$1 requires a value."
            RESOURCE_GROUP="${2:-}"
            shift 2
            ;;
        --cluster)
            [[ $# -ge 2 ]] || fail "$1 requires a value."
            CLUSTER="${2:-}"
            shift 2
            ;;
        --namespace)
            [[ $# -ge 2 ]] || fail "$1 requires a value."
            NAMESPACE="${2:-}"
            shift 2
            ;;
        --local-port)
            [[ $# -ge 2 ]] || fail "$1 requires a value."
            LOCAL_PORT="${2:-}"
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            fail "Unknown option: $1"
            ;;
    esac
done

start_port_forward() {
    info "Starting local port-forward http://localhost:${LOCAL_PORT} -> service/nodeapp:80."
    kubectl port-forward --namespace "${NAMESPACE}" service/nodeapp "${LOCAL_PORT}:80" >/dev/null 2>&1 &
    PORT_FORWARD_PID=$!

    for _ in {1..30}; do
        if curl --fail --silent "http://localhost:${LOCAL_PORT}/ports" >/dev/null; then
            success "Local port-forward is ready."
            return
        fi
        if ! kill -0 "${PORT_FORWARD_PID}" 2>/dev/null; then
            fail "kubectl port-forward exited before the service became reachable."
        fi
        sleep 1
    done

    fail "Timed out waiting for the local port-forward."
}

verify_node() {
    local service_type
    local external_ip
    local ports
    local order

    service_type="$(kubectl get service nodeapp --namespace "${NAMESPACE}" -o jsonpath='{.spec.type}')"
    external_ip="$(kubectl get service nodeapp --namespace "${NAMESPACE}" -o jsonpath='{.status.loadBalancer.ingress[0].ip}')"

    [[ "${service_type}" == "ClusterIP" ]] || fail "nodeapp must be a ClusterIP service, but is ${service_type}."
    [[ -z "${external_ip}" ]] || fail "nodeapp unexpectedly has external IP ${external_ip}."
    success "Service nodeapp is private: type=${service_type}, externalIP=none."

    start_port_forward
    ports="$(curl --fail --silent --show-error "http://localhost:${LOCAL_PORT}/ports")"
    success "GET /ports response: ${ports}"
    info "POST /neworder using sample.json."
    curl --fail --silent --show-error \
        --request POST \
        --data "@${REPO_ROOT}/sample.json" \
        --header "Content-Type: application/json" \
        "http://localhost:${LOCAL_PORT}/neworder" >/dev/null
    order="$(curl --fail --silent --show-error "http://localhost:${LOCAL_PORT}/order")"
    success "GET /order response: ${order}"
}

verify_python() {
    local initial_order
    local current_order

    initial_order="$(curl --fail --silent --show-error "http://localhost:${LOCAL_PORT}/order")"
    info "Initial persisted order before publisher check: ${initial_order}"

    for _ in {1..30}; do
        sleep 1
        current_order="$(curl --fail --silent --show-error "http://localhost:${LOCAL_PORT}/order")"
        if [[ "${current_order}" != "${initial_order}" ]]; then
            success "Python publisher updated the order through Dapr service invocation: ${current_order}"
            return
        fi
    done

    fail "The Python publisher did not update the order within 30 seconds."
}

deploy() {
    require_command az
    require_command kubectl
    require_command curl

    require_value "--subscription" "${SUBSCRIPTION}"
    require_value "--resource-group" "${RESOURCE_GROUP}"
    require_value "--cluster" "${CLUSTER}"
    validate_namespace
    validate_local_port

    step "Connecting kubectl to the existing AKS cluster"
    connect_cluster

    kubectl get customresourcedefinition components.dapr.io >/dev/null \
        || fail "Dapr is not installed on the AKS cluster."
    success "Dapr component CRD is installed."

    step "Creating an isolated namespace"
    info "Namespace: ${NAMESPACE}"
    ensure_namespace

    step "Deploying Redis and the Dapr state-store component"
    info "Redis runs inside the quickstart namespace and stores temporary sample data."
    kubectl apply --namespace "${NAMESPACE}" -f "${REPO_ROOT}/deploy/redis.yaml"
    kubectl rollout status deployment/redis --namespace "${NAMESPACE}" --timeout=180s

    step "Deploying the Node.js app with a Dapr sidecar"
    info "The dapr.io annotations request sidecar injection and assign app ID 'nodeapp'."
    kubectl apply --namespace "${NAMESPACE}" -f "${REPO_ROOT}/deploy/node.yaml"
    kubectl rollout status deployment/nodeapp --namespace "${NAMESPACE}" --timeout=180s

    step "Verifying private access and the Dapr state API"
    info "The service remains ClusterIP-only; kubectl port-forward provides temporary local access."
    verify_node

    step "Deploying the Python publisher with a Dapr sidecar"
    info "The publisher invokes app ID 'nodeapp' through its local Dapr sidecar."
    kubectl apply --namespace "${NAMESPACE}" -f "${REPO_ROOT}/deploy/python.yaml"
    kubectl rollout status deployment/pythonapp --namespace "${NAMESPACE}" --timeout=180s

    step "Verifying Dapr service invocation and shared state"
    verify_python

    step "Inspecting the deployed Dapr resources"
    kubectl get pods,services,components.dapr.io --namespace "${NAMESPACE}" -o wide

    step "Quickstart completed"
    success "Quickstart deployment and verification completed successfully."
    info "Inspect the sidecars with: kubectl get pods -n ${NAMESPACE}"
    info "Inspect the component with: kubectl get component statestore -n ${NAMESPACE} -o yaml"
    info "Watch persisted orders with: kubectl logs -n ${NAMESPACE} -l app=node -c node -f"
    if [[ -n "${CONFIG_FILE}" ]]; then
        info "Run './scripts/quickstart.sh cleanup --config ${CONFIG_FILE}' when finished."
    else
        info "Run the cleanup command from the README when finished."
    fi
}

verify() {
    require_command kubectl
    require_command curl
    validate_namespace
    validate_local_port

    if [[ -n "${SUBSCRIPTION}" || -n "${RESOURCE_GROUP}" || -n "${CLUSTER}" ]]; then
        step "Connecting kubectl to the configured AKS cluster"
        connect_cluster
    else
        info "No AKS resource configuration supplied; using kubectl context $(kubectl config current-context)."
    fi

    verify_node
    if kubectl get deployment pythonapp --namespace "${NAMESPACE}" >/dev/null 2>&1; then
        verify_python
    fi
}

cleanup() {
    local owner

    validate_namespace
    step "Connecting kubectl to the configured AKS cluster"
    connect_cluster

    if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
        warn "Namespace '${NAMESPACE}' doesn't exist; nothing to delete."
        return
    fi

    owner="$(kubectl get namespace "${NAMESPACE}" \
        -o go-template="{{ index .metadata.labels \"${NAMESPACE_OWNER_KEY}\" }}")"
    [[ "${owner}" == "${NAMESPACE_OWNER_VALUE}" ]] \
        || fail "Refusing to delete namespace '${NAMESPACE}' because it isn't owned by this quickstart."

    kubectl delete namespace "${NAMESPACE}" --ignore-not-found --wait=false
    info "Namespace deletion requested: ${NAMESPACE}"

    for _ in {1..30}; do
        if ! kubectl get namespace "${NAMESPACE}" >/dev/null 2>&1; then
            success "Namespace removed: ${NAMESPACE}"
            return
        fi
        sleep 2
    done

    warn "Namespace '${NAMESPACE}' is still terminating. Check 'kubectl describe namespace ${NAMESPACE}' for cluster API discovery or finalizer issues."
}

case "${ACTION}" in
    deploy)
        info "Action: deploy"
        deploy
        ;;
    verify)
        info "Action: verify"
        verify
        ;;
    cleanup)
        info "Action: cleanup"
        cleanup
        ;;
    --help|-h)
        usage
        ;;
    *)
        usage
        exit 1
        ;;
esac
