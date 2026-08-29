#!/usr/bin/env bash
# =============================================================================
#  03-linux-destroy.sh — Kubernetes Node COMPLETE Teardown
#
#  Runtime-aware, idempotent teardown for:
#    Ubuntu 22/24 | Debian-family | RHEL/Rocky/Alma/Fedora 8/9
#
#  Jenkins:
#    export RUNTIME=containerd|crio
#    export CNI_PLUGIN=calico|flannel|weave
#    sudo -E bash /tmp/03-linux-destroy.sh
#
#  IMPORTANT:
#    - Only the selected CRI runtime is removed.
#    - Mounted trees are always unmounted before deletion.
#    - The host firewall is NOT flushed wholesale.
#    - Existing host networking/storage unrelated to Kubernetes is preserved.
# =============================================================================

set -uo pipefail

RUNTIME="${RUNTIME:-containerd}"
CNI_PLUGIN="${CNI_PLUGIN:-}"

CY='\033[0;36m'; GR='\033[0;32m'; RD='\033[0;31m'
YL='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n  ${CY}[$1]${NC} $2\n  $(printf '%0.s-' {1..66})"; }
ok()   { echo -e "  ${GR}[OK]${NC}   $*"; }
warn() { echo -e "  ${YL}[WARN]${NC} $*"; }
fail() { echo -e "  ${RD}[FAIL]${NC}  $*"; }
info() { echo -e "  ${CY}[....]${NC} $*"; }
gone() { echo -e "  ${GR}[DEL]${NC}  $*"; }

FAILURES=0
command -v sudo >/dev/null 2>&1 || true

record_failure() {
  FAILURES=$((FAILURES + 1))
  fail "$*"
}

path_exists() {
  [[ -e "$1" || -L "$1" ]]
}

# Delete ordinary paths only after mounted descendants have been released.
purge_paths() {
  local p
  for p in "$@"; do
    if path_exists "$p"; then
      if mountpoint -q "$p" 2>/dev/null; then
        warn "Refusing to delete mounted path: $p"
        record_failure "Mounted path remains: $p"
        continue
      fi
      rm -rf -- "$p" 2>/dev/null || {
        record_failure "Unable to remove: $p"
        continue
      }
      gone "$p"
    fi
  done
}

stop_service() {
  local svc="$1"
  if systemctl list-unit-files --full 2>/dev/null | grep -Eq "^${svc}\.service[[:space:]]"; then
    systemctl stop "$svc" 2>/dev/null || true
    systemctl disable "$svc" 2>/dev/null || true
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

remove_pkg_zypper() {
  zypper --non-interactive remove --clean-deps "$@" 2>/dev/null || true
}

pkg_installed() {
  case "$PKG_MGR" in
    apt)    dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q 'install ok installed' ;;
    dnf)    rpm -q "$1" >/dev/null 2>&1 ;;
    zypper) rpm -q "$1" >/dev/null 2>&1 ;;
    *)      return 1 ;;
  esac
}

# Unmount every mount at/below root, deepest first. Normal unmount is preferred;
# lazy unmount is used only as a fallback so teardown can finish cleanly.
unmount_tree() {
  local root="$1" mnt
  [[ -d "$root" || -e "$root" ]] || return 0

  if command -v findmnt >/dev/null 2>&1; then
    while IFS= read -r mnt; do
      [[ -n "$mnt" ]] || continue
      if umount "$mnt" 2>/dev/null; then
        info "Unmounted: $mnt"
      elif umount -l "$mnt" 2>/dev/null; then
        info "Lazy-unmounted: $mnt"
      else
        warn "Unable to unmount: $mnt"
        record_failure "Mount remains: $mnt"
      fi
    done < <(findmnt -Rno TARGET -- "$root" 2>/dev/null | awk 'NF' | sort -r)
  else
    if mountpoint -q "$root" 2>/dev/null; then
      umount "$root" 2>/dev/null || umount -l "$root" 2>/dev/null || {
        record_failure "Unable to unmount: $root"
      }
    fi
  fi
}

