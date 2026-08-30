#!/usr/bin/env bash
# =============================================================================
#  03-linux-destroy.sh  —  Kubernetes Node COMPLETE Teardown
#
#  Removes every trace of:
#    kubeadm · kubelet · kubectl · containerd · crio
#    CNI (calico · flannel · weave) · all temp files
#    repos · keyrings · systemd units · logs · sockets
#    iptables · ipvs · kernel modules · sysctl overrides
#    /root/.kube · all user ~/.kube · etcd data · pki
#    containerd data dir · crio data dir · run sockets
#
#  Supports: Ubuntu 22/24  |  Rocky / RHEL 8/9
#  Called by Jenkins:
#    export RUNTIME=containerd|crio  CNI_PLUGIN=calico|flannel|weave
#    sudo -E bash /tmp/03-linux-destroy.sh
# =============================================================================
set -uo pipefail   # no -e so every step runs even if one fails

RUNTIME="${RUNTIME:-containerd}"
CNI_PLUGIN="${CNI_PLUGIN:-}"   # blank = clean all CNIs

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

# Calico can mount a cgroup filesystem below /var/run/calico/cgroup.  Those
# entries are kernel-managed virtual files, not ordinary files.  Never run
# rm -rf against the mounted tree: unmount every nested mount first.
unmount_tree() {
  local root="$1" mnt
  [[ -e "$root" || -d "$root" ]] || return 0
  command -v findmnt >/dev/null 2>&1 || return 0
  command -v umount >/dev/null 2>&1 || return 0

  # findmnt returns nested mounts. Unmount deepest paths first. CRI-O's
  # containers/storage commonly contains overlay .../merged mountpoints;
  # rm -rf cannot remove those while mounted and reports "different device".
  for mnt in $(findmnt -Rno TARGET -- "$root" 2>/dev/null | awk 'NF {print length($0) "\t" $0}' | sort -rn | cut -f2-); do
    [[ -n "$mnt" ]] || continue
    mountpoint -q "$mnt" 2>/dev/null || continue
    info "Unmounting mounted filesystem: $mnt"
    umount "$mnt" 2>/dev/null || umount -l "$mnt" 2>/dev/null || true
  done

  # A second pass catches mounts that were hidden by a parent/overlay during
  # the first pass. Keep this idempotent for partially destroyed nodes.
  for mnt in $(findmnt -Rno TARGET -- "$root" 2>/dev/null | awk 'NF {print length($0) "\t" $0}' | sort -rn | cut -f2-); do
    [[ -n "$mnt" ]] || continue
    mountpoint -q "$mnt" 2>/dev/null || continue
    umount -l "$mnt" 2>/dev/null || true
  done
}

verify_no_mounts_under() {
  local root="$1"
  command -v findmnt >/dev/null 2>&1 || return 0
  if findmnt -Rno TARGET -- "$root" 2>/dev/null | grep -q .; then
    warn "Mounted filesystems remain under ${root}"
    findmnt -R -- "$root" 2>/dev/null || true
    return 1
  fi
  return 0
}

# CRI-O can leave overlay mounts alive after the service/container processes
# have stopped. Stop known helpers and release the mount tree before deleting
# /var/lib/containers/storage.
cleanup_crio_storage_mounts() {
  local root="/var/lib/containers/storage"

  stop_service crio
  stop_service cri-o

  if command -v pkill >/dev/null 2>&1; then
    pkill -TERM -x conmon 2>/dev/null || true
    pkill -TERM -x crio 2>/dev/null || true
    sleep 1
    pkill -KILL -x conmon 2>/dev/null || true
    pkill -KILL -x crio 2>/dev/null || true
  fi

  # Release any remaining CRI-O storage mounts. Do not use fuser -k against
  # the whole host: unrelated workloads must never be killed by destroy.
  unmount_tree "$root"
  unmount_tree /var/lib/containers
  unmount_tree /run/containers
  unmount_tree /run/crio
}

unmount_calico_cgroup() {
  local root
  for root in /var/run/calico/cgroup /run/calico/cgroup; do
    unmount_tree "$root"
  done
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
step "1/11" "kubeadm reset"
# =============================================================================

case "${RUNTIME}" in
  containerd) CRI_SOCKET="unix:///run/containerd/containerd.sock" ;;
  crio)       CRI_SOCKET="unix:///var/run/crio/crio.sock" ;;
  *)          CRI_SOCKET="" ;;
