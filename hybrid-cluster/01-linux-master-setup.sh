#!/usr/bin/env bash
# =============================================================================
#  01-linux-master-setup.sh  —  Kubernetes Master Node Bootstrap
#  Supports: ContainerD | CRI-O  x  Calico | Flannel CNI
#  k8s v1.32.x  |  Ubuntu 22/24 + Rocky/RHEL 8/9
# =============================================================================
set -euo pipefail

# ── Passed by Jenkins via env ─────────────────────────────────────────────────
MASTER_IP="${MASTER_IP:-$(hostname -I | awk '{print $1}')}"
K8S_VERSION="${K8S_VERSION:-1.32.3}"
RUNTIME="${RUNTIME:-containerd}"          # containerd | crio
CNI_PLUGIN="${CNI_PLUGIN:-calico}"        # calico | flannel | weave
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"
SETUP_USER="${SETUP_USER:-k8sadmin}"

# ── Colours ───────────────────────────────────────────────────────────────────
CY='\033[0;36m'; GR='\033[0;32m'; RD='\033[0;31m'; YL='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n  ${CY}[$1]${NC} $2\n  $(printf '%0.s-' {1..66})"; }
ok()   { echo -e "  ${GR}[OK]${NC}   $*"; }
info() { echo -e "  ${CY}[....${NC}  $*"; }
die()  { echo -e "  ${RD}[FAIL]${NC} $*" >&2; exit 1; }

# ── APT non-interactive — fixes debconf dialog errors ────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-y -q \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -o APT::Get::Assume-Yes=true"

# ── Detect OS ─────────────────────────────────────────────────────────────────
if   [[ -f /etc/os-release ]]; then source /etc/os-release; OS_ID="${ID}"; OS_VER="${VERSION_ID%%.*}"
else die "Cannot detect OS"; fi
[[ "$OS_ID" =~ ^(ubuntu|debian)$ ]] && PKG_MGR="apt" || PKG_MGR="dnf"

echo -e "
  ${CY}+================================================================+${NC}
  ${CY}|     KUBERNETES MASTER NODE SETUP  v${K8S_VERSION}              |${NC}
  ${CY}+================================================================+${NC}

  ${CY}[....${NC}  Master IP: ${MASTER_IP} | OS: ${OS_ID} ${OS_VER} | Runtime: ${RUNTIME} | CNI: ${CNI_PLUGIN}
        kubectl will be configured for user: ${SETUP_USER}
"

# =============================================================================
step "1/9" "System prerequisites"
# =============================================================================

# ── Swap off (idempotent) ─────────────────────────────────────────────────────
swapoff -a
sed -i.bak '/\bswap\b/d' /etc/fstab
ok "Swap disabled"

# ── Kernel modules ─────────────────────────────────────────────────────────────
cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

# ── sysctl ────────────────────────────────────────────────────────────────────
cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
EOF
sysctl --system -q
ok "Kernel modules and sysctl configured (rp_filter=0 for Windows VXLAN)"

# ── SELinux permissive (RHEL/Rocky) ───────────────────────────────────────────
if [[ "$PKG_MGR" == "dnf" ]] && command -v setenforce &>/dev/null; then
  setenforce 0 || true
  sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
  ok "SELinux set to permissive"
fi

# ── Firewall off (lab cluster) ────────────────────────────────────────────────
if [[ "$PKG_MGR" == "apt" ]]; then
  ufw disable 2>/dev/null || true
else
  systemctl disable --now firewalld 2>/dev/null || true
fi
ok "Firewall disabled"

# =============================================================================
step "2/9" "Installing container runtime: ${RUNTIME}"
# =============================================================================

install_containerd_apt() {
  apt-get update -qq
  apt-get install ${APT_OPTS} ca-certificates curl gnupg lsb-release
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg --batch --yes
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" \
    >/etc/apt/sources.list.d/docker.list
  apt-get update -qq
  apt-get install ${APT_OPTS} containerd.io
}

install_containerd_dnf() {
  dnf config-manager --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo -y 2>/dev/null || true
  dnf install -y containerd.io
}

install_crio_apt() {
  local OS="xUbuntu_$(lsb_release -rs | tr -d '.')"
  local VERSION="${K8S_VERSION%.*}"
  # Use cri-o project repo
  curl -fsSL "https://pkgs.k8s.io/addons:/cri-o:/stable:/v${VERSION}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/cri-o-apt-keyring.gpg --batch --yes
  echo "deb [signed-by=/etc/apt/keyrings/cri-o-apt-keyring.gpg] \
    https://pkgs.k8s.io/addons:/cri-o:/stable:/v${VERSION}/deb/ /" \
    >/etc/apt/sources.list.d/cri-o.list
  apt-get update -qq
  apt-get install ${APT_OPTS} cri-o
}

install_crio_dnf() {
  local VERSION="${K8S_VERSION%.*}"
  cat >/etc/yum.repos.d/cri-o.repo <<EOF
[cri-o]
name=CRI-O
baseurl=https://pkgs.k8s.io/addons:/cri-o:/stable:/v${VERSION}/rpm/
gpgcheck=1
gpgkey=https://pkgs.k8s.io/addons:/cri-o:/stable:/v${VERSION}/rpm/repodata/repomd.xml.key
EOF
  dnf install -y cri-o
}

configure_containerd() {
  mkdir -p /etc/containerd
  containerd config default >/etc/containerd/config.toml
  # Enable systemd cgroup driver
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  systemctl enable --now containerd
  ok "containerd installed and configured (SystemdCgroup=true)"
}

configure_crio() {
  # cri-o uses systemd cgroup by default
  systemctl enable --now crio
  ok "CRI-O installed and configured"
}

case "${RUNTIME}" in
  containerd)
    [[ "$PKG_MGR" == "apt" ]] && install_containerd_apt || install_containerd_dnf
    configure_containerd
    CRICTL_SOCK="unix:///run/containerd/containerd.sock"
    ;;
  crio)
    [[ "$PKG_MGR" == "apt" ]] && install_crio_apt || install_crio_dnf
    configure_crio
    CRICTL_SOCK="unix:///var/run/crio/crio.sock"
    ;;
  *) die "Unknown runtime: ${RUNTIME}. Choose containerd or crio" ;;
