#!/usr/bin/env bash
# =============================================================================
#  02-linux-worker-setup.sh  —  Kubernetes Worker Node Bootstrap
#  Supports: ContainerD | CRI-O
#  k8s v1.32.x  |  Ubuntu 22/24 + Rocky/RHEL 8/9
# =============================================================================
set -euo pipefail

# ── Passed by Jenkins via env ─────────────────────────────────────────────────
K8S_VERSION="${K8S_VERSION:-1.32.3}"
RUNTIME="${RUNTIME:-containerd}"         # containerd | crio (CRI-O)
JOIN_COMMAND="${JOIN_COMMAND:-}"         # full kubeadm join ... string
SETUP_USER="${SETUP_USER:-k8sadmin}"

# Kubernetes/host-only subnet.
# Example:
#   NODE_SUBNET=192.168.56.
#
# The script searches the host interfaces for an IPv4 address
# belonging to this subnet instead of relying on hostname -I ordering.
NODE_SUBNET="${NODE_SUBNET:-192.168.56.}"

# If NODE_IP is explicitly supplied by Jenkins, use it.
# Otherwise dynamically detect the IP from NODE_SUBNET.
if [[ -n "${NODE_IP:-}" ]]; then
  NODE_IP="${NODE_IP}"
else
  NODE_IP="$(
    ip -4 -o addr show |
      awk -v subnet="${NODE_SUBNET}" '
        $4 ~ "^" subnet {
          split($4, a, "/")
          print a[1]
          exit
        }
      '
  )"
fi

# Fail early if the host-only IP could not be detected.
if [[ -z "${NODE_IP}" ]]; then
  echo "ERROR: Could not detect an IPv4 address on NODE_SUBNET=${NODE_SUBNET}" >&2
  echo "Available IPv4 addresses:" >&2
  ip -4 -o addr show >&2 || true
  exit 1
fi

# ENABLE_FIREWALL: true = enable + open ports, false = disable firewall entirely
ENABLE_FIREWALL="${ENABLE_FIREWALL:-true}"

# ── Colours ───────────────────────────────────────────────────────────────────
CY='\033[0;36m'; GR='\033[0;32m'; RD='\033[0;31m'; YL='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n  ${CY}[$1]${NC} $2\n  $(printf '%0.s-' {1..66})"; }
ok()   { echo -e "  ${GR}[OK]${NC}   $*"; }
warn() { echo -e "  ${YL}[WARN]${NC} $*"; }
die()  { echo -e "  ${RD}[FAIL]${NC} $*" >&2; exit 1; }
info() { echo -e "  ${CY}[....]${NC} $*"; }

# ── APT non-interactive ───────────────────────────────────────────────────────
export DEBIAN_FRONTEND=noninteractive
APT_OPTS="-y -q \
  -o Dpkg::Options::=--force-confold \
  -o Dpkg::Options::=--force-confdef \
  -o APT::Get::Assume-Yes=true"

# ── Detect OS ─────────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  OS_ID="${ID}"
  OS_VER="${VERSION_ID%%.*}"
else
  die "Cannot detect OS"
fi

if [[ "${OS_ID}" =~ ^(ubuntu|debian|linuxmint|pop|elementary|kali|raspbian)$ ]]; then
  PKG_MGR="apt"
elif [[ "${OS_ID}" =~ ^(rhel|centos|rocky|almalinux|fedora|ol|scientific)$ ]]; then
  PKG_MGR="dnf"
elif [[ "${OS_ID}" =~ ^(opensuse|sles|suse)$ ]]; then
  PKG_MGR="zypper"
elif command -v apt-get &>/dev/null; then
  PKG_MGR="apt"
elif command -v dnf &>/dev/null; then
  PKG_MGR="dnf"
else
  die "Unsupported OS: ${OS_ID}"
fi

