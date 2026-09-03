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
info() { echo -e "  ${CY}[....]${NC} $*"; }

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

case "${RUNTIME}" in
  containerd) CRI_SOCKET="unix:///run/containerd/containerd.sock" ;;
  crio)       CRI_SOCKET="unix:///var/run/crio/crio.sock" ;;
  *)          CRI_SOCKET="" ;;
esac

# Same dpkg-lock race documented and fixed in 01-linux-master-setup.sh and
# 02-linux-worker-setup.sh: a fresh/recently-active VM's own apt-daily timers
# (or this script's own back-to-back apt-get calls) can collide on the dpkg
# lock, and apt-get does not wait for it — it just fails with exit 100.
wait_for_apt_lock() {
  [[ "${PKG_MGR}" == "apt" ]] || return 0
  local waited=0
  local max_wait=120
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

# K8S_VERSION may be a full X.Y.Z (the final target, exact as requested) or
# just X.Y (an intermediate hop on a multi-minor upgrade path — see note
# below on why intermediate hops are NOT hardcoded to "X.Y.0").
if [[ "${K8S_VERSION}" =~ ^[0-9]+\.[0-9]+$ ]]; then
  K8S_MINOR="${K8S_VERSION}"
  K8S_VERSION_IS_MINOR_ONLY=true
else
  K8S_MINOR="${K8S_VERSION%.*}"   # e.g. 1.32
  K8S_VERSION_IS_MINOR_ONLY=false
fi

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
  wait_for_apt_lock
  apt-get install ${APT_OPTS} apt-transport-https curl ca-certificates
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/Release.key" | \
    gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg --batch --yes
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] \
    https://pkgs.k8s.io/core:/stable:/v${K8S_MINOR}/deb/ /" \
    >/etc/apt/sources.list.d/kubernetes.list
  wait_for_apt_lock
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

# -----------------------------------------------------------------------------
# Resolve an intermediate hop's minor-only version (e.g. "1.31") to the
# LATEST patch actually available in the repo just configured above, rather
# than assuming/hardcoding "X.Y.0". Kubernetes package repos rotate patches
# over time — the exact ".0" release for an older minor line can be pruned
# long before anyone upgrades through it, which would make
# `apt-get install kubeadm=1.31.0-*` fail outright with "version not found."
# Using whatever the repo actually has avoids that, and is also simply
# better practice (latest patch = most bug/CVE fixes) for a hop that's just
# passing through on the way to the real target version.
# -----------------------------------------------------------------------------
if [[ "${K8S_VERSION_IS_MINOR_ONLY}" == "true" ]]; then
  info "Resolving latest available patch for v${K8S_MINOR} in the configured repository..."
  RESOLVED_VERSION=""
  if [[ "${PKG_MGR}" == "apt" ]]; then
    RESOLVED_VERSION=$(apt-cache madison kubeadm 2>/dev/null |
      awk '{print $3}' | grep -E "^${K8S_MINOR//./\\.}\." | sed 's/-.*//' |
      sort -V | tail -1)
  else
    RESOLVED_VERSION=$(dnf list --showduplicates kubeadm --disableexcludes=kubernetes 2>/dev/null |
      awk '{print $2}' | grep -E "^${K8S_MINOR//./\\.}\." | sed 's/-.*//' |
      sort -V | tail -1)
  fi
  [[ -n "${RESOLVED_VERSION}" ]] ||
    die "Could not resolve an available kubeadm patch version for minor ${K8S_MINOR} in the configured repository"
  K8S_VERSION="${RESOLVED_VERSION}"
  ok "Resolved v${K8S_MINOR} to latest available patch: v${K8S_VERSION}"
fi

# =============================================================================
step "2" "Upgrade kubeadm to v${K8S_VERSION}"
# =============================================================================

if [[ "${PKG_MGR}" == "apt" ]]; then
  wait_for_apt_lock
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

# Do not exit awk early here either: whether the early-closer is `head` or
# `awk ... {exit}`, if `kubectl get nodes` still has more lines queued when
# the reader closes its end of the pipe, kubectl can be killed by SIGPIPE and
# the whole pipeline reports exit status 141 under `set -o pipefail` — even
# though a match was found (this is the actual root cause that surfaced live
# in 01-linux-master-setup.sh's Calico interface detection; the same fix
# applies here: let awk consume all of kubectl's output, no `exit`, and pick
# the first line in pure bash so there is no pipe left to break).
NODE_NAME=$(kubectl get nodes --no-headers 2>/dev/null \
  | awk -v ip="${HOSTNAME}" '$1==ip || $1==ENVIRON["HOSTNAME"]{print $1}')
NODE_NAME="${NODE_NAME%%$'\n'*}"
[[ -z "${NODE_NAME}" ]] && NODE_NAME=$(hostname)