esac

if command -v kubeadm &>/dev/null; then
  # Destroy must tolerate partially-configured/broken nodes (a runtime that
  # never started, a node that never fully joined, etc). We deliberately do
  # NOT use --ignore-preflight-errors=all here: that would silently swallow
  # every preflight class, including ones worth knowing about. Ignore only
  # the specific checks that legitimately fire on a torn-down/partial node.
  if [[ -n "${CRI_SOCKET}" ]]; then
    kubeadm reset -f --cri-socket "${CRI_SOCKET}" \
      --ignore-preflight-errors=CRI,Swap,FileAvailable--etc-kubernetes-manifests-etcd.yaml \
      2>/dev/null || true
  else
    kubeadm reset -f \
      --ignore-preflight-errors=CRI,Swap,FileAvailable--etc-kubernetes-manifests-etcd.yaml \
      2>/dev/null || true
  fi
  ok "kubeadm reset complete"
else
  warn "kubeadm not installed — skipping reset"
fi

# =============================================================================
step "2/11" "Stop all K8s and runtime services"
# =============================================================================

for svc in kubelet kube-proxy containerd crio cri-o docker; do
  stop_service "${svc}"
done

# Force-kill any lingering control-plane processes (may survive service stop)
for proc in kube-apiserver kube-controller-manager kube-scheduler etcd; do
  if pgrep -x "$proc" &>/dev/null; then
    info "Force-killing lingering process: $proc"
    pkill -9 -x "$proc" 2>/dev/null || true
  fi
done

ok "All services stopped and disabled"

# =============================================================================
step "3/11" "Remove Kubernetes packages (kubelet · kubeadm · kubectl · crictl)"
# =============================================================================

if [[ "${PKG_MGR}" == "apt" ]]; then
  # Remove version pins first
  apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
  remove_pkg_apt kubelet kubeadm kubectl kubernetes-cni cri-tools
  DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -q 2>/dev/null || true
  ok "K8s packages purged (apt)"
else
  # Remove version locks first
  dnf versionlock delete kubelet kubeadm kubectl cri-tools kubernetes-cni 2>/dev/null || true
  remove_pkg_dnf kubelet kubeadm kubectl kubernetes-cni cri-tools conntrack-tools 2>/dev/null || true
  ok "K8s packages removed (dnf)"
fi

purge_paths \
  /usr/bin/kubeadm \
  /usr/bin/kubelet \
  /usr/bin/kubectl \
  /usr/local/bin/kubectl \
  /usr/bin/crictl \
  /usr/local/bin/crictl \
  /usr/local/bin/calicoctl

# =============================================================================
step "4/11" "Remove containerd — packages · config · data · sockets · logs"
# =============================================================================

stop_service containerd

if [[ "${PKG_MGR}" == "apt" ]]; then
  remove_pkg_apt containerd.io containerd docker-ce docker-ce-cli docker-ce-rootless-extras
  DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -q 2>/dev/null || true
else
  remove_pkg_dnf containerd.io containerd container-selinux
fi

purge_paths \
  /etc/containerd \
  /var/lib/containerd \
  /run/containerd \
  /var/run/containerd \
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
step "5/11" "Remove CRI-O — packages · config · data · sockets · logs"
# =============================================================================

# Stop processes and unmount overlay storage BEFORE package removal/path purge.
cleanup_crio_storage_mounts

if [[ "${PKG_MGR}" == "apt" ]]; then
  remove_pkg_apt cri-o cri-o-runc cri-tools
else
  remove_pkg_dnf cri-o cri-tools
fi

# Package removal can expose another layer of mounts, so perform a second
# mount cleanup before deleting the storage directory.
cleanup_crio_storage_mounts
verify_no_mounts_under /var/lib/containers/storage || true

purge_paths \
  /etc/crio \
  /var/lib/crio \
  /var/cache/crio \
  /var/run/crio \
  /run/crio \
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

# Only remove the storage tree after all overlay mounts have been released.
unmount_tree /var/lib/containers/storage
unmount_tree /var/lib/containers
verify_no_mounts_under /var/lib/containers/storage || true
purge_paths /var/lib/containers/storage /var/lib/containers

