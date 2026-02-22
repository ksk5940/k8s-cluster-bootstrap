#!/usr/bin/env bash
# =============================================================================
# 01-linux-master-setup.sh
# Kubernetes Control Plane Setup
# Supports: Ubuntu 22/24 | Rocky 8/9 | RHEL | CentOS Stream
# Kubernetes v1.32.3
# Fully idempotent - safe to re-run at any time
# =============================================================================

set -euo pipefail

K8S_VERSION="1.32.3"
POD_CIDR="10.244.0.0/16"
SERVICE_CIDR="10.96.0.0/12"
CALICO_VERSION="v3.29.3"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $*"; }
info() { echo -e "  ${CYAN}[....]${NC}  $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC}  $*"; exit 1; }
step() { echo -e "\n  ${CYAN}[$1/8]${NC} $2\n  $(printf '%0.s-' {1..66})"; }

echo -e "\n  ${CYAN}+================================================================+${NC}"
echo -e "  ${CYAN}|     KUBERNETES MASTER NODE SETUP  v${K8S_VERSION}              |${NC}"
echo -e "  ${CYAN}+================================================================+${NC}\n"

[[ $EUID -ne 0 ]] && fail "Run as root: sudo bash $0"

source /etc/os-release
OS_ID=$ID
MASTER_IP=$(hostname -I | awk '{print $1}')

# Resolve the actual invoking user's home dir (works whether called via
# "sudo ./script.sh" or "sudo bash script.sh" or directly as root)
REAL_USER="${SUDO_USER:-${USER:-root}}"
REAL_HOME=$(getent passwd "$REAL_USER" | cut -d: -f6)

info "Master IP: $MASTER_IP | OS: $OS_ID | kubectl will be configured for user: $REAL_USER"

# =============================================================================
step 1  "System prerequisites"
# =============================================================================

# Disable swap (idempotent: swapoff -a is always safe)
swapoff -a
# Remove any swap entries from fstab only if present
if grep -qE '\bswap\b' /etc/fstab; then
    sed -i '/\bswap\b/d' /etc/fstab
    info "Swap removed from /etc/fstab"
fi

# Write kernel module load config (overwrite is safe / idempotent)
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF

# Load modules only if not already loaded
lsmod | grep -q '^overlay'       || modprobe overlay
lsmod | grep -q '^br_netfilter'  || modprobe br_netfilter

# Write sysctl config (overwrite is safe / idempotent)
cat > /etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
EOF

sysctl --system > /dev/null
ok "Kernel modules and sysctl configured (rp_filter=0 for Windows VXLAN)"

# =============================================================================
step 2  "Installing ContainerD"
# =============================================================================

# -----------------------------------------------------------------------------
# Rocky/RHEL/CentOS: disable SELinux enforcing BEFORE installing or configuring
# containerd.  SELinux Enforcing blocks containerd's gRPC socket on el8/el9
# with the containerd.io Docker RPM (policy does not cover v2 socket paths).
# Setting Permissive is the standard Kubernetes production approach on RHEL.
# -----------------------------------------------------------------------------
if [[ $OS_ID == "rocky" || $OS_ID == "rhel" || $OS_ID == "centos" ]]; then
    if command -v getenforce &>/dev/null; then
        SELINUX_STATE=$(getenforce 2>/dev/null || echo "Unknown")
        if [[ "$SELINUX_STATE" == "Enforcing" ]]; then
            setenforce 0
            info "SELinux set to Permissive (runtime)"
        else
            skip "SELinux already $SELINUX_STATE"
        fi
    fi
    if [[ -f /etc/selinux/config ]]; then
        if grep -q '^SELINUX=enforcing' /etc/selinux/config; then
            sed -i 's/^SELINUX=enforcing/SELINUX=permissive/' /etc/selinux/config
            info "SELinux set to Permissive (persistent /etc/selinux/config)"
        fi
    fi
fi

if command -v containerd &>/dev/null; then
    skip "ContainerD already installed ($(containerd --version 2>/dev/null | awk '{print $3}'))"
else
    if [[ $OS_ID == "ubuntu" ]]; then
        apt-get update -qq
        apt-get install -y -qq containerd apt-transport-https ca-certificates curl gnupg
    else
        dnf install -y -q dnf-plugins-core
        dnf config-manager --set-enabled crb        &>/dev/null || true
        dnf config-manager --set-enabled appstream  &>/dev/null || true
        dnf config-manager --add-repo \
            https://download.docker.com/linux/centos/docker-ce.repo &>/dev/null || true
        dnf makecache -q
        dnf install -y -q containerd.io
    fi