verify_no_mounts_under() {
  local root="$1" m
  [[ -e "$root" ]] || return 0
  if command -v findmnt >/dev/null 2>&1; then
    m="$(findmnt -Rno TARGET -- "$root" 2>/dev/null | awk 'NF' | sort -r | head -n1)"
    if [[ -n "$m" ]]; then
      record_failure "Mount still present under $root: $m"
      return 1
    fi
  fi
  return 0
}

unmount_calico_cgroup() {
  unmount_tree /var/run/calico/cgroup
  unmount_tree /run/calico/cgroup
}

# Runtime-specific process cleanup. Do NOT stop/remove an unrelated runtime.
stop_selected_runtime() {
  case "$RUNTIME" in
    containerd)
      stop_service containerd
      ;;
    crio)
      stop_service crio
      stop_service cri-o
      ;;
  esac
}

# Discover and stop runtime processes before touching their state directories.
kill_selected_runtime_processes() {
  local proc
  case "$RUNTIME" in
    containerd)
      for proc in containerd containerd-shim containerd-shim-runc-v1 containerd-shim-runc-v2; do
        if pgrep -x "$proc" >/dev/null 2>&1; then
          info "Force-killing lingering process: $proc"
          pkill -9 -x "$proc" 2>/dev/null || true
        fi
      done
      ;;
    crio)
      for proc in crio conmon; do
        if pgrep -x "$proc" >/dev/null 2>&1; then
          info "Force-killing lingering process: $proc"
          pkill -9 -x "$proc" 2>/dev/null || true
        fi
      done
      ;;
  esac
}

# Remove only known Kubernetes/CNI iptables chains and their rules. Never flush
# the complete host firewall because that can remove unrelated security rules.
cleanup_iptables() {
  local family_cmd="$1" table chain
  for table in nat filter mangle raw; do
    while read -r chain; do
      [[ -n "$chain" ]] || continue
      "$family_cmd" -t "$table" -F "$chain" 2>/dev/null || true
      "$family_cmd" -t "$table" -X "$chain" 2>/dev/null || true
    done < <(
      "$family_cmd" -t "$table" -S 2>/dev/null |
      awk '/^-N (KUBE|CALI|cali|CALICO|FLANNEL|WEAVE|WEAVE-NPC|WEAVE-EXPOSE)/ {print $2}' |
      sort -u
    )
  done
}

# =============================================================================
# Detect OS / package manager
# =============================================================================
if [[ -f /etc/os-release ]]; then
  # shellcheck disable=SC1091
  source /etc/os-release
  OS_ID="${ID:-unknown}"
  OS_VER="${VERSION_ID%%.*}"
else
  OS_ID="unknown"; OS_VER="?"
fi

if [[ "$OS_ID" =~ ^(ubuntu|debian|linuxmint|pop|elementary|kali|raspbian)$ ]]; then
  PKG_MGR="apt"
elif [[ "$OS_ID" =~ ^(rhel|centos|rocky|almalinux|fedora|ol|scientific)$ ]]; then
  PKG_MGR="dnf"
elif [[ "$OS_ID" =~ ^(opensuse|sles|suse)$ ]]; then
  PKG_MGR="zypper"
elif command -v apt-get >/dev/null 2>&1; then
  PKG_MGR="apt"
elif command -v dnf >/dev/null 2>&1; then
  PKG_MGR="dnf"
elif command -v zypper >/dev/null 2>&1; then
  PKG_MGR="zypper"
else
  PKG_MGR="unknown"
fi

case "$RUNTIME" in
  containerd|crio) ;;
  *)
    echo -e "${RD}ERROR:${NC} Unsupported RUNTIME='$RUNTIME'. Use containerd or crio."
    exit 2
    ;;
esac

