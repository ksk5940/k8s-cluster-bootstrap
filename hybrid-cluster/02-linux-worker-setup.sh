#!/usr/bin/env bash
# =============================================================================
# 02-linux-worker-setup.sh
# Kubernetes Worker Node Setup (Ubuntu / Rocky / RHEL / CentOS)
# Kubernetes v1.32.3
# Fully idempotent - safe to re-run at any time
# =============================================================================

set -euo pipefail

K8S_VERSION="1.32.3"
K8S_SHORT="${K8S_VERSION%.*}"

GREEN='\033[0;32m'; CYAN='\033[0;36m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
ok()   { echo -e "  ${GREEN}[OK]${NC}   $*"; }
skip() { echo -e "  ${YELLOW}[SKIP]${NC} $*"; }
info() { echo -e "  ${CYAN}[....]${NC}  $*"; }
warn() { echo -e "  ${YELLOW}[WARN]${NC}  $*"; }
fail() { echo -e "  ${RED}[FAIL]${NC}  $*"; exit 1; }
step() { echo -e "\n  ${CYAN}[$1/5]${NC} $2\n  $(printf '%0.s-' {1..66})"; }

echo -e "\n  ${CYAN}+================================================================+${NC}"
echo -e "  ${CYAN}|       KUBERNETES LINUX WORKER NODE SETUP  v${K8S_VERSION}        |${NC}"
echo -e "  ${CYAN}+================================================================+${NC}\n"

[[ $EUID -ne 0 ]] && fail "Run as root: sudo bash $0"

source /etc/os-release
OS_ID=$ID
OS_VER=$VERSION_ID

# =============================================================================
step 1 "System Prerequisites"
# =============================================================================

# ---------- SELinux (RHEL family only) ---------------------------------------
# Must run BEFORE containerd install. SELinux Enforcing on el8/el9 with the
# Docker containerd.io RPM blocks the CRI gRPC socket even though containerd
# starts fine and the socket exists.  Setting Permissive is the standard K8s
# production approach on RHEL/Rocky (same as the reference bootstrap script).
if [[ $OS_ID =~ ^(rocky|rhel|centos|almalinux)$ ]]; then
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
            info "SELinux set to Permissive (persistent)"
        fi
    fi
fi

# ---------- Swap -------------------------------------------------------------
swapoff -a
if grep -qE '\bswap\b' /etc/fstab; then
    sed -i '/\bswap\b/d' /etc/fstab
    info "Swap removed from /etc/fstab"
else
    skip "No swap entries in /etc/fstab"
fi

# ---------- Kernel modules ---------------------------------------------------
cat > /etc/modules-load.d/k8s.conf <<EOF
overlay
br_netfilter
EOF
lsmod | grep -q '^overlay'      || modprobe overlay
lsmod | grep -q '^br_netfilter' || modprobe br_netfilter

# ---------- sysctl -----------------------------------------------------------
cat > /etc/sysctl.d/99-k8s.conf <<EOF
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv4.conf.all.rp_filter         = 0
net.ipv4.conf.default.rp_filter     = 0
EOF
sysctl --system > /dev/null
ok "Kernel modules and sysctl configured (rp_filter=0 for Windows VXLAN)"

# ---------- DNS (RHEL family only) -------------------------------------------
# Rocky/RHEL does not run systemd-resolved.  Ensure /etc/resolv.conf has a
# nameserver and /etc/hosts has minimal localhost entries so pod DNS works.
if [[ $OS_ID =~ ^(rocky|rhel|centos|almalinux)$ ]]; then
    grep -q "nameserver" /etc/resolv.conf 2>/dev/null || echo "nameserver 8.8.8.8" >> /etc/resolv.conf
    grep -q "127.0.0.1" /etc/hosts || echo "127.0.0.1 localhost" >> /etc/hosts
    grep -q "::1"       /etc/hosts || echo "::1 localhost"       >> /etc/hosts
    if ! grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+$(hostname -s)" /etc/hosts 2>/dev/null; then
        echo "$(hostname -I | awk '{print $1}') $(hostname -s)" >> /etc/hosts
        info "Added $(hostname -s) to /etc/hosts"
    fi
fi

# =============================================================================
step 2 "Install and Configure ContainerD"
# =============================================================================