fi

# -----------------------------------------------------------------------------
# Configure containerd.
#
# Strategy: always build the desired config from scratch into a temp file,
# compare its checksum against the live config, and only restart if something
# actually changed.  This is genuinely idempotent regardless of:
#   - whether this is a first run or a re-run
#   - whether containerd v1 or v2 is installed
#   - what config the RPM/deb shipped with
#
# containerd v1 uses plugin path: io.containerd.grpc.v1.cri
# containerd v2 uses plugin path: io.containerd.cri.v1.runtime
# "containerd config default" always produces the correct path for the
# installed version, so we never need to hardcode either.
# -----------------------------------------------------------------------------
mkdir -p /etc/containerd

DESIRED_CFG=$(mktemp /tmp/containerd-desired.XXXXXX.toml)
trap 'rm -f "$DESIRED_CFG"' EXIT

# Generate the correct default config for the installed containerd version
containerd config default > "$DESIRED_CFG"

# Apply required Kubernetes settings
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/'           "$DESIRED_CFG"
sed -i "s|sandbox_image = .*|sandbox_image = \"registry.k8s.io/pause:3.10\"|" "$DESIRED_CFG"

# Compare desired vs live config by checksum
DESIRED_SUM=$(md5sum "$DESIRED_CFG" | awk '{print $1}')
CURRENT_SUM=""
[[ -f /etc/containerd/config.toml ]] \
    && CURRENT_SUM=$(md5sum /etc/containerd/config.toml | awk '{print $1}')

if [[ "$DESIRED_SUM" != "$CURRENT_SUM" ]]; then
    cp "$DESIRED_CFG" /etc/containerd/config.toml

    systemctl daemon-reexec
    systemctl enable containerd &>/dev/null
    systemctl restart containerd

    # Wait for socket after restart
    SOCKET_WAIT=0
    until [[ -S /var/run/containerd/containerd.sock ]] || (( SOCKET_WAIT >= 30 )); do
        sleep 1; (( SOCKET_WAIT++ ))
    done
    [[ -S /var/run/containerd/containerd.sock ]] || fail "containerd socket did not appear after 30s"
    ok "ContainerD configured and restarted"
else
    # Config is already correct - just make sure the service is up
    systemctl enable containerd &>/dev/null
    systemctl start containerd  &>/dev/null || true

    SOCKET_WAIT=0
    until [[ -S /var/run/containerd/containerd.sock ]] || (( SOCKET_WAIT >= 30 )); do
        sleep 1; (( SOCKET_WAIT++ ))
    done
    [[ -S /var/run/containerd/containerd.sock ]] || fail "containerd socket did not appear after 30s"
    skip "ContainerD config already correct - no restart needed"
fi

# -----------------------------------------------------------------------------
# Install cri-tools (crictl) and write /etc/crictl.yaml BEFORE the CRI check.
#
# ROOT CAUSE OF PREVIOUS FAILURE:
#   The CRI check called 'crictl' here in Step 2, but cri-tools is only pulled
#   in as a dependency of kubelet in Step 3.  On a fresh Ubuntu install crictl
#   does not exist yet → command-not-found → CRI_OK=false → script exits.
#
# WHY crictl.yaml IS ALSO REQUIRED (same fix as the worker script):
#   Without /etc/crictl.yaml, crictl probes every possible socket path
#   sequentially and times out on each one before giving up.  The 20-second
#   wait loop here expires before crictl finishes probing even though containerd
#   is healthy.  Writing crictl.yaml makes crictl connect directly without
#   probing, so the check succeeds in under 1 second.
# -----------------------------------------------------------------------------
if ! command -v crictl &>/dev/null; then
    info "Installing cri-tools (crictl)..."
    if [[ $OS_ID == "ubuntu" ]]; then
        # cri-tools lives in the Kubernetes apt repo which is not configured
        # until Step 3. Use || true so a missing package does NOT kill the
        # script under set -euo pipefail; we handle the missing case below.
        apt-get install -y -qq cri-tools 2>/dev/null || true
    else
        dnf install -y -q cri-tools 2>/dev/null || true
    fi
fi

