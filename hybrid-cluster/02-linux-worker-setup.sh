#!/usr/bin/env bash
# =============================================================================
#  02-linux-worker-setup.sh  —  Kubernetes Worker Node Bootstrap
#  Supports: ContainerD | CRI-O
#  k8s v1.32.x  |  Ubuntu 22/24 + Rocky/RHEL 8/9
# =============================================================================
set -euo pipefail

# ── Passed by Jenkins via env ─────────────────────────────────────────────────
K8S_VERSION="${K8S_VERSION:-1.32.3}"
RUNTIME="${RUNTIME:-containerd}"      # containerd | crio (CRI-O)
JOIN_COMMAND="${JOIN_COMMAND:-}"      # full kubeadm join ... string
SETUP_USER="${SETUP_USER:-k8sadmin}"
NODE_IP="${NODE_IP:-$(hostname -I | awk '{print $1}')}"

# ── Colours ───────────────────────────────────────────────────────────────────
CY='\033[0;36m'; GR='\033[0;32m'; RD='\033[0;31m'; NC='\033[0m'
step() { echo -e "\n  ${CY}[$1]${NC} $2\n  $(printf '%0.s-' {1..66})"; }
ok()   { echo -e "  ${GR}[OK]${NC}   $*"; }
die()  { echo -e "  ${RD}[FAIL]${NC} $*" >&2; exit 1; }

# ── APT non-interactive ───────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-y -q \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -o APT::Get::Assume-Yes=true"

# ── Detect OS ─────────────────────────────────────────────────────────────────
if   [[ -f /etc/os-release ]]; then source /etc/os-release; OS_ID="${ID}"; OS_VER="${VERSION_ID%%.*}"
else die "Cannot detect OS"; fi
if   [[ "${OS_ID}" =~ ^(ubuntu|debian|linuxmint|pop|elementary|kali|raspbian)$ ]]; then PKG_MGR="apt"
elif [[ "${OS_ID}" =~ ^(rhel|centos|rocky|almalinux|fedora|ol|scientific)$ ]];     then PKG_MGR="dnf"
elif [[ "${OS_ID}" =~ ^(opensuse|sles|suse)$ ]];                                    then PKG_MGR="zypper"
elif command -v apt-get &>/dev/null;  then PKG_MGR="apt"
elif command -v dnf     &>/dev/null;  then PKG_MGR="dnf"
else die "Unsupported OS: ${OS_ID}"; fi

echo -e "
  ${CY}+================================================================+${NC}
  ${CY}|     KUBERNETES WORKER NODE SETUP  v${K8S_VERSION}              |${NC}
  ${CY}+================================================================+${NC}

  ${CY}[....${NC}  Node IP: ${NODE_IP} | OS: ${OS_ID} ${OS_VER} | Runtime: ${RUNTIME}
"

# =============================================================================
step "1/6" "System prerequisites"
# =============================================================================

# ── Repair any interrupted dpkg state (common on reused VMs) ─────────────────
if [[ "$PKG_MGR" == "apt" ]]; then
  dpkg --configure -a --force-confold 2>/dev/null || true
  apt-get install -f -y -q 2>/dev/null || true
  ok "dpkg state verified / repaired"
fi

swapoff -a
sed -i.bak '/\bswap\b/d' /etc/fstab
ok "Swap disabled"

cat >/etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
EOF
modprobe overlay
modprobe br_netfilter

cat >/etc/sysctl.d/99-k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
EOF
sysctl --system -q
ok "Kernel modules and sysctl configured"

if [[ "$PKG_MGR" == "dnf" ]] && command -v setenforce &>/dev/null; then
  setenforce 0 || true
  sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config 2>/dev/null || true
  ok "SELinux set to permissive"
fi

if [[ "$PKG_MGR" == "apt" ]]; then
  ufw disable 2>/dev/null || true
else
  systemctl disable --now firewalld 2>/dev/null || true
fi
ok "Firewall disabled"

# =============================================================================
step "2/6" "Installing container runtime: ${RUNTIME}"
# =============================================================================

install_containerd_apt() {
  apt-get update -qq
  apt-get install ${APT_OPTS} ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  local CODENAME
  CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}}")
  local REPO_URL KEYRING_FILE
  if [[ "${OS_ID}" == "debian" ]]; then
    REPO_URL="https://download.docker.com/linux/debian"
  else
    REPO_URL="https://download.docker.com/linux/ubuntu"
  fi
  KEYRING_FILE="/etc/apt/keyrings/docker.gpg"
  curl -fsSL "${REPO_URL}/gpg" | gpg --dearmor -o "${KEYRING_FILE}" --batch --yes
  chmod a+r "${KEYRING_FILE}"
  echo "deb [arch=$(dpkg --print-architecture) signed-by=${KEYRING_FILE}] ${REPO_URL} ${CODENAME} stable" \
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
  local VERSION="${K8S_VERSION%.*}"
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

  # Stop first — containerd auto-starts on install with a bad default config
  systemctl stop containerd 2>/dev/null || true

  # Regenerate default config
  containerd config default > /etc/containerd/config.toml

  # Enable systemd cgroup driver (required for Kubernetes)
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

  # Verify the sed actually worked (containerd v2.x safety check)
  if ! grep -q 'SystemdCgroup = true' /etc/containerd/config.toml; then
    sed -i '/\[plugins.*runc.*options\]/,/\[/ s/SystemdCgroup = false/SystemdCgroup = true/' \
      /etc/containerd/config.toml
  fi

  # Restart cleanly with the new config
  systemctl enable containerd
  systemctl restart containerd

  # Wait for the socket to be ready before kubelet tries to use it
  local retries=0
  until [ -S /run/containerd/containerd.sock ] && \
        ctr version &>/dev/null; do
    sleep 1
    retries=$((retries+1))
    [ $retries -ge 15 ] && die "containerd socket not ready after 15s"
  done

  ok "containerd installed (SystemdCgroup=true)"
}

