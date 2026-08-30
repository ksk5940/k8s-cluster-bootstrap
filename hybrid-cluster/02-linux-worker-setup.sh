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
CNI_PLUGIN="${CNI_PLUGIN:-calico}"

JOIN_COMMAND="${JOIN_COMMAND:-}"         # full kubeadm join ... string
JOIN_COMMAND_FILE="${JOIN_COMMAND_FILE:-/tmp/k8s-join-command.sh}"
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
#   6783/tcp  Weave control/peer
#   6783-6784/udp Weave peer/data

configure_firewall_worker() {
  local enable
  enable="${ENABLE_FIREWALL,,}"

  # Detect firewall type — firewalld takes priority on RHEL
  local FWT="none"

  command -v ufw &>/dev/null && FWT="ufw"
  command -v firewall-cmd &>/dev/null && FWT="firewalld"

  local UFW_PORTS=(22/tcp 10250/tcp 10256/tcp 4789/udp 8472/udp 6783/tcp 6783/udp 6784/udp)
  local FWD_PORTS=(22/tcp 10250/tcp 10256/tcp 4789/udp 8472/udp 6783/tcp 6783/udp 6784/udp)

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

  ok "containerd ${CONTAINERD_VERSION} installed and configured (SystemdCgroup=true, sandbox=${PAUSE_IMAGE})"
}
configure_crio() {
  # CRI-O package layouts can differ slightly between distro/package builds.
  # Discover the service and binary from the package itself instead of relying
  # only on PATH or one hard-coded systemd location.
  systemctl daemon-reload 2>/dev/null || true

  local CRIO_UNIT=""
  local CRIO_BIN=""

  # ---------------------------------------------------------------------------
  # 1. Discover CRI-O binary from the installed package.
  # ---------------------------------------------------------------------------
  if [[ "${PKG_MGR}" == "apt" ]] && dpkg-query -W -f='${Status}' cri-o 2>/dev/null | grep -q "install ok installed"; then
    CRIO_BIN=""
    while IFS= read -r candidate; do
      if [[ -f "${candidate}" && -x "${candidate}" ]]; then
        CRIO_BIN="${candidate}"
        break
      fi
    done < <(dpkg -L cri-o 2>/dev/null | grep -E '/crio$' || true)
  elif [[ "${PKG_MGR}" == "dnf" ]] && rpm -q cri-o &>/dev/null; then
    CRIO_BIN=""
    while IFS= read -r candidate; do
      if [[ -f "${candidate}" && -x "${candidate}" ]]; then
        CRIO_BIN="${candidate}"
        break
      fi
    done < <(rpm -ql cri-o 2>/dev/null | grep -E '/crio$' || true)
  fi

  # PATH fallback for package layouts that do not expose the file through the
  # package query in the expected form.
  if [[ -z "${CRIO_BIN}" ]]; then
    CRIO_BIN="$(command -v crio 2>/dev/null || true)"
    if [[ ! -f "${CRIO_BIN}" || ! -x "${CRIO_BIN}" ]]; then
      CRIO_BIN=""
    fi
  fi

  # Known package locations as an additional safety net.
  if [[ -z "${CRIO_BIN}" ]]; then
    for candidate in \
      /usr/bin/crio \
      /usr/sbin/crio \
      /usr/libexec/crio \
      /usr/local/bin/crio; do
      if [[ -f "${candidate}" && -x "${candidate}" ]]; then
        CRIO_BIN="${candidate}"
        break
      fi
    done
  fi

  # ---------------------------------------------------------------------------
  # 2. Discover the systemd unit from systemd and from the package file list.
  # ---------------------------------------------------------------------------
  for candidate in crio.service cri-o.service; do
    if systemctl cat "${candidate}" &>/dev/null; then
      CRIO_UNIT="${candidate}"
      break
    fi
  done

  if [[ -z "${CRIO_UNIT}" ]]; then
    local UNIT_PATH=""
    if [[ "${PKG_MGR}" == "apt" ]] && dpkg-query -W -f='${Status}' cri-o 2>/dev/null | grep -q "install ok installed"; then
      UNIT_PATH="$(
        dpkg -L cri-o 2>/dev/null |
          awk '/\/(crio|cri-o)\.service$/ {print; exit}'
      )"
    elif [[ "${PKG_MGR}" == "dnf" ]] && rpm -q cri-o &>/dev/null; then
      UNIT_PATH="$(
        rpm -ql cri-o 2>/dev/null |
          awk '/\/(crio|cri-o)\.service$/ {print; exit}'
      )"
    fi

    if [[ -n "${UNIT_PATH}" && -f "${UNIT_PATH}" ]]; then
      CRIO_UNIT="$(basename "${UNIT_PATH}")"
    fi
  fi

  # Common systemd locations.
  if [[ -z "${CRIO_UNIT}" ]]; then
    for candidate in \
      /usr/lib/systemd/system/crio.service \
      /lib/systemd/system/crio.service \
      /usr/lib/systemd/system/cri-o.service \
      /lib/systemd/system/cri-o.service \
      /usr/local/lib/systemd/system/crio.service \
      /usr/local/lib/systemd/system/cri-o.service; do
      if [[ -f "${candidate}" ]]; then
        CRIO_UNIT="$(basename "${candidate}")"
        break
      fi
    done
  fi

  # ---------------------------------------------------------------------------
  # 3. If package metadata says CRI-O is installed but its files are missing,
  #    repair the package. Do not manufacture a fake systemd unit.
  # ---------------------------------------------------------------------------
  if [[ -z "${CRIO_BIN}" || -z "${CRIO_UNIT}" ]]; then
    warn "CRI-O package is installed but its runtime/service files were not discovered."
    info "Repairing the CRI-O package installation."

    if [[ "${PKG_MGR}" == "apt" ]]; then
      apt-get install ${APT_OPTS} --reinstall cri-o
    elif [[ "${PKG_MGR}" == "dnf" ]]; then
      dnf reinstall -y cri-o
    fi

    systemctl daemon-reload 2>/dev/null || true

    if [[ "${PKG_MGR}" == "apt" ]]; then
      CRIO_BIN="$(
        dpkg -L cri-o 2>/dev/null |
          awk '/\/crio$/ && -f $0 && -x $0 {print; exit}'
      )"
      UNIT_PATH="$(
        dpkg -L cri-o 2>/dev/null |
          awk '/\/(crio|cri-o)\.service$/ {print; exit}'
      )"
    else
      CRIO_BIN="$(
        rpm -ql cri-o 2>/dev/null |
          awk '/\/crio$/ && -f $0 && -x $0 {print; exit}'
      )"
      UNIT_PATH="$(
        rpm -ql cri-o 2>/dev/null |
          awk '/\/(crio|cri-o)\.service$/ {print; exit}'
      )"
    fi

    if [[ -z "${CRIO_BIN}" ]]; then
      CRIO_BIN="$(command -v crio 2>/dev/null || true)"
      if [[ ! -f "${CRIO_BIN}" || ! -x "${CRIO_BIN}" ]]; then
        CRIO_BIN=""
      fi
    fi

    if [[ -n "${UNIT_PATH:-}" && -f "${UNIT_PATH}" ]]; then
      CRIO_UNIT="$(basename "${UNIT_PATH}")"
    else
      for candidate in crio.service cri-o.service; do
        if systemctl cat "${candidate}" &>/dev/null; then
          CRIO_UNIT="${candidate}"
          break
        fi
      done
    fi
  fi

  [[ -n "${CRIO_BIN}" ]] ||
    die "CRI-O package is installed but the crio binary could not be located"

  [[ -f "${CRIO_BIN}" && -x "${CRIO_BIN}" ]] ||
    die "CRI-O binary path is invalid (must be an executable regular file): ${CRIO_BIN}"

  [[ -n "${CRIO_UNIT}" ]] ||
    die "CRI-O package is installed but no crio/cri-o systemd service was found"

  info "CRI-O binary: ${CRIO_BIN}"
  info "CRI-O systemd unit: ${CRIO_UNIT}"

  # ---------------------------------------------------------------------------
  # 4. Start CRI-O and verify the actual CRI socket.
  # ---------------------------------------------------------------------------
  systemctl enable --now "${CRIO_UNIT}" ||
    die "Failed to start ${CRIO_UNIT}. Check: journalctl -u ${CRIO_UNIT} -n 100 --no-pager"

  local sock="/var/run/crio/crio.sock"
  local retries=0

  while [[ ${retries} -lt 30 ]]; do
    if systemctl is-active --quiet "${CRIO_UNIT}" && [[ -S "${sock}" ]]; then
      break
    fi
    sleep 1
    retries=$((retries + 1))
  done

  [[ -S "${sock}" ]] && systemctl is-active --quiet "${CRIO_UNIT}" ||
    die "CRI-O did not become ready. Check: systemctl status ${CRIO_UNIT} -l --no-pager; journalctl -u ${CRIO_UNIT} -n 100 --no-pager"

  # Kubernetes kubeadm expects an explicit, consistent sandbox image.
  mkdir -p /etc/crio/crio.conf.d

  cat >/etc/crio/crio.conf.d/10-kubernetes-pause.conf <<'EOF'