if command -v containerd &>/dev/null; then
    skip "ContainerD already installed ($(containerd --version 2>/dev/null | awk '{print $3}'))"
else
    if [[ $OS_ID == "ubuntu" ]]; then
        info "Installing containerd (Ubuntu)"
        apt-get update -qq
        apt-get install -y -qq containerd
    else
        # ---------- Rocky/RHEL: Docker CE repo, pinned to centos/8 for el9 ------
        # Docker's CentOS mirror only has dirs for 7 and 8 — el9 must use "8".
        # containerd.io from centos/8 installs and runs correctly on RHEL 9.
        info "Installing containerd (Rocky/RHEL/CentOS)"
        local_OS_MAJOR=$(rpm -E '%{rhel}' 2>/dev/null || echo "8")
        DOCKER_RELVER="8"
        [[ "$local_OS_MAJOR" -lt 9 ]] && DOCKER_RELVER="$local_OS_MAJOR"

        cat > /etc/yum.repos.d/docker-ce.repo <<DCEOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://download.docker.com/linux/centos/${DOCKER_RELVER}/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
DCEOF
        rpm --import https://download.docker.com/linux/centos/gpg &>/dev/null || true
        dnf makecache --enablerepo="docker-ce-stable" &>/dev/null || true
        dnf install -y -q --enablerepo="docker-ce-stable" containerd.io

        # Fallback 1: EPEL
        if ! command -v containerd &>/dev/null; then
            warn "Docker CE repo failed — trying EPEL containerd"
            rpm -q epel-release &>/dev/null || dnf install -y -q epel-release &>/dev/null || true
            dnf install -y -q --enablerepo="epel" containerd &>/dev/null || true
        fi

        # Fallback 2: distro repo
        if ! command -v containerd &>/dev/null; then
            warn "EPEL failed — trying distro containerd"
            dnf install -y -q containerd &>/dev/null || true
        fi

        command -v containerd &>/dev/null || fail "containerd could not be installed from any source"
    fi
fi

# ---------- containerd config ------------------------------------------------
# Strategy: always build the desired config from "containerd config default"
# (which is always correct for the installed version — v1 or v2), apply the
# two required patches, then compare by checksum.  Only restart if changed.
# This is genuinely idempotent and version-agnostic.
mkdir -p /etc/containerd

DESIRED_CFG=$(mktemp /tmp/containerd-desired.XXXXXX.toml)
trap 'rm -f "$DESIRED_CFG"' EXIT

containerd config default > "$DESIRED_CFG"
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/'                          "$DESIRED_CFG"
sed -i "s|sandbox_image = .*|sandbox_image = \"registry.k8s.io/pause:3.10\"|" "$DESIRED_CFG"

DESIRED_SUM=$(md5sum "$DESIRED_CFG" | awk '{print $1}')
CURRENT_SUM=""
[[ -f /etc/containerd/config.toml ]] \
    && CURRENT_SUM=$(md5sum /etc/containerd/config.toml | awk '{print $1}')

if [[ "$DESIRED_SUM" != "$CURRENT_SUM" ]]; then
    cp "$DESIRED_CFG" /etc/containerd/config.toml
    systemctl daemon-reexec
    systemctl enable containerd &>/dev/null
    systemctl restart containerd

    SOCKET_WAIT=0
    until [[ -S /run/containerd/containerd.sock ]] || (( SOCKET_WAIT >= 30 )); do
        sleep 1; (( SOCKET_WAIT++ ))
    done
    [[ -S /run/containerd/containerd.sock ]] || fail "containerd socket did not appear after 30s"
    ok "ContainerD configured and restarted"
else
    systemctl enable containerd &>/dev/null
    systemctl start  containerd &>/dev/null || true

    SOCKET_WAIT=0
    until [[ -S /run/containerd/containerd.sock ]] || (( SOCKET_WAIT >= 30 )); do
        sleep 1; (( SOCKET_WAIT++ ))
    done
    [[ -S /run/containerd/containerd.sock ]] || fail "containerd socket did not appear after 30s"
    skip "ContainerD config already correct - no restart needed"
fi

ok "ContainerD installed & configured"

# =============================================================================
step 3 "Install Kubernetes Packages + crictl"
# =============================================================================

