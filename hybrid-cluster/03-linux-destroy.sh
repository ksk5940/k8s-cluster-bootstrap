#!/usr/bin/env bash
# =============================================================================
#  03-linux-destroy.sh  —  Kubernetes Node COMPLETE Teardown
#  Removes every trace of: kubeadm · kubelet · kubectl · containerd · crio
#                          CNI (calico · flannel · weave) · all temp files
#                          repos · keyrings · systemd units · logs · sockets
#
#  Supports: Ubuntu 22/24  |  Rocky / RHEL 8/9
#  Called by Jenkins via:
#    export RUNTIME=containerd|crio  CNI_PLUGIN=calico|flannel|weave
#    sudo -E bash /tmp/03-linux-destroy.sh
# =============================================================================
set -uo pipefail   # note: no -e so every step runs even if one fails

RUNTIME="${RUNTIME:-containerd}"
CNI_PLUGIN="${CNI_PLUGIN:-}"     # blank = clean all three CNIs

# ── Colours ───────────────────────────────────────────────────────────────────
CY='\033[0;36m'; GR='\033[0;32m'; RD='\033[0;31m'; YL='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n  ${CY}[$1]${NC} $2\n  $(printf '%0.s-' {1..66})"; }
ok()   { echo -e "  ${GR}[OK]${NC}   $*"; }
warn() { echo -e "  ${YL}[WARN]${NC} $*"; }
info() { echo -e "  ${CY}[....]${NC} $*"; }
gone() { echo -e "  ${GR}[DEL]${NC}  $*"; }

# ── Helpers ───────────────────────────────────────────────────────────────────
purge_paths() {
  for p in "$@"; do
    if [[ -e "${p}" || -L "${p}" ]]; then
      rm -rf "${p}"
      gone "${p}"
    fi
  done
}

stop_service() {
  local svc="$1"
  if systemctl list-units --full --all 2>/dev/null | grep -q "${svc}.service"; then
    systemctl stop    "${svc}" 2>/dev/null || true
    systemctl disable "${svc}" 2>/dev/null || true
    info "Stopped + disabled: ${svc}"
  fi
}

remove_pkg_apt() {
  DEBIAN_FRONTEND=noninteractive apt-get remove --purge -y -q \
    -o Dpkg::Options::=--force-confold \
    -o Dpkg::Options::=--force-confdef \
    "$@" 2>/dev/null || true
}

remove_pkg_dnf() {
  dnf remove -y "$@" 2>/dev/null || true
}

# ── Detect OS ─────────────────────────────────────────────────────────────────
if [[ -f /etc/os-release ]]; then
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID%%.*}"
else
  OS_ID="unknown"; OS_VER="?"
fi
if   [[ "${OS_ID}" =~ ^(ubuntu|debian|linuxmint|pop|elementary|kali|raspbian)$ ]]; then PKG_MGR="apt"
elif [[ "${OS_ID}" =~ ^(rhel|centos|rocky|almalinux|fedora|ol|scientific)$ ]];     then PKG_MGR="dnf"
elif [[ "${OS_ID}" =~ ^(opensuse|sles|suse)$ ]];                                    then PKG_MGR="zypper"
elif command -v apt-get &>/dev/null;  then PKG_MGR="apt"
elif command -v dnf     &>/dev/null;  then PKG_MGR="dnf"
else PKG_MGR="dnf"; fi

echo -e "
  ${CY}+================================================================+${NC}
  ${CY}|     KUBERNETES NODE — COMPLETE TEARDOWN                        |${NC}
  ${CY}+================================================================+${NC}

  ${CY}[....]${NC}  Host     : $(hostname)
  ${CY}[....]${NC}  OS       : ${OS_ID} ${OS_VER}
  ${CY}[....]${NC}  Runtime  : ${RUNTIME}
  ${CY}[....]${NC}  CNI      : ${CNI_PLUGIN:-all}
"

# =============================================================================
step "1/10" "kubeadm reset"
# =============================================================================