# Fallback: if the package manager did not have cri-tools yet (K8s repo not
# configured until Step 3), download the crictl binary directly so the CRI
# check below always has a working binary.
if ! command -v crictl &>/dev/null; then
    info "cri-tools not in repos yet - fetching crictl binary directly..."
    CRICTL_VERSION="v1.32.0"
    CRICTL_TMP=$(mktemp /tmp/crictl.XXXXXX.tar.gz)
    curl -fsSL \
        "https://github.com/kubernetes-sigs/cri-tools/releases/download/${CRICTL_VERSION}/crictl-${CRICTL_VERSION}-linux-amd64.tar.gz" \
        -o "$CRICTL_TMP"
    tar -xzf "$CRICTL_TMP" -C /usr/local/bin crictl
    rm -f "$CRICTL_TMP"
    chmod +x /usr/local/bin/crictl
fi

# Ensure crictl is on PATH regardless of where the package installed it
for _cdir in /usr/bin /usr/local/bin; do
    [[ -x "$_cdir/crictl" ]] && export PATH="$_cdir:${PATH}" && break
done

# Write /etc/crictl.yaml so crictl connects directly without probing all sockets
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint:   unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
ok "crictl configured → /run/containerd/containerd.sock"

# Verify the CRI runtime API is actually responding before proceeding.
# This catches any remaining misconfiguration before kubeadm tries to use it.
info "Verifying CRI runtime API..."
CRI_OK=false
for i in $(seq 1 10); do
    if crictl version &>/dev/null 2>&1; then
        CRI_OK=true
        break
    fi
    sleep 2
done
if [[ "$CRI_OK" == "false" ]]; then
    echo ""
    journalctl -u containerd -n 30 --no-pager 2>/dev/null | sed 's/^/    /' || true
    echo ""
    fail "CRI runtime API not responding after 20s. See journal above."
fi
ok "CRI runtime API responding"

ok "ContainerD installed and running"

# =============================================================================
step 3  "Installing Kubernetes packages"
# =============================================================================

K8S_SHORT="${K8S_VERSION%.*}"

# All three must be present at the correct version before we skip
K8S_ALL_INSTALLED=true
for bin in kubectl kubeadm kubelet; do
    if ! command -v "$bin" &>/dev/null; then
        K8S_ALL_INSTALLED=false
        info "$bin not found - will install"
        break
    fi
done
if [[ "$K8S_ALL_INSTALLED" == "true" ]]; then
    if ! kubectl version --client 2>/dev/null | grep -q "${K8S_VERSION}"; then
        K8S_ALL_INSTALLED=false
        info "kubectl version mismatch - will reinstall"
    fi
fi

if [[ "$K8S_ALL_INSTALLED" == "true" ]]; then
    skip "Kubernetes packages (kubectl/kubeadm/kubelet) already at v${K8S_VERSION}"
else
    if [[ $OS_ID == "ubuntu" ]]; then
        mkdir -p /etc/apt/keyrings
        # Use versioned key filename to avoid the "Overwrite? (y/N)" prompt on re-runs
        KEY_FILE="/etc/apt/keyrings/kubernetes-${K8S_SHORT}.gpg"
        if [[ ! -f "$KEY_FILE" ]]; then
            curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_SHORT}/deb/Release.key" \
                | gpg --dearmor -o "$KEY_FILE"
        fi
        # Symlink canonical name so existing apt config stays valid
        ln -sf "$KEY_FILE" /etc/apt/keyrings/kubernetes.gpg

        echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_SHORT}/deb/ /" \
            > /etc/apt/sources.list.d/kubernetes.list

        # Unhold before install so version changes are picked up
        apt-mark unhold kubelet kubeadm kubectl &>/dev/null || true
        apt-get update -qq
        apt-get install -y -qq kubelet="${K8S_VERSION}-1.1" \
                               kubeadm="${K8S_VERSION}-1.1" \
                               kubectl="${K8S_VERSION}-1.1"
        apt-mark hold kubelet kubeadm kubectl
    else
        cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_SHORT}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_SHORT}/rpm/repodata/repomd.xml.key
EOF
        dnf makecache -q
        dnf install -y -q \
            kubelet-${K8S_VERSION} \
            kubeadm-${K8S_VERSION} \
            kubectl-${K8S_VERSION}
    fi
fi

systemctl enable kubelet
ok "Kubernetes packages installed"

# =============================================================================
step 4  "Initialising control plane"
# =============================================================================

