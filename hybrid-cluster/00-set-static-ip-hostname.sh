#!/usr/bin/env bash
# =============================================================================
#  00-set-static-ip-hostname.sh  —  Configure Static IP + Hostname
#
#  Supports:
#    Ubuntu 18/20/22/24   (netplan)
#    Debian 10/11/12      (ifupdown  → /etc/network/interfaces)
#    RHEL / Rocky / AlmaLinux / CentOS 8/9  (NetworkManager nmcli)
#    Fedora 36+           (NetworkManager nmcli)
#    openSUSE / SLES      (wicked)
#    Raspberry Pi OS      (dhcpcd.conf)
#
#  Environment variables (passed by Jenkins or set manually):
#    STATIC_IP      — e.g. 192.168.56.11
#    GATEWAY        — e.g. 192.168.56.1   (default: first 3 octets of STATIC_IP + .1)
#    DNS_SERVERS    — e.g. "8.8.8.8 8.8.4.4" (space-separated)
#    PREFIX_LENGTH  — e.g. 24  (default: 24)
#    NETWORK_IFACE  — e.g. eth0 (default: auto-detected primary interface)
#    NEW_HOSTNAME   — e.g. k8s-master (optional; current hostname kept if empty)
#    NODE_ROLE      — master | worker  (informational only)
#
#  Usage (standalone):
#    sudo STATIC_IP=192.168.56.11 NEW_HOSTNAME=k8s-master bash 00-set-static-ip-hostname.sh
#
#  The script is IDEMPOTENT — safe to run multiple times.
# =============================================================================
set -euo pipefail

# ── Parameters ────────────────────────────────────────────────────────────────
STATIC_IP="${STATIC_IP:-}"
GATEWAY="${GATEWAY:-}"
DNS_SERVERS="${DNS_SERVERS:-8.8.8.8 1.1.1.1}"
PREFIX_LENGTH="${PREFIX_LENGTH:-24}"
NETWORK_IFACE="${NETWORK_IFACE:-}"
NEW_HOSTNAME="${NEW_HOSTNAME:-}"
NODE_ROLE="${NODE_ROLE:-}"

# ── Colours ───────────────────────────────────────────────────────────────────
CY='\033[0;36m'; GR='\033[0;32m'; RD='\033[0;31m'; YL='\033[1;33m'; NC='\033[0m'
step() { echo -e "\n  ${CY}[$1]${NC} $2\n  $(printf '%0.s-' {1..66})"; }
ok()   { echo -e "  ${GR}[OK]${NC}   $*"; }
warn() { echo -e "  ${YL}[WARN]${NC} $*"; }
die()  { echo -e "  ${RD}[FAIL]${NC} $*" >&2; exit 1; }

[[ -z "${STATIC_IP}" ]] && die "STATIC_IP is required. Export it before calling this script."

# ── Auto-detect gateway ───────────────────────────────────────────────────────
if [[ -z "${GATEWAY}" ]]; then
  GATEWAY=$(ip route show default 2>/dev/null | awk '/default/ {print $3; exit}')
  [[ -z "${GATEWAY}" ]] && GATEWAY="$(echo "${STATIC_IP}" | cut -d. -f1-3).1"
fi

# ── Auto-detect primary NIC ───────────────────────────────────────────────────
if [[ -z "${NETWORK_IFACE}" ]]; then
  NETWORK_IFACE=$(ip route show default 2>/dev/null | awk '/default/ {print $5; exit}')
  [[ -z "${NETWORK_IFACE}" ]] && NETWORK_IFACE=$(ip -o link show | awk -F': ' '!/lo/{print $2; exit}')
  [[ -z "${NETWORK_IFACE}" ]] && die "Cannot auto-detect network interface. Set NETWORK_IFACE."
fi

# ── Detect OS ─────────────────────────────────────────────────────────────────
source /etc/os-release 2>/dev/null || true
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-0}"
OS_VER_MAJOR="${OS_VER%%.*}"

echo -e "
  ${CY}+================================================================+${NC}
  ${CY}|     STATIC IP + HOSTNAME CONFIGURATION                         |${NC}
  ${CY}+================================================================+${NC}

  ${CY}[....]${NC}  OS         : ${OS_ID} ${OS_VER}
  ${CY}[....]${NC}  Interface  : ${NETWORK_IFACE}
  ${CY}[....]${NC}  Static IP  : ${STATIC_IP}/${PREFIX_LENGTH}
  ${CY}[....]${NC}  Gateway    : ${GATEWAY}
  ${CY}[....]${NC}  DNS        : ${DNS_SERVERS}
  ${CY}[....]${NC}  Hostname   : ${NEW_HOSTNAME:-<unchanged>}
  ${CY}[....]${NC}  Role       : ${NODE_ROLE:-<unset>}
