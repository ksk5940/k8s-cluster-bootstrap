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
MASTER_IP="${MASTER_IP:-}"               # control-plane IP for the TCP precheck

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

# On fresh VMs, Ubuntu's own apt-daily/apt-daily-upgrade timers (or
# unattended-upgrades) can grab the dpkg lock shortly after boot — and this
# has been observed colliding with this script's own back-to-back apt-get
# calls in practice (one call's dpkg cleanup hadn't fully released the lock
# before the next apt-get call started, on the master's equivalent flow).
# `apt-get` itself does not wait for the lock — it just fails immediately
# with exit 100. Poll for the lock to be free before every apt-get
# invocation rather than hoping it never collides.
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
info() { echo -e "  ${CY}[....]${NC} $*"; }

# A CRI-O service restarted several times in quick succession (install,
# package-repair if that path fires, later CNI-detection nudges) can trip
# systemd's own StartLimitBurst rate limiting — `systemctl restart` then
# fails even though the unit itself is perfectly fine. Observed in practice:
# "Failed to restart crio.service" immediately after two earlier restarts in
# the same run. `systemctl reset-failed` clears that counter so a retry can
# actually succeed, instead of giving up (or, worse, `die`-ing) after a
# single attempt.
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

# Collect the standard set of node-side diagnostics on a join failure so the
# Jenkins console log has enough information to root-cause without a manual
# SSH session. Never print secrets/tokens here.
collect_join_diagnostics() {
  echo "──────────────── JOIN FAILURE DIAGNOSTICS ────────────────" >&2
  echo "-- systemctl status kubelet --" >&2
  systemctl status kubelet --no-pager -l 2>&1 | tail -40 >&2 || true
  echo "-- journalctl -u kubelet (last 60 lines) --" >&2
  journalctl -u kubelet -n 60 --no-pager 2>&1 >&2 || true
  if [[ "${RUNTIME}" == "containerd" ]]; then
    echo "-- systemctl status containerd --" >&2
    systemctl status containerd --no-pager -l 2>&1 | tail -20 >&2 || true
    echo "-- journalctl -u containerd (last 40 lines) --" >&2
    journalctl -u containerd -n 40 --no-pager 2>&1 >&2 || true
  else
    echo "-- systemctl status crio/cri-o --" >&2
    systemctl status crio --no-pager -l 2>&1 | tail -20 >&2 ||
      systemctl status cri-o --no-pager -l 2>&1 | tail -20 >&2 || true
    echo "-- journalctl -u crio/cri-o (last 40 lines) --" >&2
    journalctl -u crio -n 40 --no-pager 2>&1 >&2 ||
      journalctl -u cri-o -n 40 --no-pager 2>&1 >&2 || true
  fi
  echo "-- crictl info --" >&2
  crictl --runtime-endpoint="${CRI_SOCKET:-}" info 2>&1 >&2 || true
  echo "-- crictl ps -a --" >&2
  crictl --runtime-endpoint="${CRI_SOCKET:-}" ps -a 2>&1 >&2 || true
  echo "-- ip addr --" >&2
  ip addr 2>&1 >&2 || true
  echo "-- ip route --" >&2
  ip route 2>&1 >&2 || true
  echo "-- hostname / resolution --" >&2
  echo "hostname: $(hostname); hostname -s: $(hostname -s)" >&2
  getent hosts "$(hostname -s)" >&2 || echo "getent hosts: no entry" >&2
  echo "-- time --" >&2
  timedatectl 2>&1 >&2 || true
  date -u >&2 || true
  echo "────────────────────────────────────────────────────────" >&2
}

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
  wait_for_apt_lock
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

  # Base worker ports, plus only the CNI-specific ports the selected CNI
  # actually needs (Calico: VXLAN 4789/udp; Flannel: VXLAN 8472/udp; Weave:
  # 6783/tcp control + 6783-6784/udp data). CNI_PLUGIN is empty in
  # environments that never set it (defaults to calico's port set to match
  # the historical default rather than silently opening nothing).
  local CNI_SEL="${CNI_PLUGIN:-calico}"
  local CNI_PORTS=()
  case "${CNI_SEL}" in
    calico)  CNI_PORTS=(4789/udp) ;;
    flannel) CNI_PORTS=(8472/udp) ;;
    weave)   CNI_PORTS=(6783/tcp 6783/udp 6784/udp) ;;
    *)       CNI_PORTS=(4789/udp 8472/udp 6783/tcp 6783/udp 6784/udp) ;;
  esac

  local UFW_PORTS=(22/tcp 10250/tcp 10256/tcp "${CNI_PORTS[@]}")
  local FWD_PORTS=(22/tcp 10250/tcp 10256/tcp "${CNI_PORTS[@]}")

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
        info "Ensure external firewall allows: ${UFW_PORTS[*]}"
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
  wait_for_apt_lock
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

  wait_for_apt_lock
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

    if [[ "${PKG_MGR}" == "apt" ]]; then
      # NOTE: awk has no -f/-x file-test operators — see the equivalent
      # comment in 01-linux-master-setup.sh. Verify candidates with a real
      # bash file test instead, matching the primary discovery path above.
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
  # explicitly set and verified above (see configure_containerd); CRI-O
  # needs the equivalent guarantee here on the worker too, or pods can
  # silently fail to schedule/start with a driver mismatch.
  cat >/etc/crio/crio.conf.d/20-kubernetes-cgroup.conf <<'EOF'
