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

# On fresh VMs, Ubuntu's own apt-daily/apt-daily-upgrade timers (or
# unattended-upgrades) can grab the dpkg lock shortly after boot — and this
# has been observed in practice colliding with this script's own back-to-back
# apt-get calls too (one call's dpkg cleanup hadn't fully released the lock
# before the very next apt-get call started). `apt-get` itself does not wait
# for the lock — it just fails immediately with exit 100. Poll for the lock
# to be free before every apt-get invocation rather than hoping it never
# collides.
wait_for_apt_lock() {
  [[ "${PKG_MGR}" == "apt" ]] || return 0
  local waited=0
  local max_wait=120
  # Prefer flock (util-linux — present on virtually every distro) over fuser
  # (psmisc — not guaranteed on minimal cloud images). If neither tool is
  # available, don't block indefinitely on a check we can't perform.
  while (( waited < max_wait )); do
    if command -v flock &>/dev/null; then
      flock -n -x /var/lib/dpkg/lock-frontend -c true 2>/dev/null && return 0
    elif command -v fuser &>/dev/null; then
      fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock 2>/dev/null | grep -q . || return 0
    else
      return 0
    fi
    if (( waited == 0 )); then
      info "Waiting for another apt/dpkg process to release its lock..."
    fi
    sleep 3
    waited=$((waited + 3))
  done
  warn "dpkg/apt lock still held after ${max_wait}s — proceeding anyway; the next apt-get call may fail"
}

# A CRI-O service restarted several times in quick succession (install,
# package-repair if that path fires, later validation restarts) can trip
# systemd's own StartLimitBurst rate limiting — `systemctl restart` then
# fails even though the unit itself is perfectly fine. `systemctl
# reset-failed` clears that counter so a retry can actually succeed, instead
# of giving up (or, worse, `die`-ing) after a single attempt.
restart_crio_service() {
  local unit="$1"
  if systemctl restart "${unit}" 2>/dev/null; then
    return 0
  fi
  warn "${unit} restart failed — clearing systemd's failure/rate-limit state and retrying once..."
  systemctl reset-failed "${unit}" 2>/dev/null || true
  sleep 2
  systemctl restart "${unit}"
}

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

# ── Clock synchronization (must happen before any apt/dnf operation) ─────────
# CRITICAL: observed in practice — apt refuses a repo's Release file with
# "not valid yet (invalid for another Nmin)" when this node's clock is
# behind real time, which aborts every subsequent apt-get/dnf install in
# this script (containerd, kubeadm/kubelet/kubectl, etc). The worker script
# already force-syncs the clock before `kubeadm join` for the equivalent
# x509 "certificate is not yet valid" failure mode — the master needs the
# same guarantee, and needs it first, since package installation is the
# very first thing that can fail here.
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
      timedatectl status 2>/dev/null | grep -q "synchronized: yes" && { synced=true; break; }
      sleep 2
      w=$((w+2))
    done

    if [[ "$synced" == "false" ]] && command -v ntpdate &>/dev/null; then
      ntpdate -u pool.ntp.org 2>/dev/null && synced=true || true
    fi
  else
    # RHEL/Rocky/AlmaLinux/SUSE — use chrony
    if ! command -v chronyd &>/dev/null; then
      info "Installing chrony..."
      if [[ "$PKG_MGR" == "dnf" ]]; then
        dnf install -y -q chrony 2>/dev/null || true
      elif [[ "$PKG_MGR" == "zypper" ]]; then
        zypper --non-interactive install chrony 2>/dev/null || true
      fi
    fi

    if command -v chronyd &>/dev/null; then
      systemctl enable --now chronyd 2>/dev/null || true
      sleep 2
      if chronyc makestep 2>/dev/null; then
        synced=true
      fi
      info "Chrony tracking:"
      chronyc tracking 2>/dev/null | grep -E 'System time|RMS offset|Last offset' || true
    fi

    if [[ "$synced" == "false" ]] && command -v ntpdate &>/dev/null; then
      ntpdate -u pool.ntp.org 2>/dev/null && synced=true || true
    fi
  fi

  local now_after
  now_after=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  if [[ "$synced" == "true" ]]; then
    ok "Clock synced — UTC: ${now_after}"
  else
    warn "Clock sync uncertain — UTC: ${now_after}"
    warn "If apt/kubeadm fails with time-related errors, run: chronyc makestep (or) timedatectl set-ntp true"
  fi
}

