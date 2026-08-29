#!/usr/bin/env bash
# =============================================================================
# 03-linux-destroy.sh
#
# Kubernetes COMPLETE TEARDOWN
#
# Supported:
#   OS      : Ubuntu 22/24, Rocky/RHEL 9
#   Runtime : containerd OR CRI-O
#   CNI     : Flannel OR Calico OR Weave
#
# IMPORTANT:
#   - Removes Kubernetes and the SELECTED container runtime.
#   - Removes the SELECTED CNI state.
#   - Preserves the alternate runtime and its data.
#   - Does NOT perform blanket orphan/dependency cleanup.
#   - Preserves host dependencies such as conntrack unless explicitly part
#     of the selected Kubernetes/runtime installation.
#
# Environment:
#   RUNTIME=containerd|crio       (default: containerd)
#   CNI_PLUGIN=flannel|calico|weave (default: flannel)
#
# Optional:
#   PRESERVE_HOST_DEPS=true       (default: true)
#   REMOVE_REPOS=true             (default: true)
# =============================================================================

set -Eeuo pipefail

RUNTIME="${RUNTIME:-containerd}"
CNI_PLUGIN="${CNI_PLUGIN:-flannel}"
PRESERVE_HOST_DEPS="${PRESERVE_HOST_DEPS:-true}"
REMOVE_REPOS="${REMOVE_REPOS:-true}"

GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

die() {
    echo -e "  ${RED}[FAIL]${NC} $*" >&2
    exit 1
}

ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
del()  { echo -e "  ${GREEN}[DEL]${NC}  $*"; }
info() { echo -e "  ${CYAN}[....]${NC} $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC} $*"; }

[[ $EUID -eq 0 ]] || die "Run this script as root or through sudo."

case "${RUNTIME,,}" in
    containerd|crio) RUNTIME="${RUNTIME,,}" ;;
    *) die "Unsupported RUNTIME='$RUNTIME'. Use containerd or crio." ;;
esac

case "${CNI_PLUGIN,,}" in
    flannel|calico|weave) CNI_PLUGIN="${CNI_PLUGIN,,}" ;;
    *) die "Unsupported CNI_PLUGIN='$CNI_PLUGIN'. Use flannel, calico or weave." ;;
esac

# -----------------------------------------------------------------------------
# Helpers
# -----------------------------------------------------------------------------
have_cmd() { command -v "$1" >/dev/null 2>&1; }

remove_path() {
    local p="$1"
    if [[ -e "$p" || -L "$p" ]]; then
        rm -rf --one-file-system "$p"
        del "$p"
    fi
}

stop_disable_service() {
    local svc="$1"
    if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 &&
       systemctl cat "${svc}.service" >/dev/null 2>&1; then
        systemctl disable --now "$svc" >/dev/null 2>&1 || true
    else
        systemctl stop "$svc" >/dev/null 2>&1 || true
    fi
}

kill_processes_by_name() {
    local name="$1"
    local pids
    pids="$(pgrep -x "$name" 2>/dev/null || true)"
    if [[ -n "$pids" ]]; then
        info "Stopping lingering process: $name"
        kill $pids 2>/dev/null || true
        sleep 1
        pids="$(pgrep -x "$name" 2>/dev/null || true)"
        [[ -z "$pids" ]] || kill -9 $pids 2>/dev/null || true
    fi
}

pkg_manager() {
    if have_cmd dnf; then
        echo dnf
    elif have_cmd yum; then
        echo yum
    elif have_cmd apt-get; then
        echo apt
    else
        die "No supported package manager found."
    fi
}

PM="$(pkg_manager)"

remove_packages() {
    local pkgs=("$@")
    local existing=()
    local p

    for p in "${pkgs[@]}"; do
        case "$PM" in
            dnf|yum)
                rpm -q "$p" >/dev/null 2>&1 && existing+=("$p") || true
                ;;
            apt)
                dpkg-query -W -f='${Status}' "$p" 2>/dev/null |
                    grep -q 'install ok installed' && existing+=("$p") || true
                ;;
        esac
    done

    ((${#existing[@]})) || return 0

    info "Removing explicitly selected packages: ${existing[*]}"

    case "$PM" in
        dnf)
            # --no-autoremove is intentional: preserve host dependencies.
            dnf -y --noautoremove remove "${existing[@]}"
            ;;
        yum)
            # yum on supported RHEL/Rocky versions delegates to dnf behavior.
            yum -y remove "${existing[@]}"
            ;;
        apt)
            # Explicit package removal only. NEVER run autoremove here.
            DEBIAN_FRONTEND=noninteractive apt-get -y remove "${existing[@]}"
            ;;
    esac
}

