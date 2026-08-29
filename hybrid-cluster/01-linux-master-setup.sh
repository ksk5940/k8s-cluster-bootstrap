#!/usr/bin/env bash
# =============================================================================
#  01-linux-master-setup.sh  —  Kubernetes Master Node Bootstrap
#  Supports: ContainerD | CRI-O  x  Calico | Flannel | Weave CNI
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
# ENABLE_FIREWALL: true = enable + open required K8s master ports
#                 false = disable firewall completely
ENABLE_FIREWALL="${ENABLE_FIREWALL:-true}"

# ── Colours ───────────────────────────────────────────────────────────────────
CY='\033[0;36m'; GR='\033[0;32m'; RD='\033[0;31m'; YL='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n  ${CY}[$1]${NC} $2\n  $(printf '%0.s-' {1..66})"; }
ok()   { echo -e "  ${GR}[OK]${NC}   $*"; }
info() { echo -e "  ${CY}[....${NC}  $*"; }
warn() { echo -e "  ${YL}[WARN]${NC} $*"; }
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
# Broad Linux family detection: apt for Debian-based, dnf for RHEL-based, zypper for SUSE
if   [[ "${OS_ID}" =~ ^(ubuntu|debian|linuxmint|pop|elementary|kali|raspbian)$ ]]; then PKG_MGR="apt"
elif [[ "${OS_ID}" =~ ^(rhel|centos|rocky|almalinux|fedora|ol|scientific)$ ]];     then PKG_MGR="dnf"
elif [[ "${OS_ID}" =~ ^(opensuse|sles|suse)$ ]];                                    then PKG_MGR="zypper"
elif command -v apt-get &>/dev/null;  then PKG_MGR="apt"
elif command -v dnf     &>/dev/null;  then PKG_MGR="dnf"
elif command -v zypper  &>/dev/null;  then PKG_MGR="zypper"
else die "Unsupported OS: ${OS_ID}. Only Debian/RHEL/SUSE families are supported."; fi

echo -e "
  ${CY}+================================================================+${NC}
  ${CY}|     KUBERNETES MASTER NODE SETUP  v${K8S_VERSION}              |${NC}
  ${CY}+================================================================+${NC}

  ${CY}[....${NC}  Master IP: ${MASTER_IP} | OS: ${OS_ID} ${OS_VER} | Runtime: ${RUNTIME} | CNI: ${CNI_PLUGIN}
        kubectl will be configured for user: ${SETUP_USER}
        Firewall enabled: ${ENABLE_FIREWALL}
"

# =============================================================================
step "1/9" "System prerequisites"
# =============================================================================

# ── Repair any interrupted dpkg state (common on reused VMs) ─────────────────
if [[ "$PKG_MGR" == "apt" ]]; then
  dpkg --configure -a --force-confold 2>/dev/null || true
  apt-get install -f -y -q 2>/dev/null || true
  ok "dpkg state verified / repaired"
fi

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

# ── Firewall management ───────────────────────────────────────────────────────
# Master K8s ports:
#   22/tcp        SSH
#   6443/tcp      API server
#   2379-2380/tcp etcd
#   10250/tcp     Kubelet API
#   10257/tcp     kube-controller-manager
#   10259/tcp     kube-scheduler
#   4789/udp      Calico VXLAN
#   8472/udp      Flannel VXLAN
#   6783/tcp      Weave control/peer
#   6783-6784/udp Weave peer/data
#   30000-32767/tcp NodePort services

configure_firewall_master() {
  local enable; enable="${ENABLE_FIREWALL,,}"

  # Detect firewall — firewalld wins on RHEL
  local FWT="none"
  command -v ufw          &>/dev/null && FWT="ufw"
  command -v firewall-cmd &>/dev/null && FWT="firewalld"

  local UFW_PORTS=(22/tcp 6443/tcp 2379:2380/tcp 10250/tcp 10257/tcp 10259/tcp
                   4789/udp 8472/udp 6783/tcp 6783/udp 6784/udp 30000:32767/tcp)
  local FWD_PORTS=(22/tcp 6443/tcp 2379-2380/tcp 10250/tcp 10257/tcp 10259/tcp
                   4789/udp 8472/udp 6783/tcp 6783/udp 6784/udp 30000-32767/tcp)

  if [[ "$enable" == "true" ]]; then
    case "$FWT" in
      ufw)
        ufw --force enable 2>/dev/null || true
        for p in "${UFW_PORTS[@]}"; do
          ufw allow "$p" comment "K8s-master" 2>/dev/null || true
        done
        ufw reload 2>/dev/null || true
        ok "ufw enabled — master K8s ports opened"
        ;;
      firewalld)
        systemctl enable --now firewalld 2>/dev/null || true
        for p in "${FWD_PORTS[@]}"; do
          firewall-cmd --permanent --add-port="$p" 2>/dev/null || true
        done
        firewall-cmd --reload 2>/dev/null || true
        ok "firewalld enabled — master K8s ports opened"
        ;;
      *)
        warn "No ufw/firewalld found — skipping firewall config"
        info "Ensure external firewall allows: 22/tcp 6443/tcp 2379-2380/tcp 10250/tcp 4789/udp 8472/udp"
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