ok "CRI-O fully removed"

if [[ "${RUNTIME}" == "crio" ]]; then
  if [[ -e /var/lib/containers/storage ]]; then
    if verify_no_mounts_under /var/lib/containers/storage; then
      purge_paths /var/lib/containers/storage
    fi
  fi
  verify_no_mounts_under /var/lib/containers/storage || die "CRI-O storage mounts remain after cleanup"
  [[ ! -e /var/lib/containers/storage ]] || die "CRI-O storage still exists after cleanup"
fi

# =============================================================================
step "6/11" "Remove package repos and keyrings (containerd · cri-o · kubernetes)"
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

# Clean dnf repo caches for removed repos
if [[ "${PKG_MGR}" == "dnf" ]]; then
  for cache in kubernetes docker-ce-stable cri-o epel; do
    find /var/cache/dnf -maxdepth 2 -name "${cache}*" -exec rm -rf {} + 2>/dev/null || true
  done
fi

if [[ "${PKG_MGR}" == "apt" ]]; then
  apt-get update -qq 2>/dev/null || true
fi

ok "Package repos and keyrings removed"

# =============================================================================
step "7/11" "Remove Kubernetes state · config · PKI · etcd · kubeconfig · logs"
# =============================================================================

# Unmount any kubelet bind-mounts first
for mnt in $(mount 2>/dev/null | awk '{print $3}' \
    | grep -E '^/var/lib/kubelet|^/run/containerd|^/run/crio|^/var/lib/containers' \
    | sort -r); do
  umount -l "${mnt}" 2>/dev/null || true
done

purge_paths \
  /etc/kubernetes \
  /var/lib/etcd \
  /var/lib/kubelet \
  /var/lib/kube-proxy \
  /var/run/kubernetes \
  /run/kubernetes \
  /etc/default/kubelet \
  /etc/sysconfig/kubelet \
  /etc/systemd/system/kubelet.service.d \
  /usr/lib/systemd/system/kubelet.service \
  /lib/systemd/system/kubelet.service \
  /var/log/pods \
  /var/log/containers \
  /root/.kube \
  /root/kubeadm-config.yaml \
  /tmp/k8s-join-command.sh \
  /tmp/calico.yaml \
  /tmp/calico-felix.yaml \
  /tmp/calico-ippool.yaml \
  /tmp/kube-flannel.yaml \
  /tmp/01-linux-master-setup.sh \
  /tmp/02-linux-worker-setup.sh \
  /tmp/03-linux-destroy.sh \
  /tmp/04-linux-upgrade.sh \
  /tmp/kubeadm-init.log \
  /var/log/k8s-init.log \
  /var/log/k8s-destroy.log \
  /var/log/k8s-reset.log \
  /var/log/k8s-upgrade.log