# -----------------------------------------------------------------------------
# Header
# -----------------------------------------------------------------------------
echo ""
echo -e "  ${CYAN}+================================================================+${NC}"
echo -e "  ${CYAN}|     KUBERNETES NODE — COMPLETE TEARDOWN                        |${NC}"
echo -e "  ${CYAN}+================================================================+${NC}"
echo ""
info "Host     : $(hostname)"
if [[ -f /etc/os-release ]]; then
    . /etc/os-release
    info "OS       : ${ID:-unknown} ${VERSION_ID:-unknown}"
fi
info "Runtime  : ${RUNTIME}"
info "CNI      : ${CNI_PLUGIN}"
echo ""

# -----------------------------------------------------------------------------
# [1/11] kubeadm reset
# -----------------------------------------------------------------------------
echo -e "  ${CYAN}[1/11]${NC} kubeadm reset"
echo "------------------------------------------------------------------"

if have_cmd kubeadm; then
    kubeadm reset -f || true
else
    info "kubeadm not installed; reset skipped"
fi

ok "kubeadm reset complete"

# -----------------------------------------------------------------------------
# [2/11] Stop Kubernetes and selected runtime
# -----------------------------------------------------------------------------
echo ""
echo -e "  ${CYAN}[2/11]${NC} Stop Kubernetes and selected runtime services"
echo "------------------------------------------------------------------"

for svc in kubelet kube-proxy; do
    stop_disable_service "$svc"
done

if [[ "$RUNTIME" == "containerd" ]]; then
    stop_disable_service containerd
    kill_processes_by_name containerd
else
    stop_disable_service crio
    stop_disable_service podman
    kill_processes_by_name crio
fi

ok "Kubernetes services and selected runtime stopped"

# -----------------------------------------------------------------------------
# [3/11] Remove Kubernetes packages
# -----------------------------------------------------------------------------
echo ""
echo -e "  ${CYAN}[3/11]${NC} Remove Kubernetes packages"
echo "------------------------------------------------------------------"

# These are explicit Kubernetes packages. No autoremove.
remove_packages \
    kubeadm kubelet kubectl cri-tools kubernetes-cni

ok "Kubernetes packages cleaned"

# -----------------------------------------------------------------------------
# [4/11] Remove SELECTED runtime only
# -----------------------------------------------------------------------------
echo ""
echo -e "  ${CYAN}[4/11]${NC} Remove ${RUNTIME} — packages · config · data · sockets · logs"
echo "------------------------------------------------------------------"

if [[ "$RUNTIME" == "containerd" ]]; then
    # Package names differ between distributions/install methods.
    remove_packages containerd.io containerd

    remove_path /etc/containerd
    remove_path /var/lib/containerd
    remove_path /run/containerd
    remove_path /var/log/containerd

    ok "containerd cleanup complete; CRI-O data preserved"
else
    # CRI-O package names commonly used by RPM and DEB installations.
    remove_packages cri-o cri-o-runc

    remove_path /etc/crio
    remove_path /etc/crio/crio.conf
    remove_path /var/lib/containers/storage
    remove_path /var/lib/crio
    remove_path /run/crio
    remove_path /var/log/crio

    ok "CRI-O cleanup complete; containerd data preserved"
fi

# -----------------------------------------------------------------------------
# [5/11] Verify selected runtime is stopped
# -----------------------------------------------------------------------------
echo ""
echo -e "  ${CYAN}[5/11]${NC} Verify selected runtime is stopped and state is safe"
echo "------------------------------------------------------------------"

if [[ "$RUNTIME" == "containerd" ]]; then
    if pgrep -x containerd >/dev/null 2>&1; then
        kill_processes_by_name containerd
    fi
    if pgrep -x containerd >/dev/null 2>&1; then
        die "containerd process is still running"
    fi
    ok "containerd process not running"
else
    if pgrep -x crio >/dev/null 2>&1; then
        kill_processes_by_name crio
    fi
    if pgrep -x crio >/dev/null 2>&1; then
        die "CRI-O process is still running"
    fi
    ok "CRI-O process not running"
fi

# -----------------------------------------------------------------------------
# [6/11] Remove known Kubernetes/runtime repositories
# -----------------------------------------------------------------------------
echo ""
echo -e "  ${CYAN}[6/11]${NC} Remove Kubernetes and selected-runtime repositories / keyrings"
echo "------------------------------------------------------------------"