configure_firewall_master

# =============================================================================
step "2/9" "Installing container runtime: ${RUNTIME}"
# =============================================================================

install_containerd_apt() {
  apt-get update -qq
  apt-get install ${APT_OPTS} ca-certificates curl gnupg python3
  install -m 0755 -d /etc/apt/keyrings
  # Detect distro codename — Ubuntu 24.04 (noble) supported from Docker hub
  local CODENAME
  CODENAME=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-${VERSION_CODENAME:-$(lsb_release -cs 2>/dev/null)}}")
  # Map non-Ubuntu debian-based distros to their Ubuntu equivalent for Docker repo
  case "${CODENAME}" in
    bookworm|bullseye|buster) true ;;  # Debian uses its own codename below
    *) true ;;
  esac
  # Use distro-specific Docker repo URL
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

  systemctl stop containerd 2>/dev/null || true

  # Generate the vendor-supported configuration. Do not reconstruct the
  # containerd 2.x CRI hierarchy manually unless a required table is absent.
  containerd config default > /etc/containerd/config.toml ||
    die "Failed to generate containerd default configuration"

  local CONTAINERD_VERSION CONTAINERD_MAJOR PAUSE_IMAGE
  CONTAINERD_VERSION="$(containerd --version | awk '{print $3}' | sed 's/^v//')"
  CONTAINERD_MAJOR="${CONTAINERD_VERSION%%.*}"
  PAUSE_IMAGE="${PAUSE_IMAGE:-registry.k8s.io/pause:3.10}"

  [[ "${CONTAINERD_MAJOR}" =~ ^[0-9]+$ ]] ||
    die "Unable to determine containerd major version: ${CONTAINERD_VERSION}"

  info "Detected containerd version: ${CONTAINERD_VERSION} (major ${CONTAINERD_MAJOR})"
  info "Configuring CRI sandbox image: ${PAUSE_IMAGE}"

  if [[ "${CONTAINERD_MAJOR}" == "1" ]]; then
    # containerd 1.x uses the legacy CRI plugin namespace.
    python3 - "${PAUSE_IMAGE}" <<'PYEOF'
import sys
from pathlib import Path

path = Path("/etc/containerd/config.toml")
pause = sys.argv[1]
lines = path.read_text().splitlines()

def section_bounds(headers):
    for i, line in enumerate(headers):
        if line.startswith("["):
            yield i, line

def find_section(target):
    start = None
    for i, line in enumerate(lines):
        if line.strip() == target:
            start = i
            break
    if start is None:
        return None, None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if lines[j].startswith("["):
            end = j
            break
    return start, end

target = '[plugins."io.containerd.grpc.v1.cri"]'
start, end = find_section(target)
if start is None:
    lines += ["", target, f'  sandbox_image = "{pause}"']