# ---------- K8s repo ---------------------------------------------------------
if [[ $OS_ID == "ubuntu" ]]; then
    mkdir -p /etc/apt/keyrings
    KEY_FILE="/etc/apt/keyrings/kubernetes-${K8S_SHORT}.gpg"
    if [[ ! -f "$KEY_FILE" ]]; then
        curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${K8S_SHORT}/deb/Release.key" \
            | gpg --dearmor -o "$KEY_FILE"
    fi
    ln -sf "$KEY_FILE" /etc/apt/keyrings/kubernetes.gpg
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes.gpg] \
https://pkgs.k8s.io/core:/stable:/v${K8S_SHORT}/deb/ /" \
        > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq
else
    # exclude= protects against accidental upgrades via 'dnf update'.
    # Intentional installs below use --disableexcludes=kubernetes.
    cat > /etc/yum.repos.d/kubernetes.repo <<EOF
[kubernetes]
name=Kubernetes v${K8S_SHORT}
baseurl=https://pkgs.k8s.io/core:/stable:/v${K8S_SHORT}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${K8S_SHORT}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
EOF
    dnf makecache --disablerepo="*" --enablerepo="kubernetes" &>/dev/null || true
fi

# ---------- K8s binaries -----------------------------------------------------
K8S_ALL_INSTALLED=true
for bin in kubectl kubeadm kubelet; do
    command -v "$bin" &>/dev/null || { K8S_ALL_INSTALLED=false; break; }
done
if [[ "$K8S_ALL_INSTALLED" == "true" ]]; then
    if ! kubectl version --client 2>/dev/null | grep -q "${K8S_VERSION}"; then
        K8S_ALL_INSTALLED=false
        info "kubectl version mismatch - will reinstall"
    fi
fi

if [[ "$K8S_ALL_INSTALLED" == "true" ]]; then
    skip "Kubernetes packages already at v${K8S_VERSION}"
else
    if [[ $OS_ID == "ubuntu" ]]; then
        apt-mark unhold kubelet kubeadm kubectl &>/dev/null || true
        apt-get install -y -qq kubelet="${K8S_VERSION}-1.1" \
                               kubeadm="${K8S_VERSION}-1.1" \
                               kubectl="${K8S_VERSION}-1.1"
        apt-mark hold kubelet kubeadm kubectl
    else
        dnf install -y -q --disableexcludes=kubernetes \
            kubelet-${K8S_VERSION} \
            kubeadm-${K8S_VERSION} \
            kubectl-${K8S_VERSION}
    fi
fi
systemctl enable kubelet
ok "Kubernetes packages installed"

# ---------- crictl -----------------------------------------------------------
# crictl must be configured BEFORE kubeadm join.  Without /etc/crictl.yaml,
# crictl tries all default socket paths, times out, and the CRI check that
# kubeadm runs in preflight fails with "unknown service runtime.v1.RuntimeService"
# — even though containerd itself is healthy.
# The reference bootstrap script installs cri-tools and writes crictl.yaml
# explicitly; we do the same here.
if ! command -v crictl &>/dev/null; then
    info "Installing cri-tools..."
    if [[ $OS_ID == "ubuntu" ]]; then
        apt-get install -y -qq cri-tools &>/dev/null
    else
        dnf install -y -q --disableexcludes=kubernetes cri-tools &>/dev/null
    fi
fi

# Ensure crictl is on PATH (cri-tools installs to /usr/bin on some distros)
for _cdir in /usr/bin /usr/local/bin; do
    [[ -x "$_cdir/crictl" ]] && export PATH="$_cdir:${PATH}" && break
done

# Write /etc/crictl.yaml pointing at the containerd socket.
# This is the only reliable way to ensure crictl (and kubeadm's preflight)
# use the correct runtime endpoint without needing --runtime-endpoint flags.
cat > /etc/crictl.yaml <<EOF
runtime-endpoint: unix:///run/containerd/containerd.sock
image-endpoint:   unix:///run/containerd/containerd.sock
timeout: 10
debug: false
EOF
ok "crictl configured → /run/containerd/containerd.sock"

# ---------- Verify CRI API ---------------------------------------------------
# Containerd is healthy when the journal shows "serving... containerd.sock"
# but crictl still fails if crictl.yaml is missing or the socket path is wrong.
# Now that crictl.yaml is written, this check should always pass.
info "Verifying CRI runtime API..."
CRI_OK=false
for i in $(seq 1 15); do
    if crictl version &>/dev/null 2>&1; then
        CRI_OK=true; break
    fi
    sleep 2