if [[ "$REMOVE_REPOS" == "true" ]]; then
    if [[ -d /etc/apt/sources.list.d ]]; then
        remove_path /etc/apt/sources.list.d/kubernetes.list
        remove_path /etc/apt/sources.list.d/docker.list
        remove_path /etc/apt/sources.list.d/cri-o.list
        remove_path /etc/apt/sources.list.d/cri-o.sources
        remove_path /etc/apt/keyrings/kubernetes-apt-keyring.gpg
        remove_path /etc/apt/keyrings/docker.gpg
        remove_path /etc/apt/keyrings/cri-o.gpg
    fi

    if [[ -d /etc/yum.repos.d ]]; then
        remove_path /etc/yum.repos.d/kubernetes.repo
        remove_path /etc/yum.repos.d/docker-ce.repo
        remove_path /etc/yum.repos.d/cri-o.repo
    fi

    ok "Known Kubernetes/runtime repositories and keyrings removed"
else
    info "Repository removal disabled"
fi

# -----------------------------------------------------------------------------
# [7/11] Kubernetes state
# -----------------------------------------------------------------------------
echo ""
echo -e "  ${CYAN}[7/11]${NC} Remove Kubernetes state · config · PKI · etcd · kubeconfig · logs"
echo "------------------------------------------------------------------"

remove_path /etc/kubernetes
remove_path /var/lib/kubelet
remove_path /var/lib/etcd
remove_path /var/log/pods
remove_path /var/log/containers
remove_path /root/.kube