else:
    found = False
    for i in range(start + 1, end):
        if lines[i].strip().startswith("sandbox_image"):
            indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())] or "  "
            lines[i] = f'{indent}sandbox_image = "{pause}"'
            found = True
            break
    if not found:
        lines.insert(start + 1, f'  sandbox_image = "{pause}"')

target = '[plugins."io.containerd.grpc.v1.cri".containerd.runtimes.runc.options]'
start, end = find_section(target)
if start is None:
    lines += ["", target, "  SystemdCgroup = true"]
else:
    found = False
    for i in range(start + 1, end):
        if lines[i].strip().startswith("SystemdCgroup"):
            indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())] or "  "
            lines[i] = f"{indent}SystemdCgroup = true"
            found = True
            break
    if not found:
        lines.insert(start + 1, "  SystemdCgroup = true")

path.write_text("\n".join(lines) + "\n")
PYEOF

  elif [[ "${CONTAINERD_MAJOR}" == "2" ]]; then
    # containerd 2.x uses config version 3 and the split CRI v1 images/runtime
    # plugin namespaces. Modify only the exact sections; never perform a
    # global replacement of sandbox/SystemdCgroup values.
    python3 - "${PAUSE_IMAGE}" <<'PYEOF'
import sys
from pathlib import Path

path = Path("/etc/containerd/config.toml")
pause = sys.argv[1]
lines = path.read_text().splitlines()

def bounds(targets):
    start = None
    for i, line in enumerate(lines):
        if line.strip() in targets:
            start = i
            break
    if start is None:
        return None, None
    end = len(lines)
    for j in range(start + 1, len(lines)):
        if lines[j].startswith("["):
            end = j
            break
    return start, end

# containerd 2.x requires config version 3.
version_idx = None
for i, line in enumerate(lines):
    if line.strip().startswith("version"):
        version_idx = i
        break
if version_idx is None:
    lines.insert(0, "version = 3")
elif lines[version_idx].strip() != "version = 3":
    lines[version_idx] = "version = 3"

# CRI sandbox image.
targets = {
    '[plugins."io.containerd.cri.v1.images".pinned_images]',
    "[plugins.'io.containerd.cri.v1.images'.pinned_images]",
}
start, end = bounds(targets)
if start is None:
    # Parent table is not needed when using the fully-qualified child table.
    lines += ["", '[plugins."io.containerd.cri.v1.images".pinned_images]',
              f'  sandbox = "{pause}"']
else:
    found = False
    for i in range(start + 1, end):
        if lines[i].strip().startswith("sandbox"):
            indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())] or "  "
            lines[i] = f'{indent}sandbox = "{pause}"'
            found = True
            break
    if not found:
        lines.insert(start + 1, f'  sandbox = "{pause}"')

# runc SystemdCgroup. The official containerd 2.x path is:
# io.containerd.cri.v1.runtime.containerd.runtimes.runc.options
targets = {
    '[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]',
    "[plugins.'io.containerd.cri.v1.runtime'.containerd.runtimes.runc.options]",
}
start, end = bounds(targets)
if start is None:
    lines += [
        "",
        '[plugins."io.containerd.cri.v1.runtime".containerd]',
        '  default_runtime_name = "runc"',
        "",
        '[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc]',
        '  runtime_type = "io.containerd.runc.v2"',
        "",
        '[plugins."io.containerd.cri.v1.runtime".containerd.runtimes.runc.options]',
        "  SystemdCgroup = true",
    ]
else:
    found = False
    for i in range(start + 1, end):
        if lines[i].strip().startswith("SystemdCgroup"):
            indent = lines[i][:len(lines[i]) - len(lines[i].lstrip())] or "  "
            lines[i] = f"{indent}SystemdCgroup = true"
            found = True
            break
    if not found:
        lines.insert(start + 1, "  SystemdCgroup = true")