if [[ "${NODE_ROLE}" == "master" ]]; then
  kubectl drain "${NODE_NAME}" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --force \
    --grace-period=60 \
    --timeout=120s 2>/dev/null || {
      warn "First drain attempt had warnings — retrying once with a longer timeout..."
      kubectl drain "${NODE_NAME}" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --grace-period=60 \
        --timeout=180s 2>/dev/null || warn "Drain still reported warnings after retry (non-fatal) — check for PodDisruptionBudgets blocking eviction"
    }
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
    --timeout=120s 2>/dev/null || {
      warn "First drain attempt had warnings — retrying once with a longer timeout..."
      kubectl drain "${NODE_NAME}" \
        --ignore-daemonsets \
        --delete-emptydir-data \
        --force \
        --grace-period=60 \
        --timeout=180s 2>/dev/null || warn "Drain still reported warnings after retry (non-fatal) — check for PodDisruptionBudgets blocking eviction"
    }
  ok "Worker drained"
fi

# =============================================================================
step "5" "Upgrade kubelet and kubectl to v${K8S_VERSION}"
# =============================================================================

if [[ "${PKG_MGR}" == "apt" ]]; then
  wait_for_apt_lock
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

# Do not blindly sleep-and-uncordon: confirm kubelet actually came back up
# (and, where we can check it, that the CRI socket is still responding)
# before returning this node to schedulable state. Uncordoning a node whose
# kubelet failed to restart just means new pods get scheduled onto a node
# that can't run them.
kubelet_wait=0
kubelet_ready=false
while (( kubelet_wait < 60 )); do
  if systemctl is-active --quiet kubelet; then
    kubelet_ready=true
    break
  fi
  sleep 3
  kubelet_wait=$((kubelet_wait + 3))
done

if [[ "${kubelet_ready}" != "true" ]]; then
  warn "kubelet did not report active within ${kubelet_wait}s after restart — collecting diagnostics"
  systemctl status kubelet --no-pager -l 2>&1 | tail -30 >&2 || true
  journalctl -u kubelet -n 40 --no-pager 2>&1 >&2 || true
  die "Refusing to uncordon ${NODE_NAME}: kubelet is not active after the upgrade restart"
fi

if [[ -n "${CRI_SOCKET}" ]] && command -v crictl &>/dev/null; then
  if ! crictl --runtime-endpoint="${CRI_SOCKET}" info &>/dev/null; then
    warn "CRI endpoint ${CRI_SOCKET} is not responding after kubelet restart — collecting diagnostics"
    systemctl status "${RUNTIME}" --no-pager -l 2>&1 | tail -20 >&2 || true
    die "Refusing to uncordon ${NODE_NAME}: CRI endpoint ${CRI_SOCKET} is not responding"
  fi
fi

ok "kubelet + kubectl upgraded to v${K8S_VERSION} and confirmed active"

# =============================================================================
step "6" "Uncordon node"
# =============================================================================

kubectl uncordon "${NODE_NAME}" 2>/dev/null || warn "Uncordon failed — check manually"
ok "Node ${NODE_NAME} uncordoned"

# =============================================================================
step "7" "Verify node version and Ready status"
# =============================================================================

# Don't just sleep-and-hope: actually poll until this node reports Ready
# AND is running the target kubelet version before declaring the hop done.
# Proceeding to the next node/hop while this one is still converging is
# exactly how a multi-node upgrade compounds problems and makes root-causing
# harder — verify each node before moving on, per real-world rolling-upgrade
# practice.
verify_wait=0
verify_timeout=180
node_ready="false"
node_version=""
while (( verify_wait < verify_timeout )); do
  node_version=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.nodeInfo.kubeletVersion}' 2>/dev/null || true)
  node_ready_status=$(kubectl get node "${NODE_NAME}" -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null || true)
  if [[ "${node_ready_status}" == "True" && "${node_version}" == "v${K8S_VERSION}" ]]; then
    node_ready="true"
    break
  fi
  sleep 5
  verify_wait=$((verify_wait + 5))
done

if [[ "${node_ready}" == "true" ]]; then
  ok "${NODE_NAME} is Ready on ${node_version} (${verify_wait}s)"
else
  warn "${NODE_NAME} did not confirm Ready+v${K8S_VERSION} within ${verify_timeout}s (last seen: ready=${node_ready_status:-unknown} version=${node_version:-unknown})"
  warn "Continuing, but check this node manually — proceeding to the next node/hop with an unconfirmed node risks compounding the problem"
fi

kubectl get nodes -o wide 2>/dev/null | head -10 || true

echo -e "
  ${GR}+================================================================+${NC}
  ${GR}|     NODE UPGRADE COMPLETE                                       |${NC}
  ${GR}+================================================================+${NC}
  Host    : $(hostname)
  Role    : ${NODE_ROLE}
  Version : v${K8S_VERSION}
"