"

# =============================================================================
step "1" "Detect network configuration method"
# =============================================================================

detect_config_method() {
  # 1. netplan
  if command -v netplan &>/dev/null && ls /etc/netplan/*.yaml &>/dev/null 2>&1; then
    echo "netplan"; return
  fi
  # 2. NetworkManager (RHEL/Rocky/Fedora/Ubuntu with NM)
  if command -v nmcli &>/dev/null && systemctl is-active NetworkManager &>/dev/null 2>&1; then
    echo "nmcli"; return
  fi
  # 3. wicked (openSUSE)
  if command -v wicked &>/dev/null; then
    echo "wicked"; return
  fi
  # 4. dhcpcd (Raspbian / some Debian)
  if command -v dhcpcd &>/dev/null && [[ -f /etc/dhcpcd.conf ]]; then
    echo "dhcpcd"; return
  fi
  # 5. ifupdown (Debian/Ubuntu without netplan)
  if command -v ifup &>/dev/null && [[ -d /etc/network ]]; then
    echo "ifupdown"; return
  fi
  echo "unknown"
}

METHOD=$(detect_config_method)
ok "Detected method: ${METHOD}"

# =============================================================================
step "2" "Configure static IP via ${METHOD}"
# =============================================================================

DNS_COMMA=$(echo "${DNS_SERVERS}" | tr ' ' ',')
DNS_YAML=$(echo "${DNS_SERVERS}" | tr ' ' '\n' | sed 's/^/          - /')

case "${METHOD}" in

  # ── Netplan (Ubuntu 18+ default) ──────────────────────────────────────────
  netplan)
    NETPLAN_FILE="/etc/netplan/99-k8s-static.yaml"
    cat > "${NETPLAN_FILE}" <<EOF
network:
  version: 2
  renderer: networkd
  ethernets:
    ${NETWORK_IFACE}:
      dhcp4: false
      dhcp6: false
      addresses:
        - ${STATIC_IP}/${PREFIX_LENGTH}
      routes:
        - to: default
          via: ${GATEWAY}
      nameservers:
        addresses:
${DNS_YAML}
EOF
    chmod 600 "${NETPLAN_FILE}"
    netplan generate
    netplan apply
    ok "Netplan config written to ${NETPLAN_FILE} and applied"
    ;;

  # ── NetworkManager via nmcli (RHEL/Rocky/AlmaLinux/CentOS/Fedora) ─────────
  nmcli)
    CONN_NAME="k8s-static-${NETWORK_IFACE}"
    # Delete existing managed connection for this iface if present
    nmcli connection delete "${CONN_NAME}" 2>/dev/null || true
    nmcli connection delete "$(nmcli -t -f NAME,DEVICE connection show --active 2>/dev/null \
      | awk -F: -v iface="${NETWORK_IFACE}" '$2==iface{print $1}')" 2>/dev/null || true

    nmcli connection add \
      type ethernet \
      ifname "${NETWORK_IFACE}" \
      con-name "${CONN_NAME}" \
      ipv4.addresses "${STATIC_IP}/${PREFIX_LENGTH}" \
      ipv4.gateway   "${GATEWAY}" \
      ipv4.dns       "${DNS_COMMA}" \
      ipv4.method    manual \
      ipv6.method    disabled \
      connection.autoconnect yes

    nmcli connection up "${CONN_NAME}" || true
    ok "NetworkManager connection '${CONN_NAME}' created and activated"
    ;;

  # ── wicked (openSUSE/SLES) ────────────────────────────────────────────────
  wicked)
    IFACE_FILE="/etc/sysconfig/network/ifcfg-${NETWORK_IFACE}"
    cat > "${IFACE_FILE}" <<EOF
BOOTPROTO='static'
IPADDR='${STATIC_IP}'
PREFIXLEN='${PREFIX_LENGTH}'
STARTMODE='auto'
EOF
    ROUTES_FILE="/etc/sysconfig/network/routes"
    grep -v "^default" "${ROUTES_FILE}" 2>/dev/null > /tmp/routes.tmp || true
    echo "default ${GATEWAY} - -" >> /tmp/routes.tmp
    mv /tmp/routes.tmp "${ROUTES_FILE}"

    DNS_FILE="/etc/sysconfig/network/config"
    if [[ -f "${DNS_FILE}" ]]; then
      sed -i "s|^NETCONFIG_DNS_STATIC_SERVERS=.*|NETCONFIG_DNS_STATIC_SERVERS='${DNS_SERVERS}'|" "${DNS_FILE}"
    fi
    wicked ifreload all || systemctl restart wicked
    ok "wicked config written and reloaded"
    ;;

  # ── dhcpcd (Raspberry Pi OS / some Debian) ────────────────────────────────
  dhcpcd)
    DHCPCD_CONF="/etc/dhcpcd.conf"
    # Remove existing static block for this interface
    python3 - "${DHCPCD_CONF}" "${NETWORK_IFACE}" <<'PYEOF' 2>/dev/null || \
      grep -v "^interface ${NETWORK_IFACE}\|^static ip_address\|^static routers\|^static domain" \
        "${DHCPCD_CONF}" > /tmp/dhcpcd.tmp && mv /tmp/dhcpcd.tmp "${DHCPCD_CONF}"
import sys, re
path, iface = sys.argv[1], sys.argv[2]
with open(path) as f: content = f.read()
# Remove existing block
content = re.sub(rf'(?m)^interface {re.escape(iface)}\n(^static .*\n)*', '', content)
with open(path, 'w') as f: f.write(content)
PYEOF

    cat >> "${DHCPCD_CONF}" <<EOF

interface ${NETWORK_IFACE}
static ip_address=${STATIC_IP}/${PREFIX_LENGTH}
static routers=${GATEWAY}
static domain_name_servers=${DNS_SERVERS}
EOF
    systemctl restart dhcpcd
    ok "dhcpcd.conf updated and service restarted"
    ;;

  # ── ifupdown (Debian/Ubuntu classic) ─────────────────────────────────────
  ifupdown)
    IFACE_FILE="/etc/network/interfaces.d/k8s-${NETWORK_IFACE}"
    # Disable DHCP for this iface in main interfaces file
    sed -i "/iface ${NETWORK_IFACE} inet dhcp/d" /etc/network/interfaces 2>/dev/null || true
    sed -i "/auto ${NETWORK_IFACE}/d"           /etc/network/interfaces 2>/dev/null || true

    cat > "${IFACE_FILE}" <<EOF
auto ${NETWORK_IFACE}
iface ${NETWORK_IFACE} inet static
    address ${STATIC_IP}/${PREFIX_LENGTH}
    gateway ${GATEWAY}
    dns-nameservers ${DNS_SERVERS}
EOF
    ifdown "${NETWORK_IFACE}" 2>/dev/null || true
    ifup   "${NETWORK_IFACE}" 2>/dev/null || true
    ok "ifupdown config written: ${IFACE_FILE}"
    ;;

  *)
    warn "Unsupported/unknown network manager. Setting IP temporarily with 'ip' command."
    warn "This will NOT survive a reboot. Configure your network manager manually."
    ip addr flush dev "${NETWORK_IFACE}" 2>/dev/null || true
    ip addr add "${STATIC_IP}/${PREFIX_LENGTH}" dev "${NETWORK_IFACE}"
    ip route add default via "${GATEWAY}" dev "${NETWORK_IFACE}" 2>/dev/null || true
    ;;
esac

# =============================================================================
step "3" "Update /etc/hosts with this node's static IP"
# =============================================================================

HOSTNAME_FQDN="${NEW_HOSTNAME:-$(hostname)}"

# Remove any existing entry for this IP or hostname
sed -i "/^${STATIC_IP}[[:space:]]/d"                  /etc/hosts
sed -i "/[[:space:]]${HOSTNAME_FQDN}$/d"              /etc/hosts
sed -i "/[[:space:]]${HOSTNAME_FQDN}[[:space:]]/d"    /etc/hosts

echo "${STATIC_IP}    ${HOSTNAME_FQDN}" >> /etc/hosts
ok "/etc/hosts updated: ${STATIC_IP} → ${HOSTNAME_FQDN}"

# =============================================================================
step "4" "Set hostname: ${NEW_HOSTNAME:-<skip>}"
# =============================================================================

if [[ -n "${NEW_HOSTNAME}" ]]; then
  hostnamectl set-hostname "${NEW_HOSTNAME}" 2>/dev/null || \
    echo "${NEW_HOSTNAME}" > /etc/hostname
  ok "Hostname set to: ${NEW_HOSTNAME}"
else
  warn "NEW_HOSTNAME is empty — hostname unchanged: $(hostname)"
fi

# =============================================================================
step "5" "Verify connectivity"
# =============================================================================

sleep 2
if ping -c 2 -W 2 "${GATEWAY}" &>/dev/null; then
  ok "Gateway ${GATEWAY} is reachable"
else
  warn "Gateway ${GATEWAY} not responding — check network settings"
fi

echo -e "
  ${GR}+================================================================+${NC}
  ${GR}|     STATIC IP CONFIGURATION COMPLETE                           |${NC}
  ${GR}+================================================================+${NC}
  Interface  : ${NETWORK_IFACE}
  Static IP  : ${STATIC_IP}/${PREFIX_LENGTH}
  Gateway    : ${GATEWAY}
  DNS        : ${DNS_SERVERS}
  Hostname   : $(hostname)
  Method     : ${METHOD}
"