echo -e "
  ${CY}+================================================================+${NC}
  ${CY}|     KUBERNETES WORKER NODE SETUP  v${K8S_VERSION}              |${NC}
  ${CY}+================================================================+${NC}

  ${CY}[....${NC}  Node IP: ${NODE_IP} | OS: ${OS_ID} ${OS_VER} | Runtime: ${RUNTIME}
  ${CY}[....${NC}  Node subnet: ${NODE_SUBNET}
  ${CY}[....${NC}  Firewall enabled: ${ENABLE_FIREWALL}
"

# =============================================================================
step "1/7" "System prerequisites"
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

# ── Firewall management ───────────────────────────────────────────────────────
# Worker K8s ports:
#   22/tcp    SSH
#   10250/tcp Kubelet API
#   10256/tcp kube-proxy healthz
#   4789/udp  Calico VXLAN
#   8472/udp  Flannel VXLAN

configure_firewall_worker() {
  local enable
  enable="${ENABLE_FIREWALL,,}"

  # Detect firewall type — firewalld takes priority on RHEL
  local FWT="none"

  command -v ufw &>/dev/null && FWT="ufw"
  command -v firewall-cmd &>/dev/null && FWT="firewalld"

  local UFW_PORTS=(22/tcp 10250/tcp 10256/tcp 4789/udp 8472/udp)
  local FWD_PORTS=(22/tcp 10250/tcp 10256/tcp 4789/udp 8472/udp)

  if [[ "$enable" == "true" ]]; then
    case "$FWT" in
      ufw)
        ufw --force enable 2>/dev/null || true

        for p in "${UFW_PORTS[@]}"; do
          ufw allow "$p" comment "K8s-worker" 2>/dev/null || true
        done

        ufw reload 2>/dev/null || true

        ok "ufw enabled — worker ports opened: ${UFW_PORTS[*]}"
        ;;

      firewalld)
        systemctl enable --now firewalld 2>/dev/null || true

        for p in "${FWD_PORTS[@]}"; do
          firewall-cmd --permanent --add-port="$p" 2>/dev/null || true
        done

        firewall-cmd --reload 2>/dev/null || true

        ok "firewalld enabled — worker ports opened: ${FWD_PORTS[*]}"
        ;;

      *)
        warn "No ufw/firewalld found — skipping firewall config"
        info "Ensure external firewall allows: 22/tcp 10250/tcp 10256/tcp 4789/udp 8472/udp"
        ;;
    esac
  else
    case "$FWT" in
      ufw)
        ufw disable 2>/dev/null || true
        ok "ufw disabled"
        ;;

      firewalld)
        systemctl disable --now firewalld 2>/dev/null || true
        ok "firewalld disabled"
        ;;

      *)
        ok "No active firewall found"
        ;;
    esac
  fi
}

configure_firewall_worker

# =============================================================================
step "2/7" "Installing container runtime: ${RUNTIME}"
# =============================================================================

install_containerd_apt() {
  apt-get update -qq
  apt-get install ${APT_OPTS} ca-certificates curl gnupg

  install -m 0755 -d /etc/apt/keyrings

  local CODENAME
  CODENAME=$(
    . /etc/os-release &&
    echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}}"
  )

  local REPO_URL KEYRING_FILE

  if [[ "${OS_ID}" == "debian" ]]; then
    REPO_URL="https://download.docker.com/linux/debian"
  else
    REPO_URL="https://download.docker.com/linux/ubuntu"
  fi

  KEYRING_FILE="/etc/apt/keyrings/docker.gpg"

  curl -fsSL "${REPO_URL}/gpg" |
    gpg --dearmor -o "${KEYRING_FILE}" --batch --yes

  chmod a+r "${KEYRING_FILE}"

  echo "deb [arch=$(dpkg --print-architecture) signed-by=${KEYRING_FILE}] ${REPO_URL} ${CODENAME} stable" \
    >/etc/apt/sources.list.d/docker.list

  apt-get update -qq
  apt-get install ${APT_OPTS} containerd.io
}

install_containerd_dnf() {
  dnf config-manager --add-repo \
    https://download.docker.com/linux/centos/docker-ce.repo \
    -y 2>/dev/null || true

  dnf install -y containerd.io
}

install_crio_apt() {
  local VERSION="${K8S_VERSION%.*}"

  curl -fsSL \
    "https://pkgs.k8s.io/addons:/cri-o:/stable:/v${VERSION}/deb/Release.key" |
    gpg --dearmor \
      -o /etc/apt/keyrings/cri-o-apt-keyring.gpg \
      --batch --yes

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

  until [ -S /run/containerd/containerd.sock ] &&
        ctr version &>/dev/null; do

    sleep 2
    retries=$((retries+1))

    [ $retries -ge 20 ] &&
      die "containerd socket not ready after 40s"
  done

  ok "containerd installed (SystemdCgroup=true)"
}

configure_crio() {
  systemctl enable --now crio
  ok "CRI-O installed"
}