[crio.image]
pause_image = "registry.k8s.io/pause:3.10"
EOF

  # Validate only when the executable supports the command.
  if "${CRIO_BIN}" config validate >/dev/null 2>&1; then
    :
  else
    # Some packaged CRI-O builds do not expose "config validate".
    # The service restart below remains the authoritative configuration check.
    info "CRI-O config validate is unavailable or returned non-zero; validating via service restart."
  fi

  systemctl restart "${CRIO_UNIT}" ||
    die "Failed to restart ${CRIO_UNIT} after configuring pause_image"

  retries=0
  while [[ ${retries} -lt 30 ]]; do
    if systemctl is-active --quiet "${CRIO_UNIT}" && [[ -S "${sock}" ]]; then
      break
    fi
    sleep 1
    retries=$((retries + 1))
  done

  [[ -S "${sock}" ]] && systemctl is-active --quiet "${CRIO_UNIT}" ||
    die "CRI-O did not become ready after pause_image configuration"

  ok "CRI-O installed and running (${CRIO_UNIT}, binary=${CRIO_BIN}, socket=${sock}, sandbox=registry.k8s.io/pause:3.10)"
}
case "${RUNTIME}" in
  containerd)
    if [[ "$PKG_MGR" == "apt" ]]; then
      install_containerd_apt
    else
      install_containerd_dnf
    fi

    configure_containerd
    CRI_SOCKET="unix:///run/containerd/containerd.sock"
    ;;

  crio)
    if [[ "$PKG_MGR" == "apt" ]]; then
      install_crio_apt
    else
      install_crio_dnf
    fi

    configure_crio
    CRI_SOCKET="unix:///var/run/crio/crio.sock"
    ;;

  *)
    die "Unknown runtime: ${RUNTIME}. Choose containerd or crio"
    ;;
