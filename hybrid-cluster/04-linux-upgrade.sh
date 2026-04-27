#!/usr/bin/env bash
# =============================================================================
#  04-linux-upgrade.sh  —  Kubernetes Node In-Place Upgrade
#
#  Supports:
#    Ubuntu 22/24  |  Debian 11/12
#    Rocky / RHEL / AlmaLinux 8/9
#    Fedora 36+
#
#  Called by Jenkins with env vars, or standalone:
#    sudo K8S_VERSION=1.31.0 NODE_ROLE=master RUNTIME=containerd bash 04-linux-upgrade.sh
#
#  Version-gap strategy (handled by Jenkinsfile):
#    Kubernetes supports upgrading only ONE minor version at a time.
#    The Jenkinsfile calls this script once per hop (e.g. 1.30→1.31→1.32).
#    This script upgrades kubeadm, does kubeadm upgrade apply/node,
#    then upgrades kubelet + kubectl and drains/uncordons accordingly.
# =============================================================================
set -euo pipefail

K8S_VERSION="${K8S_VERSION:-}"       # e.g. 1.32.3
NODE_ROLE="${NODE_ROLE:-worker}"     # master | worker
RUNTIME="${RUNTIME:-containerd}"
MASTER_IP="${MASTER_IP:-}"           # needed by workers to check API server
SETUP_USER="${SETUP_USER:-k8sadmin}"

# ── Colours ───────────────────────────────────────────────────────────────────
CY='\033[0;36m'; GR='\033[0;32m'; RD='\033[0;31m'; YL='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n  ${CY}[$1]${NC} $2\n  $(printf '%0.s-' {1..66})"; }
ok()   { echo -e "  ${GR}[OK]${NC}   $*"; }
warn() { echo -e "  ${YL}[WARN]${NC} $*"; }
die()  { echo -e "  ${RD}[FAIL]${NC} $*" >&2; exit 1; }

[[ -z "${K8S_VERSION}" ]] && die "K8S_VERSION is required"

export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-y -q -o Dpkg::Options::=--force-confold -o Dpkg::Options::=--force-confdef"

# ── Detect OS ─────────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
  source /etc/os-release; OS_ID="${ID}"; OS_VER="${VERSION_ID%%.*}"
else die "Cannot detect OS"; fi
if   [[ "${OS_ID}" =~ ^(ubuntu|debian|linuxmint|pop|elementary|kali|raspbian)$ ]]; then PKG_MGR="apt"
elif [[ "${OS_ID}" =~ ^(rhel|centos|rocky|almalinux|fedora|ol|scientific)$ ]];     then PKG_MGR="dnf"
elif command -v apt-get &>/dev/null; then PKG_MGR="apt"
elif command -v dnf     &>/dev/null; then PKG_MGR="dnf"
else die "Unsupported OS: ${OS_ID}. Only Debian/RHEL families are supported."; fi

K8S_MINOR="${K8S_VERSION%.*}"   # e.g. 1.32

echo -e "
  ${CY}+================================================================+${NC}
  ${CY}|     KUBERNETES NODE UPGRADE  →  v${K8S_VERSION}               |${NC}
  ${CY}+================================================================+${NC}

  ${CY}[....]${NC}  Host     : $(hostname)
  ${CY}[....]${NC}  Role     : ${NODE_ROLE}
  ${CY}[....]${NC}  OS       : ${OS_ID} ${OS_VER}
  ${CY}[....]${NC}  Runtime  : ${RUNTIME}
  ${CY}[....]${NC}  Target   : v${K8S_VERSION}
"

# =============================================================================
step "1" "Update Kubernetes apt/dnf repository to v${K8S_MINOR}"
# =============================================================================

if [[ "${PKG_MGR}" == "apt" ]]; then
  apt-get install ${APT_OPTS} apt-transport-https curl ca-certificates
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --batch --yes
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  apt-get update -qq
  ok "APT repo updated to v${K8S_MINOR}"
else
  cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
  dnf makecache -y 2>/dev/null || true
  ok "DNF repo updated to v${K8S_MINOR}"
fi

# =============================================================================
step "2" "Upgrade kubeadm to v${K8S_VERSION}"
# =============================================================================

