#!/usr/bin/env bash
# =============================================================================
# 07-validate.sh
# Hybrid Cluster Validation - Run on Linux Master
# =============================================================================
set -euo pipefail

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[PASS]${NC}  $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC}  $*"; FAILURES=$((FAILURES+1)); }
info() { echo -e "  ${CYAN}[INFO]${NC}  $*"; }
FAILURES=0

# =============================================================================
# Intelligent pod readiness gate
# =============================================================================
# A cluster is not considered healthy merely because nodes are Ready. Every
# non-terminal pod must be Running AND all of its containers must be Ready.
# Completed/Succeeded pods are allowed; Failed, Pending, ImagePullBackOff,
# CrashLoopBackOff, Init:* and ContainerCreating are not.
wait_for_all_pods_running() {
    local timeout="${1:-600}"
    local elapsed=0
    local interval=5
    local snapshot=""

    info "Waiting for every non-terminal pod in every namespace to be Running and Ready (timeout ${timeout}s)..."

    while (( elapsed < timeout )); do
        snapshot=$(kubectl get pods -A --no-headers 2>/dev/null || true)

        if [[ -n "$snapshot" ]]; then
            # Columns: NAMESPACE NAME READY STATUS RESTARTS AGE ...
            # Ignore Completed pods. Everything else must be Running with
            # READY numerator == denominator.
            if ! awk '
                BEGIN { bad=0; seen=0 }
                {
                    seen=1
                    ready=$3; status=$4
                    if (status == "Completed" || status == "Succeeded") next
                    split(ready, r, "/")
                    if (status != "Running" || r[1] != r[2]) bad=1
                }
                END { exit (seen && bad == 0) ? 0 : 1 }
            ' <<< "$snapshot"; then
                sleep "$interval"
                elapsed=$((elapsed + interval))
                continue
            fi

            ok "All non-terminal pods are Running and Ready"
            return 0
        fi

        sleep "$interval"
        elapsed=$((elapsed + interval))
    done

    echo ""
    echo -e "  ${RED}[FAIL]${NC} Pod readiness timeout after ${timeout}s"
    echo -e "  ${YELLOW}Non-ready pods:${NC}"
    kubectl get pods -A -o wide 2>/dev/null || true

    # Intelligent diagnostics: show the reason for the first few unhealthy
    # pods. This is especially useful for ImagePullBackOff/network failures.
    local shown=0 ns pod status
    while read -r ns pod _ready status _rest; do
        [[ -z "$ns" || -z "$pod" ]] && continue
        [[ "$status" == "Running" || "$status" == "Completed" || "$status" == "Succeeded" ]] && continue
        echo -e "\n  ${YELLOW}--- Diagnosis: ${ns}/${pod} (${status}) ---${NC}"
        kubectl describe pod -n "$ns" "$pod" 2>/dev/null \
          | sed -n '/Events:/,$p' | tail -40 || true
        shown=$((shown + 1))
        (( shown >= 5 )) && break
    done < <(kubectl get pods -A --no-headers 2>/dev/null || true)

    return 1
}

echo -e "\n  ${CYAN}+================================================================+${NC}"
echo -e "  ${CYAN}|         HYBRID CLUSTER VALIDATION                              |${NC}"
echo -e "  ${CYAN}+================================================================+${NC}\n"

# =============================================================================
echo -e "  ${CYAN}[1/6] Node status${NC}"
# =============================================================================
echo ""
NODE_TIMEOUT=300
NODE_ELAPSED=0
while (( NODE_ELAPSED < NODE_TIMEOUT )); do
    NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {c++} END {print c+0}')
    NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
    (( NODE_COUNT > 0 && NOT_READY == 0 )) && break
    sleep 5; NODE_ELAPSED=$((NODE_ELAPSED + 5))
done
kubectl get nodes -o wide
echo ""
NOT_READY=$(kubectl get nodes --no-headers 2>/dev/null | awk '$2 != "Ready" {c++} END {print c+0}')
NODE_COUNT=$(kubectl get nodes --no-headers 2>/dev/null | wc -l)
if (( NODE_COUNT > 0 && NOT_READY == 0 )); then
    ok "All ${NODE_COUNT} node(s) Ready"
else
    fail "${NOT_READY} node(s) not Ready after ${NODE_TIMEOUT}s"