sync_clock

# ── Repair any interrupted dpkg state (common on reused VMs) ─────────────────
if [[ "$PKG_MGR" == "apt" ]]; then
  wait_for_apt_lock
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
  wait_for_apt_lock
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
  wait_for_apt_lock
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
  wait_for_apt_lock
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
          awk '/\/(crio|cri-o)\.service$/ {print}'
      )"
      UNIT_PATH="${UNIT_PATH%%$'\n'*}"
    elif [[ "${PKG_MGR}" == "dnf" ]] && rpm -q cri-o &>/dev/null; then
      UNIT_PATH="$(
        rpm -ql cri-o 2>/dev/null |
          awk '/\/(crio|cri-o)\.service$/ {print}'
      )"
      UNIT_PATH="${UNIT_PATH%%$'\n'*}"
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
      wait_for_apt_lock
      apt-get install ${APT_OPTS} --reinstall cri-o
    elif [[ "${PKG_MGR}" == "dnf" ]]; then
      dnf reinstall -y cri-o
    fi

    systemctl daemon-reload 2>/dev/null || true

    # NOTE: awk has no -f/-x file-test operators. `-f $0` parses as unary
    # minus of the uninitialized variable `f` (→ 0) string-concatenated with
    # $0, which is always a non-empty (truthy) string — so a prior version
    # of this check silently never verified the file at all, and could pick
    # up a non-binary path (like the /etc/crio config directory, which also
    # matches /crio$) if the package listed it before the real binary. Find
    # candidates with awk/grep, then verify each with a real bash file test,
    # exactly like the primary discovery path above.
    if [[ "${PKG_MGR}" == "apt" ]]; then
      CRIO_BIN=""
      while IFS= read -r candidate; do
        if [[ -f "${candidate}" && -x "${candidate}" ]]; then
          CRIO_BIN="${candidate}"
          break
        fi
      done < <(dpkg -L cri-o 2>/dev/null | grep -E '/crio$' || true)
      UNIT_PATH="$(
        dpkg -L cri-o 2>/dev/null |
          awk '/\/(crio|cri-o)\.service$/ {print}'
      )"
      UNIT_PATH="${UNIT_PATH%%$'\n'*}"
    else
      CRIO_BIN=""
      while IFS= read -r candidate; do
        if [[ -f "${candidate}" && -x "${candidate}" ]]; then
          CRIO_BIN="${candidate}"
          break
        fi
      done < <(rpm -ql cri-o 2>/dev/null | grep -E '/crio$' || true)
      UNIT_PATH="$(
        rpm -ql cri-o 2>/dev/null |
          awk '/\/(crio|cri-o)\.service$/ {print}'
      )"
      UNIT_PATH="${UNIT_PATH%%$'\n'*}"
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

  # kubeadm/kubelet default to the systemd cgroup driver (cgroupDriver:
  # systemd) since Kubernetes 1.22+. containerd's SystemdCgroup=true is
  # explicitly set and verified above; CRI-O needs the equivalent guarantee.
  # A driver mismatch between kubelet and the CRI does not fail loudly — pods
  # simply fail to schedule/start with confusing cgroup errors, and this is
  # the kind of gap that only surfaces on the CRI-O combinations. Do not rely
  # on the packaged default; pin it explicitly.
  cat >/etc/crio/crio.conf.d/20-kubernetes-cgroup.conf <<'EOF'