[crio.runtime]
cgroup_manager = "systemd"
conmon_cgroup = "pod"
EOF

  # CNI config/binary directories must match where kubeadm/kubelet install
  # CNI plugins (/opt/cni/bin) and where the master's CNI manifest writes
  # its config (/etc/cni/net.d), regardless of which CNI is selected. Write
  # this explicitly rather than relying on `crio config` (not supported on
  # every packaged CRI-O build, confirmed in practice) or on the packaged
  # default — a mismatch here silently breaks pod networking.
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
  wait_for_apt_lock
  apt-get install ${APT_OPTS} apt-transport-https curl

  curl -fsSL \
    "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" |
    gpg --dearmor \
      -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
      --batch --yes

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

# -----------------------------------------------------------------------------
# Validate the join command before ever executing it (section 6/7 of the audit
# requirements). It must be a genuine kubeadm-generated command with the
# expected discovery arguments — never an arbitrary string.
# -----------------------------------------------------------------------------
[[ "${JOIN_COMMAND}" == kubeadm\ join* ]] ||
  die "Refusing to run: join command does not start with 'kubeadm join'"
[[ "${JOIN_COMMAND}" == *"--token"* ]] ||
  die "Refusing to run: join command is missing --token"
[[ "${JOIN_COMMAND}" == *"--discovery-token-ca-cert-hash"* ]] ||
  die "Refusing to run: join command is missing --discovery-token-ca-cert-hash"

# -----------------------------------------------------------------------------
# Network connectivity precheck (section 35): verify the API server endpoint
# is reachable over TCP before attempting to join. A ping-only check is not
# sufficient — the port itself must accept connections.
# -----------------------------------------------------------------------------
API_ENDPOINT=$(printf '%s' "${JOIN_COMMAND}" | grep -oP 'kubeadm join \K[0-9.]+:[0-9]+' || true)
if [[ -z "${API_ENDPOINT}" && -n "${MASTER_IP}" ]]; then
  API_ENDPOINT="${MASTER_IP}:6443"
fi

if [[ -n "${API_ENDPOINT}" ]]; then
  API_HOST="${API_ENDPOINT%%:*}"
  API_PORT="${API_ENDPOINT##*:}"
  info "Checking TCP connectivity to API server ${API_HOST}:${API_PORT}..."
  conn_wait=0
  conn_ok=false
  until [[ ${conn_wait} -ge 30 ]]; do
    if timeout 5 bash -c "cat </dev/null >/dev/tcp/${API_HOST}/${API_PORT}" 2>/dev/null; then
      conn_ok=true
      break
    fi
    sleep 2
    conn_wait=$((conn_wait + 2))
  done
  [[ "${conn_ok}" == "true" ]] ||
    die "Cannot reach API server at ${API_HOST}:${API_PORT} over TCP after 30s." \
        "Check firewall rules and that the control plane is Ready."
  ok "API server ${API_HOST}:${API_PORT} is reachable"