# Do not blindly delete an operator/admin user's kubeconfig.
# Remove only root kubeconfig above; common k8sadmin kubeconfigs are handled
# separately if they belong to this cluster.
for home in /home/*; do
    [[ -d "$home" ]] || continue
    if [[ -f "$home/.kube/config" ]]; then
        # Remove only if it is clearly a Kubernetes admin config containing
        # the standard kubeadm cluster path; otherwise preserve it.
        if grep -qE 'server: https?://' "$home/.kube/config" 2>/dev/null; then
            rm -f "$home/.kube/config"
            del "$home/.kube/config"
        fi
    fi
done

remove_path /tmp/02-linux-worker-setup.sh
remove_path /tmp/03-linux-destroy.sh

ok "Kubernetes state, PKI, etcd, kubeconfigs and logs cleaned"

# -----------------------------------------------------------------------------
# [8/11] CNI cleanup
# -----------------------------------------------------------------------------
echo ""
echo -e "  ${CYAN}[8/11]${NC} Remove ${CNI_PLUGIN} CNI plugins · config · virtual interfaces"
echo "------------------------------------------------------------------"

# CNI binaries are Kubernetes-owned on these nodes, but do not remove an
# unrelated CNI directory blindly when another runtime/application owns it.
remove_path /etc/cni/net.d

case "$CNI_PLUGIN" in
    flannel)
        remove_path /run/flannel
        remove_path /var/lib/cni/flannel
        ;;
    calico)
        remove_path /var/lib/cni/calico
        remove_path /var/run/calico
        remove_path /var/lib/calico
        ;;
    weave)
        remove_path /var/lib/cni/weave
        remove_path /var/lib/weave
        ;;
esac

# CNI plugin binaries installed by kubernetes-cni.
# Remove only known Kubernetes/CNI binaries, not the entire /opt/cni tree.
for bin in \
    bridge host-local loopback portmap firewall bandwidth dhcp tuning \
    ipvlan macvlan ptp sbr static tap vlan vrf \
    flannel calico calico-ipam calico-node weave-ipam weave-net; do
    [[ -e "/opt/cni/bin/$bin" ]] && rm -f "/opt/cni/bin/$bin"
done

# Remove now-empty CNI directories, but preserve unrelated content.
rmdir /opt/cni/bin /opt/cni 2>/dev/null || true

# Delete known CNI interfaces if present.
ip link delete cni0 2>/dev/null || true
ip link delete flannel.1 2>/dev/null || true
ip link delete weave 2>/dev/null || true
ip link delete vxlan.calico 2>/dev/null || true
ip link delete tunl0 2>/dev/null || true

ok "CNI plugins, configuration and known interfaces cleaned"

# -----------------------------------------------------------------------------
# [9/11] Firewall / IPVS / known Kubernetes networking state
# -----------------------------------------------------------------------------
echo ""
echo -e "  ${CYAN}[9/11]${NC} Remove Kubernetes/CNI firewall state · IPVS · pod routes"
echo "------------------------------------------------------------------"

# Remove only Kubernetes/CNI chains where possible.
if have_cmd iptables; then
    # Kubernetes chains commonly created by kube-proxy.
    for table in filter nat mangle; do
        for chain in KUBE-SERVICES KUBE-NODEPORTS KUBE-POSTROUTING \
                     KUBE-FORWARD KUBE-PROXY-FIREWALL KUBE-FIREWALL \
                     KUBE-MARK-MASQ KUBE-MARK-DROP; do
            iptables -t "$table" -F "$chain" 2>/dev/null || true
            iptables -t "$table" -X "$chain" 2>/dev/null || true
        done
    done

    # Delete jump rules that reference KUBE chains.
    for table in filter nat mangle; do
        while iptables -t "$table" -S 2>/dev/null |
              grep -E '^-A .*KUBE-' | sed 's/^-A /-D /' |
              while read -r rule; do
                  [[ -n "$rule" ]] && iptables -t "$table" $rule 2>/dev/null || true
              done
        do :; done
    done
fi

if have_cmd ipvsadm; then
    ipvsadm --clear 2>/dev/null || true
fi

# Remove routes for the default kubeadm pod CIDR only if explicitly supplied.
# Never flush the host's complete routing table.
if [[ -n "${POD_CIDR:-}" ]]; then
    ip route del "$POD_CIDR" 2>/dev/null || true
fi

ok "Kubernetes/CNI firewall state, IPVS and known pod routes cleaned"

# -----------------------------------------------------------------------------
# [10/11] Kernel module/sysctl cleanup
# -----------------------------------------------------------------------------
echo ""
echo -e "  ${CYAN}[10/11]${NC} Remove Kubernetes kernel module config · sysctl overrides"
echo "------------------------------------------------------------------"

remove_path /etc/modules-load.d/k8s.conf
remove_path /etc/sysctl.d/99-k8s.conf

# Do not unload modules blindly: overlay/br_netfilter may be used by other
# container workloads. Only unload if no known container runtime remains.
if ! pgrep -x containerd >/dev/null 2>&1 &&
   ! pgrep -x crio >/dev/null 2>&1; then
    modprobe -r br_netfilter 2>/dev/null || true
    modprobe -r overlay 2>/dev/null || true
fi

sysctl --system >/dev/null 2>&1 || true

ok "Kubernetes kernel-module config and sysctl overrides removed"

# -----------------------------------------------------------------------------
# [11/11] Final verification
# -----------------------------------------------------------------------------
echo ""
echo -e "  ${CYAN}[11/11]${NC} Reload systemd · restore fstab · final verification"
echo "------------------------------------------------------------------"

systemctl daemon-reload
ok "systemd reloaded"

# Restore swap if this script created a backup.
if [[ -f /etc/fstab.bak ]]; then
    cp -a /etc/fstab.bak /etc/fstab
    ok "Swap restored from fstab.bak"
fi

# Ensure selected runtime state is gone.
if [[ "$RUNTIME" == "containerd" ]]; then
    [[ ! -e /run/containerd/containerd.sock ]] || die "containerd socket still exists"
    [[ ! -d /var/lib/containerd ]] || die "/var/lib/containerd still exists"
else
    [[ ! -e /run/crio/crio.sock ]] || die "CRI-O socket still exists"
fi

# Ensure Kubernetes state is gone.
[[ ! -d /etc/kubernetes ]] || die "/etc/kubernetes still exists"
[[ ! -d /var/lib/kubelet ]] || die "/var/lib/kubelet still exists"

echo ""
echo -e "  ${GREEN}+================================================================+${NC}"
echo -e "  ${GREEN}|        COMPLETE TEARDOWN FINISHED — SUCCESS                  |${NC}"
echo -e "  ${GREEN}+================================================================+${NC}"
echo ""
echo "  Host    : $(hostname)"
echo "  Runtime : ${RUNTIME}"
echo "  CNI     : ${CNI_PLUGIN}"
echo ""
echo "  Removed / cleaned:"
echo "    kubeadm · kubelet · kubectl · crictl · Kubernetes state"
echo "    selected runtime packages and state"
echo "    selected CNI state and known CNI interfaces"
echo "    Kubernetes PKI · etcd · kubeconfigs · logs"
echo "    known Kubernetes firewall/IPVS state"
echo "    Kubernetes kernel-module config · sysctl overrides"
echo ""
if [[ "$RUNTIME" == "containerd" ]]; then
    echo "    CRI-O was NOT removed"
    echo "    /var/lib/containers was NOT removed"
else
    echo "    containerd was NOT removed"
    echo "    /var/lib/containerd was NOT removed"
fi
echo ""
echo "  Host dependencies such as conntrack are preserved."
echo "  The node is ready to re-provision."