[crio.runtime]
cgroup_manager = "systemd"
conmon_cgroup = "pod"
EOF

  # CNI config/binary directories must match where kubeadm/kubelet install
  # CNI plugins (/opt/cni/bin) and where the CNI manifest (Calico/Flannel)
  # writes its config (/etc/cni/net.d). Earlier revisions of this script only
  # checked this via `crio config`, but that subcommand is not supported on
  # every packaged CRI-O build (confirmed in practice: "CRI-O binary does not
  # support 'config' dump on this build"), which left the check unable to run
  # at all on those builds. Write it explicitly instead of hoping the
  # packaged default matches — a mismatch here silently breaks pod
  # networking regardless of which CNI is selected.
  cat >/etc/crio/crio.conf.d/30-kubernetes-cni.conf <<'EOF'
[crio.network]
network_dir = "/etc/cni/net.d/"
plugin_dirs = ["/opt/cni/bin/"]
EOF

  # Validate only when the executable supports the command.
  if "${CRIO_BIN}" config validate >/dev/null 2>&1; then
    :
  else
    # Some packaged CRI-O builds do not expose "config validate".
    # The service restart below remains the authoritative configuration check.
    info "CRI-O config validate is unavailable or returned non-zero; validating via service restart."
  fi

  restart_crio_service "${CRIO_UNIT}" ||
    die "Failed to restart ${CRIO_UNIT} after configuring pause_image (including after a reset-failed retry)"

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

step "3/9" "Installing kubeadm / kubelet / kubectl  (v${K8S_VERSION})"
# =============================================================================

K8S_MINOR="${K8S_VERSION%.*}"   # e.g. 1.32

install_k8s_apt() {
  wait_for_apt_lock
  apt-get install ${APT_OPTS} apt-transport-https curl
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --batch --yes
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  wait_for_apt_lock
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
    "kubelet-${K8S_VERSION}" "kubeadm-${K8S_VERSION}" "kubectl-${K8S_VERSION}" cri-tools
  dnf versionlock add kubelet kubeadm kubectl 2>/dev/null || true
}

if [[ "$PKG_MGR" == "apt" ]]; then install_k8s_apt; else install_k8s_dnf; fi
systemctl enable --now kubelet
ok "kubeadm / kubelet / kubectl / cri-tools installed and pinned"

# Validate the CRI by making a real CRI request. Do not infer CRI health
# from containerd's plugin-list formatting, which differs across containerd 1.x/2.x.
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

USER_HOME=$(getent passwd "${SETUP_USER}" | cut -d: -f6)
[[ -n "${USER_HOME}" && -d "${USER_HOME}" ]] || die "Could not resolve home directory for user ${SETUP_USER}"
mkdir -p "${USER_HOME}/.kube"
cp /etc/kubernetes/admin.conf "${USER_HOME}/.kube/config"
chown -R "${SETUP_USER}:${SETUP_USER}" "${USER_HOME}/.kube"
chmod 600 "${USER_HOME}/.kube/config"

# Also configure for root
mkdir -p /root/.kube
cp /etc/kubernetes/admin.conf /root/.kube/config
chmod 600 /root/.kube/config
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

  # NOTE ON SIGPIPE 141: do not use `awk '{...; exit}'` reading from a pipe
  # under `set -o pipefail`. If `ip -o -4 addr show` still has more lines
  # queued when awk exits early after its first match, awk closing its end
  # of the pipe delivers SIGPIPE to `ip`, and pipefail then reports the
  # whole pipeline as exit status 141 — even though a match was found. This
  # is exactly what happened here in practice. The fix is to let awk consume
  # ALL of its input (no `exit`) so `ip` always finishes and exits normally,
  # then take the first line of awk's output in pure bash.

  # Prefer the interface that actually owns MASTER_IP. This avoids selecting
  # the NAT interface on multi-NIC VMs.
  IFACE="$(ip -o -4 addr show 2>/dev/null |
    awk -v ip="${MASTER_IP}" '$4 ~ ("^" ip "/") {print $2}')"
  IFACE="${IFACE%%$'\n'*}"

  # Fallback: first non-loopback/virtual interface with an IPv4 address.
  if [[ -z "${IFACE}" ]]; then
    IFACE="$(ip -o -4 addr show 2>/dev/null |
      awk '$2 !~ /^(lo|docker|cni|flannel|weave|cali|veth|br-)/ && $4 !~ /^127\./ {print $2}')"
    IFACE="${IFACE%%$'\n'*}"
  fi

  [[ -n "${IFACE}" ]] || die "Unable to determine a usable IPv4 interface for Calico"
  info "Calico IP autodetection interface: ${IFACE}"

  info "Calico interface selected: ${IFACE} (MASTER_IP=${MASTER_IP})"
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
step "8/9" "Generating and verifying secure join command"
# =============================================================================