if [[ "$CNI_PLUGIN" != "" && "$CNI_PLUGIN" != "calico" &&
      "$CNI_PLUGIN" != "flannel" && "$CNI_PLUGIN" != "weave" ]]; then
  echo -e "${RD}ERROR:${NC} Unsupported CNI_PLUGIN='$CNI_PLUGIN'."
  exit 2
fi

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
# 1/11 kubeadm reset
# =============================================================================
step "1/11" "kubeadm reset"

case "$RUNTIME" in
  containerd) CRI_SOCKET="unix:///run/containerd/containerd.sock" ;;
  crio)       CRI_SOCKET="unix:///var/run/crio/crio.sock" ;;
esac

if command -v kubeadm >/dev/null 2>&1; then
  if [[ -n "$CRI_SOCKET" ]]; then
    kubeadm reset -f --cri-socket "$CRI_SOCKET" \
      --ignore-preflight-errors=all 2>/dev/null || true
  else
    kubeadm reset -f --ignore-preflight-errors=all 2>/dev/null || true
  fi
  ok "kubeadm reset complete"
else
  warn "kubeadm not installed — skipping reset"
fi

# =============================================================================
# 2/11 Stop Kubernetes + SELECTED runtime
# =============================================================================
step "2/11" "Stop Kubernetes and selected runtime services"

for svc in kubelet kube-proxy; do
  stop_service "$svc"
done

stop_selected_runtime

# Docker is deliberately NOT stopped: it is an independent host runtime and
# may be used by workloads outside this Kubernetes installation.

for proc in kube-apiserver kube-controller-manager kube-scheduler etcd; do
  if pgrep -x "$proc" >/dev/null 2>&1; then
    info "Force-killing lingering process: $proc"
    pkill -9 -x "$proc" 2>/dev/null || true
  fi
done

kill_selected_runtime_processes
ok "Kubernetes services and selected runtime stopped"

# =============================================================================
# 3/11 Kubernetes packages
# =============================================================================
step "3/11" "Remove Kubernetes packages (kubelet · kubeadm · kubectl · crictl)"

case "$PKG_MGR" in
  apt)
    apt-mark unhold kubelet kubeadm kubectl 2>/dev/null || true
    remove_pkg_apt kubelet kubeadm kubectl kubernetes-cni cri-tools
    DEBIAN_FRONTEND=noninteractive apt-get autoremove --purge -y -q 2>/dev/null || true
    ;;
  dnf)
    dnf versionlock delete kubelet kubeadm kubectl cri-tools kubernetes-cni 2>/dev/null || true
    remove_pkg_dnf kubelet kubeadm kubectl kubernetes-cni cri-tools
    ;;
  zypper)
    remove_pkg_zypper kubelet kubeadm kubectl cri-tools kubernetes-cni
    ;;
  *)
    warn "No supported package manager detected"
    ;;
esac

purge_paths \
  /usr/bin/kubeadm /usr/bin/kubelet /usr/bin/kubectl \
  /usr/local/bin/kubectl /usr/bin/crictl /usr/local/bin/crictl \
  /usr/local/bin/calicoctl

ok "Kubernetes packages cleaned"

# =============================================================================
# 4/11 Runtime-aware removal
# =============================================================================
if [[ "$RUNTIME" == "containerd" ]]; then
  step "4/11" "Remove containerd — packages · config · data · sockets · logs"

  stop_service containerd
  kill_selected_runtime_processes

  # Only containerd is removed. CRI-O and /var/lib/containers are preserved.
  case "$PKG_MGR" in
    apt)
      remove_pkg_apt containerd.io containerd
      ;;
    dnf)
      remove_pkg_dnf containerd.io containerd
      ;;
    zypper)
      remove_pkg_zypper containerd
      ;;
  esac

  # Release any runtime/kubelet mounts before deleting state.
  unmount_tree /var/lib/containerd
  unmount_tree /run/containerd
  unmount_tree /var/run/containerd

  verify_no_mounts_under /var/lib/containerd
  verify_no_mounts_under /run/containerd
  verify_no_mounts_under /var/run/containerd

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
    /usr/local/bin/ctr

  # runc can be shared by other container runtimes. Do not blindly delete it.
  if ! pkg_installed runc 2>/dev/null; then
    purge_paths /usr/bin/runc /usr/local/bin/runc /usr/sbin/runc
  else
    info "Preserving runc package because it remains installed"
  fi

  ok "containerd cleanup complete; CRI-O data preserved"