path.write_text("\n".join(lines) + "\n")
PYEOF

  else
    die "Unsupported containerd major version ${CONTAINERD_MAJOR}; supported: 1.x and 2.x"
  fi

  # Validate the actual file before touching the running service.
  containerd config dump >/dev/null 2>&1 ||
    die "Generated containerd configuration is invalid"

  grep -q 'SystemdCgroup[[:space:]]*=[[:space:]]*true' /etc/containerd/config.toml ||
    die "SystemdCgroup=true was not configured"

  systemctl enable containerd
  systemctl restart containerd

  local retries=0
  until systemctl is-active --quiet containerd &&
        [ -S /run/containerd/containerd.sock ] &&
        ctr version >/dev/null 2>&1; do
    sleep 1
    retries=$((retries+1))
    [ "$retries" -ge 30 ] &&
      die "containerd did not become ready after 30s. Check: journalctl -u containerd -n 100 --no-pager"
  done

  # Confirm the CRI service is actually registered.
  if containerd plugins 2>/dev/null |
      grep -Eq 'io\.containerd\.(cri\.v1\.runtime|grpc\.v1\.cri|cri\.v1\.images)'; then
    :
  else
    die "containerd is running but no CRI plugin is registered"
  fi

  ok "containerd ${CONTAINERD_VERSION} installed and configured (CRI + SystemdCgroup=true, sandbox=${PAUSE_IMAGE})"
}
configure_crio() {
  # CRI-O normally installs crio.service. Some package builds expose the
  # unit under a different alias or fail to register the unit with systemd.
  # Discover the installed unit instead of hard-coding one service name.
  systemctl daemon-reload 2>/dev/null || true

  local CRIO_UNIT=""
  local candidate
  for candidate in crio.service cri-o.service; do
    if systemctl cat "${candidate}" &>/dev/null; then
      CRIO_UNIT="${candidate}"
      break
    fi
  done

  # Also inspect common systemd unit locations.
  if [[ -z "${CRIO_UNIT}" ]]; then
    for candidate in \
      /usr/lib/systemd/system/crio.service \
      /lib/systemd/system/crio.service \
      /usr/lib/systemd/system/cri-o.service \
      /lib/systemd/system/cri-o.service; do
      if [[ -f "${candidate}" ]]; then
        CRIO_UNIT="$(basename "${candidate}")"
        break
      fi
    done
  fi

  # Last-resort recovery for a package that contains the CRI-O binary but
  # failed to install/register its systemd unit.
  if [[ -z "${CRIO_UNIT}" ]]; then
    local CRIO_BIN=""
    CRIO_BIN="$(command -v crio 2>/dev/null || true)"

    if [[ -n "${CRIO_BIN}" ]]; then
      info "CRI-O binary found at ${CRIO_BIN}, but no systemd unit was registered."
      info "Creating a minimal managed systemd unit for this package layout."

      cat >/etc/systemd/system/crio.service <<EOF
[Unit]
Description=CRI-O Container Runtime
Wants=network-online.target
After=network-online.target
Before=kubelet.service

[Service]
Type=notify
EnvironmentFile=-/etc/sysconfig/crio
ExecStart=${CRIO_BIN}
Restart=on-failure
RestartSec=10
TasksMax=infinity
LimitNPROC=1048576
LimitCORE=infinity
OOMScoreAdjust=-999
TimeoutStartSec=0

[Install]
WantedBy=multi-user.target
EOF

      systemctl daemon-reload
      CRIO_UNIT="crio.service"
    fi
  fi

  [[ -n "${CRIO_UNIT}" ]] ||
    die "CRI-O package is installed but no usable crio systemd unit/binary was found"

  systemctl enable --now "${CRIO_UNIT}" ||
    die "Failed to start ${CRIO_UNIT}. Check: journalctl -u ${CRIO_UNIT} -n 100 --no-pager"

  local sock="/var/run/crio/crio.sock"
  local retries=0
  while [[ ! -S "${sock}" && ${retries} -lt 30 ]]; do
    sleep 1
    retries=$((retries + 1))
  done

  [[ -S "${sock}" ]] ||
    die "CRI-O service is active but CRI socket ${sock} was not created"

  ok "CRI-O installed and running (${CRIO_UNIT}, socket=${sock})"
}