case "${RUNTIME}" in
  containerd) CRI_SOCKET="unix:///run/containerd/containerd.sock" ;;
  crio)       CRI_SOCKET="unix:///var/run/crio/crio.sock" ;;
  *)          CRI_SOCKET="" ;;
esac

if command -v kubeadm &>/dev/null; then
  if [[ -n "${CRI_SOCKET}" ]]; then
    kubeadm reset -f --cri-socket "${CRI_SOCKET}" 2>/dev/null || true
  else
    kubeadm reset -f 2>/dev/null || true
  fi
  ok "kubeadm reset complete"
else
  warn "kubeadm not installed — skipping reset"
fi

# =============================================================================
step "2/10" "Stop all K8s and runtime services"
# =============================================================================

for svc in kubelet kube-proxy containerd crio cri-o docker; do
  stop_service "${svc}"
done
ok "All services stopped and disabled"

# =============================================================================
step "3/10" "Remove Kubernetes packages (kubelet · kubeadm · kubectl · crictl)"
# =============================================================================

if [[ "${PKG_MGR}" == "apt" ]]; then
  remove_pkg_apt kubelet kubeadm kubectl kubernetes-cni cri-tools
  DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -q 2>/dev/null || true
  ok "K8s packages purged (apt)"
else
  remove_pkg_dnf kubelet kubeadm kubectl kubernetes-cni cri-tools
  ok "K8s packages removed (dnf)"
fi

purge_paths \
  /usr/bin/kubeadm \
  /usr/bin/kubelet \
  /usr/bin/kubectl \
  /usr/local/bin/kubectl \
  /usr/bin/crictl \
  /usr/local/bin/crictl

# =============================================================================
step "4/10" "Remove containerd — packages · config · data · sockets · logs"
# =============================================================================

stop_service containerd

if [[ "${PKG_MGR}" == "apt" ]]; then
  remove_pkg_apt containerd.io containerd docker-ce docker-ce-cli docker-ce-rootless-extras
  DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -q 2>/dev/null || true
else
  remove_pkg_dnf containerd.io containerd
fi

purge_paths \
  /etc/containerd \
  /etc/containerd/config.toml \
  /var/lib/containerd \
  /run/containerd \
  /var/run/containerd \
  /run/containerd/containerd.sock \
  /run/containerd/containerd.sock.ttrpc \
  /run/containerd/debug.sock \
  /etc/systemd/system/containerd.service \
  /etc/systemd/system/containerd.service.d \
  /usr/lib/systemd/system/containerd.service \
  /lib/systemd/system/containerd.service \
  /var/log/containerd \
  /usr/bin/containerd \
  /usr/bin/containerd-shim \
  /usr/bin/containerd-shim-runc-v1 \
  /usr/bin/containerd-shim-runc-v2 \
  /usr/bin/ctr \
  /usr/local/bin/containerd \
  /usr/local/bin/containerd-shim \
  /usr/local/bin/containerd-shim-runc-v2 \
  /usr/local/bin/ctr \
  /usr/bin/runc \
  /usr/local/bin/runc \
  /usr/sbin/runc

ok "containerd fully removed"

# =============================================================================
step "5/10" "Remove CRI-O — packages · config · data · sockets · logs"
# =============================================================================

stop_service crio
stop_service cri-o

if [[ "${PKG_MGR}" == "apt" ]]; then
  remove_pkg_apt cri-o cri-o-runc cri-tools
  DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -q 2>/dev/null || true
else
  remove_pkg_dnf cri-o cri-tools
fi

purge_paths \
  /etc/crio \
  /etc/crio/crio.conf \
  /etc/crio/crio.conf.d \
  /var/lib/crio \
  /var/lib/containers \
  /var/cache/crio \
  /var/run/crio \
  /run/crio \
  /var/run/crio/crio.sock \
  /run/crio/crio.sock \
  /etc/systemd/system/crio.service \
  /etc/systemd/system/crio.service.d \
  /usr/lib/systemd/system/crio.service \
  /lib/systemd/system/crio.service \
  /var/log/crio \
  /usr/bin/crio \
  /usr/local/bin/crio \
  /usr/bin/crio-status \
  /usr/libexec/crio \
  /usr/local/libexec/crio

