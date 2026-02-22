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

echo -e "\n  ${CYAN}+================================================================+${NC}"
echo -e "  ${CYAN}|         HYBRID CLUSTER VALIDATION                              |${NC}"
echo -e "  ${CYAN}+================================================================+${NC}\n"

# =============================================================================
echo -e "  ${CYAN}[1/6] Node status${NC}"
# =============================================================================
echo ""
kubectl get nodes -o wide
echo ""
NOT_READY=$(kubectl get nodes --no-headers | grep -v ' Ready' | wc -l)
if [[ $NOT_READY -eq 0 ]]; then
    ok "All nodes Ready"
else
    fail "$NOT_READY node(s) not Ready"
fi
WIN_NODE=$(kubectl get nodes --no-headers -l kubernetes.io/os=windows -o name | head -1)
if [[ -n "$WIN_NODE" ]]; then ok "Windows node found: $WIN_NODE"
else fail "No Windows node found"; fi

# =============================================================================
echo -e "\n  ${CYAN}[2/6] System pods${NC}"
# =============================================================================
echo ""
kubectl get pods -n kube-system -o wide
echo ""
NOT_RUNNING=$(kubectl get pods -n kube-system --no-headers | grep -v ' Running\| Completed' | wc -l)
if [[ $NOT_RUNNING -eq 0 ]]; then ok "All kube-system pods Running"
else fail "$NOT_RUNNING kube-system pod(s) not Running"; fi

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

# =============================================================================
echo -e "\n  ${CYAN}[5/6] Pod-to-pod connectivity${NC}"
# =============================================================================
# Linux -> Windows
if [[ -n "$WIN_POD_IP" ]]; then
    if kubectl exec linux-test -- ping -c 2 "$WIN_POD_IP" &>/dev/null; then
        ok "Linux pod -> Windows pod: reachable"
    else
        fail "Linux pod -> Windows pod: NOT reachable (check routing + rp_filter)"
    fi
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

# Cleanup test pods
read -rp "  Delete test pods? [Y/n]: " ans
if [[ ! "$ans" =~ ^[Nn] ]]; then
    kubectl delete pod linux-test windows-test --ignore-not-found
    ok "Test pods deleted"
fi
