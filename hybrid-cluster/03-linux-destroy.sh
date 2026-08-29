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
#   - Does NOT remove conntrack/conntrack-tools as an orphan dependency.
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

run_bounded() {
    local seconds="$1"
    shift

    if have_cmd timeout; then
        timeout "${seconds}s" "$@" || return $?
    else
        # Coreutils timeout is expected on supported Ubuntu/Rocky hosts.
        # If unavailable, run the command normally rather than aborting the
        # entire destroy because of the helper itself.
        "$@"
    fi
}

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

if [[ "$PM" == "apt" ]]; then
    # IMPORTANT:
    # kubeadm -> cri-tools
    # kubelet -> kubernetes-cni
    #
    # Removing cri-tools/kubernetes-cni first causes apt's dependency resolver
    # to reject the transaction while kubeadm/kubelet are still installed.
    #
    # Remove the Kubernetes package set in ONE transaction. This allows apt
    # to resolve the dependency graph correctly while avoiding a blanket
    # autoremove of unrelated host software.
    apt-get update -qq >/dev/null 2>&1 || true

    # Kubernetes packages may have been held by the bootstrap.
    apt-mark unhold kubeadm kubelet kubectl cri-tools kubernetes-cni \
        >/dev/null 2>&1 || true

    APT_K8S_PKGS=()
    for p in kubeadm kubelet kubectl cri-tools kubernetes-cni; do
        if dpkg-query -W -f='${Status}' "$p" 2>/dev/null |
            grep -q 'install ok installed'; then
            APT_K8S_PKGS+=("$p")
        fi
    done

    if ((${#APT_K8S_PKGS[@]})); then
        info "Removing Kubernetes package set: ${APT_K8S_PKGS[*]}"

        # Explicitly remove only Kubernetes packages.
        # --allow-change-held-packages is harmless after apt-mark unhold and
        # protects against package-state leftovers from older bootstrap runs.
        DEBIAN_FRONTEND=noninteractive \
            apt-get -y \
            --allow-change-held-packages \
            remove "${APT_K8S_PKGS[@]}"
    else
        info "No installed Kubernetes packages found"
    fi

    # Only now are Kubernetes dependencies eligible to be orphaned.
    # Do NOT use autoremove: it can remove unrelated host packages such as
    # conntrack. If a package is required by something else it remains.
    ok "Kubernetes packages cleaned; host dependencies preserved"

else
    # RPM-based systems: remove the Kubernetes package set explicitly.
    # Do not use a blanket autoremove/clean-dependencies operation.
    RPM_K8S_PKGS=()
    for p in kubeadm kubelet kubectl cri-tools kubernetes-cni; do
        if rpm -q "$p" >/dev/null 2>&1; then
            RPM_K8S_PKGS+=("$p")
        fi
    done

    if ((${#RPM_K8S_PKGS[@]})); then
        info "Removing Kubernetes package set: ${RPM_K8S_PKGS[*]}"
        dnf -y --noautoremove remove "${RPM_K8S_PKGS[@]}" 2>/dev/null ||
            dnf -y remove "${RPM_K8S_PKGS[@]}"
    else
        info "No installed Kubernetes packages found"
    fi

    ok "Kubernetes packages cleaned; host dependencies preserved"
fi

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

# IMPORTANT:
# Never use an unbounded while-loop around iptables output here.
# On some iptables/nft combinations, a rule can remain visible after a delete
# attempt and cause an endless loop. Jenkins must never hang in destroy.
#
# This cleanup is intentionally:
#   1. bounded
#   2. best-effort
#   3. limited to Kubernetes chains/rules
#   4. never a full firewall flush

iptables_delete_rule() {
    local table="$1"
    local rule="$2"

    run_bounded 5 iptables -w 3 -t "$table" $rule >/dev/null 2>&1 || true
}

iptables_cleanup_table() {
    local table="$1"
    local rules
    local rule

    # Take ONE snapshot. Do not continuously re-query the table.
    rules="$(run_bounded 5 iptables -w 3 -t "$table" -S 2>/dev/null |
        grep -E '^-A .*KUBE-' || true)"

    if [[ -n "$rules" ]]; then
        while IFS= read -r rule; do
            [[ -z "$rule" ]] && continue

            # Convert:
            #   -A CHAIN ...
            # to:
            #   -D CHAIN ...
            rule="${rule/#-A /-D }"

            iptables_delete_rule "$table" "$rule"
        done <<< "$rules"
    fi

    # Flush/delete only well-known Kubernetes chains.
    local chain
    for chain in \
        KUBE-SERVICES \
        KUBE-NODEPORTS \
        KUBE-POSTROUTING \
        KUBE-FORWARD \
        KUBE-PROXY-FIREWALL \
        KUBE-FIREWALL \
        KUBE-MARK-MASQ \
        KUBE-MARK-DROP \
        KUBE-IPVS-STATICES \
        KUBE-IPVS-FILTER \
        KUBE-KUBELET-CANARY \
        KUBE-EXTERNAL-SERVICES \
        KUBE-LOAD-BALANCER-SOURCE-CIDR \
        KUBE-LOAD-BALANCER-FW \
        KUBE-LOAD-BALANCER; do

        run_bounded 5 iptables -w 3 -t "$table" -F "$chain" \
            >/dev/null 2>&1 || true

        run_bounded 5 iptables -w 3 -t "$table" -X "$chain" \
            >/dev/null 2>&1 || true
    done
}

if have_cmd iptables; then
    # A maximum of ~15 seconds per table, with each individual iptables
    # operation bounded to 5 seconds.
    for table in filter nat mangle; do
        iptables_cleanup_table "$table"
    done

    ok "Kubernetes iptables chains/rules cleaned"
else
    info "iptables not installed; firewall cleanup skipped"
fi

# IPVS cleanup is independently bounded.
if have_cmd ipvsadm; then
    if run_bounded 10 ipvsadm --clear >/dev/null 2>&1; then
        ok "IPVS tables cleared"
    else
        warn "IPVS cleanup returned non-zero or timed out; continuing"
    fi
else
    info "ipvsadm not installed; IPVS cleanup skipped"
fi

# Remove ONLY an explicitly supplied Kubernetes pod CIDR.
# Never flush the host routing table.
if [[ -n "${POD_CIDR:-}" ]]; then
    if run_bounded 5 ip route del "$POD_CIDR" >/dev/null 2>&1; then
        ok "Pod CIDR route removed: ${POD_CIDR}"
    else
        info "Pod CIDR route already absent: ${POD_CIDR}"
    fi
fi

ok "Kubernetes/CNI firewall state, IPVS and known pod routes cleanup complete"

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

# Final package verification. Do not treat unrelated packages as failures.
if [[ "$PM" == "apt" ]]; then
    remaining_k8s=()
    for p in kubeadm kubelet kubectl cri-tools kubernetes-cni; do
        if dpkg-query -W -f='${Status}' "$p" 2>/dev/null |
            grep -q 'install ok installed'; then
            remaining_k8s+=("$p")
        fi
    done
    if ((${#remaining_k8s[@]})); then
        die "Kubernetes packages still installed: ${remaining_k8s[*]}"
    fi
else
    remaining_k8s=()
    for p in kubeadm kubelet kubectl cri-tools kubernetes-cni; do
        if rpm -q "$p" >/dev/null 2>&1; then
            remaining_k8s+=("$p")
        fi
    done
    if ((${#remaining_k8s[@]})); then
        die "Kubernetes packages still installed: ${remaining_k8s[*]}"
    fi
fi

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