case "${RUNTIME}" in
  containerd)
    if [[ "$PKG_MGR" == "apt" ]]; then
      install_containerd_apt
    else
      install_containerd_dnf
    fi

    configure_containerd
    ;;

  crio)
    if [[ "$PKG_MGR" == "apt" ]]; then
      install_crio_apt
    else
      install_crio_dnf
    fi

    configure_crio
    ;;

  *)
    die "Unknown runtime: ${RUNTIME}"
    ;;
esac

# =============================================================================
step "3/7" "Installing kubeadm / kubelet / kubectl  (v${K8S_VERSION})"
# =============================================================================

K8S_MINOR="${K8S_VERSION%.*}"

install_k8s_apt() {
  apt-get install ${APT_OPTS} apt-transport-https curl

  curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" |
    gpg --dearmor \
      -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
      --batch --yes

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
    "kubelet-${K8S_VERSION}" \
    "kubeadm-${K8S_VERSION}" \
    "kubectl-${K8S_VERSION}"
}

if [[ "$PKG_MGR" == "apt" ]]; then
  install_k8s_apt
else
  install_k8s_dnf
fi

systemctl enable --now kubelet

ok "kubeadm / kubelet / kubectl installed"

# =============================================================================
step "4/7" "Syncing system clock (prevents x509 TLS errors on join)"
# =============================================================================

# CRITICAL:
# The "x509: current time is before certificate validity" error occurs
# when this node's clock is behind the master by more than ~5 minutes.
#
# RHEL/Rocky VMs are especially prone to this when started from snapshots or
# when chrony has not stepped the clock since boot.
#
# We force an immediate hard sync HERE, before kubeadm join.

sync_clock() {
  local synced=false

  local now_before
  now_before=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  info "Clock before sync: ${now_before}"

  if [[ "$PKG_MGR" == "apt" ]]; then

    # Ubuntu/Debian — use systemd-timesyncd
    timedatectl set-ntp true 2>/dev/null || true
    systemctl restart systemd-timesyncd 2>/dev/null || true

    local w=0

    while [[ $w -lt 30 ]]; do
      timedatectl status 2>/dev/null |
        grep -q "synchronized: yes" &&
        {
          synced=true
          break
        }

      sleep 2
      w=$((w+2))
    done

    # Fallback: ntpdate
    if [[ "$synced" == "false" ]] &&
       command -v ntpdate &>/dev/null; then

      ntpdate -u pool.ntp.org 2>/dev/null &&
        synced=true ||
        true
    fi

  else

    # RHEL/Rocky/AlmaLinux — use chrony
    if ! command -v chronyd &>/dev/null; then
      info "Installing chrony..."
      dnf install -y -q chrony 2>/dev/null || true
    fi

    if command -v chronyd &>/dev/null; then

      systemctl enable --now chronyd 2>/dev/null || true

      sleep 2

      # chronyc makestep:
      # immediately step the clock rather than slew.
      if chronyc makestep 2>/dev/null; then
        synced=true
      fi

      info "Chrony tracking:"

      chronyc tracking 2>/dev/null |
        grep -E 'System time|RMS offset|Last offset' ||
        true
    fi

    # Fallback
    if [[ "$synced" == "false" ]] &&
       command -v ntpdate &>/dev/null; then

      ntpdate -u pool.ntp.org 2>/dev/null &&
        synced=true ||
        true
    fi
  fi

  local now_after
  now_after=$(date -u '+%Y-%m-%dT%H:%M:%SZ')

  if [[ "$synced" == "true" ]]; then
    ok "Clock synced — UTC: ${now_after}"
  else
    warn "Clock sync uncertain — UTC: ${now_after}"
    warn "If kubeadm join fails with x509 certificate errors, run: chronyc makestep"
  fi
}

sync_clock

# =============================================================================
step "5/7" "Joining cluster"
# =============================================================================

case "${RUNTIME}" in
  containerd)
    CRI_SOCKET="unix:///run/containerd/containerd.sock"
    ;;

  crio)
    CRI_SOCKET="unix:///var/run/crio/crio.sock"
    ;;
esac

if [[ -z "${JOIN_COMMAND}" ]]; then
  die "JOIN_COMMAND env var is empty — cannot join cluster"
fi

# Ensure runtime socket is ready
RT_SOCK="${CRI_SOCKET#unix://}"