else
  step "4/11" "Preserve containerd — removing only CRI-O"

  info "RUNTIME=crio: containerd package, config and data are preserved"

  # Ensure no CRI-O process keeps /var/lib/containers busy.
  stop_service crio
  stop_service cri-o
  kill_selected_runtime_processes

  case "$PKG_MGR" in
    apt)
      remove_pkg_apt cri-o cri-o-runc
      ;;
    dnf)
      remove_pkg_dnf cri-o
      ;;
    zypper)
      remove_pkg_zypper cri-o
      ;;
  esac

  # /var/lib/containers may contain overlay mounts. Never rm -rf it directly.
  # Unmount every nested mount first.
  unmount_tree /var/lib/containers
  unmount_tree /var/lib/crio
  unmount_tree /var/run/crio
  unmount_tree /run/crio

  verify_no_mounts_under /var/lib/containers
  verify_no_mounts_under /var/lib/crio
  verify_no_mounts_under /var/run/crio
  verify_no_mounts_under /run/crio

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

  # /var/lib/containers is shared Podman/Buildah/CRI-O storage on many systems.
  # Do NOT delete it automatically merely because CRI-O was removed.
  if [[ -d /var/lib/containers ]]; then
    warn "Preserving /var/lib/containers because it may belong to Podman/Buildah/other containers"
  fi

  ok "CRI-O cleanup complete; containerd data preserved"
fi

# =============================================================================
# 5/11 Runtime verification
# =============================================================================
step "5/11" "Verify selected runtime is stopped and state is safe"

if [[ "$RUNTIME" == "containerd" ]]; then
  if pgrep -x containerd >/dev/null 2>&1; then
    record_failure "containerd process still running"
  else
    ok "containerd process not running"
  fi
else
  if pgrep -x crio >/dev/null 2>&1; then
    record_failure "CRI-O process still running"
  else
    ok "CRI-O process not running"
  fi
fi

# =============================================================================
# 6/11 Repositories / keyrings
# =============================================================================
step "6/11" "Remove Kubernetes and runtime package repositories / keyrings"

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

# Remove only known cache material for removed repositories.
if [[ "$PKG_MGR" == "dnf" && -d /var/cache/dnf ]]; then
  for cache in kubernetes docker-ce-stable cri-o; do
    find /var/cache/dnf -maxdepth 2 -name "${cache}*" \
      -exec rm -rf -- {} + 2>/dev/null || true
  done
fi

# Do not run apt-get update here: the purpose is teardown, and remaining
# third-party repositories may be unavailable. Avoid adding unrelated failure.
ok "Known Kubernetes/runtime repositories and keyrings removed"

# =============================================================================
# 7/11 Kubernetes state / kubeconfigs / etcd
# =============================================================================
step "7/11" "Remove Kubernetes state · config · PKI · etcd · kubeconfig · logs"

# Release kubelet/runtime mounts first.
for root in \
  /var/lib/kubelet \
  /run/kubernetes \
  /var/run/kubernetes \
  /var/lib/etcd \
  /var/lib/kube-proxy; do
  unmount_tree "$root"
done

verify_no_mounts_under /var/lib/kubelet
verify_no_mounts_under /var/lib/etcd

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