else
  warn "Could not determine API server endpoint to precheck (no MASTER_IP and none parsed from join command)"
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
# to be generated by kubeadm and may contain quoted arguments, so it is
# re-parsed through a single shell invocation rather than eval'd or manually
# tokenized (which risks corrupting valid kubeadm arguments).
set +e
if [[ "${JOIN_COMMAND}" == *"--cri-socket"* ]]; then
  bash -c "${JOIN_COMMAND}"
else
  bash -c "${JOIN_COMMAND} --cri-socket ${CRI_SOCKET}"
fi
JOIN_RC=$?
set -e

if [[ ${JOIN_RC} -ne 0 ]]; then
  collect_join_diagnostics
  die "kubeadm join failed (exit ${JOIN_RC}) — see diagnostics above"
fi

rm -f -- "${JOIN_COMMAND_FILE}" 2>/dev/null || true

ok "Node joined cluster"

# =============================================================================
step "6/7" "Configuring kubelet node IP and DNS"
# =============================================================================
#
# CRITICAL ORDERING NOTE: this must run BEFORE the CRI-O CNI-wait/restart
# logic below, not after — confirmed by a live run. kubeadm join pulls its
# initial /var/lib/kubelet/config.yaml from the cluster-wide kubelet-config
# ConfigMap, which was populated from the MASTER's own resolvConf value at
# `kubeadm init` time. On a mixed-OS cluster (Ubuntu master + Rocky worker),
# that means a Rocky worker initially inherits Ubuntu's
# `/run/systemd/resolve/resolv.conf` path — which doesn't exist on Rocky
# (NetworkManager, not systemd-resolved) — and DaemonSet pods (kube-proxy,
# calico-node) get scheduled onto the node the moment it registers, well
# before this script would otherwise get around to fixing it. Observed in
# practice: "FailedCreatePodSandBox ... open /run/systemd/resolve/resolv.conf:
# no such file or directory" retried for 3+ minutes, only resolving once this
# fix-and-restart step finally ran — and it used to run AFTER the CRI-O
# CNI-wait block, which can itself take up to several minutes, compounding
# the delay. Running this immediately after join instead minimizes the
# window where pods fail sandbox creation on a mismatched resolver path.

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