# -----------------------------------------------------------------------------
# CRITICAL (historical failure A):
#   "couldn't validate the identity of the API Server: could not find a JWS
#    signature in the cluster-info ConfigMap for token ID ..."
#
# kubeadm's bootstrap-token discovery requires that the token's JWS signature
# has actually been published to kube-public/cluster-info by the
# bootstrap-signer controller BEFORE any worker uses that token to join.
# Publication is asynchronous — "token create" returning successfully does
# NOT guarantee the JWS has landed yet. We must generate the token, extract
# its ID, and poll cluster-info for the matching jws-kubeconfig-<id> entry
# before the join command is handed to any worker.
# -----------------------------------------------------------------------------

JOIN_CMD=$(kubeadm token create --ttl 24h --print-join-command 2>/dev/null)
[[ -n "${JOIN_CMD}" ]] || die "Failed to generate kubeadm join command"

# Validate the shape of what kubeadm gave us before trusting it further.
[[ "${JOIN_CMD}" == kubeadm\ join* ]] ||
  die "Generated join command does not start with 'kubeadm join': ${JOIN_CMD%% *}..."
[[ "${JOIN_CMD}" == *"--token"* ]] ||
  die "Generated join command is missing --token"
[[ "${JOIN_CMD}" == *"--discovery-token-ca-cert-hash"* ]] ||
  die "Generated join command is missing --discovery-token-ca-cert-hash"

# Extract the token ID (the part before the dot in <id>.<secret>).
TOKEN_ID=$(printf '%s' "${JOIN_CMD}" | grep -oP -- '--token\s+\K[a-z0-9]+(?=\.)')
[[ -n "${TOKEN_ID}" ]] || die "Could not parse token ID from generated join command"
info "Bootstrap token ID: ${TOKEN_ID}"

# Poll kube-public/cluster-info for the signer to publish this token's JWS.
# This is asynchronous — retry with a bounded timeout instead of assuming
# it is already present.
JWS_KEY="jws-kubeconfig-${TOKEN_ID}"
jws_wait=0
jws_timeout=60
jws_found=false
info "Waiting for JWS signature (${JWS_KEY}) in kube-public/cluster-info..."
while (( jws_wait < jws_timeout )); do
  if kubectl -n kube-public get configmap cluster-info \
       -o jsonpath="{.data.${JWS_KEY}}" 2>/dev/null | grep -q .; then
    jws_found=true
    break
  fi
  sleep 2
  jws_wait=$((jws_wait + 2))
done

if [[ "${jws_found}" != "true" ]]; then
  warn "JWS signature for token ${TOKEN_ID} did not appear within ${jws_timeout}s"
  info "cluster-info ConfigMap keys currently present:"
  kubectl -n kube-public get configmap cluster-info -o jsonpath='{.data}' 2>/dev/null |
    grep -oP '"jws-kubeconfig-[a-z0-9]+"' || true
  echo "" >&2
  die "Refusing to hand out an unverified join token. The bootstrap-signer" \
      "controller never published a JWS signature for token ID ${TOKEN_ID}." \
      "Workers must NEVER be started with an unverified join command."
fi

ok "JWS signature verified for token ${TOKEN_ID} (${jws_wait}s)"

printf '%s\n' "${JOIN_CMD}" >/tmp/k8s-join-command.sh
chmod 600 /tmp/k8s-join-command.sh
ok "Verified join command generated and stored securely (mode 600)"

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