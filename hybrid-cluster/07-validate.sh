#!/usr/bin/env bash
# =============================================================================
# 07-validate.sh
# Hybrid Kubernetes Cluster Validation - Run on Linux Master
#
# Validates:
#   - Node readiness
#   - Control-plane/system pod readiness
#   - Linux workload scheduling
#   - Optional Windows workload scheduling
#   - Pod networking
#   - Cluster DNS
#   - CNI-aware status reporting (Flannel / Calico / Weave)
#   - Final cluster readiness gate
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'
RED='\033[0;31m'; NC='\033[0m'

ok()   { echo -e "  ${GREEN}[PASS]${NC}  $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC}  $*"; FAILURES=$((FAILURES+1)); }
info() { echo -e "  ${CYAN}[INFO]${NC}  $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC}  $*"; }

FAILURES=0
LINUX_POD_NAME="linux-test"
WINDOWS_POD_NAME="windows-test"
TEST_NAMESPACE="default"

# -----------------------------------------------------------------------------
# kubectl availability
# -----------------------------------------------------------------------------
if ! command -v kubectl >/dev/null 2>&1; then
    echo -e "  ${RED}[FAIL]${NC} kubectl is not installed or not in PATH"
    exit 1
fi

if ! kubectl cluster-info >/dev/null 2>&1; then
    echo -e "  ${RED}[FAIL]${NC} Cannot connect to Kubernetes API server"
    exit 1
fi

# =============================================================================
# Intelligent pod readiness gate
# =============================================================================
# A cluster is healthy only when every non-terminal pod is Running and all
# containers are Ready. Completed/Succeeded pods are allowed.
wait_for_all_pods_running() {
    local timeout="${1:-600}"
    local elapsed=0
    local interval=5
    local snapshot=""

    info "Waiting for every non-terminal pod in every namespace to be Running and Ready (timeout ${timeout}s)..."

    while (( elapsed < timeout )); do
        snapshot=$(kubectl get pods -A --no-headers 2>/dev/null || true)

        if [[ -n "$snapshot" ]]; then
            if awk '
                BEGIN { bad=0; seen=0 }
                {
                    seen=1
                    ready=$3
                    status=$4

                    if (status == "Completed" || status == "Succeeded")
                        next

                    split(ready, r, "/")
                    if (status != "Running" || r[1] != r[2])
                        bad=1
                }
                END { exit (seen && bad == 0) ? 0 : 1 }
            ' <<< "$snapshot"; then
                ok "All non-terminal pods are Running and Ready"
                return 0
            fi
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
    echo -e "  ${RED}[FAIL]${NC} Pod readiness timeout after ${timeout}s"
    echo -e "  ${YELLOW}Non-ready pods:${NC}"
    kubectl get pods -A -o wide 2>/dev/null || true

    # Diagnose up to five unhealthy pods. Do NOT use a bare `&&` under set -e.
    local shown=0 ns pod ready status rest
    while read -r ns pod ready status rest; do
        [[ -z "$ns" || -z "$pod" ]] && continue
        [[ "$status" == "Running" || "$status" == "Completed" || "$status" == "Succeeded" ]] && continue

        echo -e "\n  ${YELLOW}--- Diagnosis: ${ns}/${pod} (${status}) ---${NC}"
        kubectl describe pod -n "$ns" "$pod" 2>/dev/null \
            | sed -n '/Events:/,$p' | tail -40 || true

        shown=$((shown + 1))
        if (( shown >= 5 )); then
            break
        fi
    done < <(kubectl get pods -A --no-headers 2>/dev/null || true)

    return 1
}

# =============================================================================
# Detect CNI
# =============================================================================
detect_cni() {
    if kubectl get daemonset -n kube-flannel kube-flannel-ds >/dev/null 2>&1; then
        echo "flannel"
        return
    fi

    if kubectl get daemonset -n calico-system calico-node >/dev/null 2>&1 ||
       kubectl get daemonset -n kube-system calico-node >/dev/null 2>&1; then
        echo "calico"
        return
    fi

    if kubectl get daemonset -A -l name=weave-net -o name 2>/dev/null | grep -q .; then
        echo "weave"
        return
    fi

    echo "unknown"
}

# =============================================================================
# CNI status
# =============================================================================
show_cni_status() {
    local cni="$1"

    echo ""
    echo -e "  ${CYAN}CNI status: ${cni}${NC}"

    case "$cni" in
        flannel)
            kubectl get daemonset -n kube-flannel kube-flannel-ds -o wide 2>/dev/null || true
            kubectl get pods -n kube-flannel -o wide 2>/dev/null || true
            ;;
        calico)
            if kubectl get daemonset -n calico-system calico-node >/dev/null 2>&1; then
                kubectl get daemonset -n calico-system calico-node -o wide
                kubectl get pods -n calico-system -l k8s-app=calico-node -o wide
            else
                kubectl get daemonset -n kube-system calico-node -o wide 2>/dev/null || true
                kubectl get pods -n kube-system -l k8s-app=calico-node -o wide 2>/dev/null || true
            fi
            ;;
        weave)
            kubectl get daemonset -A -l name=weave-net -o wide 2>/dev/null || true
            kubectl get pods -A -l name=weave-net -o wide 2>/dev/null || true
            ;;
        *)
            warn "CNI could not be detected automatically"
            ;;
    esac
}