# Remove all user kubeconfigs and kube directories
for d in /home/*/; do
  [[ -d "${d}.kube" ]] && purge_paths "${d}.kube"
done

ok "Kubernetes state, PKI, etcd, logs and temp files fully removed"

# =============================================================================
step "8/11" "Remove CNI plugins · config · virtual interfaces"
# =============================================================================

# Release Calico's cgroup mount before deleting its state directory.
unmount_calico_cgroup

purge_paths \
  /opt/cni \
  /etc/cni \
  /var/lib/cni \
  /run/cni

# ── Calico ────────────────────────────────────────────────────────────────────
if [[ -z "${CNI_PLUGIN}" || "${CNI_PLUGIN}" == "calico" ]]; then
  ip link delete vxlan.calico 2>/dev/null || true
  ip link delete tunl0        2>/dev/null || true
  # Remove all calico-named interfaces
  ip link show 2>/dev/null \
    | grep -oP '(?<=\d: )\S+(?=@|:)' \
    | grep -E '^cali' \
    | while read -r iface; do ip link delete "${iface}" 2>/dev/null || true; done
  purge_paths \
    /var/lib/calico \
    /etc/calico \
    /var/run/calico \
    /run/calico \
    /run/nodeagent
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
step "9/11" "Remove Kubernetes/CNI firewall state · IPVS · pod routes"
# =============================================================================

# Never flush the complete host firewall during a Kubernetes teardown.  That
# can remove unrelated security rules and can also disconnect SSH.  Remove
# only Kubernetes/CNI chains and their jump rules.
cleanup_iptables() {
  local family_cmd="$1" table chain
  for table in nat filter mangle raw; do
    while read -r chain; do
      [[ -n "$chain" ]] || continue
      "$family_cmd" -t "$table" -F "$chain" 2>/dev/null || true
      "$family_cmd" -t "$table" -X "$chain" 2>/dev/null || true
    done < <("$family_cmd" -t "$table" -S 2>/dev/null | awk '/^-N (KUBE|CALI|cali|CALICO|FLANNEL|WEAVE)/ {print $2}' | sort -u)
  done
}

command -v iptables >/dev/null 2>&1 && cleanup_iptables iptables
command -v ip6tables >/dev/null 2>&1 && cleanup_iptables ip6tables

if command -v ipvsadm &>/dev/null; then
  ipvsadm --clear 2>/dev/null || true
  info "IPVS table cleared"
fi

# Remove only known Kubernetes/CNI pod/service routes.
ip route show 2>/dev/null | awk '$1 ~ /^(10\.244\.|10\.96\.|10\.32\.)/ {print}' | \
  while IFS= read -r route; do
    [[ -n "$route" ]] && ip route del $route 2>/dev/null || true
  done

ok "Kubernetes/CNI firewall state, IPVS, and pod routes cleaned"

# =============================================================================
step "10/11" "Remove kernel module config · sysctl overrides"
# =============================================================================

purge_paths \
  /etc/modules-load.d/k8s.conf \
  /etc/sysctl.d/99-k8s.conf \
  /etc/sysctl.d/k8s.conf \
  /etc/crictl.yaml

for mod in br_netfilter overlay; do
  if lsmod 2>/dev/null | grep -q "^${mod}"; then
    modprobe -r "${mod}" 2>/dev/null || true
    info "Unloaded kernel module: ${mod}"
  fi
done

sysctl --system -q 2>/dev/null || true
ok "Kernel module config and sysctl overrides removed"

# =============================================================================
step "11/11" "Reload systemd · restore fstab"
# =============================================================================

systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed  2>/dev/null || true
ok "systemd reloaded — removed units no longer visible"

# Restore swap if setup script backed up fstab
if [[ -f /etc/fstab.bak ]]; then
  info "fstab.bak found — restoring swap entries"
  while IFS= read -r line; do
    echo "$line" | grep -qi swap && {
      grep -qF "${line}" /etc/fstab || echo "${line}" >> /etc/fstab
    }
  done < /etc/fstab.bak
  swapon -a 2>/dev/null || true
  ok "Swap restored from fstab.bak"
else
  info "No fstab.bak — swap not restored"
fi

# =============================================================================
echo -e "\n  ${GR}+================================================================+${NC}"
echo -e "  ${GR}|        COMPLETE TEARDOWN FINISHED                              |${NC}"
echo -e "  ${GR}+================================================================+${NC}"
echo -e "  Host    : $(hostname)"
echo -e "  OS      : ${OS_ID} ${OS_VER}"
echo -e "  Runtime : ${RUNTIME}  — fully removed"
echo -e "  CNI     : ${CNI_PLUGIN:-all}  — fully removed"
echo -e ""
echo -e "  Removed:"
echo -e "    kubeadm · kubelet · kubectl · crictl · calicoctl"
echo -e "    containerd  (pkg · config · /var/lib/containerd · socket · units · logs)"
echo -e "    CRI-O       (pkg · config · /var/lib/crio · socket · units · logs)"
echo -e "    CNI plugins: calico + flannel + weave"
echo -e "    /etc/kubernetes · /var/lib/etcd · /var/lib/kubelet · PKI certs"
echo -e "    /root/.kube · all user ~/.kube · kubeadm-config.yaml"
echo -e "    Package repos and keyrings (apt/dnf)"
echo -e "    All temp files and join-command tokens"
echo -e "    Kernel module config · sysctl overrides"
echo -e "    iptables · ip6tables · ipvs · CNI routes"
echo -e "    systemd units reloaded — node is fully clean"
echo -e ""
echo -e "  The node is ready to re-provision."
echo ""