for d in /home/*/; do
  [[ -d "${d}.kube" ]] && purge_paths "${d}.kube"
done

ok "Kubernetes state, PKI, etcd, kubeconfigs and logs cleaned"

# =============================================================================
# 8/11 CNI
# =============================================================================
step "8/11" "Remove CNI plugins · config · virtual interfaces"

unmount_calico_cgroup

purge_paths /opt/cni /etc/cni /var/lib/cni /run/cni

if [[ -z "$CNI_PLUGIN" || "$CNI_PLUGIN" == "calico" ]]; then
  ip link delete vxlan.calico 2>/dev/null || true
  ip link delete tunl0 2>/dev/null || true

  ip -o link show 2>/dev/null |
    awk -F': ' '{print $2}' |
    sed 's/@.*//' |
    grep -E '^cali' |
    while read -r iface; do
      [[ -n "$iface" ]] && ip link delete "$iface" 2>/dev/null || true
    done

  unmount_tree /var/run/calico
  unmount_tree /run/calico

  purge_paths \
    /var/lib/calico \
    /etc/calico \
    /var/run/calico \
    /run/calico \
    /run/nodeagent

  info "Calico cleaned"
fi

if [[ -z "$CNI_PLUGIN" || "$CNI_PLUGIN" == "flannel" ]]; then
  ip link delete flannel.1 2>/dev/null || true
  ip link delete cni0 2>/dev/null || true
  purge_paths \
    /run/flannel \
    /var/run/flannel \
    /etc/kube-flannel \
    /var/lib/flannel
  info "Flannel cleaned"
fi

if [[ -z "$CNI_PLUGIN" || "$CNI_PLUGIN" == "weave" ]]; then
  ip link delete weave 2>/dev/null || true
  ip link delete dummy0 2>/dev/null || true
  ip link delete datapath 2>/dev/null || true

  for chain in WEAVE-NPC WEAVE-NPC-EGRESS WEAVE-NPC-DEFAULT \
               WEAVE-EXPOSE WEAVE; do
    iptables -t filter -F "$chain" 2>/dev/null || true
    iptables -t filter -X "$chain" 2>/dev/null || true
  done

  purge_paths \
    /var/lib/weave \
    /etc/weave \
    /run/weave \
    /var/run/weave
  info "Weave cleaned"
fi

# Catch-all for known Kubernetes CNI interfaces only.
ip -o link show 2>/dev/null |
  awk -F': ' '{print $2}' |
  sed 's/@.*//' |
  grep -E '^(cali|vxlan\.calico|flannel|weave)' |
  while read -r iface; do
    [[ -n "$iface" ]] || continue
    ip link delete "$iface" 2>/dev/null || true
    info "Removed stale interface: $iface"
  done

ok "CNI plugins and interfaces cleaned"

# =============================================================================
# 9/11 Firewall / IPVS / routes
# =============================================================================
step "9/11" "Remove Kubernetes/CNI firewall state · IPVS · pod routes"

command -v iptables >/dev/null 2>&1 && cleanup_iptables iptables
command -v ip6tables >/dev/null 2>&1 && cleanup_iptables ip6tables

if command -v ipvsadm >/dev/null 2>&1; then
  ipvsadm --clear 2>/dev/null || true
  info "IPVS table cleared"
fi

# Only remove well-known default Kubernetes pod/service CIDRs used by this
# provisioning workflow. Do not flush all routes.
ip route show 2>/dev/null |
  awk '$1 ~ /^(10\.244\.|10\.96\.|10\.32\.)/ {print}' |
  while IFS= read -r route; do
    [[ -n "$route" ]] && ip route del $route 2>/dev/null || true
  done

ok "Kubernetes/CNI firewall state, IPVS and known pod routes cleaned"

# =============================================================================
# 10/11 Kernel module config / sysctl
# =============================================================================
step "10/11" "Remove Kubernetes kernel module config · sysctl overrides"

purge_paths \
  /etc/modules-load.d/k8s.conf \
  /etc/sysctl.d/99-k8s.conf \
  /etc/sysctl.d/k8s.conf \
  /etc/crictl.yaml