ok "CRI-O fully removed"

# =============================================================================
step "6/10" "Remove package repos and keyrings (containerd · cri-o · kubernetes)"
# =============================================================================

purge_paths \
  /etc/apt/sources.list.d/docker.list \
  /etc/apt/sources.list.d/cri-o.list \
  /etc/apt/sources.list.d/kubernetes.list \
  /etc/apt/keyrings/docker.gpg \
  /etc/apt/keyrings/docker.asc \
  /etc/apt/keyrings/cri-o-apt-keyring.gpg \
  /etc/apt/keyrings/kubernetes-apt-keyring.gpg \
  /etc/yum.repos.d/docker-ce.repo \
  /etc/yum.repos.d/containerd.repo \
  /etc/yum.repos.d/cri-o.repo \
  /etc/yum.repos.d/kubernetes.repo

if [[ "${PKG_MGR}" == "apt" ]]; then
  apt-get update -qq 2>/dev/null || true
fi

ok "Package repos and keyrings removed"

# =============================================================================
step "7/10" "Remove Kubernetes state · config · data · logs · temp files"
# =============================================================================

purge_paths \
  /etc/kubernetes \
  /var/lib/etcd \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/run/kubernetes \
  /run/kubernetes \
  /etc/default/kubelet \
  /etc/systemd/system/kubelet.service.d \
  /usr/lib/systemd/system/kubelet.service \
  /lib/systemd/system/kubelet.service \
  /var/log/pods \
  /var/log/containers \
  /root/.kube \
  /tmp/kubeadm-init.log \
  /tmp/k8s-join-command.sh \
  /tmp/01-linux-master-setup.sh \
  /tmp/02-linux-worker-setup.sh