# -----------------------------------------------------------------------------
# CRI-O ONLY: work around a real, reproduced race where CRI-O's CNI
# config-directory watcher isn't reliably armed yet on a just-joined worker.
# The master's CRI-O has typically been running for minutes (image pulls,
# cert generation) before its own CNI gets applied, so its watcher is fully
# up by then — but a worker's CRI-O has been running mere seconds before the
# CNI DaemonSet schedules onto it and writes /etc/cni/net.d/<cni>.conflist.
# When CRI-O misses that create event, kubelet reports indefinitely:
#   Ready=False KubeletNotReady "container runtime network not ready:
#   NetworkReady=false ... no CNI configuration file in /etc/cni/net.d/"
# and it does NOT self-heal — confirmed by direct `kubectl describe node`
# output showing the condition still false after 5+ minutes on both Calico
# and Flannel. The fix: wait for the CNI plugin to actually write its config
# file, then restart CRI-O once to force it to (re-)detect it.
#
# TIMEOUT NOTE: an earlier version of this wait used a 90s budget, and a live
# run showed a Rocky/CRI-O worker's calico-node pod finish starting right at
# the ~91s mark — a hair too slow for that 90s window, and my wait bailed
# out before the file ever appeared. Image pull time for the CNI pod is
# genuinely variable (slower registries, RHEL-family dnf mirrors, etc.), so
# give this real margin instead of a tight timeout, and restart CRI-O
# regardless of whether the file was confirmed within the wait — a restart
# is cheap, and if the file lands moments after the loop gives up, the
# restart still picks it up rather than leaving the node stuck.
if [[ "${RUNTIME}" == "crio" ]]; then
  info "Waiting for CNI plugin to write its config to /etc/cni/net.d..."
  cni_wait=0
  cni_conf_found=false
  while (( cni_wait < 300 )); do
    if compgen -G "/etc/cni/net.d/*.conf*" > /dev/null 2>&1; then
      cni_conf_found=true
      break
    fi
    sleep 5
    cni_wait=$((cni_wait + 5))
  done

  if [[ "${cni_conf_found}" == "true" ]]; then
    ok "CNI config file present in /etc/cni/net.d (${cni_wait}s)"
  else
    warn "No CNI config file appeared in /etc/cni/net.d within ${cni_wait}s — restarting CRI-O anyway in case it lands momentarily; if it doesn't, the node will need this step re-run manually"
  fi

  CRIO_SVC_NAME=""
  for u in crio.service cri-o.service; do
    if systemctl list-unit-files "${u}" &>/dev/null; then
      CRIO_SVC_NAME="${u}"
      break
    fi
  done

  if [[ -n "${CRIO_SVC_NAME}" ]]; then
    info "Restarting ${CRIO_SVC_NAME} so it (re-)detects the CNI configuration..."
    if restart_crio_service "${CRIO_SVC_NAME}"; then
      rt_wait=0
      rt_ready=false
      while (( rt_wait < 30 )); do
        if [[ -S "${CRI_SOCKET#unix://}" ]] &&
           crictl --runtime-endpoint="${CRI_SOCKET}" info &>/dev/null; then
          rt_ready=true
          break
        fi
        sleep 2
        rt_wait=$((rt_wait + 2))
      done
      if [[ "${rt_ready}" == "true" ]]; then
        ok "${CRIO_SVC_NAME} restarted and CRI socket is responding again"
      else
        warn "${CRIO_SVC_NAME} restarted but CRI socket did not come back within 30s — check systemctl status ${CRIO_SVC_NAME}"
      fi

      # If the CNI file hadn't appeared yet when we restarted, give it one
      # more chance to show up and nudge CRI-O again — covers the case where
      # the DaemonSet pod was still mid-pull during the first restart.
      if [[ "${cni_conf_found}" != "true" ]]; then
        info "Giving the CNI config file one more chance to appear (up to 60s more)..."
        extra_wait=0
        while (( extra_wait < 60 )); do
          if compgen -G "/etc/cni/net.d/*.conf*" > /dev/null 2>&1; then
            cni_conf_found=true
            break
          fi
          sleep 5
          extra_wait=$((extra_wait + 5))
        done
        if [[ "${cni_conf_found}" == "true" ]]; then
          ok "CNI config file appeared after all (+${extra_wait}s) — restarting ${CRIO_SVC_NAME} once more"
          restart_crio_service "${CRIO_SVC_NAME}" || warn "Second restart of ${CRIO_SVC_NAME} failed"
        else
          warn "CNI config file still not present after ${cni_wait}s + ${extra_wait}s — this node will likely need 'systemctl restart ${CRIO_SVC_NAME}' run manually once the CNI DaemonSet actually schedules here"
        fi
      fi
    else
      warn "Failed to restart ${CRIO_SVC_NAME} — node may remain NotReady until it is restarted manually"
    fi
  else
    warn "Could not determine the CRI-O systemd unit name to restart it — node may remain NotReady"
  fi
fi

# Ensure the node's own hostname resolves locally even when external DNS has no
# record for it (common on lab/host-only networks and isolated enterprise DNS).
NODE_HOSTNAME=$(hostname -s)
if ! getent hosts "${NODE_HOSTNAME}" >/dev/null 2>&1; then
  printf '%s %s\n' "${NODE_IP}" "${NODE_HOSTNAME}" >> /etc/hosts
  ok "Added local hostname mapping: ${NODE_IP} ${NODE_HOSTNAME}"
fi

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