for mod in br_netfilter overlay; do
  if lsmod 2>/dev/null | grep -q "^${mod}[[:space:]]"; then
    # Failure is non-fatal: another host process may still legitimately use it.
    if modprobe -r "$mod" 2>/dev/null; then
      info "Unloaded kernel module: $mod"
    else
      info "Preserving kernel module in use: $mod"
    fi
  fi
done

sysctl --system -q 2>/dev/null || true
ok "Kubernetes kernel module config and sysctl overrides removed"

# =============================================================================
# 11/11 systemd / fstab / final verification
# =============================================================================
step "11/11" "Reload systemd · restore fstab · final verification"

systemctl daemon-reload 2>/dev/null || true
systemctl reset-failed 2>/dev/null || true
ok "systemd reloaded"

if [[ -f /etc/fstab.bak ]]; then
  info "fstab.bak found — restoring swap entries"
  while IFS= read -r line; do
    if echo "$line" | grep -qi swap; then
      grep -qF "$line" /etc/fstab || echo "$line" >> /etc/fstab
    fi
  done < /etc/fstab.bak
  swapon -a 2>/dev/null || true
  ok "Swap restored from fstab.bak"
else
  info "No fstab.bak — swap not restored"
fi

# Final selected-runtime checks.
if [[ "$RUNTIME" == "containerd" ]]; then
  if systemctl is-active --quiet containerd 2>/dev/null; then
    record_failure "containerd service is still active"
  fi
  verify_no_mounts_under /var/lib/containerd
else
  if systemctl is-active --quiet crio 2>/dev/null ||
     systemctl is-active --quiet cri-o 2>/dev/null; then
    record_failure "CRI-O service is still active"
  fi
  verify_no_mounts_under /var/lib/crio
  verify_no_mounts_under /var/lib/containers
fi

# Kubernetes state should never remain mounted.
verify_no_mounts_under /etc/kubernetes
verify_no_mounts_under /var/lib/kubelet
verify_no_mounts_under /var/lib/etcd

if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "\n  ${GR}+================================================================+${NC}"
  echo -e "  ${GR}|        COMPLETE TEARDOWN FINISHED — SUCCESS                  |${NC}"
  echo -e "  ${GR}+================================================================+${NC}"
else
  echo -e "\n  ${YL}+================================================================+${NC}"
  echo -e "  ${YL}|        TEARDOWN FINISHED — ${FAILURES} CHECK(S) NEED REVIEW        |${NC}"
  echo -e "  ${YL}+================================================================+${NC}"
fi

echo -e "  Host    : $(hostname)"
echo -e "  OS      : ${OS_ID} ${OS_VER}"
echo -e "  Runtime : ${RUNTIME}"
echo -e "  CNI     : ${CNI_PLUGIN:-all}"
echo -e ""
echo -e "  Removed / cleaned:"
echo -e "    kubeadm · kubelet · kubectl · crictl · calicoctl"
if [[ "$RUNTIME" == "containerd" ]]; then
  echo -e "    containerd runtime state (selected runtime)"
  echo -e "    CRI-O was NOT removed"
  echo -e "    /var/lib/containers was NOT removed"
else
  echo -e "    CRI-O runtime state (selected runtime)"
  echo -e "    containerd was NOT removed"
  echo -e "    /var/lib/containers was preserved when shared"
fi
echo -e "    Kubernetes state · etcd · PKI · kubeconfigs · CNI"
echo -e "    Known Kubernetes/CNI firewall chains · IPVS · known pod routes"
echo -e "    Kubernetes kernel-module config · sysctl overrides"
echo -e "    Known Kubernetes/runtime repositories and keyrings"
echo -e ""
if [[ "$FAILURES" -eq 0 ]]; then
  echo -e "  The node is ready to re-provision."
  exit 0
else
  echo -e "  Review the WARN/FAIL entries above before re-provisioning."
  exit 1
fi