case "${RUNTIME}" in
  containerd)
    if [[ "$PKG_MGR" == "apt" ]]; then install_containerd_apt; else install_containerd_dnf; fi
    configure_containerd
    CRI_SOCKET="unix:///run/containerd/containerd.sock"
    CRICTL_SOCK="${CRI_SOCKET}"
    ;;
  crio)
    if [[ "$PKG_MGR" == "apt" ]]; then install_crio_apt; else install_crio_dnf; fi
    configure_crio
    CRI_SOCKET="unix:///var/run/crio/crio.sock"
    CRICTL_SOCK="${CRI_SOCKET}"
    ;;
  *) die "Unknown runtime: ${RUNTIME}. Choose containerd or crio" ;;
esac

# Runtime-independent sanity check. kubeadm must never proceed with a
# selected runtime whose CRI endpoint is unavailable.
RT_SOCK="${CRI_SOCKET#unix://}"
[[ -S "${RT_SOCK}" ]] || die "Selected runtime ${RUNTIME} socket is unavailable: ${RT_SOCK}"
ok "Selected CRI endpoint is ready: ${CRI_SOCKET}"

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

if [[ "$PKG_MGR" == "apt" ]]; then install_k8s_apt; else install_k8s_dnf; fi
systemctl enable --now kubelet
ok "kubeadm / kubelet / kubectl installed and pinned"

# =============================================================================
step "4/9" "kubeadm init"
# =============================================================================

# CRI_SOCKET was selected and validated during runtime installation above.

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
  # Direct manifest approach — no Tigera operator, no CSI sidecar pods.
  # Matches k8s-cluster-bootstrap.sh exactly:
  #   calico_backend = vxlan  → pure VXLAN, BIRD/BGP never starts
  #   IPIP = Never            → no tunl0 interface
  #   VXLAN = Always          → UDP 4789 · vxlan.calico
  #   liveness/readiness probes removed → probes check BIRD socket which is absent in vxlan mode
  # Uses python3 to patch the manifest in-place (same as bootstrap script).

  local CALICO_VERSION="v3.29.3"
  local CALICO_MANIFEST="/tmp/calico.yaml"

  # Detect host-only interface (the non-NAT NIC — typically the 192.168.x.x one)
  local IFACE
  IFACE=$(ip -4 route show | awk '$1 !~ /^(default|local|broadcast|unreachable|prohibit|blackhole|throw)$/ && $0 ~ / dev / {for (i=1;i<=NF;i++) if ($i=="dev") {print $(i+1); exit}}')
  # Fallback: first non-loopback interface
  [[ -z "$IFACE" ]] && IFACE=$(ip -o link show | awk -F': ' '$2 !~ /lo|docker|veth|br-|cali|flannel|weave/ {print $2}' | head -1)
  [[ -z "$IFACE" ]] && IFACE="eth1"
  info "Calico IP autodetection interface: ${IFACE}"

  echo -e "  ${CY}Downloading Calico ${CALICO_VERSION} manifest...${NC}"
  curl -fsSL \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
    -o "${CALICO_MANIFEST}" || die "Calico manifest download failed"

  # Patch manifest: pure VXLAN, correct pod CIDR, remove BIRD probes
  python3 - "${CALICO_MANIFEST}" "${POD_CIDR}" "${IFACE}" <<'PYEOF'
import sys, re

manifest_path = sys.argv[1]
pod_cidr      = sys.argv[2]
iface         = sys.argv[3]

with open(manifest_path) as f:
    content = f.read()

# Set calico_backend: "vxlan" in ConfigMap
content = re.sub(r'(calico_backend:\s*)"[^"]*"', r'\1"vxlan"', content)
content = re.sub(r'(calico_backend:\s*)(?!")(\S+)', r'\1"vxlan"', content)

def set_env_value(text, name, value):
    lines = text.split('\n')
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if stripped == f'- name: {name}':
            out.append(line)
            i += 1
            while i < len(lines):
                next_line = lines[i]
                next_stripped = next_line.lstrip()
                next_indent = len(next_line) - len(next_stripped)
                if next_stripped and next_indent <= indent and not next_stripped.startswith('#'):
                    break
                i += 1
            out.append(' ' * (indent + 2) + f'value: "{value}"')
        else:
            out.append(line)
            i += 1
    return '\n'.join(out)