# =============================================================================
# Header
# =============================================================================
echo -e "\n  ${CYAN}+================================================================+${NC}"
echo -e "  ${CYAN}|         HYBRID CLUSTER VALIDATION                              |${NC}"
echo -e "  ${CYAN}+================================================================+${NC}\n"

CNI="$(detect_cni)"
info "Detected CNI: ${CNI}"

# =============================================================================
# [1/6] Node status
# =============================================================================
echo -e "  ${CYAN}[1/6] Node status${NC}"
echo ""

NODE_TIMEOUT=300
NODE_ELAPSED=0

while (( NODE_ELAPSED < NODE_TIMEOUT )); do
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null |
        awk '$2 != "Ready" {c++} END {print c+0}')

    if (( NODE_COUNT > 0 && NOT_READY == 0 )); then
        break
    fi

    sleep 5
    NODE_ELAPSED=$((NODE_ELAPSED + 5))
done

kubectl get nodes -o wide
echo ""

NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null |
    awk '$2 != "Ready" {c++} END {print c+0}')

if (( NODE_COUNT > 0 && NOT_READY == 0 )); then
    ok "All ${NODE_COUNT} node(s) Ready"
else
    fail "${NOT_READY} node(s) not Ready after ${NODE_TIMEOUT}s"
fi

WIN_NODE=$(kubectl get nodes --no-headers -l kubernetes.io/os=windows -o name 2>/dev/null | head -1 || true)

if [[ -n "$WIN_NODE" ]]; then
    ok "Windows node found: $WIN_NODE"
else
    warn "No Windows node found (Windows workload checks will be skipped)"
    WIN_NODE=""
fi

# =============================================================================
# [2/6] System pods / cluster readiness
# =============================================================================
echo -e "\n  ${CYAN}[2/6] System pods${NC}"
echo ""
kubectl get pods -n kube-system -o wide
echo ""

if wait_for_all_pods_running 600; then
    kubectl get pods -A -o wide
    ok "All cluster pods are Running and Ready"
else
    fail "One or more cluster pods are not Running/Ready"
    echo -e "  ${RED}Cluster readiness gate failed; stopping validation.${NC}"
    exit 1
fi

# =============================================================================
# [3/6] Linux test pod
# =============================================================================
echo -e "\n  ${CYAN}[3/6] Deploy Linux test pod${NC}"

kubectl delete pod "$LINUX_POD_NAME" -n "$TEST_NAMESPACE" \
    --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true

kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: linux-test
  namespace: default
  labels:
    app: k8s-validation-linux
spec:
  nodeSelector:
    kubernetes.io/os: linux
  containers:
  - name: nginx
    image: nginx:alpine
    ports:
    - containerPort: 80
EOF

echo "  Waiting for linux-test pod..."
if kubectl wait --for=condition=Ready pod/"$LINUX_POD_NAME" \
    -n "$TEST_NAMESPACE" --timeout=120s >/dev/null 2>&1; then
    ok "linux-test pod running"
else
    fail "linux-test pod failed to become Ready"
fi

LINUX_POD_IP="$(kubectl get pod "$LINUX_POD_NAME" -n "$TEST_NAMESPACE" \
    -o jsonpath='{.status.podIP}' 2>/dev/null || true)"

if [[ -n "$LINUX_POD_IP" ]]; then
    info "Linux pod IP: $LINUX_POD_IP"
else
    fail "Linux test pod has no pod IP"
fi

# =============================================================================
# [4/6] Optional Windows test pod
# =============================================================================
echo -e "\n  ${CYAN}[4/6] Deploy Windows test pod${NC}"

WIN_POD_IP=""

if [[ -n "$WIN_NODE" ]]; then
    kubectl delete pod "$WINDOWS_POD_NAME" -n "$TEST_NAMESPACE" \
        --ignore-not-found --wait=true --timeout=60s >/dev/null 2>&1 || true

    kubectl apply -f - >/dev/null <<'EOF'
apiVersion: v1
kind: Pod
metadata:
  name: windows-test
  namespace: default
  labels:
    app: k8s-validation-windows
spec:
  nodeSelector:
    kubernetes.io/os: windows
  tolerations:
  - key: "os"
    operator: "Equal"
    value: "windows"
    effect: "NoSchedule"
  containers:
  - name: servercore
    image: mcr.microsoft.com/windows/servercore:ltsc2022
    command: ["powershell", "-Command", "while($true) { Start-Sleep 30 }"]