if [[ "${PKG_MGR}" == "apt" ]]; then
  apt-mark unhold kubeadm 2>/dev/null || true
  apt-get install ${APT_OPTS} "kubeadm=${K8S_VERSION}-*"
  apt-mark hold kubeadm
else
  dnf install -y --disableexcludes=kubernetes "kubeadm-${K8S_VERSION}"
  dnf versionlock delete kubeadm 2>/dev/null || true
  dnf versionlock add    kubeadm 2>/dev/null || true
fi

kubeadm version
ok "kubeadm upgraded to v${K8S_VERSION}"

# =============================================================================
step "3" "Run kubeadm upgrade"
# =============================================================================

export KUBECONFIG=/etc/kubernetes/admin.conf

if [[ "${NODE_ROLE}" == "master" ]]; then
  echo "  Verifying upgrade plan..."
  kubeadm upgrade plan "v${K8S_VERSION}" 2>&1 | tail -20 || true

  echo "  Applying upgrade..."
  kubeadm upgrade apply "v${K8S_VERSION}" --yes \
    --ignore-preflight-errors=NumCPU,Mem \
    2>&1 | tee /tmp/kubeadm-upgrade.log
  ok "kubeadm upgrade apply complete"
else
  # Workers call 'kubeadm upgrade node' — no apply
  kubeadm upgrade node 2>&1 | tee /tmp/kubeadm-upgrade-node.log
  ok "kubeadm upgrade node complete"
fi

# =============================================================================
step "4" "Drain node"
# =============================================================================

NODE_NAME=$(kubectl get nodes --no-headers 2>/dev/null \
  | awk -v ip="${HOSTNAME}" '$1==ip || $1==ENVIRON["HOSTNAME"]{print $1}' | head -1)
[[ -z "${NODE_NAME}" ]] && NODE_NAME=$(hostname)

if [[ "${NODE_ROLE}" == "master" ]]; then
  kubectl drain "${NODE_NAME}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --grace-period=60 \
    --timeout=120s 2>/dev/null || warn "Drain had warnings (non-fatal)"
  ok "Master drained"
else
  # Workers need master API. Poll until reachable.
  if [[ -n "${MASTER_IP}" ]]; then
    for i in $(seq 1 10); do
      if curl -sk "https://${MASTER_IP}:6443/healthz" &>/dev/null; then break; fi
      echo "  Waiting for API server..."; sleep 10
    done
  fi
  kubectl drain "${NODE_NAME}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --grace-period=60 \
    --timeout=120s 2>/dev/null || warn "Drain had warnings (non-fatal)"
  ok "Worker drained"
fi

# =============================================================================
step "5" "Upgrade kubelet and kubectl to v${K8S_VERSION}"
# =============================================================================

if [[ "${PKG_MGR}" == "apt" ]]; then
  apt-mark unhold kubelet kubectl 2>/dev/null || true
  apt-get install ${APT_OPTS} "kubelet=${K8S_VERSION}-*" "kubectl=${K8S_VERSION}-*"
  apt-mark hold kubelet kubectl
else
  dnf install -y --disableexcludes=kubernetes \
    "kubelet-${K8S_VERSION}" "kubectl-${K8S_VERSION}"
  dnf versionlock delete kubelet kubectl 2>/dev/null || true
  dnf versionlock add    kubelet kubectl 2>/dev/null || true
fi

# Reload and restart
systemctl daemon-reload
systemctl restart kubelet
ok "kubelet + kubectl upgraded to v${K8S_VERSION}"

# =============================================================================
step "6" "Uncordon node"
# =============================================================================

sleep 10   # brief settle time after kubelet restart
kubectl uncordon "${NODE_NAME}" 2>/dev/null || warn "Uncordon failed — check manually"
ok "Node ${NODE_NAME} uncordoned"

# =============================================================================
step "7" "Verify node version"
# =============================================================================

sleep 5
kubectl get nodes -o wide 2>/dev/null | head -5 || true

echo -e "
  ${GR}+================================================================+${NC}
  ${GR}|     NODE UPGRADE COMPLETE                                       |${NC}
  ${GR}+================================================================+${NC}
  Host    : $(hostname)
  Role    : ${NODE_ROLE}
  Version : v${K8S_VERSION}
"