content = set_env_value(content, "CALICO_IPV4POOL_VXLAN",     "Always")
content = set_env_value(content, "CALICO_IPV4POOL_IPIP",      "Never")
content = set_env_value(content, "CALICO_IPV4POOL_CIDR",      pod_cidr)
content = set_env_value(content, "CALICO_NETWORKING_BACKEND", "vxlan")
content = set_env_value(content, "IP_AUTODETECTION_METHOD",   f"interface={iface}")
content = set_env_value(content, "FELIX_IPINIPENABLED",       "false")
content = set_env_value(content, "FELIX_VXLANENABLED",        "true")
content = set_env_value(content, "FELIX_BPFENABLED",          "false")

def remove_probe_block(text, probe_name):
    lines = text.split('\n')
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if stripped == f'{probe_name}:':
            i += 1
            while i < len(lines):
                next_line = lines[i]
                next_stripped = next_line.lstrip()
                next_indent = len(next_line) - len(next_stripped)
                if next_stripped and next_indent <= indent:
                    break
                i += 1
        else:
            out.append(line)
            i += 1
    return '\n'.join(out)

content = remove_probe_block(content, "livenessProbe")
content = remove_probe_block(content, "readinessProbe")
content = remove_probe_block(content, "startupProbe")

with open(manifest_path, 'w') as f:
    f.write(content)
PYEOF

  echo -e "  ${CY}Applying Calico manifest (DaemonSet + RBAC + CRDs)...${NC}"
  kubectl apply -f "${CALICO_MANIFEST}" || die "kubectl apply calico failed"

  ok "Calico ${CALICO_VERSION} applied (pure VXLAN · no operator · no CSI pods)"
  info "  Pod CIDR  : ${POD_CIDR}"
  info "  Backend   : vxlan  (BIRD/BGP never starts)"
  info "  IPIP      : Never  (no tunl0)"
  info "  VXLAN     : Always (UDP 4789 · vxlan.calico)"
  info "  Interface : ${IFACE}"
}

install_flannel() {
  # Pin the manifest so a future upstream change cannot silently break Jenkins.
  local FLANNEL_VERSION="v0.26.7"
  local FLANNEL_MANIFEST="/tmp/kube-flannel-${FLANNEL_VERSION}.yml"

  curl -fsSL \
    "https://github.com/flannel-io/flannel/releases/download/${FLANNEL_VERSION}/kube-flannel.yml" \
    -o "${FLANNEL_MANIFEST}" ||
    die "Flannel ${FLANNEL_VERSION} manifest download failed"

  # Align Flannel's network with kubeadm --pod-network-cidr.
  python3 - "${FLANNEL_MANIFEST}" "${POD_CIDR}" <<'PYEOF'
import sys, re
path, cidr = sys.argv[1], sys.argv[2]
s = open(path).read()
s = re.sub(r'("Network"\s*:\s*)"[^"]+"', rf'\1"{cidr}"', s)
open(path, 'w').write(s)
PYEOF

  kubectl apply -f "${FLANNEL_MANIFEST}" ||
    die "kubectl apply flannel failed"

  ok "Flannel ${FLANNEL_VERSION} applied"
  info "  Pod CIDR  : ${POD_CIDR}"
}