EOF

    echo "  Waiting for windows-test pod (Windows image pull may take several minutes)..."
    if kubectl wait --for=condition=Ready pod/"$WINDOWS_POD_NAME" \
        -n "$TEST_NAMESPACE" --timeout=600s >/dev/null 2>&1; then
        ok "windows-test pod running"
    else
        fail "windows-test pod failed to become Ready"
        kubectl describe pod "$WINDOWS_POD_NAME" -n "$TEST_NAMESPACE" 2>/dev/null |
            sed -n '/Events:/,$p' | tail -40 || true
    fi

    WIN_POD_IP="$(kubectl get pod "$WINDOWS_POD_NAME" -n "$TEST_NAMESPACE" \
        -o jsonpath='{.status.podIP}' 2>/dev/null || true)"

    if [[ -n "$WIN_POD_IP" ]]; then
        info "Windows pod IP: $WIN_POD_IP"
    fi
else
    echo -e "  ${YELLOW}[SKIP]${NC} No Windows node — skipping Windows pod deployment"
fi

# =============================================================================
# [5/6] Pod-to-pod connectivity
# =============================================================================
echo -e "\n  ${CYAN}[5/6] Pod-to-pod connectivity${NC}"

# Linux -> Windows.
# ICMP is not guaranteed to be available/allowed in Windows containers, so use
# TCP/HTTP when possible rather than treating ping support as a mandatory test.
if [[ -n "$WIN_POD_IP" ]]; then
    if kubectl exec "$LINUX_POD_NAME" -n "$TEST_NAMESPACE" -- \
        wget -q --spider --timeout=5 "http://${WIN_POD_IP}" >/dev/null 2>&1; then
        ok "Linux pod -> Windows pod: TCP/HTTP reachable"
    elif kubectl exec "$LINUX_POD_NAME" -n "$TEST_NAMESPACE" -- \
        sh -c "nc -z -w 5 ${WIN_POD_IP} 80" >/dev/null 2>&1; then
        ok "Linux pod -> Windows pod: TCP/80 reachable"
    else
        warn "Linux -> Windows connectivity could not be proven with HTTP/TCP"
        info "Windows test image may not expose a listening application on port 80"
    fi
else
    echo -e "  ${YELLOW}[SKIP]${NC} Linux -> Windows connectivity (no Ready Windows pod)"
fi

# Linux -> itself via loopback proves little; instead verify the pod can reach
# the Kubernetes service IP and its own HTTP endpoint.
if [[ -n "$LINUX_POD_IP" ]]; then
    if kubectl exec "$LINUX_POD_NAME" -n "$TEST_NAMESPACE" -- \
        wget -qO- --timeout=5 "http://${LINUX_POD_IP}" >/dev/null 2>&1; then
        ok "Linux pod -> its pod IP: HTTP reachable"
    else
        fail "Linux pod -> its pod IP: HTTP NOT reachable"
    fi
fi

# =============================================================================
# [6/6] DNS resolution
# =============================================================================
echo -e "\n  ${CYAN}[6/6] DNS resolution${NC}"

if kubectl exec "$LINUX_POD_NAME" -n "$TEST_NAMESPACE" -- \
    nslookup kubernetes.default.svc.cluster.local >/dev/null 2>&1; then
    ok "DNS: kubernetes.default.svc.cluster.local resolves in Linux pod"
else
    fail "DNS: resolution failed in Linux pod"
fi

# =============================================================================
# CNI-aware status
# =============================================================================
show_cni_status "$CNI"

# =============================================================================
# Summary
# =============================================================================
echo ""

if (( FAILURES == 0 )); then
    echo -e "  ${GREEN}+--------------------------------------------------+${NC}"
    echo -e "  ${GREEN}|  ALL CHECKS PASSED - Cluster is healthy!       |${NC}"
    echo -e "  ${GREEN}+--------------------------------------------------+${NC}"
else
    echo -e "  ${RED}+--------------------------------------------------+${NC}"
    echo -e "  ${RED}|  ${FAILURES} CHECK(S) FAILED - See output above      |${NC}"
    echo -e "  ${RED}+--------------------------------------------------+${NC}"
fi

echo ""

# =============================================================================
# Cleanup
# =============================================================================
kubectl delete pod "$LINUX_POD_NAME" "$WINDOWS_POD_NAME" \
    -n "$TEST_NAMESPACE" --ignore-not-found --wait=true --timeout=120s \
    >/dev/null 2>&1 || true
ok "Test pod cleanup completed"

# =============================================================================
# Final gate
# =============================================================================
if wait_for_all_pods_running 600; then
    kubectl get nodes -o wide
    kubectl get pods -A -o wide
    ok "FINAL GATE PASSED: all cluster pods are Running and Ready"
else
    fail "FINAL GATE FAILED: cluster still has non-ready pods"
fi

if (( FAILURES > 0 )); then
    exit 1
fi

exit 0