done
if [[ "$CRI_OK" == "false" ]]; then
    echo ""
    echo -e "  ${RED}--- containerd journal (last 30 lines) ---${NC}"
    journalctl -u containerd -n 30 --no-pager 2>/dev/null | sed 's/^/    /' || true
    echo ""
    fail "CRI runtime API not responding after 30s. See journal above."
fi
ok "CRI runtime API responding"

# =============================================================================
step 4 "Join Cluster"
# =============================================================================

if [[ -f /etc/kubernetes/kubelet.conf ]]; then
    ok "Node already joined the cluster"
else
    # ---------- RHEL: write kubelet node-ip before join ----------------------
    # Bind kubelet to the host-only IP so the master can reach this node.
    # The reference script does this in detect_network_interfaces() before join.
    if [[ $OS_ID =~ ^(rocky|rhel|centos|almalinux)$ ]]; then
        NODE_IP=$(ip -4 addr | awk '/inet 192\.168\./ {print $2}' | cut -d/ -f1 | head -1)
        if [[ -n "$NODE_IP" ]]; then
            mkdir -p /etc/sysconfig
            echo "KUBELET_EXTRA_ARGS=--node-ip=${NODE_IP}" > /etc/sysconfig/kubelet
            systemctl daemon-reload
            info "kubelet --node-ip set to ${NODE_IP}"
        fi
    fi

    SOCKET_WAIT=0
    until [[ -S /run/containerd/containerd.sock ]] || (( SOCKET_WAIT >= 30 )); do
        sleep 1; (( SOCKET_WAIT++ ))
    done
    [[ -S /run/containerd/containerd.sock ]] || fail "containerd socket not available - cannot join"

    echo ""
    echo -e "  ${YELLOW}Paste the kubeadm join command from the master node:${NC}"
    read -r JOIN_CMD

    [[ "$JOIN_CMD" != kubeadm\ join* ]] \
        && fail "Input does not look like a kubeadm join command. Aborting."

    eval "$JOIN_CMD"
    ok "Joined cluster successfully"
fi

# ---------- RHEL: patch kubelet resolvConf after join ------------------------
# kubeadm join writes /var/lib/kubelet/config.yaml from the master's
# KubeletConfiguration which contains resolvConf: /run/systemd/resolve/resolv.conf
# Rocky/RHEL does not run systemd-resolved so that path does not exist.
# Patch it to /etc/resolv.conf and restart kubelet.  (Same fix as reference script.)
if [[ $OS_ID =~ ^(rocky|rhel|centos|almalinux)$ ]]; then
    KUBELET_CFG="/var/lib/kubelet/config.yaml"
    if [[ -f "$KUBELET_CFG" ]]; then
        CURRENT_RESOLV=$(grep "^resolvConf:" "$KUBELET_CFG" 2>/dev/null | awk '{print $2}' || true)
        if [[ "$CURRENT_RESOLV" != "/etc/resolv.conf" && -n "$CURRENT_RESOLV" ]]; then
            sed -i 's|^resolvConf:.*|resolvConf: /etc/resolv.conf|' "$KUBELET_CFG"
            systemctl daemon-reload
            systemctl restart kubelet
            info "kubelet resolvConf patched: ${CURRENT_RESOLV} → /etc/resolv.conf"
        elif [[ -z "$CURRENT_RESOLV" ]]; then
            echo "resolvConf: /etc/resolv.conf" >> "$KUBELET_CFG"
            systemctl daemon-reload
            systemctl restart kubelet
            info "kubelet resolvConf added: /etc/resolv.conf"
        else
            skip "kubelet resolvConf already correct (/etc/resolv.conf)"
        fi
    fi
fi

# =============================================================================
step 5 "Verification"
# =============================================================================

systemctl is-active containerd >/dev/null \
    && ok  "containerd running" \
    || fail "containerd not running"

systemctl is-active kubelet >/dev/null \
    && ok  "kubelet running" \
    || fail "kubelet not running"

echo ""
echo -e "  ${GREEN}Worker node setup completed successfully.${NC}"
echo -e "  Verify from master: kubectl get nodes"
echo ""