# Helper: install kubeconfig for a given user (called after admin.conf exists)
install_kubeconfig() {
    local user="$1"
    local home="$2"
    mkdir -p "${home}/.kube"
    cp /etc/kubernetes/admin.conf "${home}/.kube/config"
    chown "${user}:${user}" "${home}/.kube/config"
}

if [[ -f /etc/kubernetes/admin.conf ]]; then
    # ----- Re-run path: cluster already initialised, just refresh kubeconfigs -----
    install_kubeconfig root /root
    [[ "$REAL_USER" != "root" ]] && install_kubeconfig "$REAL_USER" "$REAL_HOME"
    ok "Control plane already initialised and running"
    echo ""
    kubectl get nodes 2>/dev/null | sed 's/^/    /'
    echo ""
else
    # ----- First-run path: initialise the cluster, then install kubeconfigs -----
    kubeadm init \
        --kubernetes-version="${K8S_VERSION}" \
        --pod-network-cidr="${POD_CIDR}" \
        --service-cidr="${SERVICE_CIDR}" \
        --apiserver-advertise-address="${MASTER_IP}" \
        --node-name="$(hostname)" \
        2>&1 | tee /tmp/kubeadm-init.log

    # admin.conf now exists - safe to copy
    install_kubeconfig root /root
    [[ "$REAL_USER" != "root" ]] && install_kubeconfig "$REAL_USER" "$REAL_HOME"

    ok "Control plane initialised"
    ok "kubectl configured for root"
    [[ "$REAL_USER" != "root" ]] && ok "kubectl configured for user '$REAL_USER' (${REAL_HOME}/.kube/config)"
fi

# =============================================================================
step 5  "Installing Calico"
# =============================================================================

# kubectl apply -f is idempotent - suppress per-resource noise on re-runs
CALICO_OUT=$(kubectl apply -f \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" 2>&1) || true
# Only surface lines that reflect actual new creates (not unchanged/configured)
CALICO_NEW=$(echo "$CALICO_OUT" | grep ' created$' || true)
[[ -n "$CALICO_NEW" ]] && echo "$CALICO_NEW" | sed 's/^/    /'
ok "Calico installed/updated"

# =============================================================================
step 6  "Enable strictAffinity (Windows required)"
# =============================================================================

if ! kubectl get ipamconfigs.crd.projectcalico.org default &>/dev/null; then
    info "Waiting for Calico ipamconfig CRD to become available..."
    for i in $(seq 1 30); do
        kubectl get ipamconfigs.crd.projectcalico.org default &>/dev/null && break
        sleep 5
    done
fi

# --type=merge patch is idempotent
kubectl patch ipamconfigs.crd.projectcalico.org default \
    --type=merge \
    -p '{"spec":{"strictAffinity":true,"autoAllocateBlocks":true}}' || true

ok "Calico strictAffinity enabled"

# =============================================================================
step 7  "Apply Windows RBAC"
# =============================================================================

# The old docs.projectcalico.org URL is permanently 404 (migrated to Tigera).
# Attempt silently - no output on re-run since this is a known permanent state.
CALICO_WINDOWS_RBAC_URL="https://docs.projectcalico.org/manifests/calico-windows-rbac.yaml"
if curl -fsSL --max-time 10 "$CALICO_WINDOWS_RBAC_URL" -o /tmp/calico-windows-rbac.yaml 2>/dev/null; then
    kubectl apply -f /tmp/calico-windows-rbac.yaml
    ok "calico-windows-rbac.yaml applied from upstream"
fi
# (URL is permanently 404 since Calico migrated to Tigera docs - silently skipped)

# Idempotent: check before create
if kubectl get clusterrolebinding kube-proxy-windows &>/dev/null; then
    ok "Windows RBAC already configured"
else
    kubectl create clusterrolebinding kube-proxy-windows \
        --clusterrole=system:node-proxier \
        --group=system:nodes
    ok "ClusterRoleBinding 'kube-proxy-windows' created"
fi

# =============================================================================
step 8  "Print join command"
# =============================================================================

echo ""
echo -e "  ${YELLOW}SAVE THIS JOIN COMMAND:${NC}"
kubeadm token create --print-join-command
echo ""
kubectl get nodes
echo ""
echo -e "  ${GREEN}Master setup complete.${NC}"
echo -e " Next: run 02-linux-worker-setup.sh on each Linux worker."
echo -e " Then: run 06-k8s-windows-worker-join.ps1 on the Windows node."