esac

# =============================================================================
step "3/9" "Installing kubeadm / kubelet / kubectl  (v${K8S_VERSION})"
# =============================================================================

K8S_MINOR="${K8S_VERSION%.*}"   # e.g. 1.32

install_k8s_apt() {
  apt-get install ${APT_OPTS} apt-transport-https curl
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --batch --yes
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  apt-get update -qq
  apt-get install ${APT_OPTS} \
    kubelet="${K8S_VERSION}-*" \
    kubeadm="${K8S_VERSION}-*" \
    kubectl="${K8S_VERSION}-*"
  apt-mark hold kubelet kubeadm kubectl
}

install_k8s_dnf() {
  cat >/etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
  dnf install -y --disableexcludes=kubernetes \
    "kubelet-${K8S_VERSION}" "kubeadm-${K8S_VERSION}" "kubectl-${K8S_VERSION}"
  dnf versionlock add kubelet kubeadm kubectl 2>/dev/null || true
}

[[ "$PKG_MGR" == "apt" ]] && install_k8s_apt || install_k8s_dnf
systemctl enable --now kubelet
ok "kubeadm / kubelet / kubectl installed and pinned"

# =============================================================================
step "4/9" "kubeadm init"
# =============================================================================

# Determine CRI socket
case "${RUNTIME}" in
  containerd) CRI_SOCKET="unix:///run/containerd/containerd.sock" ;;
  crio)       CRI_SOCKET="unix:///var/run/crio/crio.sock" ;;
esac

# Reset any previous state
kubeadm reset -f --cri-socket "${CRI_SOCKET}" 2>/dev/null || true
rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet/config.yaml

kubeadm init \
  --apiserver-advertise-address="${MASTER_IP}" \
  --pod-network-cidr="${POD_CIDR}" \
  --cri-socket="${CRI_SOCKET}" \
  --kubernetes-version="v${K8S_VERSION}" \
  --ignore-preflight-errors=NumCPU,Mem \
  2>&1 | tee /tmp/kubeadm-init.log

ok "kubeadm init complete"

# =============================================================================
step "5/9" "Configuring kubectl for ${SETUP_USER}"
# =============================================================================