# All user kubeconfigs
for d in /home/*/; do
  purge_paths "${d}.kube"
done

ok "Kubernetes state and temp files fully removed"

# =============================================================================
step "8/10" "Remove CNI plugins · config · interfaces"
# =============================================================================

# Common CNI dirs
purge_paths \
  /opt/cni \
  /etc/cni \
  /var/lib/cni \
  /run/cni

# ── Calico ────────────────────────────────────────────────────────────────────
if [[ -z "${CNI_PLUGIN}" || "${CNI_PLUGIN}" == "calico" ]]; then
  ip link delete vxlan.calico 2>/dev/null || true
  ip link delete tunl0        2>/dev/null || true
  ip link show 2>/dev/null \
    | grep -oP '(?<=\d: )\S+(?=@|:)' \
    | grep -E '^cali' \
    | while read -r iface; do ip link delete "${iface}" 2>/dev/null || true; done
  purge_paths \
    /var/lib/calico \
    /etc/calico \
    /var/run/calico \
    /run/calico
  info "Calico fully cleaned"
fi

# ── Flannel ───────────────────────────────────────────────────────────────────
if [[ -z "${CNI_PLUGIN}" || "${CNI_PLUGIN}" == "flannel" ]]; then
  ip link delete flannel.1 2>/dev/null || true
  ip link delete cni0      2>/dev/null || true
  purge_paths \
    /run/flannel \
    /var/run/flannel \
    /etc/kube-flannel \
    /var/lib/flannel
  info "Flannel fully cleaned"
fi

# ── Weave ─────────────────────────────────────────────────────────────────────
if [[ -z "${CNI_PLUGIN}" || "${CNI_PLUGIN}" == "weave" ]]; then
  ip link delete weave    2>/dev/null || true
  ip link delete dummy0   2>/dev/null || true
  ip link delete datapath 2>/dev/null || true
  for chain in WEAVE-NPC WEAVE-NPC-EGRESS WEAVE-NPC-DEFAULT WEAVE-EXPOSE WEAVE; do
    iptables -t filter -F "${chain}" 2>/dev/null || true
    iptables -t filter -X "${chain}" 2>/dev/null || true
  done
  purge_paths \
    /var/lib/weave \
    /etc/weave \
    /run/weave \
    /var/run/weave
  info "Weave fully cleaned"
fi

# Catch-all: any remaining CNI-named interfaces
ip link show 2>/dev/null \
  | grep -oP '(?<=\d: )\S+(?=@|:)' \
  | grep -E 'cali|vxlan|flannel|weave' \
  | while read -r iface; do
      ip link delete "${iface}" 2>/dev/null || true
      info "Removed stale interface: ${iface}"
    done

ok "CNI plugins and interfaces fully removed"

# =============================================================================
step "9/10" "Flush iptables · ip6tables · ipvs · routing"
# =============================================================================

for table in filter nat mangle raw; do
  iptables  -t "${table}" -F 2>/dev/null || true
  iptables  -t "${table}" -X 2>/dev/null || true
  iptables  -t "${table}" -Z 2>/dev/null || true
  ip6tables -t "${table}" -F 2>/dev/null || true
  ip6tables -t "${table}" -X 2>/dev/null || true
  ip6tables -t "${table}" -Z 2>/dev/null || true
done

if command -v ipvsadm &>/dev/null; then
  ipvsadm --clear 2>/dev/null || true
  info "IPVS table cleared"
fi

# Remove pod/service routes left by kube-proxy or CNI
ip route show 2>/dev/null | grep -E '10\.(244|96|32)\.' | \
  while read -r route; do ip route del ${route} 2>/dev/null || true; done

ok "iptables, ip6tables, ipvs, and routing fully flushed"

# =============================================================================
step "10/10" "Remove kernel module config · sysctl overrides · reload systemd"
# =============================================================================

purge_paths /etc/modules-load.d/k8s.conf
purge_paths /etc/sysctl.d/99-k8s.conf

for mod in br_netfilter overlay; do
  if lsmod 2>/dev/null | grep -q "^${mod}"; then
    modprobe -r "${mod}" 2>/dev/null || true
    info "Unloaded kernel module: ${mod}"
  fi
done

sysctl --system -q 2>/dev/null || true
ok "sysctl config removed and system settings reloaded"

systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed  2>/dev/null || true
ok "systemd reloaded — removed units no longer visible"

# Restore swap if setup script backed up fstab
if [[ -f /etc/fstab.bak ]]; then
  info "fstab.bak found — restoring swap entries"
  grep -i swap /etc/fstab.bak | while read -r line; do
    grep -qF "${line}" /etc/fstab || echo "${line}" >> /etc/fstab
  done
  swapon -a 2>/dev/null || true
  ok "Swap restored"
else
  info "No fstab.bak — swap not restored"
fi

# =============================================================================
echo -e "\n  ${GR}+================================================================+${NC}"
echo -e "  ${GR}|        COMPLETE TEARDOWN FINISHED                              |${NC}"
echo -e "  ${GR}+================================================================+${NC}"
echo -e "  Host    : $(hostname)"
echo -e "  Runtime : ${RUNTIME}  — fully removed"
echo -e "  CNI     : ${CNI_PLUGIN:-all}  — fully removed"
echo -e ""
echo -e "  Removed:"
echo -e "    kubeadm · kubelet · kubectl · crictl"
echo -e "    containerd  (pkg · config · data · socket · units · logs)"
echo -e "    CRI-O       (pkg · config · data · socket · units · logs)"
echo -e "    CNI plugins: calico + flannel + weave"
echo -e "    Package repos and keyrings"
echo -e "    All temp files and join-command tokens"
echo -e "    Kernel module config (/etc/modules-load.d/k8s.conf)"
echo -e "    sysctl overrides (/etc/sysctl.d/99-k8s.conf)"
echo -e "    iptables · ip6tables · ipvs · CNI routes"
echo -e "    systemd units reloaded — node is clean"
echo -e ""
echo -e "  The node is ready to re-provision."
echo ""