fi
WIN_NODE=$(kubectl get nodes --no-headers -l kubernetes.io/os=windows -o name | head -1)
if [[ -n "$WIN_NODE" ]]; then ok "Windows node found: $WIN_NODE"
else
    echo -e "  ${YELLOW}[WARN]${NC}  No Windows node found (skipping Windows checks)"
    WIN_NODE=""
fi

# =============================================================================
echo -e "\n  ${CYAN}[2/6] System pods${NC}"
# =============================================================================
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
echo -e "\n  ${CYAN}[3/6] Deploy Linux test pod${NC}"
# =============================================================================
kubectl apply -f - << 'EOF' > /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: linux-test
  namespace: default
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
kubectl wait --for=condition=Ready pod/linux-test --timeout=90s 2>/dev/null && ok "linux-test pod running" || fail "linux-test pod failed"
LINUX_POD_IP=$(kubectl get pod linux-test -o jsonpath='{.status.podIP}')
info "Linux pod IP: $LINUX_POD_IP"

# =============================================================================
echo -e "\n  ${CYAN}[4/6] Deploy Windows test pod${NC}"
# =============================================================================
WIN_POD_IP=""
if [[ -n "$WIN_NODE" ]]; then
kubectl apply -f - << 'EOF' > /dev/null
apiVersion: v1
kind: Pod
metadata:
  name: windows-test
  namespace: default
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
echo "  Waiting for windows-test pod (may take 3-5 min for image pull)..."
kubectl wait --for=condition=Ready pod/windows-test --timeout=300s 2>/dev/null && ok "windows-test pod running" || fail "windows-test pod failed to start"
WIN_POD_IP=$(kubectl get pod windows-test -o jsonpath='{.status.podIP}')
info "Windows pod IP: $WIN_POD_IP"
else
    echo -e "  ${YELLOW}[SKIP]${NC}  No Windows node — skipping Windows pod deployment"
fi

# =============================================================================
echo -e "\n  ${CYAN}[5/6] Pod-to-pod connectivity${NC}"
# =============================================================================
# Linux -> Windows (only if Windows pod exists)
if [[ -n "$WIN_POD_IP" ]]; then
    if kubectl exec linux-test -- ping -c 2 "$WIN_POD_IP" &>/dev/null; then
        ok "Linux pod -> Windows pod: reachable"
    else
        fail "Linux pod -> Windows pod: NOT reachable (check routing + rp_filter)"
    fi
else
    echo -e "  ${YELLOW}[SKIP]${NC}  Linux -> Windows ping skipped (no Windows pod)"
fi
# Linux -> Linux  
if kubectl exec linux-test -- wget -qO- http://linux-test &>/dev/null 2>&1; then
    ok "Linux pod -> Linux pod: OK"
fi

# =============================================================================
echo -e "\n  ${CYAN}[6/6] DNS resolution${NC}"
# =============================================================================
if kubectl exec linux-test -- nslookup kubernetes.default.svc.cluster.local &>/dev/null; then
    ok "DNS: kubernetes.default resolves in Linux pod"
else
    fail "DNS: resolution failed in Linux pod"
fi

# =============================================================================
echo ""
echo -e "  ${CYAN}Calico node status:${NC}"
# =============================================================================
kubectl get nodes -o custom-columns='NODE:.metadata.name,IP:.metadata.annotations.projectcalico\.org/IPv4Address,VXLAN:.metadata.annotations.projectcalico\.org/IPv4VXLANTunnelAddr'
echo ""

# =============================================================================
# Summary
# =============================================================================
echo ""
if [[ $FAILURES -eq 0 ]]; then
    echo -e "  ${GREEN}+--------------------------------------------------+${NC}"
    echo -e "  ${GREEN}|  ALL CHECKS PASSED - Cluster is healthy!          |${NC}"
    echo -e "  ${GREEN}+--------------------------------------------------+${NC}"
else
    echo -e "  ${RED}+--------------------------------------------------+${NC}"
    echo -e "  ${RED}|  $FAILURES CHECK(S) FAILED - See output above      |${NC}"
    echo -e "  ${RED}+--------------------------------------------------+${NC}"
fi
echo ""

# Cleanup test pods (and their service if created in a future validation extension).
kubectl delete pod linux-test windows-test --ignore-not-found --wait=true --timeout=120s > /dev/null 2>&1 || true
ok "Test pods cleanup completed"

# Final gate: Jenkins must not finish successfully until every remaining
# non-terminal pod across every namespace is Running and Ready.
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