configure_crio() {
  systemctl enable --now crio
  ok "CRI-O installed"
}

case "${RUNTIME}" in
  containerd)
    if [[ "$PKG_MGR" == "apt" ]]; then install_containerd_apt; else install_containerd_dnf; fi
    configure_containerd ;;
  crio)
    if [[ "$PKG_MGR" == "apt" ]]; then install_crio_apt; else install_crio_dnf; fi
    configure_crio ;;
  *) die "Unknown runtime: ${RUNTIME}" ;;
esac

# =============================================================================
step "3/6" "Installing kubeadm / kubelet / kubectl  (v${K8S_VERSION})"
# =============================================================================

K8S_MINOR="${K8S_VERSION%.*}"

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
}

if [[ "$PKG_MGR" == "apt" ]]; then install_k8s_apt; else install_k8s_dnf; fi
systemctl enable --now kubelet
ok "kubeadm / kubelet / kubectl installed"

# =============================================================================
step "4/6" "Joining cluster"
# =============================================================================

case "${RUNTIME}" in
  containerd) CRI_SOCKET="unix:///run/containerd/containerd.sock" ;;
  crio)       CRI_SOCKET="unix:///var/run/crio/crio.sock" ;;
esac

if [[ -z "${JOIN_COMMAND}" ]]; then
  die "JOIN_COMMAND env var is empty — cannot join cluster"
fi

kubeadm reset -f --cri-socket "${CRI_SOCKET}" 2>/dev/null || true
rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet/config.yaml /etc/cni/net.d

# Execute join with explicit CRI socket appended
eval "${JOIN_COMMAND} --cri-socket ${CRI_SOCKET}"
ok "Node joined cluster"

# =============================================================================
step "5/6" "Configuring kubelet node IP"
# =============================================================================

mkdir -p /etc/default
echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" >/etc/default/kubelet
systemctl daemon-reload
systemctl restart kubelet
ok "kubelet node-ip set to ${NODE_IP}"

# =============================================================================
step "6/6" "Done"
# =============================================================================

echo -e "\n  ${GR}+================================================================+${NC}"
echo -e "  ${GR}|        WORKER NODE BOOTSTRAP COMPLETE                          |${NC}"
echo -e "  ${GR}+================================================================+${NC}"
echo -e "  Node IP  : ${NODE_IP}"
echo -e "  Runtime  : ${RUNTIME}"
echo -e "  K8s ver  : v${K8S_VERSION}"
echo ""