info "Waiting for runtime socket: ${RT_SOCK}"

rt_wait=0

until [ -S "${RT_SOCK}" ]; do
  sleep 2
  rt_wait=$((rt_wait + 2))

  [ $rt_wait -ge 30 ] &&
    die "Runtime socket ${RT_SOCK} not ready after 30s — check containerd/crio logs"
done

ok "Runtime socket ready"

kubeadm reset -f --cri-socket "${CRI_SOCKET}" 2>/dev/null || true

rm -rf \
  /etc/kubernetes \
  /var/lib/etcd \
  /var/lib/kubelet/config.yaml \
  /etc/cni/net.d

# Execute join with explicit CRI socket appended
eval "${JOIN_COMMAND} --cri-socket ${CRI_SOCKET}"

ok "Node joined cluster"

# =============================================================================
step "6/7" "Configuring kubelet node IP and DNS"
# =============================================================================

# kubelet drop-in location differs by distro:
#
#   Debian/Ubuntu → /etc/default/kubelet
#   RHEL/Rocky   → /etc/sysconfig/kubelet

case "${PKG_MGR}" in
  apt)
    KUBELET_ENV_FILE="/etc/default/kubelet"
    ;;

  dnf)
    KUBELET_ENV_FILE="/etc/sysconfig/kubelet"
    ;;

  *)
    die "Unsupported package manager for kubelet configuration: ${PKG_MGR}"
    ;;
esac

mkdir -p "$(dirname "${KUBELET_ENV_FILE}")"

cat > "${KUBELET_ENV_FILE}" <<EOF
KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}
EOF

ok "kubelet node-ip configured: ${NODE_IP}"
ok "kubelet environment file: ${KUBELET_ENV_FILE}"

# -----------------------------------------------------------------------------
# Configure kubelet DNS resolver path
#
# Ubuntu systems using systemd-resolved normally have:
#   /run/systemd/resolve/resolv.conf
#
# Rocky/RHEL systems using NetworkManager normally have:
#   /etc/resolv.conf
#
# Detect the resolver path instead of hard-coding one distribution's path.
# -----------------------------------------------------------------------------

if [[ -f /run/systemd/resolve/resolv.conf ]]; then

  KUBELET_RESOLV_CONF="/run/systemd/resolve/resolv.conf"

elif [[ -f /etc/resolv.conf ]]; then

  KUBELET_RESOLV_CONF="/etc/resolv.conf"

else

  die "No usable DNS resolver configuration found"

fi

if [[ -f /var/lib/kubelet/config.yaml ]]; then

  if grep -qE '^[[:space:]]*resolvConf:' /var/lib/kubelet/config.yaml; then

    sed -i \
      "s|^[[:space:]]*resolvConf:.*|resolvConf: ${KUBELET_RESOLV_CONF}|" \
      /var/lib/kubelet/config.yaml

  else

    cat >> /var/lib/kubelet/config.yaml <<EOF

resolvConf: ${KUBELET_RESOLV_CONF}
EOF

  fi

else

  die "Kubelet config not found: /var/lib/kubelet/config.yaml"

fi

ok "kubelet DNS resolver configured: ${KUBELET_RESOLV_CONF}"

# -----------------------------------------------------------------------------
# Restart kubelet and validate
# -----------------------------------------------------------------------------

systemctl daemon-reload
systemctl restart kubelet

if ! systemctl is-active --quiet kubelet; then
  die "kubelet failed to start after configuration"
fi

ok "kubelet restarted successfully"

# Show final configuration for troubleshooting/Jenkins logs
info "Final kubelet network configuration:"
grep -E 'node-ip|resolvConf' \
  "${KUBELET_ENV_FILE}" \
  /var/lib/kubelet/config.yaml 2>/dev/null ||
  true

# =============================================================================
step "7/7" "Done"
# =============================================================================

echo -e "\n  ${GR}+================================================================+${NC}"
echo -e "  ${GR}|        WORKER NODE BOOTSTRAP COMPLETE                          |${NC}"
echo -e "  ${GR}+================================================================+${NC}"
echo -e "  Node IP  : ${NODE_IP}"
echo -e "  Node Subnet : ${NODE_SUBNET}"
echo -e "  Runtime  : ${RUNTIME}"
echo -e "  K8s ver  : v${K8S_VERSION}"
echo -e "  Firewall : ${ENABLE_FIREWALL}"
echo ""