esac

RT_SOCK="${CRI_SOCKET#unix://}"
[[ -S "${RT_SOCK}" ]] ||
  die "Selected runtime ${RUNTIME} socket is unavailable: ${RT_SOCK}"

ok "Selected CRI endpoint is ready: ${CRI_SOCKET}"

# Runtime socket is checked here; actual CRI API validation happens after
# cri-tools is installed below. This avoids containerd-version-specific plugin
# list parsing.
[[ -S "${RT_SOCK}" ]] || die "Selected runtime socket is unavailable: ${RT_SOCK}"

# =============================================================================

# -----------------------------------------------------------------------------
# Registry connectivity / IPv4 preference
# -----------------------------------------------------------------------------
# Some dual-stack lab hosts have IPv6 DNS but no IPv6 route. Go-based CRI
# clients can then select the unreachable AAAA address and wait for TCP timeout.
# Resolve registry.k8s.io to IPv4 once and add a temporary hosts entry for the
# bootstrap. The entry is refreshed on every bootstrap and removed by destroy.
configure_registry_ipv4() {
  local ip
  ip="$(getent ahostsv4 registry.k8s.io 2>/dev/null | awk 'NR==1{print $1}')"
  [[ -n "$ip" ]] || die "Cannot resolve registry.k8s.io over IPv4"

  if ! timeout 10 bash -c "cat </dev/null >/dev/tcp/${ip}/443" 2>/dev/null; then
    die "registry.k8s.io:443 is unreachable over IPv4 (${ip}). Fix outbound registry/proxy/firewall connectivity."
  fi

  # Remove only our own managed entry, never touch unrelated hosts entries.
  sed -i '/# K8S_BOOTSTRAP_REGISTRY_IPV4/d' /etc/hosts
  printf '%s registry.k8s.io # K8S_BOOTSTRAP_REGISTRY_IPV4\n' "$ip" >> /etc/hosts
  ok "registry.k8s.io pinned to reachable IPv4 ${ip} for this bootstrap"
}

configure_registry_ipv4