install_weave() {
  # Weave Net is archived upstream. Keep it available for legacy/lab use,
  # but recommend Calico or Flannel for new clusters.
  local WEAVE_VER="2.8.1"
  local WEAVE_MANIFEST="/tmp/weave-${WEAVE_VER}.yaml"

  warn "Weave Net is archived upstream; use Calico or Flannel for new clusters."

  curl -fsSL \
    "https://github.com/weaveworks/weave/releases/download/v${WEAVE_VER}/weave-daemonset-k8s.yaml" \
    -o "${WEAVE_MANIFEST}" ||
    die "Weave Net ${WEAVE_VER} manifest download failed"

  # Align Weave's default IPALLOC_RANGE with kubeadm's pod CIDR.
  python3 - "${WEAVE_MANIFEST}" "${POD_CIDR}" <<'PYEOF'
import sys
path, cidr = sys.argv[1], sys.argv[2]
lines = open(path).read().splitlines()
for i, line in enumerate(lines):
    if 'name: IPALLOC_RANGE' in line:
        for j in range(i + 1, min(i + 5, len(lines))):
            if 'value:' in lines[j]:
                indent = lines[j][:len(lines[j]) - len(lines[j].lstrip())]
                lines[j] = f'{indent}value: "{cidr}"'
                break
open(path, 'w').write('\n'.join(lines) + '\n')
PYEOF

  kubectl apply -f "${WEAVE_MANIFEST}" ||
    die "kubectl apply weave failed"

  ok "Weave Net ${WEAVE_VER} applied"
  info "  Pod CIDR  : ${POD_CIDR}"
}

case "${CNI_PLUGIN}" in
  calico)  install_calico  ;;
  flannel) install_flannel ;;
  weave)   install_weave   ;;
  *)       die "Unknown CNI: ${CNI_PLUGIN}. Choose calico, flannel, or weave" ;;
esac

# Verify that the selected CNI created its expected DaemonSet before waiting.
case "${CNI_PLUGIN}" in
  calico)  kubectl -n kube-system get daemonset/calico-node >/dev/null 2>&1 || die "Calico DaemonSet was not created" ;;
  flannel) kubectl -n kube-flannel get daemonset/kube-flannel-ds >/dev/null 2>&1 || die "Flannel DaemonSet was not created" ;;
  weave)   kubectl -n kube-system get daemonset/weave-net >/dev/null 2>&1 || die "Weave DaemonSet was not created" ;;
esac

# =============================================================================
step "7/9" "Waiting for complete control-plane readiness"
# =============================================================================

wait_for_node_ready() {
  local timeout=300 elapsed=0 status=""
  info "Waiting for master node Ready..."
  while (( elapsed < timeout )); do
    status=$(kubectl get node --no-headers 2>/dev/null | awk 'NR==1 {print $2}')
    [[ "$status" == "Ready" ]] && { ok "Master node is Ready"; return 0; }
    sleep 5; elapsed=$((elapsed + 5))
  done
  kubectl get nodes -o wide 2>/dev/null || true
  die "Master node did not become Ready within ${timeout}s"
}

wait_for_cni() {
  local timeout=300
  case "${CNI_PLUGIN}" in
    calico)
      kubectl -n kube-system rollout status daemonset/calico-node --timeout="${timeout}s" || die "Calico node DaemonSet did not become ready"
      kubectl -n kube-system rollout status deployment/calico-kube-controllers --timeout="${timeout}s" || die "Calico controllers did not become ready"
      ;;
    flannel)
      kubectl -n kube-flannel rollout status daemonset/kube-flannel-ds --timeout="${timeout}s" || die "Flannel DaemonSet did not become ready"
      ;;
    weave)
      kubectl -n kube-system rollout status daemonset/weave-net --timeout="${timeout}s" || die "Weave DaemonSet did not become ready"
      ;;
    *) die "Unknown CNI: ${CNI_PLUGIN}" ;;
  esac
  ok "${CNI_PLUGIN} networking is ready"
}

wait_for_system_pods() {
  local timeout=300
  kubectl -n kube-system rollout status deployment/coredns --timeout="${timeout}s" || die "CoreDNS did not become ready"
  kubectl -n kube-system rollout status daemonset/kube-proxy --timeout="${timeout}s" || die "kube-proxy did not become ready"
  ok "CoreDNS and kube-proxy are ready"
}

wait_for_node_ready
wait_for_cni
wait_for_system_pods

# =============================================================================
step "8/9" "Generating secure join command"
# =============================================================================

JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)
[[ -n "${JOIN_CMD}" ]] || die "Failed to generate kubeadm join command"
printf '%s\n' "${JOIN_CMD}" >/tmp/k8s-join-command.sh
chmod 600 /tmp/k8s-join-command.sh
ok "Join command generated and stored securely"

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