USER_HOME=$(eval echo "~${SETUP_USER}")
mkdir -p "${USER_HOME}/.kube"
cp /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
chown -R "${SETUP_USER}:${SETUP_USER}" "${USER_HOME}/.kube"

# Also configure for root
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
export KUBECONFIG=/etc/kubernetes/admin.conf

ok "kubectl configured for ${SETUP_USER} and root"

# =============================================================================
step "6/9" "Installing CNI: ${CNI_PLUGIN}"
# =============================================================================

install_calico() {
  # Tigera operator approach — production-grade
  kubectl create -f \
    https://raw.githubusercontent.com/projectcalico/calico/v3.29.0/manifests/tigera-operator.yaml \
    --dry-run=client -o yaml | kubectl apply -f -

  cat <<EOF | kubectl apply -f -
apiVersion: operator.tigera.io/v1
kind: Installation
metadata:
  name: default
spec:
  calicoNetwork:
    ipPools:
    - blockSize: 26
      cidr: ${POD_CIDR}
      encapsulation: VXLANCrossSubnet
      natOutgoing: Enabled
      nodeSelector: all()
EOF
  ok "Calico CNI applied (VXLANCrossSubnet mode)"
}

install_flannel() {
  # Flannel requires pod CIDR set — already done via kubeadm
  kubectl apply -f \
    https://raw.githubusercontent.com/flannel-io/flannel/master/Documentation/kube-flannel.yml
  ok "Flannel CNI applied"
}

install_weave() {
  # Weave Net — peer-to-peer overlay, no external dependency
  local WEAVE_VER
  WEAVE_VER=$(curl -sSL https://api.github.com/repos/weaveworks/weave/releases/latest \
    | grep '"tag_name"' | head -1 | sed 's/.*"v\([^"]*\)".*/\1/')
  WEAVE_VER="${WEAVE_VER:-2.8.1}"
  kubectl apply -f \
    "https://github.com/weaveworks/weave/releases/download/v${WEAVE_VER}/weave-daemonset-k8s.yaml"
  ok "Weave Net CNI applied (v${WEAVE_VER})"
}

case "${CNI_PLUGIN}" in
  calico)  install_calico  ;;
  flannel) install_flannel ;;
  weave)   install_weave   ;;
  *)       die "Unknown CNI: ${CNI_PLUGIN}. Choose calico, flannel, or weave" ;;
esac

# =============================================================================
step "7/9" "Waiting for control-plane to be Ready"
# =============================================================================

echo -n "  Waiting for master node Ready"
for i in $(seq 1 60); do
  STATUS=$(kubectl get nodes --no-headers 2>/dev/null | awk '{print $2}' | head -1)
  if [[ "$STATUS" == "Ready" ]]; then
    echo -e "\n  ${GR}[OK]${NC}   Master node is Ready"
    break
  fi
  echo -n "."
  sleep 5
done
[[ "$STATUS" != "Ready" ]] && echo -e "\n  ${YL}[WARN]${NC} Master not Ready yet — workers may still join"

# =============================================================================
step "8/9" "Extracting join command"
# =============================================================================

JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)
echo "${JOIN_CMD}" >/tmp/k8s-join-command.sh
chmod 644 /tmp/k8s-join-command.sh
ok "Join command saved to /tmp/k8s-join-command.sh"
echo ""
echo "  JOIN COMMAND:"
echo "  ${JOIN_CMD}"

# =============================================================================
step "9/9" "Final cluster state"
# =============================================================================

kubectl get nodes -o wide 2>/dev/null || true
kubectl get pods -n kube-system 2>/dev/null || true

echo -e "\n  ${GR}+================================================================+${NC}"
echo -e "  ${GR}|        MASTER NODE BOOTSTRAP COMPLETE                          |${NC}"
echo -e "  ${GR}+================================================================+${NC}"
echo -e "  Master IP  : ${MASTER_IP}"
echo -e "  Runtime    : ${RUNTIME}"
echo -e "  CNI        : ${CNI_PLUGIN}  (calico | flannel | weave)"
echo -e "  Pod CIDR   : ${POD_CIDR}"
echo -e "  K8s version: v${K8S_VERSION}"
echo ""