step "3/7" "Installing kubeadm / kubelet / kubectl / cri-tools  (v${K8S_VERSION})"
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
    kubectl="${K8S_VERSION}-*" \
    cri-tools

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
    "kubectl-${K8S_VERSION}" \
    cri-tools
}

if [[ "$PKG_MGR" == "apt" ]]; then
  install_k8s_apt
else
  install_k8s_dnf
fi

systemctl enable --now kubelet

ok "kubeadm / kubelet / kubectl / cri-tools installed"

cat >/etc/crictl.yaml <<EOF
runtime-endpoint: ${CRI_SOCKET}
image-endpoint: ${CRI_SOCKET}
timeout: 30
debug: false
EOF

crictl --runtime-endpoint="${CRI_SOCKET}" \
       --image-endpoint="${CRI_SOCKET}" \
       info >/dev/null 2>&1 || {
  echo "CRI validation failed. Runtime endpoint: ${CRI_SOCKET}" >&2
  if [[ "${RUNTIME}" == "containerd" ]]; then
    journalctl -u containerd -n 100 --no-pager >&2 || true
  else
    journalctl -u crio -n 100 --no-pager >&2 || journalctl -u cri-o -n 100 --no-pager >&2 || true
  fi
  die "CRI endpoint is not responding: ${CRI_SOCKET}"
}
ok "CRI endpoint verified with crictl: ${CRI_SOCKET}"

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


# The selected CRI must advertise the configured sandbox image. We deliberately
# do not pre-pull it here: kubeadm/CRI will pull it on demand, avoiding a slow
# serial image-download phase before bootstrap.
if [[ "${RUNTIME}" == "containerd" ]]; then
  if ! grep -Rqs 'registry.k8s.io/pause:3.10' /etc/containerd/config.toml /etc/containerd/config.toml.d 2>/dev/null; then
    die "containerd sandbox image is not configured as registry.k8s.io/pause:3.10"
  fi
elif [[ "${RUNTIME}" == "crio" ]]; then
  if ! grep -Rqs 'pause_image[[:space:]]*=[[:space:]]*"registry.k8s.io/pause:3.10"' /etc/crio/crio.conf /etc/crio/crio.conf.d 2>/dev/null; then
    die "CRI-O pause_image is not configured as registry.k8s.io/pause:3.10"
  fi
fi

# =============================================================================
step "5/7" "Joining cluster"
# =============================================================================

# CRI_SOCKET was selected and validated during runtime installation.

if [[ -z "${JOIN_COMMAND}" && -f "${JOIN_COMMAND_FILE}" ]]; then
  JOIN_COMMAND=$(cat "${JOIN_COMMAND_FILE}")
fi
if [[ -z "${JOIN_COMMAND}" ]]; then
  die "No kubeadm join command supplied — cannot join cluster"
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
# Add the selected CRI endpoint only when the supplied join command does not
# already specify one. Avoid eval where possible; the join command is expected
# to be generated by kubeadm and may contain quoted arguments.
if [[ "${JOIN_COMMAND}" == *"--cri-socket"* ]]; then
  bash -c "${JOIN_COMMAND}"
else
  bash -c "${JOIN_COMMAND} --cri-socket ${CRI_SOCKET}"
fi
rm -f -- "${JOIN_COMMAND_FILE}" 2>/dev/null || true

ok "Node joined cluster"

# Ensure the node's own hostname resolves locally even when external DNS has no
# record for it (common on lab/host-only networks and isolated enterprise DNS).
NODE_HOSTNAME=$(hostname -s)
if ! getent hosts "${NODE_HOSTNAME}" >/dev/null 2>&1; then
  printf '%s %s\n' "${NODE_IP}" "${NODE_HOSTNAME}" >> /etc/hosts
  ok "Added local hostname mapping: ${NODE_IP} ${NODE_HOSTNAME}"
fi

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

# Final runtime/CRI validation after kubelet restart.
[[ -S "${RT_SOCK}" ]] ||
  die "Selected runtime socket disappeared after kubelet restart: ${RT_SOCK}"

command -v crictl >/dev/null 2>&1 ||
  die "crictl is not installed; cannot validate CRI after worker bootstrap"

crictl --runtime-endpoint="${CRI_SOCKET}" \
       --image-endpoint="${CRI_SOCKET}" \
       info >/dev/null 2>&1 ||
  die "CRI endpoint is not responding after worker bootstrap: ${CRI_SOCKET}"

ok "Runtime and CRI endpoint remain healthy after worker configuration"

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