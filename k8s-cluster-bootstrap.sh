#!/usr/bin/env bash

# ╔════════════════════════════════════════════════════════════════════════════╗
# ║            ENTERPRISE KUBERNETES BOOTSTRAP & INTEGRATED CNI                ║
# ║                                                                            ║
# ║  Automates full Kubernetes cluster setup on Ubuntu/Debian and              ║
# ║  Rocky/RHEL/AlmaLinux — master and worker nodes.                           ║
# ║                                                                            ║
# ║  Features:                                                                 ║
# ║   • Multi-OS support  : Ubuntu · Debian · Rocky · RHEL · AlmaLinux         ║
# ║   • CNI options       : Calico (VXLAN) · Flannel                           ║
# ║   • Runtime options   : containerd · CRI-O                                 ║
# ║   • Host-Only network : kubelet --node-ip bound to 192.168.x.x             ║
# ║   • Idempotent        : safe to re-run, skips completed steps              ║
# ║                                                                            ║
# ║  Usage:                                                                    ║
# ║   sudo ./k8s-cluster-bootstrap.sh --init      Bootstrap cluster            ║
# ║   sudo ./k8s-cluster-bootstrap.sh --upgrade   Upgrade K8s version          ║
# ║   sudo ./k8s-cluster-bootstrap.sh --reset     Reset cluster (keep pkgs)    ║
# ║   sudo ./k8s-cluster-bootstrap.sh --destroy   Full uninstall everything    ║
# ║                                                                            ║
# ║  Author  : Sreekanth K                                                     ║
# ║  Email   : ksk5940@gmail.com                                               ║
# ║  Version : 1.0.0                                                           ║
# ╚════════════════════════════════════════════════════════════════════════════╝

set -o pipefail

# ════════════════════════════════════════════════════════════════════════════
# GLOBAL VARIABLES
# ════════════════════════════════════════════════════════════════════════════
# LOG_FILE is set dynamically in setup_logging() based on the active mode:
#   --init    -> k8s-init.log
#   --reset   -> k8s-reset.log
#   --upgrade -> k8s-upgrade.log
#   --destroy -> k8s-destroy.log
# The variable is declared here so early references (check_root) see it.
LOG_FILE="/var/log/k8s-bootstrap.log"   # overridden in setup_logging()
START_TIME=$(date +%s)

INIT_MODE=false
UPGRADE_MODE=false
RESET_MODE=false
DESTROY_MODE=false

TOTAL_STEPS=20
CURRENT_STEP=0

K8S_VERSION_FILE="/etc/kubernetes/k8s-version.txt"
CNI_CONFIG_FILE="/etc/kubernetes/cni-config.txt"
CNI_IFACE_FILE="/etc/kubernetes/cni-iface.txt"

POD_CIDR="10.244.0.0/16"

OS=""
PKG_MANAGER=""
PKG_UPDATE=""
PKG_INSTALL=""
RUNTIME=""
NODE_TYPE=""
HOST_ONLY_IFACE=""
HOST_ONLY_IP=""
K8S_VERSION=""
CNI_CHOICE=""
MASTER_IP=""

# ── Optional flag overrides (set by parse_arguments) ────────────────────────
ARG_HOST_CIDR=""        # --host-cidr  x.x.x.x/xx  override Host-Only CIDR detection
ARG_POD_CIDR=""         # --pod-cidr   x.x.x.x/xx  override default pod network CIDR
ARG_NODE_TYPE=""        # --node-type  master|worker  override hostname detection
ARG_TIMEZONE=""         # --timezone   Region/City|skip  default: empty = skip (keep existing)

# ════════════════════════════════════════════════════════════════════════════
# COLORS
# ════════════════════════════════════════════════════════════════════════════
GREEN=$'\033[1;32m'
RED=$'\033[1;31m'
YELLOW=$'\033[1;33m'
CYAN=$'\033[1;36m'
BLUE=$'\033[1;34m'
MAGENTA=$'\033[1;35m'
WHITE=$'\033[1;97m'
DIM=$'\033[2m'
BOLD=$'\033[1m'
NC=$'\033[0m'

show_usage() {

  WIDTH=76
  INNER=$((WIDTH-4))

  border() {
    printf "${CYAN}+"
    printf "%-${INNER}s" "" | tr ' ' '='
    printf "+${NC}\n"
  }

  line() {
    printf "${CYAN}|${NC} %-*s ${CYAN}|${NC}\n" "$INNER" "$1"
  }

  line_color() {
    local text="$1"
    local color="$2"
    local len=${#text}
    local pad=$((INNER - len))
    printf "${CYAN}|${NC} %b%s%b%*s ${CYAN}|${NC}\n" \
      "$color" "$text" "$NC" "$pad" ""
  }

  echo
  border

  # Header
  line_color "      KUBERNETES CLUSTER BOOTSTRAP" "${BOLD}${YELLOW}"
  line "Author : Sreekanth K"
  line "Email  : ksk5940@gmail.com"

  border

  line_color "Usage:" "$YELLOW"
  line_color "  sudo ./k8s-cluster-bootstrap.sh <mode> [flags]" "$GREEN"
  line ""

  line_color "Modes:" "$YELLOW"
  line_color "  --init      Init cluster / join worker" "$GREEN"
  line_color "  --upgrade   Upgrade Kubernetes" "$CYAN"
  line_color "  --reset     Reset cluster state" "$CYAN"
  line_color "  --destroy   Uninstall everything" "$RED"
  line ""

  line_color "Flags:" "$YELLOW"
  line_color "  --node-type master|worker" "$MAGENTA"
  line_color "  --host-cidr 192.168.56.x/24" "$MAGENTA"
  line_color "  --pod-cidr  10.244.0.0/16" "$MAGENTA"
  line_color "  --timezone  Region/City" "$MAGENTA"
  line ""

  line_color "Example:" "$YELLOW"
  line_color "  sudo ./k8s-cluster-bootstrap.sh --init" "$GREEN"

  border
  echo
  exit 1
}


parse_arguments() {
  if [[ $# -eq 0 ]]; then
    echo -e "${RED}❌ No option specified.${NC}"
    show_usage
  fi

  # First argument must be a mode
  case "$1" in
    --init)    INIT_MODE=true    ;;
    --upgrade) UPGRADE_MODE=true ;;
    --reset)   RESET_MODE=true   ;;
    --destroy) DESTROY_MODE=true ;;
    --help|-h) show_usage        ;;
    *)
      echo -e "${RED}❌ Unknown mode: ${WHITE}${1}${NC}"
      show_usage
      ;;
  esac
  shift

  # Parse optional flags
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --host-cidr)
        [[ -z "${2:-}" ]] && { echo -e "${RED}❌ --host-cidr requires a value (e.g. 192.168.56.0/24)${NC}"; exit 1; }
        ARG_HOST_CIDR="$2"; shift 2
        ;;
      --pod-cidr)
        [[ -z "${2:-}" ]] && { echo -e "${RED}❌ --pod-cidr requires a value (e.g. 10.244.0.0/16)${NC}"; exit 1; }
        ARG_POD_CIDR="$2"; shift 2
        ;;
      --node-type)
        [[ -z "${2:-}" ]] && { echo -e "${RED}❌ --node-type requires master or worker${NC}"; exit 1; }
        case "${2,,}" in
          master|worker) ARG_NODE_TYPE="${2,,}" ;;
          *) echo -e "${RED}❌ --node-type must be 'master' or 'worker', got: ${2}${NC}"; exit 1 ;;
        esac
        shift 2
        ;;
      --timezone)
        [[ -z "${2:-}" ]] && { echo -e "${RED}❌ --timezone requires a value (e.g. Asia/Kolkata or skip)${NC}"; exit 1; }
        ARG_TIMEZONE="$2"; shift 2
        ;;
      *)
        echo -e "${RED}❌ Unknown flag: ${WHITE}${1}${NC}"
        show_usage
        ;;
    esac
  done

  # Validate flag/mode combinations — these flags are only valid with --init
  local _init_only_flags=""
  [[ -n "$ARG_HOST_CIDR" ]] && _init_only_flags+=" --host-cidr"
  [[ -n "$ARG_POD_CIDR"  ]] && _init_only_flags+=" --pod-cidr"
  [[ -n "$ARG_TIMEZONE" && "${ARG_TIMEZONE,,}" != "skip" ]] && _init_only_flags+=" --timezone"
  if [[ -n "$_init_only_flags" && "$INIT_MODE" != true ]]; then
    echo -e "${RED}❌ Flags${_init_only_flags} are only valid with --init${NC}"
    exit 1
  fi

  # Apply overrides
  [[ -n "$ARG_POD_CIDR" ]] && POD_CIDR="$ARG_POD_CIDR"
}

# ════════════════════════════════════════════════════════════════════════════
# ROOT CHECK
# ════════════════════════════════════════════════════════════════════════════
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ⚠️  ROOT ACCESS REQUIRED                                        ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}Run as: ${WHITE}sudo ./k8s-cluster-bootstrap.sh $*${NC}"
    exit 1
  fi
  mkdir -p /var/log
  touch "$LOG_FILE"
}

# ════════════════════════════════════════════════════════════════════════════
# UTILITIES
# ════════════════════════════════════════════════════════════════════════════

# log() — write a plain timestamped entry directly to the log file.
# Used for internal script events that are NOT echoed to the console.
log() { echo "$(date '+%F %T') | $1" >> "$LOG_FILE"; }

# ── Setup full console → log mirroring ──────────────────────────────────────
# Everything printed to stdout and stderr (every echo, every command output)
# is:
#   1. Shown on the console WITH color (original stream untouched)
#   2. Stripped of ANSI escape codes and written to LOG_FILE with a timestamp
#      per line so every event has an exact time.
#
# Pattern:
#   exec > >(tee >(strip_ansi | timestamp >> LOG_FILE)) 2>&1
#
# The _strip_color helper removes ANSI SGR codes so the log file is clean text.
_strip_color() {
  # Use printf to build sed script with real ESC (\033) so sed anchors correctly
  sed "$(printf 's/\033\[[0-9;]*[mKHfABCDJsu]//g; s/\033(B//g')"
}

_timestamp_lines() {
  while IFS= read -r _line; do
    printf '%s | %s
' "$(date '+%F %T')" "$_line"
  done
}

setup_logging() {
  mkdir -p /var/log

  # ── Choose log file based on active mode ─────────────────────────────────
  # Each operation gets its own dedicated log file so init/reset/upgrade/destroy
  # output never mixes.  Previous runs are rotated (last 3 kept) so history
  # is preserved without the file growing unbounded.
  local _TS; _TS=$(date '+%Y%m%d-%H%M%S')
  if   [[ "$INIT_MODE"    == true ]]; then LOG_FILE="/var/log/k8s-init.log"
  elif [[ "$RESET_MODE"   == true ]]; then LOG_FILE="/var/log/k8s-reset.log"
  elif [[ "$UPGRADE_MODE" == true ]]; then LOG_FILE="/var/log/k8s-upgrade.log"
  elif [[ "$DESTROY_MODE" == true ]]; then LOG_FILE="/var/log/k8s-destroy.log"
  else                                     LOG_FILE="/var/log/k8s-bootstrap.log"
  fi

  # ── Rotate previous log ───────────────────────────────────────────────────
  # Archive any existing log with a timestamp suffix before opening a fresh one.
  if [[ -s "$LOG_FILE" ]]; then
    local _BASE="${LOG_FILE%.log}"
    mv "$LOG_FILE" "${_BASE}-${_TS}.log" 2>/dev/null || true
    # Keep only the 3 most recent rotated copies; prune older ones
    ls -1t "${_BASE}"-????????-??????.log 2>/dev/null \
      | tail -n +4 | xargs rm -f 2>/dev/null || true
  fi

  touch "$LOG_FILE"

  # Write a session header so each run is clearly delimited in the log
  {
    echo ""
    echo "════════════════════════════════════════════════════════════════"
    echo "$(date '+%F %T') | SESSION START  args: $*"
    echo "  Log file : $LOG_FILE"
    echo "════════════════════════════════════════════════════════════════"
  } >> "$LOG_FILE"

  # On exit (success or error), write a session footer with exit code
  trap '_EC=$?; {
    echo "════════════════════════════════════════════════════════════════"
    echo "$(date '"'"'+%F %T'"'"') | SESSION END    exit_code=${_EC}"
    echo "════════════════════════════════════════════════════════════════"
    echo ""
  } >> "$LOG_FILE"' EXIT

  # Redirect: stdout → tee → (console AND timestamped log)
  #           stderr → same pipe (2>&1 after the exec)
  exec > >(tee >(_strip_color | _timestamp_lines >> "$LOG_FILE")) 2>&1

  echo -e "${DIM}  Log: ${WHITE}${LOG_FILE}${NC}"
}

run_cmd() {
  log "Executing: $1"
  eval "$1" >> "$LOG_FILE" 2>&1
  if [[ $? -ne 0 ]]; then
    echo -e "   ${RED}❌ FAILED${NC}"; log "FAILED: $1"; return 1
  else
    echo -e "   ${GREEN}✔${NC}"; log "SUCCESS: $1"; return 0
  fi
}

progress() {
  CURRENT_STEP=$((CURRENT_STEP + 1))
  local PCT=$(( CURRENT_STEP * 100 / TOTAL_STEPS ))
  local BAR_WIDTH=50
  local FILLED=$(( PCT * BAR_WIDTH / 100 ))
  local EMPTY=$(( BAR_WIDTH - FILLED ))
  [[ $EMPTY -lt 0 ]] && EMPTY=0
  local BAR; BAR=$(printf '%0.s█' $(seq 1 $FILLED 2>/dev/null) 2>/dev/null || printf "%${FILLED}s" | tr ' ' '█')
  local SPC; SPC=$(printf "%${EMPTY}s")
  printf "\n${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}Progress:${NC} ${WHITE}[%3d%%]${NC} ${GREEN}%s${DIM}%s${NC}  ${CYAN}║${NC}\n" "$PCT" "$BAR" "$SPC"
  printf "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}\n"
}

progress_complete() {
  local BAR; BAR=$(printf '%0.s█' $(seq 1 50))
  printf "\n${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}\n"
  printf "${CYAN}║${NC}  ${YELLOW}Progress:${NC} ${WHITE}[100%%]${NC} ${GREEN}%s${NC}  ${CYAN}║${NC}\n" "$BAR"
  printf "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}\n"
}

print_header() {
  local title="$1"
  local BOX_INNER=64          # characters between the ║ borders
  local title_len=${#title}
  local pad=$(( BOX_INNER - title_len - 2 ))   # 2 = leading spaces
  [[ $pad -lt 0 ]] && pad=0
  local spc; spc=$(printf "%${pad}s")
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${NC}  ${BOLD}${CYAN}${title}${NC}${spc}${BLUE}║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

prompt_input() {
  local label="$1" varname="$2" default="${3:-}"
  printf "${CYAN}%s${NC}" "$label"
  read -r "$varname"
  if [[ -z "${!varname}" && -n "$default" ]]; then
    printf -v "$varname" "%s" "$default"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 1: OS DETECTION
# ════════════════════════════════════════════════════════════════════════════
detect_os() {
  progress
  echo -e "${YELLOW}🔍 Detecting Operating System...${NC}"
  source /etc/os-release
  OS="$ID"
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    PKG_MANAGER="apt"; PKG_UPDATE="apt-get update -y"; PKG_INSTALL="apt-get install -y"
  elif [[ "$OS" =~ (rhel|rocky|centos|almalinux) ]]; then
    PKG_MANAGER="dnf"; PKG_UPDATE="dnf makecache"; PKG_INSTALL="dnf install -y"
  else
    echo -e "${RED}❌ Unsupported OS: $OS${NC}"; exit 1
  fi
  echo -e "${GREEN}✓ OS: ${WHITE}$OS${NC}"
  log "OS=$OS PKG_MANAGER=$PKG_MANAGER"
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 2: TIMEZONE
# ════════════════════════════════════════════════════════════════════════════
configure_timezone() {
  echo ""
  echo -e "${YELLOW}🕐 Configuring Timezone...${NC}"
  local CTZ; CTZ=$(timedatectl show --property=Timezone --value 2>/dev/null || echo "Unknown")

  if [[ "${ARG_TIMEZONE,,}" == "skip" || -z "$ARG_TIMEZONE" ]]; then
    # Default: leave timezone untouched
    echo -e "${GREEN}✓ Timezone: ${WHITE}${CTZ}${GREEN} (unchanged — use --timezone to set)${NC}"
  else
    # Validate the requested timezone exists
    if ! timedatectl list-timezones 2>/dev/null | grep -qx "$ARG_TIMEZONE"; then
      echo -e "${RED}❌ Unknown timezone: '${ARG_TIMEZONE}'${NC}"
      echo -e "${YELLOW}   Run: timedatectl list-timezones | grep <Region>${NC}"
      exit 1
    fi
    if [[ "$CTZ" == "$ARG_TIMEZONE" ]]; then
      echo -e "${GREEN}✓ Timezone: ${WHITE}${CTZ}${GREEN} (already set)${NC}"
    else
      timedatectl set-timezone "$ARG_TIMEZONE"
      echo -e "${GREEN}✓ Timezone → ${WHITE}${ARG_TIMEZONE}${NC}"
    fi
  fi

  # Sync time regardless of timezone change
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    systemctl enable --now systemd-timesyncd
    systemctl restart systemd-timesyncd
  elif [[ "$OS" =~ (rhel|rocky|centos|almalinux) ]]; then
    command -v chronyd &>/dev/null || $PKG_INSTALL chrony >> "$LOG_FILE" 2>&1
    systemctl enable --now chronyd >> "$LOG_FILE" 2>&1
    chronyc makestep >> "$LOG_FILE" 2>&1
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 3: NETWORK VALIDATION
# ════════════════════════════════════════════════════════════════════════════

_detect_ip_method() {
  local iface="$1" f method

  # NetworkManager
  local nm_dir="/etc/NetworkManager/system-connections"
  if [[ -d "$nm_dir" ]]; then
    for f in "$nm_dir"/*.nmconnection "$nm_dir"/*; do
      [[ -f "$f" ]] || continue
      grep -qiE "^interface-name=\"?${iface}\"?$" "$f" 2>/dev/null || continue
      method=$(grep -i "^method=" "$f" 2>/dev/null | head -1 | cut -d= -f2 | tr -d '"' | tr '[:upper:]' '[:lower:]')
      case "$method" in
        manual|shared|disabled|link-local) echo "static"; return ;;
        auto|dhcp)                         echo "dhcp";   return ;;
      esac
    done
  fi

  # Netplan
  for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
    [[ -f "$f" ]] || continue
    grep -q "$iface" "$f" 2>/dev/null || continue
    local in_iface=false
    while IFS= read -r line; do
      echo "$line" | grep -qE "^\s+${iface}:" && in_iface=true
      if [[ "$in_iface" == true ]]; then
        echo "$line" | grep -qiE "dhcp4:\s*(true|yes)"  && echo "dhcp"   && return
        echo "$line" | grep -qiE "dhcp4:\s*(false|no)"  && echo "static" && return
        echo "$line" | grep -qiE "^\s*addresses:"        && echo "static" && return
      fi
    done < "$f"
  done

  # /etc/network/interfaces
  if [[ -f /etc/network/interfaces ]]; then
    local in_iface=false
    while IFS= read -r line; do
      echo "$line" | grep -qE "^iface\s+${iface}\s+" && in_iface=true
      if [[ "$in_iface" == true ]]; then
        echo "$line" | grep -qiE "\bdhcp\b"   && echo "dhcp"   && return
        echo "$line" | grep -qiE "\bstatic\b" && echo "static" && return
      fi
    done < /etc/network/interfaces
  fi

  echo "unknown"
}


validate_network_config() {
  echo -e "${YELLOW}🌐 Validating network adapters...${NC}"
  echo ""

  local failed=false

  # ── Resolve Host-Only adapter ─────────────────────────────────────────────
  # If --host-cidr supplied: match that specific subnet.
  # Otherwise: fall back to auto-detect 192.168.x.x (VMware Host-Only default).
  if [[ -n "$ARG_HOST_CIDR" ]]; then
    # Extract the network prefix (e.g. "10.10.0" from "10.10.0.0/24")
    local HO_PREFIX; HO_PREFIX=$(echo "$ARG_HOST_CIDR" | cut -d/ -f1 | awk -F. '{print $1"."$2"."$3}')
    HOST_ONLY_IP=$(ip -4 addr | awk "/inet ${HO_PREFIX//./\.}\./ {print \$2}" | cut -d/ -f1 | head -1)
    HOST_ONLY_IFACE=$(ip -4 addr | awk "/inet ${HO_PREFIX//./\.}\./ {print \$NF}" | head -1)
    echo -e "${CYAN}  Host-Only CIDR override: ${WHITE}${ARG_HOST_CIDR}${NC}"
  else
    HOST_ONLY_IP=$(ip -4 addr | awk '/inet 192\.168\./ {print $2}' | cut -d/ -f1 | head -1)
    HOST_ONLY_IFACE=$(ip -4 addr | awk '/inet 192\.168\./ {print $NF}' | head -1)
  fi

  if [[ -z "$HOST_ONLY_IP" ]]; then
    local cidr_hint="${ARG_HOST_CIDR:-192.168.x.x}"
    echo -e "${RED}❌ Host-Only : not found (no ${cidr_hint} interface detected)${NC}"
    echo -e "${YELLOW}   Tip: use --host-cidr <network/prefix> if your Host-Only is not 192.168.x.x${NC}"
    failed=true
  else
    local ho_method
    ho_method=$(_detect_ip_method "$HOST_ONLY_IFACE")
    if [[ "$ho_method" == "dhcp" ]]; then
      echo -e "${RED}❌ Host-Only : ${WHITE}${HOST_ONLY_IFACE}${RED} → ${WHITE}${HOST_ONLY_IP}${RED} (DHCP — static required)${NC}"
      failed=true
    else
      echo -e "${GREEN}✓  Host-Only : ${BOLD}${WHITE}${HOST_ONLY_IFACE}${NC}${GREEN} → ${BOLD}${WHITE}${HOST_ONLY_IP}${NC}${GREEN} [static]${NC}"
      MASTER_IP="$HOST_ONLY_IP"
    fi
  fi

  # ── Resolve NAT adapter ───────────────────────────────────────────────────
  # Exclude the Host-Only IP and loopback, then pick first remaining private IP.
  # Covers 10.x, 172.16-31.x, and any other private range used for NAT/internet.
  NAT_IP=$(ip -4 addr \
    | awk '/inet (10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)/ && !/127\./' \
    | awk '{print $2}' | cut -d/ -f1 \
    | grep -v "^${HOST_ONLY_IP}$" | head -1)
  NAT_IFACE=$(ip -4 addr \
    | awk '/inet (10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.)/ && !/127\./' \
    | awk -v ho="${HOST_ONLY_IP}" '{ip=$2; iface=$NF; sub(/\/.*/, "", ip); if (ip != ho) print iface}' \
    | head -1)

  if [[ -z "$NAT_IP" ]]; then
    echo -e "${YELLOW}⚠️  NAT       : not found — internet access may be limited${NC}"
    # NAT missing is a warning not a hard failure; cluster can still work on Host-Only only
  else
    local nat_method
    nat_method=$(_detect_ip_method "$NAT_IFACE")
    if [[ "$nat_method" == "dhcp" ]]; then
      echo -e "${YELLOW}⚠️  NAT       : ${WHITE}${NAT_IFACE}${YELLOW} → ${WHITE}${NAT_IP}${YELLOW} (DHCP — acceptable for internet adapter)${NC}"
    else
      echo -e "${GREEN}✓  NAT       : ${BOLD}${WHITE}${NAT_IFACE}${NC}${GREEN} → ${BOLD}${WHITE}${NAT_IP}${NC}${GREEN} [static]${NC}"
    fi
  fi

  echo ""
  if [[ "$failed" == true ]]; then
    echo -e "${RED}❌ Network validation failed. Fix the above and re-run.${NC}"
    return 1
  fi

  echo -e "${GREEN}✓ Network validation passed — Host-Only: ${WHITE}${HOST_ONLY_IP}${GREEN} on ${WHITE}${HOST_ONLY_IFACE}${NC}"
  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 4: HOSTNAME VALIDATION
# ════════════════════════════════════════════════════════════════════════════
validate_hostname() {
  progress
  echo -e "${YELLOW}🏷️  Validating Hostname...${NC}"

  if [[ -n "$ARG_NODE_TYPE" ]]; then
    # --node-type flag overrides hostname detection
    NODE_TYPE="$ARG_NODE_TYPE"
    echo -e "${CYAN}  Node type override: ${WHITE}--node-type ${NODE_TYPE}${NC}"
  else
    local HN; HN=$(hostname | tr '[:upper:]' '[:lower:]')
    if [[ "$HN" =~ master|control ]]; then
      NODE_TYPE="master"
    elif [[ "$HN" =~ worker|node ]]; then
      NODE_TYPE="worker"
    else
      echo -e "${RED}❌ Cannot detect node type from hostname: '$(hostname)'${NC}"
      echo -e "${YELLOW}   Hostname must contain: master, control, worker, or node${NC}"
      echo -e "${YELLOW}   Examples: k8s-master-01  k8s-worker-01  control-plane-1${NC}"
      echo -e "${YELLOW}   Or use: --node-type master|worker${NC}"
      exit 1
    fi
  fi

  echo -e "${GREEN}✓ Node Type: ${BOLD}${WHITE}${NODE_TYPE^^}${NC}"
  local FHN; FHN=$(hostname)

  # ── /etc/hosts: ensure HOST_ONLY_IP → hostname is present ─────────────────
  # Required on ALL OS for both master and worker so kubeadm init/join resolves
  # the node's hostname to its real cluster IP (not loopback, not NAT).
  if [[ -z "$HOST_ONLY_IP" ]]; then
    echo -e "${RED}   ❌ HOST_ONLY_IP is not set — cannot add /etc/hosts entry${NC}"
    log "ERROR: HOST_ONLY_IP empty in validate_hostname for ${NODE_TYPE} (${FHN})"
    exit 1
  fi

  # Check 1: correct entry already present → skip
  if grep -qE "^${HOST_ONLY_IP}[[:space:]]+${FHN}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    echo -e "${CYAN}   ℹ️  /etc/hosts: ${HOST_ONLY_IP} → ${FHN} already present${NC}"

  # Check 2: hostname present but mapped to a DIFFERENT IP → fix it
  elif grep -qE "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+${FHN}([[:space:]]|$)" /etc/hosts 2>/dev/null; then
    local _OLD_IP
    _OLD_IP=$(grep -E "^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+[[:space:]]+${FHN}([[:space:]]|$)" /etc/hosts \
              | awk '{print $1}' | head -1)
    echo -e "${YELLOW}   ⚠️  /etc/hosts: ${FHN} mapped to stale IP ${_OLD_IP} — updating to ${HOST_ONLY_IP}${NC}"
    sed -i "/^[0-9]\+\.[0-9]\+\.[0-9]\+\.[0-9]\+[[:space:]]\+${FHN}/d" /etc/hosts
    printf "%s\t%s\n" "${HOST_ONLY_IP}" "${FHN}" >> /etc/hosts
    log "/etc/hosts: replaced stale ${_OLD_IP} → ${FHN} with ${HOST_ONLY_IP} → ${FHN}"
    echo -e "${GREEN}   ✓ /etc/hosts: updated ${HOST_ONLY_IP} → ${FHN}${NC}"

  # Check 3: no entry at all → add it
  else
    printf "%s\t%s\n" "${HOST_ONLY_IP}" "${FHN}" >> /etc/hosts
    log "/etc/hosts: added ${HOST_ONLY_IP} → ${FHN} (${NODE_TYPE}, ${OS})"
    echo -e "${GREEN}   ✓ /etc/hosts: added ${HOST_ONLY_IP} → ${FHN} (${NODE_TYPE^^})${NC}"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 5: SWAP
# ════════════════════════════════════════════════════════════════════════════
disable_swap() {
  echo ""
  local ST; ST=$(free | grep Swap | awk '{print $2}')
  if [[ "$ST" -gt 0 ]]; then
    echo -e "${YELLOW}🔄 Disabling Swap...${NC}"
    swapoff -a
    if grep -q "^[^#].*swap" /etc/fstab; then
      cp /etc/fstab "/etc/fstab.backup-$(date +%Y%m%d-%H%M%S)"
      sed -i.tmp '/[[:space:]]swap[[:space:]]/ s/^/#/' /etc/fstab
    fi
    echo -e "${GREEN}✓ Swap disabled${NC}"
  else
    echo -e "${GREEN}✓ Swap already disabled${NC}"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 6: FIREWALL
# ════════════════════════════════════════════════════════════════════════════
configure_firewall() {
  progress
  echo -e "${YELLOW}🛡️  Configuring Firewall...${NC}"
  local FWT="none" FWA=false
  command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active" && FWT="ufw" && FWA=true
  command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld && FWT="firewalld" && FWA=true
  echo -e "${CYAN}   Type: ${WHITE}${FWT}${NC}"
  if [[ "$FWA" == true ]]; then
    if [[ "$NODE_TYPE" == "master" ]]; then
      if [[ "$FWT" == "ufw" ]]; then
        ufw allow 22/tcp comment 'SSH'
        ufw allow 6443/tcp comment 'K8s API'
        ufw allow 2379:2380/tcp comment 'etcd'
        ufw allow 10250/tcp comment 'Kubelet'
        ufw allow 10259/tcp comment 'scheduler'
        ufw allow 10257/tcp comment 'controller'
        ufw allow 4789/udp comment 'VXLAN'
        ufw allow 8472/udp comment 'Flannel VXLAN'
        ufw allow 30000:32767/tcp comment 'NodePort'
      elif [[ "$FWT" == "firewalld" ]]; then
        for p in 22/tcp 6443/tcp 2379-2380/tcp 10250/tcp 10259/tcp 10257/tcp 4789/udp 8472/udp 30000-32767/tcp; do
          firewall-cmd --permanent --add-port=$p
        done
        firewall-cmd --reload
      fi
    else
      if [[ "$FWT" == "ufw" ]]; then
        ufw allow 22/tcp comment 'SSH'
        ufw allow 10250/tcp comment 'Kubelet'
        ufw allow 10256/tcp comment 'kube-proxy'
        ufw allow 4789/udp comment 'VXLAN'
        ufw allow 8472/udp comment 'Flannel VXLAN'
      elif [[ "$FWT" == "firewalld" ]]; then
        for p in 22/tcp 10250/tcp 10256/tcp 4789/udp 8472/udp; do
          firewall-cmd --permanent --add-port=$p
        done
        firewall-cmd --reload
      fi
    fi
    echo -e "${GREEN}✓ Firewall rules applied (BGP port 179 omitted — BGP disabled)${NC}"
  else
    echo -e "${CYAN}ℹ️  No active firewall — skipping (ensure external FW allows K8s ports)${NC}"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 7: INSTALL PREREQUISITES
# ════════════════════════════════════════════════════════════════════════════
install_prerequisites() {
  progress
  echo -e "${YELLOW}📦 Installing prerequisites...${NC}"

  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    echo -e "${CYAN}  ⬇  Updating apt cache...${NC}"
    apt-get update -qq >> "$LOG_FILE" 2>&1
    echo -e "${CYAN}  ⬇  Installing curl wget ca-certificates gnupg...${NC}"
    apt-get install -y -qq curl wget ca-certificates gnupg >> "$LOG_FILE" 2>&1
    echo -e "${GREEN}✓ Prerequisites installed${NC}"
  elif [[ "$OS" =~ (rhel|rocky|centos|almalinux) ]]; then
    echo -e "${CYAN}  ⬇  Refreshing dnf cache...${NC}"
    dnf makecache -q >> "$LOG_FILE" 2>&1
    echo -e "${CYAN}  ⬇  Installing curl wget ca-certificates gnupg2...${NC}"
    dnf install -y -q curl wget ca-certificates gnupg2 >> "$LOG_FILE" 2>&1
    echo -e "${GREEN}✓ Prerequisites installed${NC}"
  fi

  echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 8: KERNEL MODULES & SYSCTL
# ════════════════════════════════════════════════════════════════════════════
configure_kernel() {
  progress
  echo -e "${YELLOW}⚙️  Configuring kernel modules and sysctl...${NC}"
  modprobe overlay
  modprobe br_netfilter
  cat > /etc/modules-load.d/k8s.conf << 'MEOF'
overlay
br_netfilter
MEOF
  cat > /etc/sysctl.d/k8s.conf << 'SEOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
SEOF
  sysctl --system >> "$LOG_FILE" 2>&1
  echo -e "${GREEN}✓ Kernel configuration applied${NC}"
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 9: DNS
# ════════════════════════════════════════════════════════════════════════════
configure_dns() {
  echo ""
  echo -e "${YELLOW}🌐 Configuring DNS Resolver...${NC}"
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    systemctl enable systemd-resolved 2>/dev/null
    systemctl start  systemd-resolved 2>/dev/null
    [[ -f /run/systemd/resolve/resolv.conf ]] && \
      ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
  elif [[ "$OS" =~ (rhel|rocky|centos|almalinux) ]]; then
    grep -q "nameserver" /etc/resolv.conf || echo "nameserver 8.8.8.8" > /etc/resolv.conf
  fi
  echo -e "${GREEN}✓ DNS configured${NC}"
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 10: K8s REPO SETUP
# Prerequisites (curl, gnupg, ca-certificates) already installed in step 7.
# This step just ensures the APT keyring directory exists for Ubuntu,
# then configure_k8s_repo_for_version() handles the actual repo file.
# ════════════════════════════════════════════════════════════════════════════
setup_k8s_repositories() {
  progress
  echo -e "${YELLOW}📦 Setting up Kubernetes repository...${NC}"
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    mkdir -p /etc/apt/keyrings && chmod 755 /etc/apt/keyrings
    echo -e "${GREEN}✓ APT keyring directory ready${NC}"
  elif [[ "$OS" =~ (rhel|rocky|centos|almalinux) ]]; then
    echo -e "${GREEN}✓ DNF repository will be configured for selected version${NC}"
  fi
  echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# CONFIGURE K8s REPO FOR MINOR VERSION
# ════════════════════════════════════════════════════════════════════════════
configure_k8s_repo_for_version() {
  local minor="$1"
  log "Configuring K8s repo for v${minor}"
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    local KR="/etc/apt/keyrings/kubernetes-apt-keyring.gpg"
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/v${minor}/deb/Release.key" 2>/dev/null \
      | gpg --dearmor --yes -o "$KR" 2>/dev/null
    echo "deb [signed-by=${KR}] https://pkgs.k8s.io/core:/stable:/v${minor}/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list
    apt-get update -qq
    echo -e "${GREEN}   ✓ APT repo → pkgs.k8s.io/core:/stable:/v${minor}/deb/${NC}"
  elif [[ "$OS" =~ (rhel|rocky|centos|almalinux) ]]; then
    # exclude= prevents accidental upgrades via 'dnf update'.
    # install_k8s_components() uses --disableexcludes=kubernetes to bypass it intentionally.
    cat > /etc/yum.repos.d/kubernetes.repo << REOF
[kubernetes]
name=Kubernetes v${minor}
baseurl=https://pkgs.k8s.io/core:/stable:/v${minor}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/core:/stable:/v${minor}/rpm/repodata/repomd.xml.key
exclude=kubelet kubeadm kubectl cri-tools kubernetes-cni
REOF
    dnf makecache --disablerepo="*" --enablerepo="kubernetes" >> "$LOG_FILE" 2>&1
    echo -e "${GREEN}   ✓ DNF repo → pkgs.k8s.io/core:/stable:/v${minor}/rpm/${NC}"
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# STATIC VERSION TABLE (no live probing)
# ════════════════════════════════════════════════════════════════════════════
show_static_version_table() {
  echo ""
  echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BLUE}║${NC}         ${BOLD}${WHITE}KUBERNETES VERSION SELECTION${NC}                           ${BLUE}║${NC}"
  echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
  echo -e "${CYAN}  Supported stable versions from pkgs.k8s.io:${NC}"
  echo ""
  printf "  ${BLUE}╔══════════╦════════════════╦════════════════════════════════════╗${NC}\n"
  printf "  ${BLUE}║${NC} ${BOLD}${WHITE}%-8s${NC} ${BLUE}║${NC} ${BOLD}${WHITE}%-14s${NC} ${BLUE}║${NC} ${BOLD}${WHITE}%-34s${NC} ${BLUE}║${NC}\n" \
    "Minor" "Status" "Stable Patch Versions"
  printf "  ${BLUE}╠══════════╬════════════════╬════════════════════════════════════╣${NC}\n"

  local -a MINORS=( "1.33"      "1.32"     "1.31"     "1.30"      "1.29"   )
  local -a LABELS=( "🚀 Latest" "✓ Stable" "✓ Stable" "🛡  LTS"   "⚠ EOL"  )
  local -a COLOURS=( "$BLUE"    "$GREEN"   "$GREEN"   "$MAGENTA"  "$DIM"   )
  local -a PATCHES=(
    "1.33.0  1.33.1  1.33.2"
    "1.32.0  1.32.1  1.32.2  1.32.3  1.32.4  1.32.5"
    "1.31.0  1.31.1  1.31.2  1.31.3  1.31.4  1.31.5  1.31.6  1.31.7  1.31.8  1.31.9"
    "1.30.0  1.30.1  1.30.2  1.30.3  1.30.4  1.30.5  1.30.6  1.30.7  1.30.8  1.30.9  1.30.10  1.30.11  1.30.12  1.30.13"
    "1.29.0  1.29.1  1.29.2  1.29.3  1.29.4  1.29.5  1.29.6  1.29.7  1.29.8  1.29.9  1.29.10  1.29.11  1.29.12  1.29.13  1.29.14  1.29.15"
  )

  for i in "${!MINORS[@]}"; do
    local minor="${MINORS[$i]}" label="${LABELS[$i]}" colour="${COLOURS[$i]}"
    local patches="${PATCHES[$i]}" first_row=true line="" token
    for token in $patches; do
      if [[ ${#line} -eq 0 ]]; then line="$token"
      elif [[ $(( ${#line} + 2 + ${#token} )) -le 34 ]]; then line="$line  $token"
      else
        if [[ "$first_row" == true ]]; then
          printf "  ${BLUE}║${NC} ${colour}%-8s${NC} ${BLUE}║${NC} ${colour}%-14s${NC} ${BLUE}║${NC} ${WHITE}%-34s${NC} ${BLUE}║${NC}\n" \
            "$minor" "$label" "$line"
          first_row=false
        else
          printf "  ${BLUE}║${NC} %-8s ${BLUE}║${NC} %-14s ${BLUE}║${NC} ${WHITE}%-34s${NC} ${BLUE}║${NC}\n" "" "" "$line"
        fi
        line="$token"
      fi
    done
    if [[ -n "$line" ]]; then
      if [[ "$first_row" == true ]]; then
        printf "  ${BLUE}║${NC} ${colour}%-8s${NC} ${BLUE}║${NC} ${colour}%-14s${NC} ${BLUE}║${NC} ${WHITE}%-34s${NC} ${BLUE}║${NC}\n" \
          "$minor" "$label" "$line"
      else
        printf "  ${BLUE}║${NC} %-8s ${BLUE}║${NC} %-14s ${BLUE}║${NC} ${WHITE}%-34s${NC} ${BLUE}║${NC}\n" "" "" "$line"
      fi
    fi
    [[ $i -lt $(( ${#MINORS[@]} - 1 )) ]] && \
      printf "  ${BLUE}╠══════════╬════════════════╬════════════════════════════════════╣${NC}\n"
  done
  printf "  ${BLUE}╚══════════╩════════════════╩════════════════════════════════════╝${NC}\n"
  echo ""
  echo -e "  ${YELLOW}💡 Enter the full patch version (e.g. ${WHITE}1.32.3${YELLOW})${NC}"
  echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# VERSION GUARD
# ════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════
# STEP 11: VERSION SELECTION
#
# Idempotency matrix:
#   All K8s tools present    → show installed versions, ask yes/upgrade, skip
#   Only some tools present  → detect the installed version, proceed to
#                              install_k8s_components to fill the gap
#   No tools present         → show version table and ask user
#   Worker w/ K8S_VERSION_FILE → use master's version silently
# ════════════════════════════════════════════════════════════════════════════
select_k8s_version() {
  progress

  # ── Detect what is already installed ─────────────────────────────────────
  local KUBEADM_VER; KUBEADM_VER=$(_get_installed_k8s_version kubeadm)
  local KUBELET_VER;  KUBELET_VER=$(_get_installed_k8s_version kubelet)
  local KUBECTL_VER
  command -v kubectl &>/dev/null && \
    KUBECTL_VER=$(kubectl version --client -o json 2>/dev/null \
      | grep '"gitVersion"' | head -1 | awk -F'"' '{print $4}' | sed 's/^v//')

  # ── WORKER: K8S_VERSION_FILE written by master ───────────────────────────
  if [[ "$NODE_TYPE" == "worker" ]] && [[ -f "$K8S_VERSION_FILE" ]]; then
    K8S_VERSION=$(cat "$K8S_VERSION_FILE")
    echo -e "${GREEN}✓ Worker: using master version ${WHITE}v${K8S_VERSION}${NC}"
    local minor; minor=$(echo "$K8S_VERSION" | cut -d'.' -f1-2)
    configure_k8s_repo_for_version "$minor"
    return
  fi

  # ── ALL TOOLS INSTALLED: full idempotent path ─────────────────────────────
  # Master needs kubeadm + kubelet + kubectl.
  # Worker needs kubeadm + kubelet (kubectl is master-only).
  local _ALL_PRESENT=false
  if [[ "$NODE_TYPE" == "master" ]]; then
    [[ -n "$KUBEADM_VER" && -n "$KUBELET_VER" && -n "$KUBECTL_VER" ]] && _ALL_PRESENT=true
  else
    [[ -n "$KUBEADM_VER" && -n "$KUBELET_VER" ]] && _ALL_PRESENT=true
  fi

  if [[ "$_ALL_PRESENT" == true ]]; then
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║  ✔  KUBERNETES ALREADY INSTALLED                                 ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Installed versions:${NC}"
    echo -e "   ${GREEN}✓${NC} kubeadm  : ${WHITE}v${KUBEADM_VER}${NC}"
    echo -e "   ${GREEN}✓${NC} kubelet  : ${WHITE}v${KUBELET_VER}${NC}"
    [[ -n "$KUBECTL_VER" ]] && \
    echo -e "   ${GREEN}✓${NC} kubectl  : ${WHITE}v${KUBECTL_VER}${NC}"
    echo ""
    echo -e "  ${YELLOW}Use these versions and continue?${NC}"
    echo -e "  ${DIM}(Press Enter or type 'yes' to continue — 'no' to upgrade instead)${NC}"
    echo ""
    local _CONT
    prompt_input "  Continue with installed versions? (yes/no, default yes): " _CONT "yes"

    if [[ "${_CONT,,}" == "yes" || -z "$_CONT" ]]; then
      K8S_VERSION="$KUBELET_VER"
      log "Reusing installed K8s: kubeadm v${KUBEADM_VER} kubelet v${KUBELET_VER}"
      echo -e "${GREEN}✓ Using installed Kubernetes v${K8S_VERSION} — skipping version selection${NC}"
      # Ensure repo is configured for this version (needed for cri-tools install etc.)
      local minor; minor=$(echo "$K8S_VERSION" | cut -d'.' -f1-2)
      configure_k8s_repo_for_version "$minor"
      [[ "$NODE_TYPE" == "master" ]] && { mkdir -p /etc/kubernetes; echo "$K8S_VERSION" > "$K8S_VERSION_FILE"; }
      return
    else
      echo ""
      echo -e "${YELLOW}  To upgrade, run: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --upgrade${NC}"
      exit 0
    fi
  fi

  # ── PARTIAL INSTALL: one or more tools missing ────────────────────────────
  # install_k8s_components() will fill the gap — we just need to set K8S_VERSION
  # from whatever is already installed so it can install the missing piece
  # at the matching version without asking the user again.
  if [[ -n "$KUBEADM_VER" ]]; then
    K8S_VERSION="$KUBEADM_VER"
    echo -e "${CYAN}  ℹ️  kubeadm v${KUBEADM_VER} present — will complete missing components${NC}"
    local minor; minor=$(echo "$K8S_VERSION" | cut -d'.' -f1-2)
    configure_k8s_repo_for_version "$minor"
    [[ "$NODE_TYPE" == "master" ]] && { mkdir -p /etc/kubernetes; echo "$K8S_VERSION" > "$K8S_VERSION_FILE"; }
    return
  elif [[ -n "$KUBELET_VER" ]]; then
    K8S_VERSION="$KUBELET_VER"
    echo -e "${CYAN}  ℹ️  kubelet v${KUBELET_VER} present — will complete missing components${NC}"
    local minor; minor=$(echo "$K8S_VERSION" | cut -d'.' -f1-2)
    configure_k8s_repo_for_version "$minor"
    [[ "$NODE_TYPE" == "master" ]] && { mkdir -p /etc/kubernetes; echo "$K8S_VERSION" > "$K8S_VERSION_FILE"; }
    return
  fi

  # ── NO TOOLS INSTALLED: fresh install — ask user ─────────────────────────
  show_static_version_table

  local _DEFAULT_VER="1.30.2"
  echo -e "  ${DIM}⏱  Auto-selecting ${WHITE}${_DEFAULT_VER}${DIM} (LTS default) in ${WHITE}30s${DIM} if no input...${NC}"
  echo ""

  while true; do
    local _INPUT=""
    # Read with 30-second timeout; on timeout use default
    if read -r -t 30 -p "$(printf "${CYAN}Enter Kubernetes version (e.g. 1.32.3): ${NC}")" _INPUT; then
      K8S_VERSION="${_INPUT:-${_DEFAULT_VER}}"
    else
      echo ""
      echo -e "  ${YELLOW}⏱  No input — using default: ${WHITE}${_DEFAULT_VER}${NC}"
      K8S_VERSION="$_DEFAULT_VER"
    fi
    K8S_VERSION="${K8S_VERSION#v}"
    [[ -z "$K8S_VERSION" ]] && K8S_VERSION="$_DEFAULT_VER"
    [[ ! "$K8S_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] && \
      { echo -e "${RED}  ❌ Invalid format — use x.y.z (e.g. 1.32.3)${NC}"; continue; }

    local minor; minor=$(echo "$K8S_VERSION" | cut -d'.' -f1-2)
    echo -e "${CYAN}  Checking pkgs.k8s.io channel v${minor}...${NC}"
    local url http_code
    [[ "$OS" =~ (ubuntu|debian) ]] && \
      url="https://pkgs.k8s.io/core:/stable:/v${minor}/deb/" || \
      url="https://pkgs.k8s.io/core:/stable:/v${minor}/rpm/"
    http_code=$(curl -o /dev/null -s -w "%{http_code}" --max-time 8 "$url" 2>/dev/null)
    if [[ "$http_code" != "200" && "$http_code" != "301" && "$http_code" != "302" ]]; then
      echo -e "${RED}  ❌ Channel v${minor} not found (HTTP ${http_code}) — choose from table above${NC}"
      continue
    fi
    echo -e "${GREEN}  ✓ Channel v${minor} confirmed${NC}"

    configure_k8s_repo_for_version "$minor"
    [[ "$NODE_TYPE" == "master" ]] && { mkdir -p /etc/kubernetes; echo "$K8S_VERSION" > "$K8S_VERSION_FILE"; }
    break
  done
  print_header "Selected: Kubernetes v${K8S_VERSION}"
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 12: CONTAINER RUNTIME
# ════════════════════════════════════════════════════════════════════════════
setup_container_runtime() {
  progress
  echo -e "${YELLOW}🐳 Setting up Container Runtime...${NC}"

  # ── Detect already-installed runtime via package manager (most reliable) ─
  # Do NOT rely solely on `command -v` — the binary exists after install but
  # the package manager is the authoritative source.
  local _RT_FOUND=""
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    dpkg-query -W -f='${Status}' containerd    2>/dev/null | grep -q "ok installed" && _RT_FOUND="containerd"
    dpkg-query -W -f='${Status}' containerd.io 2>/dev/null | grep -q "ok installed" && _RT_FOUND="containerd"
    dpkg-query -W -f='${Status}' cri-o         2>/dev/null | grep -q "ok installed" && _RT_FOUND="crio"
  else
    rpm -q containerd    &>/dev/null && _RT_FOUND="containerd"
    rpm -q containerd.io &>/dev/null && _RT_FOUND="containerd"
    rpm -q cri-o         &>/dev/null && _RT_FOUND="crio"
  fi
  # Also accept binary-only detection (e.g. manually installed)
  [[ -z "$_RT_FOUND" ]] && command -v containerd &>/dev/null && _RT_FOUND="containerd"
  [[ -z "$_RT_FOUND" ]] && command -v crio       &>/dev/null && _RT_FOUND="crio"

  if [[ -n "$_RT_FOUND" ]]; then
    RUNTIME="$_RT_FOUND"
    local _RTV
    _RTV=$($RUNTIME --version 2>/dev/null | head -1 || echo "version unknown")
    echo -e "${GREEN}  ✓ Runtime already installed: ${WHITE}${RUNTIME}${NC}  ${DIM}(${_RTV})${NC}"
    echo -e "${GREEN}  ✓ Skipping runtime installation${NC}"

    # Ensure config is correct and service is running — idempotent
    if [[ "$RUNTIME" == "containerd" ]]; then
      if [[ ! -s /etc/containerd/config.toml ]] || \
         ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
        mkdir -p /etc/containerd
        containerd config default > /etc/containerd/config.toml 2>/dev/null
        sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
        echo -e "${CYAN}  ⚙️  containerd config updated (SystemdCgroup=true)${NC}"
      fi
    fi
    systemctl daemon-reload
    systemctl enable "$RUNTIME" 2>/dev/null || true
    if ! systemctl is-active --quiet "$RUNTIME"; then
      systemctl restart "$RUNTIME" 2>/dev/null && \
        echo -e "${CYAN}  ✓ ${RUNTIME} restarted${NC}" || \
        echo -e "${YELLOW}  ⚠️  ${RUNTIME} restart failed — check: journalctl -u ${RUNTIME} -n 20${NC}"
    fi
    return 0
  fi

  # ── No runtime installed — ask user ──────────────────────────────────────
  echo ""
  echo -e "${CYAN}  No container runtime detected. Select one to install:${NC}"
  echo ""
  echo -e "    ${WHITE}1${NC}) containerd  ${GREEN}(default — most stable, recommended)${NC}"
  echo -e "    ${WHITE}2${NC}) CRI-O       ${DIM}(OCI-native, Kubernetes-focused)${NC}"
  echo ""
  echo -e "  ${DIM}⏱  Auto-selecting ${WHITE}containerd${DIM} in ${WHITE}30s${DIM} if no input...${NC}"
  echo ""
  local RC=""
  if ! read -r -t 30 -p "$(printf "${CYAN}  Choice (1/2, default 1): ${NC}")" RC; then
    echo ""
    echo -e "  ${YELLOW}⏱  No input — using default: containerd${NC}"
    RC="1"
  fi
  RC="${RC:-1}"

  if [[ "$RC" == "2" ]]; then
    local CM="${K8S_VERSION%.*}" COK=false
    echo -e "${CYAN}  Installing CRI-O v${CM} on ${OS}...${NC}"

    if [[ "$PKG_MANAGER" == "apt" ]]; then
      local CRIO_KR="/etc/apt/keyrings/cri-o-apt-keyring.gpg"
      mkdir -p /etc/apt/keyrings
      echo -e "${CYAN}    ⬇  Fetching CRI-O GPG key from pkgs.k8s.io...${NC}"
      curl -fsSL "https://pkgs.k8s.io/addons:/cri-o/stable/v${CM}/deb/Release.key" 2>/dev/null \
        | gpg --dearmor --yes -o "$CRIO_KR" 2>/dev/null
      if [[ ! -s "$CRIO_KR" ]]; then
        echo -e "${RED}    ❌ CRI-O GPG key fetch failed — check network access to pkgs.k8s.io${NC}"
        log "CRI-O GPG key fetch failed for v${CM}/deb"
        COK=false
      else
        echo "deb [signed-by=${CRIO_KR}] https://pkgs.k8s.io/addons:/cri-o/stable/v${CM}/deb/ /" \
          > /etc/apt/sources.list.d/cri-o.list
        apt-get update -qq >> "$LOG_FILE" 2>&1
        echo -e "${CYAN}    ⬇  Installing runc...${NC}"
        apt-get install -y -qq runc >> "$LOG_FILE" 2>&1 || true
        echo -e "${CYAN}    ⬇  Installing cri-o (this may take a minute)...${NC}"
        apt-get install -y -qq cri-o >> "$LOG_FILE" 2>&1 && COK=true
      fi
    elif [[ "$PKG_MANAGER" == "dnf" ]]; then
      echo -e "${CYAN}    ⬇  Installing container-selinux dependency...${NC}"
      dnf install -y -q container-selinux >> "$LOG_FILE" 2>&1 || true
      echo -e "${CYAN}    ⬇  Writing CRI-O repo (pkgs.k8s.io/addons)...${NC}"
      cat > /etc/yum.repos.d/cri-o.repo << CREOF
[cri-o]
name=CRI-O v${CM}
baseurl=https://pkgs.k8s.io/addons:/cri-o/stable/v${CM}/rpm/
enabled=1
gpgcheck=1
gpgkey=https://pkgs.k8s.io/addons:/cri-o/stable/v${CM}/rpm/repodata/repomd.xml.key
CREOF
      local _CRIO_KEY_URL="https://pkgs.k8s.io/addons:/cri-o/stable/v${CM}/rpm/repodata/repomd.xml.key"
      rpm --import "$_CRIO_KEY_URL" >> "$LOG_FILE" 2>&1 || true
      dnf makecache --enablerepo="cri-o" >> "$LOG_FILE" 2>&1 || true
      echo -e "${CYAN}    ⬇  Installing cri-o (this may take a minute)...${NC}"
      dnf install -y -q --enablerepo="cri-o" cri-o >> "$LOG_FILE" 2>&1 && COK=true
    fi

    if [[ "$COK" == false ]]; then
      echo -e "${YELLOW}  ⚠️  CRI-O install failed — falling back to containerd${NC}"
      log "CRI-O install failed on ${OS} — falling back to containerd"
      RUNTIME="containerd"
      _install_containerd
    else
      RUNTIME="crio"
      echo -e "${GREEN}  ✓ CRI-O v${CM} installed${NC}"
    fi
  else
    RUNTIME="containerd"
    _install_containerd
  fi

  # ── Post-install config ───────────────────────────────────────────────────
  if [[ "$RUNTIME" == "containerd" ]]; then
    mkdir -p /etc/containerd
    if ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
      echo -e "${CYAN}  Applying containerd config (SystemdCgroup=true)...${NC}"
      containerd config default > /etc/containerd/config.toml
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      echo -e "${GREEN}  ✓ containerd: SystemdCgroup=true${NC}"
    else
      echo -e "${GREEN}  ✓ containerd config already correct (SystemdCgroup=true)${NC}"
    fi
  elif [[ "$RUNTIME" == "crio" ]]; then
    echo -e "${GREEN}  ✓ CRI-O: SystemdCgroup enabled by default${NC}"
  fi

  echo -e "${CYAN}  Enabling and starting ${RUNTIME}...${NC}"
  systemctl daemon-reload
  systemctl enable "$RUNTIME" 2>/dev/null || true
  if systemctl is-active --quiet "$RUNTIME"; then
    echo -e "${GREEN}✓ Runtime already running: ${WHITE}${RUNTIME}${NC} ${DIM}(active)${NC}"
  else
    systemctl restart "$RUNTIME" 2>/dev/null || true
    sleep 2
    if systemctl is-active --quiet "$RUNTIME"; then
      echo -e "${GREEN}✓ Runtime started: ${WHITE}${RUNTIME}${NC} ${DIM}(active)${NC}"
    else
      echo -e "${YELLOW}⚠️  ${RUNTIME} service not active — check: journalctl -u ${RUNTIME} -n 30${NC}"
      log "WARNING: ${RUNTIME} service not active after enable+restart"
    fi
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# CONTAINERD INSTALL HELPER
# Ubuntu/Debian : containerd package from apt (includes runc)
# Rocky/RHEL    : containerd.io from Docker's official repo (ships runc too)
#                 The distro containerd package is often outdated on RHEL9.
# ════════════════════════════════════════════════════════════════════════════
_install_containerd() {
  echo -e "${CYAN}  Installing Containerd on ${OS}...${NC}"

  if [[ "$PKG_MANAGER" == "apt" ]]; then
    # ── Ubuntu / Debian ──────────────────────────────────────────────────────
    echo -e "${CYAN}    ⬇  Refreshing apt cache...${NC}"
    apt-get update -qq >> "$LOG_FILE" 2>&1
    echo -e "${CYAN}    ⬇  Installing containerd (this may take a minute)...${NC}"
    apt-get install -y -qq containerd >> "$LOG_FILE" 2>&1

  else
    # ── Rocky / RHEL / AlmaLinux / CentOS ────────────────────────────────────
    #
    # ROOT CAUSE OF PREVIOUS FAILURE:
    #   The Docker CE repo baseurl uses $releasever which resolves to "9" on
    #   Rocky/RHEL 9 — but Docker's CentOS mirror only has dirs for 7 and 8,
    #   so the URL https://download.docker.com/linux/centos/9/x86_64/stable
    #   returns 404 and containerd.io is never found.
    #
    # FIX: detect the OS major version and pin the baseurl to "8" (the highest
    # CentOS-compatible dir Docker publishes) when running on RHEL/Rocky 9+.
    # containerd.io from the CentOS 8 repo installs and runs fine on RHEL 9.
    #
    local _DOCKER_RELVER
    local _OS_VER; _OS_VER=$(rpm -E '%{rhel}' 2>/dev/null || echo "8")
    if [[ "$_OS_VER" -ge 9 ]]; then
      _DOCKER_RELVER="8"   # Docker has no centos/9 dir — use centos/8 (compatible)
    else
      _DOCKER_RELVER="$_OS_VER"
    fi
    log "Docker repo: using centos/${_DOCKER_RELVER} for OS version ${_OS_VER}"

    # Write repo file with pinned releasever — avoids $releasever expanding to 9
    echo -e "${CYAN}    ⬇  Writing Docker CE repo (centos/${_DOCKER_RELVER})...${NC}"
    cat > /etc/yum.repos.d/docker-ce.repo << DCEOF
[docker-ce-stable]
name=Docker CE Stable - \$basearch
baseurl=https://download.docker.com/linux/centos/${_DOCKER_RELVER}/\$basearch/stable
enabled=1
gpgcheck=1
gpgkey=https://download.docker.com/linux/centos/gpg
DCEOF
    log "docker-ce.repo written: centos/${_DOCKER_RELVER}"

    # Import GPG key into RPM keyring so gpgcheck=1 passes without prompting
    echo -e "${CYAN}    ⬇  Importing Docker GPG key...${NC}"
    rpm --import https://download.docker.com/linux/centos/gpg >> "$LOG_FILE" 2>&1 || true

    # Refresh metadata for the docker repo only
    echo -e "${CYAN}    ⬇  Refreshing Docker repo metadata...${NC}"
    dnf makecache --enablerepo="docker-ce-stable" >> "$LOG_FILE" 2>&1 || true

    # Install containerd.io — the Docker-packaged build with runc bundled
    echo -e "${CYAN}    ⬇  Installing containerd.io from Docker repo (this may take a minute)...${NC}"
    dnf install -y -q --enablerepo="docker-ce-stable" containerd.io >> "$LOG_FILE" 2>&1

    # ── Fallback 1: EPEL containerd package ──────────────────────────────────
    # If Docker repo install failed (e.g. firewall, proxy), try EPEL which
    # ships a recent containerd for RHEL 8/9.
    if ! command -v containerd &>/dev/null; then
      echo -e "${YELLOW}    ⚠️  containerd.io not available — trying EPEL containerd...${NC}"
      log "Fallback: installing containerd from EPEL"
      if ! rpm -q epel-release &>/dev/null; then
        echo -e "${CYAN}    ⬇  Installing EPEL release...${NC}"
        dnf install -y -q epel-release >> "$LOG_FILE" 2>&1 || true
      fi
      echo -e "${CYAN}    ⬇  Installing containerd from EPEL (this may take a minute)...${NC}"
      dnf install -y -q --enablerepo="epel" containerd >> "$LOG_FILE" 2>&1 || true
    fi

    # ── Fallback 2: distro containerd (AppStream / BaseOS) ───────────────────
    if ! command -v containerd &>/dev/null; then
      echo -e "${YELLOW}    ⚠️  EPEL containerd not available — trying distro containerd...${NC}"
      log "Fallback: installing containerd from distro repos"
      dnf install -y -q containerd >> "$LOG_FILE" 2>&1 || true
    fi

    # ── Final check — hard exit if nothing worked ─────────────────────────────
    if ! command -v containerd &>/dev/null; then
      echo -e "${RED}  ❌ containerd could not be installed${NC}"
      echo -e "${YELLOW}  Tried: Docker CE repo (centos/${_DOCKER_RELVER}), EPEL, distro repos${NC}"
      echo -e "${YELLOW}  Check $LOG_FILE for details${NC}"
      echo -e "${YELLOW}  Tip: verify network access to download.docker.com and fedora mirrors${NC}"
      exit 1
    fi
  fi
  echo -e "${GREEN}  ✓ Containerd installed${NC}"
}

# ════════════════════════════════════════════════════════════════════════════
# VERSION LOCK HELPERS
# ════════════════════════════════════════════════════════════════════════════
ensure_versionlock_plugin() {
  # Install plugin if not present
  if ! dnf versionlock --help &>/dev/null 2>&1; then
    dnf install -y -q "dnf-plugin-versionlock" >> "$LOG_FILE" 2>&1 || \
      dnf install -y -q "python3-dnf-plugin-versionlock" >> "$LOG_FILE" 2>&1 || true
  fi
  # Create the versionlock list file if it doesn't exist yet —
  # dnf versionlock errors with ENOENT if the file is absent even after plugin install
  local VL_LIST="/etc/dnf/plugins/versionlock.list"
  if [[ ! -f "$VL_LIST" ]]; then
    mkdir -p "$(dirname "$VL_LIST")"
    touch "$VL_LIST"
    log "Created empty versionlock.list"
  fi
}

pin_k8s_packages() {
  local pkgs=("$@")
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    for pkg in "${pkgs[@]}"; do
      apt-mark hold "$pkg" >> "$LOG_FILE" 2>&1
      echo -e "   ${GREEN}✓ $pkg — held${NC}"
    done
  else
    ensure_versionlock_plugin
    for pkg in "${pkgs[@]}"; do
      dnf versionlock delete "$pkg" >> "$LOG_FILE" 2>&1 || true
      dnf versionlock add    "$pkg" >> "$LOG_FILE" 2>&1
      echo -e "   ${GREEN}✓ $pkg — locked${NC}"
    done
  fi
}

unpin_k8s_packages() {
  local pkgs=("$@")
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    for pkg in "${pkgs[@]}"; do
      apt-mark unhold "$pkg" >> "$LOG_FILE" 2>&1 || true
      echo -e "   ${CYAN}↑ $pkg — unpinned${NC}"
    done
  else
    ensure_versionlock_plugin
    for pkg in "${pkgs[@]}"; do
      dnf versionlock delete "$pkg" || true
      echo -e "   ${CYAN}↑ $pkg — unpinned${NC}"
    done
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 13: INSTALL K8s COMPONENTS
#
# select_k8s_version() already handled the user prompt and set K8S_VERSION.
# This function's only job is to install whatever is missing:
#   CASE 1 — all tools present : nothing to install, just ensure kubelet enabled
#   CASE 2 — partial install   : install only the missing piece at K8S_VERSION
#   CASE 3 — fresh node        : install all tools at K8S_VERSION
#
# DNF uses --disableexcludes=kubernetes so the repo's exclude= directive
# (which protects against accidental upgrades via 'dnf update') does NOT
# block this intentional install.
# ════════════════════════════════════════════════════════════════════════════

# Helper: get installed version of a binary (kubeadm or kubelet), empty if absent
_get_installed_k8s_version() {
  local bin="$1"
  command -v "$bin" &>/dev/null || { echo ""; return; }
  "$bin" --version 2>/dev/null | awk '{print $2}' | sed 's/^v//'
}

# Helper: install a single K8s package at a specific version
_install_k8s_pkg() {
  local pkg="$1" ver="$2"
  log "Installing ${pkg}-${ver}"
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    apt-mark unhold "$pkg" >> "$LOG_FILE" 2>&1 || true
    apt-get install -y -qq "${pkg}=${ver}-*" >> "$LOG_FILE" 2>&1
  else
    ensure_versionlock_plugin
    dnf versionlock delete "$pkg" >> "$LOG_FILE" 2>&1 || true
    dnf install -y -q --disableexcludes=kubernetes "${pkg}-${ver}" >> "$LOG_FILE" 2>&1
  fi
  if ! command -v "$pkg" &>/dev/null; then
    echo -e "${RED}   ❌ ${pkg} failed to install — check $LOG_FILE${NC}"
    exit 1
  fi
  echo -e "   ${GREEN}✓ ${pkg} v${ver}${NC}"
}

install_k8s_components() {
  progress
  echo -e "${YELLOW}📦 Installing Kubernetes components...${NC}"
  echo ""

  local KUBEADM_VER; KUBEADM_VER=$(_get_installed_k8s_version kubeadm)
  local KUBELET_VER;  KUBELET_VER=$(_get_installed_k8s_version kubelet)
  local PKGS=("kubelet" "kubeadm")
  [[ "$NODE_TYPE" == "master" ]] && PKGS+=("kubectl")

  # ── CASE 1: All required tools already installed ─────────────────────────
  # select_k8s_version() confirmed with the user and set K8S_VERSION.
  # Nothing to install — just ensure kubelet unit is enabled.
  if [[ -n "$KUBEADM_VER" && -n "$KUBELET_VER" ]]; then
    # Master: also install kubectl if it is somehow missing
    if [[ "$NODE_TYPE" == "master" ]] && ! command -v kubectl &>/dev/null; then
      echo -e "${CYAN}  kubectl missing on master — installing v${K8S_VERSION}...${NC}"
      _install_k8s_pkg "kubectl" "$K8S_VERSION"
    else
      echo -e "${GREEN}  ✓ kubeadm v${KUBEADM_VER}  kubelet v${KUBELET_VER} — already installed, skipping${NC}"
    fi
    systemctl list-unit-files kubelet.service &>/dev/null && \
      systemctl enable kubelet 2>/dev/null || true
    echo -e "${GREEN}✓ Kubernetes v${K8S_VERSION} ready${NC}"
    return 0
  fi

  # ── CASE 2a: kubeadm present, kubelet missing ────────────────────────────
  if [[ -n "$KUBEADM_VER" && -z "$KUBELET_VER" ]]; then
    echo -e "${CYAN}  ℹ️  kubeadm v${KUBEADM_VER} found — installing missing kubelet v${K8S_VERSION}...${NC}"
    _install_k8s_pkg "kubelet" "$K8S_VERSION"
    [[ "$NODE_TYPE" == "master" ]] && ! command -v kubectl &>/dev/null && \
      _install_k8s_pkg "kubectl" "$K8S_VERSION"

  # ── CASE 2b: kubelet present, kubeadm missing ────────────────────────────
  elif [[ -z "$KUBEADM_VER" && -n "$KUBELET_VER" ]]; then
    echo -e "${CYAN}  ℹ️  kubelet v${KUBELET_VER} found — installing missing kubeadm v${K8S_VERSION}...${NC}"
    _install_k8s_pkg "kubeadm" "$K8S_VERSION"
    [[ "$NODE_TYPE" == "master" ]] && ! command -v kubectl &>/dev/null && \
      _install_k8s_pkg "kubectl" "$K8S_VERSION"

  # ── CASE 3: Fresh node — install all components ──────────────────────────
  else
    log "Fresh install: ${PKGS[*]} v${K8S_VERSION}"
    if [[ "$OS" =~ (ubuntu|debian) ]]; then
      for pkg in "${PKGS[@]}"; do apt-mark unhold "$pkg" >> "$LOG_FILE" 2>&1 || true; done
      for pkg in "${PKGS[@]}"; do
        apt-get install -y -qq "${pkg}=${K8S_VERSION}-*" >> "$LOG_FILE" 2>&1
        echo -e "   ${GREEN}✓ $pkg v${K8S_VERSION}${NC}"
      done
    else
      ensure_versionlock_plugin
      for pkg in "${PKGS[@]}"; do dnf versionlock delete "$pkg" >> "$LOG_FILE" 2>&1 || true; done
      for pkg in "${PKGS[@]}"; do
        dnf install -y -q --disableexcludes=kubernetes "${pkg}-${K8S_VERSION}" >> "$LOG_FILE" 2>&1
        if ! command -v "$pkg" &>/dev/null; then
          echo -e "${RED}   ❌ $pkg failed to install — check $LOG_FILE${NC}"
          exit 1
        fi
        echo -e "   ${GREEN}✓ $pkg v${K8S_VERSION}${NC}"
      done
    fi
  fi

  echo ""
  echo -e "${YELLOW}🔒 Pinning packages at v${K8S_VERSION}...${NC}"
  pin_k8s_packages "${PKGS[@]}"
  echo -e "${GREEN}✓ Pinned. To upgrade: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --upgrade${NC}"
  echo ""
  if command -v kubelet &>/dev/null; then
    systemctl enable kubelet 2>/dev/null || true
    systemctl start  kubelet 2>/dev/null || true  # expected to fail until kubeadm init/join
    echo -e "${GREEN}✓ Kubernetes v${K8S_VERSION} installed${NC}"
  else
    echo -e "${RED}❌ kubelet binary not found after install — check $LOG_FILE${NC}"
    exit 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 14: CRICTL
#
# DNF also uses --disableexcludes=kubernetes here because cri-tools is
# listed in the repo's exclude= directive alongside kubelet/kubeadm.
# ════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════
# _restore_crictl_config
# ────────────────────────────────────────────────────────────────────────────
# Shared helper called by both configure_crictl() (--init) and run_reset()
# (--reset).  After --reset deletes /etc/crictl.yaml, crictl falls back to
# trying all default socket paths as root — non-root users get PERMISSION
# DENIED until the file is restored.
#
# This function:
#   1. Auto-detects the active runtime socket (containerd / crio)
#   2. Writes /etc/crictl.yaml pointing at that socket
#   3. Applies chgrp/chmod to the live socket immediately
#   4. Writes/refreshes the systemd drop-in so permissions survive reboots
#   5. Adds the invoking non-root user to k8sadmins if not already there
#
# It is safe to call multiple times (idempotent).
# Sets the SOCK variable in the caller's scope for use in log messages.
# ════════════════════════════════════════════════════════════════════════════
_restore_crictl_config() {
  local _rt="${1:-$RUNTIME}"   # accept explicit runtime arg or use global
  local SOCK=""

  # ── Resolve socket path ────────────────────────────────────────────────
  case "$_rt" in
    containerd) SOCK="/run/containerd/containerd.sock" ;;
    crio)       SOCK="/var/run/crio/crio.sock"         ;;
    *)
      # Auto-detect from live sockets (fallback when RUNTIME not yet set)
      if [[ -S /run/containerd/containerd.sock ]]; then
        SOCK="/run/containerd/containerd.sock"; _rt="containerd"
      elif [[ -S /var/run/crio/crio.sock ]]; then
        SOCK="/var/run/crio/crio.sock";         _rt="crio"
      else
        echo -e "${YELLOW}  ⚠️  Runtime socket not found — crictl.yaml not written${NC}"
        echo -e "${YELLOW}  (This is normal if the runtime has not started yet.)${NC}"
        return 0
      fi
      ;;
  esac

  # ── Write /etc/crictl.yaml ─────────────────────────────────────────────
  cat > /etc/crictl.yaml << CEOF
runtime-endpoint: unix://${SOCK}
image-endpoint: unix://${SOCK}
timeout: 10
debug: false
CEOF
  log "_restore_crictl_config: wrote /etc/crictl.yaml → ${SOCK}"

  # ── k8sadmins group setup ──────────────────────────────────────────────
  local GRP="k8sadmins"
  getent group "$GRP" >/dev/null || groupadd "$GRP"

  local _INVOKE_USER="${SUDO_USER:-${LOGNAME:-${USER:-}}}"
  if [[ -n "$_INVOKE_USER" && "$_INVOKE_USER" != "root" ]]; then
    if ! id -nG "$_INVOKE_USER" 2>/dev/null | grep -qw "$GRP"; then
      usermod -aG "$GRP" "$_INVOKE_USER"
      echo -e "${CYAN}    ✓ Added ${WHITE}${_INVOKE_USER}${CYAN} to group ${WHITE}${GRP}${NC}"
      echo -e "${YELLOW}    ℹ️  Group takes effect on next login (or: newgrp ${GRP})${NC}"
    else
      echo -e "${GREEN}    ✓ ${_INVOKE_USER} already in group ${GRP}${NC}"
    fi
  fi

  # ── systemd drop-in: persist socket permissions across reboots ─────────
  # ── Persist socket permissions via systemd socket unit override ────────────
  #
  # WHY NOT ExecStartPost chgrp/chmod:
  #   containerd (and crio) create their sockets via systemd socket activation
  #   or their own internal socket setup.  An ExecStartPost chgrp fires AFTER
  #   the service is marked active, but containerd may still be writing the
  #   socket — the chgrp races and loses, leaving root:root 660 (only root
  #   can connect).  On the NEXT restart the chgrp is the only thing that runs
  #   but once again races with containerd's own socket creation.
  #
  # CORRECT FIX — two-part approach:
  #   Part A: containerd.service drop-in with ExecStartPost using a robust
  #           wait+retry loop that keeps re-applying until the socket exists
  #           AND is group-writable.  This handles the "socket not yet created"
  #           race on first start.
  #   Part B: /etc/tmpfiles.d/ rule so systemd-tmpfiles recreates the correct
  #           ownership on every boot before the service even starts.
  #           (tmpfiles runs in early boot, before containerd starts.)
  #
  # Together these cover: fresh start, service restart, and node reboot.

  local _DROPIN_DIR _DROPIN_FILE _TMPFILES_FILE
  _TMPFILES_FILE="/etc/tmpfiles.d/k8sadmins-socket.conf"

  if [[ "$_rt" == "containerd" ]]; then
    _DROPIN_DIR="/etc/systemd/system/containerd.service.d"
    _DROPIN_FILE="${_DROPIN_DIR}/k8sadmins-socket.conf"
    mkdir -p "$_DROPIN_DIR"
    # Part A: service drop-in — robust wait+retry loop
    cat > "$_DROPIN_FILE" << 'DROPIN'
# Written by k8s-cluster-bootstrap.sh
# Persists k8sadmins group ownership on the containerd socket after every start.
[Service]
ExecStartPost=/bin/bash -c '\
  for i in $(seq 1 30); do \
    if [ -S /run/containerd/containerd.sock ]; then \
      chgrp k8sadmins /run/containerd/containerd.sock && \
      chmod 660 /run/containerd/containerd.sock && exit 0; \
    fi; \
    sleep 0.5; \
  done; \
  chgrp k8sadmins /run/containerd/containerd.sock && chmod 660 /run/containerd/containerd.sock'
DROPIN
    # Part B: tmpfiles — pre-boot ownership (d = create dir / adjust existing path)
    cat > "$_TMPFILES_FILE" << 'TMPEOF'
# Written by k8s-cluster-bootstrap.sh
# Adjusts containerd socket permissions at boot before containerd starts.
z /run/containerd/containerd.sock 0660 root k8sadmins - -
TMPEOF

  elif [[ "$_rt" == "crio" ]]; then
    _DROPIN_DIR="/etc/systemd/system/crio.service.d"
    _DROPIN_FILE="${_DROPIN_DIR}/k8sadmins-socket.conf"
    mkdir -p "$_DROPIN_DIR"
    # Part A: service drop-in — robust wait+retry loop
    cat > "$_DROPIN_FILE" << 'DROPIN'
# Written by k8s-cluster-bootstrap.sh
# Persists k8sadmins group ownership on the CRI-O socket after every start.
[Service]
ExecStartPost=/bin/bash -c '\
  for i in $(seq 1 30); do \
    if [ -S /var/run/crio/crio.sock ]; then \
      chgrp k8sadmins /var/run/crio/crio.sock && \
      chmod 660 /var/run/crio/crio.sock && exit 0; \
    fi; \
    sleep 0.5; \
  done; \
  chgrp k8sadmins /var/run/crio/crio.sock && chmod 660 /var/run/crio/crio.sock'
DROPIN
    # Part B: tmpfiles
    cat > "$_TMPFILES_FILE" << 'TMPEOF'
# Written by k8s-cluster-bootstrap.sh
# Adjusts CRI-O socket permissions at boot before crio starts.
z /var/run/crio/crio.sock 0660 root k8sadmins - -
TMPEOF
  fi

  # ── Apply to live socket immediately for this session ───────────────────────
  # Retry up to 5s in case the runtime just restarted and socket isn't ready yet
  local _try=0
  while [[ $_try -lt 10 ]]; do
    if [[ -S "$SOCK" ]]; then
      chgrp "$GRP" "$SOCK" && chmod 660 "$SOCK" && \
        { log "_restore_crictl_config: applied chgrp ${GRP} chmod 660 to ${SOCK}"; break; }
    fi
    sleep 0.5; _try=$((_try + 1))
  done
  if [[ ! -S "$SOCK" ]]; then
    log "_restore_crictl_config: socket ${SOCK} not present yet — drop-in will handle on next start"
  fi

  systemctl daemon-reload
  # Apply tmpfiles rules now (for the live socket, same as boot-time)
  systemd-tmpfiles --create "$_TMPFILES_FILE" 2>/dev/null || true
}

configure_crictl() {
  progress
  echo -e "${YELLOW}🔧 Configuring crictl...${NC}"
  if ! command -v crictl &>/dev/null; then
    echo -e "${CYAN}  ⬇  Installing cri-tools...${NC}"
    if [[ "$OS" =~ (ubuntu|debian) ]]; then
      apt-get install -y -qq cri-tools >> "$LOG_FILE" 2>&1
    elif [[ "$OS" =~ (rhel|rocky|centos|almalinux) ]]; then
      dnf install -y -q --disableexcludes=kubernetes cri-tools >> "$LOG_FILE" 2>&1
    fi
    echo -e "${GREEN}  ✓ cri-tools installed${NC}"
  else
    echo -e "${GREEN}  ✓ crictl already present${NC}"
  fi

  # ── Ensure crictl is visible in $PATH (kubeadm preflight checks $PATH) ──────
  # cri-tools installs crictl to /usr/bin on Debian/Ubuntu but kubeadm may
  # search only /usr/local/bin.  Symlink into /usr/local/bin if needed and
  # export PATH so every subprocess (including kubeadm) can find it.
  if ! command -v crictl &>/dev/null; then
    for _cdir in /usr/bin /usr/local/bin; do
      if [[ -x "$_cdir/crictl" ]]; then
        ln -sf "$_cdir/crictl" /usr/local/bin/crictl 2>/dev/null || true
        log "crictl symlinked from ${_cdir}"
        break
      fi
    done
  fi
  export PATH="/usr/local/bin:/usr/bin:${PATH}"
  log "PATH exported: ${PATH}"

  # Delegate all config/permission work to the shared helper
  _restore_crictl_config "$RUNTIME"

  # Expose the resolved socket path for the success banner
  local SOCK=""
  case "$RUNTIME" in
    containerd) SOCK="/run/containerd/containerd.sock" ;;
    crio)       SOCK="/var/run/crio/crio.sock"         ;;
    *)  [[ -S /run/containerd/containerd.sock ]] && SOCK="/run/containerd/containerd.sock" \
     || SOCK="/var/run/crio/crio.sock" ;;
  esac

  echo -e "${GREEN}✓ crictl → ${SOCK}${NC}"
  echo -e "${GREEN}✓ Socket permissions: group=k8sadmins mode=660 (persists across reboots)${NC}"
}

# ════════════════════════════════════════════════════════════════════════════
# STEP 15: HOST-ONLY INTERFACE DETECTION
#
# Confirms the Host-Only interface and IP (already validated in step 3).
# For MASTER: writes kubelet --node-ip extra-args config here.
# For WORKER: kubelet extra-args are written in bootstrap_worker() BEFORE
#             the kubeadm join call, so they take effect during the join.
#             This step still sets the iface file used by CNI.
# ════════════════════════════════════════════════════════════════════════════
detect_network_interfaces() {
  progress
  # HOST_ONLY_IFACE and HOST_ONLY_IP already set by validate_network_config()
  # Re-detect only if somehow unset (edge case)
  if [[ -z "$HOST_ONLY_IFACE" || -z "$HOST_ONLY_IP" ]]; then
    HOST_ONLY_IFACE=$(ip -4 addr show | grep -B2 "192\.168\." | grep -m1 "^[0-9]" | awk '{print $2}' | cut -d: -f1)
    HOST_ONLY_IP=$(ip -4 addr show | grep -oP '192\.168\.\d+\.\d+' | head -1)
    if [[ -z "$HOST_ONLY_IFACE" || -z "$HOST_ONLY_IP" ]]; then
      echo -e "${YELLOW}  ⚠️  Auto-detect failed — listing interfaces:${NC}"
      ip -4 addr show | grep -E "^[0-9]+:|inet "
      echo ""
      prompt_input "  Enter Host-Only interface (e.g. ens34, eth1): " HOST_ONLY_IFACE
      HOST_ONLY_IP=$(ip -4 addr show "$HOST_ONLY_IFACE" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
      [[ -z "$HOST_ONLY_IP" ]] && { echo -e "${RED}  ❌ No IP on $HOST_ONLY_IFACE${NC}"; exit 1; }
    fi
  fi

  MASTER_IP="$HOST_ONLY_IP"
  mkdir -p /etc/kubernetes
  echo "$HOST_ONLY_IFACE" > "$CNI_IFACE_FILE"

  # Write kubelet extra-args for MASTER here.
  # WORKER kubelet extra-args are written in bootstrap_worker() before join.
  if [[ "$NODE_TYPE" == "master" ]]; then
    if [[ "$OS" =~ (ubuntu|debian) ]]; then
      echo "KUBELET_EXTRA_ARGS=--node-ip=${HOST_ONLY_IP}" > /etc/default/kubelet
    else
      mkdir -p /etc/sysconfig
      echo "KUBELET_EXTRA_ARGS=--node-ip=${HOST_ONLY_IP}" > /etc/sysconfig/kubelet
    fi
    systemctl daemon-reload
  fi
  log "detect_network_interfaces: HOST_ONLY_IFACE=${HOST_ONLY_IFACE} HOST_ONLY_IP=${HOST_ONLY_IP}"
}

# ════════════════════════════════════════════════════════════════════════════
# CNI HEALTH CHECK
# ════════════════════════════════════════════════════════════════════════════
check_cni_interface() {
  local cni_type="$1" expected_iface="$2"
  if [[ "$cni_type" == "flannel" ]]; then
    local fp; fp=$(kubectl get pods -n kube-flannel -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$fp" ]]; then
      local cur; cur=$(kubectl logs "$fp" -n kube-flannel 2>/dev/null \
        | grep "Using interface" | grep -oP 'name \K\S+' || echo "unknown")
      [[ "$cur" == "$expected_iface" ]] && return 0
      echo -e "${RED}  Flannel using: $cur (expected $expected_iface)${NC}"; return 1
    fi
  elif [[ "$cni_type" == "calico" ]]; then
    local cp; cp=$(kubectl get pods -n kube-system -l k8s-app=calico-node \
      -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
    if [[ -n "$cp" ]]; then
      local cur eip
      cur=$(kubectl logs "$cp" -n kube-system -c calico-node 2>/dev/null \
        | grep -oP 'Using IPv4 address \K\S+' | head -1)
      eip=$(ip -4 addr show "$expected_iface" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
      [[ "$cur" == "$eip" ]] && return 0
      echo -e "${RED}  Calico IP: $cur (expected $eip on $expected_iface)${NC}"; return 1
    fi
  fi
  return 2
}

# ════════════════════════════════════════════════════════════════════════════
# CNI AUTO-FIX
# ════════════════════════════════════════════════════════════════════════════
fix_cni_interface() {
  local cni_type="$1" iface="$2"
  print_header "CNI AUTO-FIX"
  if [[ "$cni_type" == "flannel" ]]; then
    kubectl set env daemonset/kube-flannel-ds -n kube-flannel IFACE="$iface" 2>/dev/null || true
    kubectl delete pod -n kube-flannel -l app=flannel --wait=true 2>/dev/null || true
    sleep 30; echo -e "${GREEN}✓ Flannel interface fixed${NC}"
  elif [[ "$cni_type" == "calico" ]]; then
    kubectl set env daemonset/calico-node -n kube-system \
      IP_AUTODETECTION_METHOD="interface=${iface}" 2>/dev/null || true
    kubectl patch ippool default-ipv4-ippool --type merge \
      -p '{"spec":{"ipipMode":"Never","vxlanMode":"Always"}}' 2>/dev/null || true
    kubectl patch felixconfiguration default --type merge \
      -p '{"spec":{"ipipEnabled":false,"vxlanEnabled":true}}' 2>/dev/null || true
    kubectl patch configmap calico-config -n kube-system --type merge \
      -p '{"data":{"calico_backend":"none"}}' 2>/dev/null || true
    kubectl rollout restart daemonset/calico-node -n kube-system 2>/dev/null || true
    sleep 30; echo -e "${GREEN}✓ Calico reconfigured (VXLAN=Always, IPIP=Never, BGP=none)${NC}"
  fi
  kubectl delete pod -n kube-system -l k8s-app=kube-dns --wait=true 2>/dev/null || true
  sleep 15
}

# ════════════════════════════════════════════════════════════════════════════
# POD READINESS
# ════════════════════════════════════════════════════════════════════════════
pod_ready_count() {
  local ns="$1" selector="$2"
  local -n _r="$3" _t="$4"
  _t=$(kubectl get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null | wc -l)
  _r=$(kubectl get pods -n "$ns" -l "$selector" \
    -o jsonpath='{.items[*].status.containerStatuses[0].ready}' 2>/dev/null \
    | grep -o true | wc -l)
}

_pod_status_line() {
  local name="$1" rdy="$2" tot="$3"
  if [[ $tot -gt 0 && $rdy -eq $tot ]]; then
    printf "  ${GREEN}✓${NC} %-34s ${GREEN}%s/%s${NC}\n" "$name" "$rdy" "$tot"
  else
    printf "  ${YELLOW}⏳${NC} %-34s ${YELLOW}%s/%s${NC}\n" "$name" "${rdy:-0}" "${tot:-0}"
  fi
}

wait_for_master_pods_ready() {
  local MAX_WAIT=420 WAITED=0
  print_header "CLUSTER VERIFICATION"
  echo -e "${YELLOW}  Waiting for all pods to become Ready (max ${MAX_WAIT}s)...${NC}"

  while [[ $WAITED -lt $MAX_WAIT ]]; do
    local DNS_RDY DNS_TOT PROXY_RDY PROXY_TOT NODE_RDY NODE_TOT CTRL_RDY CTRL_TOT
    pod_ready_count "kube-system" "k8s-app=kube-dns"   DNS_RDY   DNS_TOT
    pod_ready_count "kube-system" "k8s-app=kube-proxy" PROXY_RDY PROXY_TOT
    if [[ "$CNI_CHOICE" == "flannel" ]]; then
      pod_ready_count "kube-flannel" "app=flannel" NODE_RDY NODE_TOT
      CTRL_RDY=1; CTRL_TOT=1
    else
      pod_ready_count "kube-system" "k8s-app=calico-node"             NODE_RDY NODE_TOT
      pod_ready_count "kube-system" "k8s-app=calico-kube-controllers" CTRL_RDY CTRL_TOT
    fi

    if [[ $((WAITED % 15)) -eq 0 ]]; then
      printf "\n${CYAN}  %-34s %s${NC}\n" "Component" "Ready/Total"
      printf "${CYAN}  %-34s %s${NC}\n"   "─────────────────────────────────" "──────────"
      _pod_status_line "CoreDNS"    $DNS_RDY   $DNS_TOT
      _pod_status_line "kube-proxy" $PROXY_RDY $PROXY_TOT
      if [[ "$CNI_CHOICE" == "flannel" ]]; then
        _pod_status_line "Flannel (node)" $NODE_RDY $NODE_TOT
      else
        _pod_status_line "Calico (node)"             $NODE_RDY $NODE_TOT
        _pod_status_line "Calico (kube-controllers)" $CTRL_RDY $CTRL_TOT
      fi
      printf "${CYAN}  %-34s %s${NC}\n" "─────────────────────────────────" "──────────"
      echo -e "  ${DIM}[${WAITED}s / ${MAX_WAIT}s]${NC}"
    fi

    local all_ready=true
    [[ $DNS_TOT   -eq 0 || $DNS_RDY   -lt $DNS_TOT   ]] && all_ready=false
    [[ $NODE_TOT  -eq 0 || $NODE_RDY  -lt $NODE_TOT  ]] && all_ready=false
    [[ $CTRL_TOT  -eq 0 || $CTRL_RDY  -lt $CTRL_TOT  ]] && all_ready=false
    [[ $PROXY_TOT -gt 0 && $PROXY_RDY -lt $PROXY_TOT ]] && all_ready=false

    if [[ "$all_ready" == true ]]; then
      echo ""
      echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
      echo -e "${GREEN}║  ${BOLD}✔  ALL CLUSTER PODS READY${NC}                                        ${GREEN}║${NC}"
      echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
      echo ""
      _pod_status_line "CoreDNS"    $DNS_RDY   $DNS_TOT
      _pod_status_line "kube-proxy" $PROXY_RDY $PROXY_TOT
      if [[ "$CNI_CHOICE" == "flannel" ]]; then
        _pod_status_line "Flannel (node)" $NODE_RDY $NODE_TOT
      else
        _pod_status_line "Calico (node)"             $NODE_RDY $NODE_TOT
        _pod_status_line "Calico (kube-controllers)" $CTRL_RDY $CTRL_TOT
      fi
      echo ""
      return 0
    fi
    sleep 5; WAITED=$((WAITED + 5))
  done

  echo -e "${RED}  ❌ Timeout — attempting CNI auto-fix...${NC}"
  check_cni_interface "$CNI_CHOICE" "$HOST_ONLY_IFACE" || \
    fix_cni_interface "$CNI_CHOICE" "$HOST_ONLY_IFACE"
  return 1
}

wait_for_worker_pods_ready() {
  local MAX_WAIT=420   # calico-node image pull can take 3-5 min on first join
  local WAITED=0

  # Wait for kubelet to be active first
  echo -e "${YELLOW}⏳ Waiting for kubelet...${NC}"
  while [[ $WAITED -lt $MAX_WAIT ]]; do
    systemctl is-active --quiet kubelet && break
    sleep 5; WAITED=$((WAITED + 5))
  done
  if ! systemctl is-active --quiet kubelet; then
    echo -e "${RED}❌ kubelet not active after ${WAITED}s${NC}"; return 1
  fi
  echo -e "${GREEN}✓ kubelet active${NC}"

  # ── Fix resolvConf on RHEL/Rocky after kubeadm join ─────────────────────
  # kubeadm join inherits the cluster-wide KubeletConfiguration which was
  # generated on the master (Ubuntu) and contains:
  #   resolvConf: /run/systemd/resolve/resolv.conf
  # Rocky/RHEL does not run systemd-resolved, so that path does not exist.
  # Patch it to /etc/resolv.conf and restart kubelet so pod sandboxes can
  # open the DNS file and containers come up cleanly.
  if [[ "$OS" =~ (rhel|rocky|centos|almalinux) ]]; then
    local _KUBELET_CFG="/var/lib/kubelet/config.yaml"
    if [[ -f "$_KUBELET_CFG" ]]; then
      local _CURRENT_RESOLV
      _CURRENT_RESOLV=$(grep "^resolvConf:" "$_KUBELET_CFG" | awk '{print $2}')
      if [[ "$_CURRENT_RESOLV" != "/etc/resolv.conf" ]]; then
        echo -e "${YELLOW}  ⚙️  Patching kubelet resolvConf: ${_CURRENT_RESOLV} → /etc/resolv.conf${NC}"
        sed -i 's|^resolvConf:.*|resolvConf: /etc/resolv.conf|' "$_KUBELET_CFG"
        systemctl daemon-reload
        systemctl restart kubelet
        sleep 5
        echo -e "${GREEN}  ✓ resolvConf patched — kubelet restarted${NC}"
      else
        echo -e "${GREEN}  ✓ resolvConf already correct (/etc/resolv.conf)${NC}"
      fi
    fi
  fi

  # Reset counter for the CNI agent wait — independent of kubelet wait above
  WAITED=0

  # Wait for calico-node (or flannel) container to be Running on this worker.
  #
  # ROOT CAUSE FIX: crictl ps output has a variable-width CREATED column:
  #   "38 seconds ago"     → 3 words → STATE lands on awk $6
  #   "2 minutes ago"      → 3 words → STATE lands on awk $6
  #   "About a minute ago" → 4 words → STATE lands on awk $7
  # Using awk '{print $5}' always hits somewhere inside the CREATED timestamp
  # (showing "ago", "minute" etc.) — never the actual STATE field.
  # Fix: use crictl's built-in --state flag so no column parsing is needed.
  #   crictl ps --state running  →  lists ONLY Running containers
  #   grep calico-node/flannel   →  matches if that container is Running
  echo -e "${YELLOW}⏳ Waiting for CNI agent (calico-node/flannel) to be Running...${NC}"
  while [[ $WAITED -lt $MAX_WAIT ]]; do
    if crictl ps --state running 2>/dev/null | grep -qE "calico-node|flannel"; then
      echo -e "${GREEN}✓ CNI agent Running${NC}"; break
    fi
    sleep 5; WAITED=$((WAITED + 5))
    if [[ $((WAITED % 30)) -eq 0 ]]; then
      # Show what the container state actually is (for diagnostics)
      local _RAW_STATE
      _RAW_STATE=$(crictl ps 2>/dev/null | grep -E "calico-node|flannel" \
        | awk '{print $4}' | head -1)
      echo -e "${CYAN}  ⟳ CNI agent: ${_RAW_STATE:-not yet created} [${WAITED}s]${NC}"
    fi
  done

  if ! crictl ps --state running 2>/dev/null | grep -qE "calico-node|flannel"; then
    echo -e "${YELLOW}⚠️  CNI agent not Running after ${MAX_WAIT}s — check: journalctl -u kubelet -n 50${NC}"
    return 1
  fi

  # ── Verify VXLAN tunnel interface (Calico only) ──────────────────────────
  # vxlan.calico comes up within seconds of calico-node Running.
  # Quick 30s check — if not up it's a warning, not a fatal error.
  local _VX=0
  while [[ $_VX -lt 30 ]]; do
    ip link show vxlan.calico &>/dev/null && break
    sleep 3; _VX=$((_VX+3))
  done
  if ip link show vxlan.calico &>/dev/null; then
    echo -e "${GREEN}✓ vxlan.calico interface up — VXLAN tunnel active${NC}"
  else
    echo -e "${YELLOW}  ⚠️  vxlan.calico not yet up — may appear in a few seconds${NC}"
  fi

  return 0
}

# ════════════════════════════════════════════════════════════════════════════
# CNI SELECTION
# ════════════════════════════════════════════════════════════════════════════
select_and_deploy_cni() {
  # ── Idempotency check ────────────────────────────────────────────────────
  # If CNI was already deployed in a previous --init run, $CNI_CONFIG_FILE
  # holds the choice ("calico" or "flannel").  Skip re-selection and just
  # ensure the runtime + kubelet are running — no manifest re-apply needed
  # unless the user explicitly wants to change CNI.
  if [[ -f "$CNI_CONFIG_FILE" ]]; then
    CNI_CHOICE=$(cat "$CNI_CONFIG_FILE" 2>/dev/null)
    if [[ "$CNI_CHOICE" == "calico" || "$CNI_CHOICE" == "flannel" ]]; then
      echo ""
      echo -e "${GREEN}✓ CNI already deployed: ${WHITE}${CNI_CHOICE}${NC} ${DIM}(from previous --init)${NC}"
      echo -e "${DIM}  Config file: ${CNI_CONFIG_FILE}${NC}"
      # Verify the CNI daemonset pods are actually running — if not, re-apply
      local _CNI_NS _CNI_LABEL
      if [[ "$CNI_CHOICE" == "flannel" ]]; then
        _CNI_NS="kube-flannel"; _CNI_LABEL="app=flannel"
      else
        _CNI_NS="kube-system";  _CNI_LABEL="k8s-app=calico-node"
      fi
      local _CNI_RUNNING
      _CNI_RUNNING=$(kubectl get pods -n "$_CNI_NS" -l "$_CNI_LABEL"         --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l)
      if [[ "$_CNI_RUNNING" -gt 0 ]]; then
        echo -e "${GREEN}✓ ${CNI_CHOICE} pods Running (${_CNI_RUNNING}) — skipping re-deploy${NC}"
        return 0
      else
        echo -e "${YELLOW}  ⚠️  ${CNI_CHOICE} pods not Running — re-applying manifests...${NC}"
        # Fall through to re-apply below using the saved choice
        print_header "RE-DEPLOYING CNI: ${CNI_CHOICE^^}"
        [[ "$CNI_CHOICE" == "flannel" ]] && deploy_flannel || deploy_calico
        echo -e "${GREEN}✓ CNI re-applied${NC}"
        return 0
      fi
    fi
  fi

  # ── Fresh install — ask user to choose ──────────────────────────────────
  echo ""
  echo -e "${YELLOW}🌐 Select CNI Plugin:${NC}"
  echo -e "  ${CYAN}1${NC}) Calico  ${DIM}(VXLAN=Always · IPIP=Never · BGP=Never · bird=none)${NC}"
  echo -e "  ${CYAN}2${NC}) Flannel ${DIM}(VXLAN · Port 8472 · CIDR 10.244.0.0/16)${NC}"
  echo ""
  echo -e "  ${DIM}⏱  Auto-selecting ${WHITE}Calico${DIM} in ${WHITE}30s${DIM} if no input...${NC}"
  echo ""
  local CS=""
  if ! read -r -t 30 -p "$(printf "${CYAN}  Choice (1 or 2, default 1): ${NC}")" CS; then
    echo ""
    echo -e "  ${YELLOW}⏱  No input — using default: Calico${NC}"
    CS="1"
  fi
  CS="${CS:-1}"
  case "$CS" in
    2) CNI_CHOICE="flannel"; echo -e "${GREEN}✓ CNI: Flannel (VXLAN, Port 8472)${NC}" ;;
    *) CNI_CHOICE="calico";  echo -e "${GREEN}✓ CNI: Calico (VXLAN=Always · IPIP=Never · BGP=Never)${NC}" ;;
  esac
  mkdir -p /etc/kubernetes
  echo "$CNI_CHOICE" > "$CNI_CONFIG_FILE"
  print_header "DEPLOYING CNI: ${CNI_CHOICE^^}"
  [[ "$CNI_CHOICE" == "flannel" ]] && deploy_flannel || deploy_calico
  if [[ "$CNI_CHOICE" == "calico" ]]; then
    echo -e "${CYAN}  ⏳ Calico stabilizing (30s)...${NC}"
    sleep 30
  else
    echo -e "${CYAN}  ⏳ Flannel stabilizing (15s)...${NC}"
    sleep 15
  fi
  echo -e "${GREEN}✓ CNI deployed${NC}"
}

# ════════════════════════════════════════════════════════════════════════════
# FLANNEL DEPLOYMENT
# ════════════════════════════════════════════════════════════════════════════
deploy_flannel() {
  local IFACE="${HOST_ONLY_IFACE:-eth0}"
  echo -e "${YELLOW}  Deploying Flannel VXLAN (CIDR=${POD_CIDR}, Port=8472, iface=${IFACE})...${NC}"

  # Write manifest with variables expanded (unquoted heredoc delimiter)
  cat > /tmp/kube-flannel.yaml << FLANNEL_YAML
---
kind: Namespace
apiVersion: v1
metadata:
  name: kube-flannel
---
kind: ClusterRole
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  labels:
    k8s-app: flannel
  name: flannel
rules:
- apiGroups: [""]
  resources: [pods]
  verbs: [get]
- apiGroups: [""]
  resources: [nodes]
  verbs: [get, list, watch]
- apiGroups: [""]
  resources: [nodes/status]
  verbs: [patch]
---
kind: ClusterRoleBinding
apiVersion: rbac.authorization.k8s.io/v1
metadata:
  labels:
    k8s-app: flannel
  name: flannel
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: flannel
subjects:
- kind: ServiceAccount
  name: flannel
  namespace: kube-flannel
---
apiVersion: v1
kind: ServiceAccount
metadata:
  labels:
    k8s-app: flannel
  name: flannel
  namespace: kube-flannel
---
kind: ConfigMap
apiVersion: v1
metadata:
  name: kube-flannel-cfg
  namespace: kube-flannel
  labels:
    tier: node
    k8s-app: flannel
data:
  cni-conf.json: |
    {
      "name": "cbr0",
      "cniVersion": "0.3.1",
      "plugins": [
        {
          "type": "flannel",
          "delegate": {
            "hairpinMode": true,
            "isDefaultGateway": true
          }
        },
        {
          "type": "portmap",
          "capabilities": {
            "portMappings": true
          }
        }
      ]
    }
  net-conf.json: |
    {
      "Network": "${POD_CIDR}",
      "Backend": {
        "Type": "vxlan",
        "VNI": 1,
        "Port": 8472
      }
    }
---
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kube-flannel-ds
  namespace: kube-flannel
  labels:
    tier: node
    app: flannel
    k8s-app: flannel
spec:
  selector:
    matchLabels:
      app: flannel
  template:
    metadata:
      labels:
        tier: node
        app: flannel
    spec:
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
            - matchExpressions:
              - key: kubernetes.io/os
                operator: In
                values: [linux]
      hostNetwork: true
      priorityClassName: system-node-critical
      tolerations:
      - operator: Exists
        effect: NoSchedule
      serviceAccountName: flannel
      initContainers:
      - name: install-cni-plugin
        image: docker.io/flannel/flannel-cni-plugin:v1.4.0
        command: [cp]
        args: [-f, /flannel, /opt/cni/bin/flannel]
        volumeMounts:
        - name: cni-plugin
          mountPath: /opt/cni/bin
      - name: install-cni
        image: docker.io/flannel/flannel:v0.26.7
        command: [cp]
        args: [-f, /etc/kube-flannel/cni-conf.json, /etc/cni/net.d/10-flannel.conflist]
        volumeMounts:
        - name: cni
          mountPath: /etc/cni/net.d
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
      containers:
      - name: kube-flannel
        image: docker.io/flannel/flannel:v0.26.7
        command: [/opt/bin/flanneld]
        args:
        - --ip-masq
        - --kube-subnet-mgr
        - --iface=${IFACE}
        resources:
          requests:
            cpu: "100m"
            memory: "50Mi"
        securityContext:
          privileged: false
          capabilities:
            add: [NET_ADMIN, NET_RAW]
        env:
        - name: POD_NAME
          valueFrom:
            fieldRef:
              fieldPath: metadata.name
        - name: POD_NAMESPACE
          valueFrom:
            fieldRef:
              fieldPath: metadata.namespace
        - name: EVENT_QUEUE_DEPTH
          value: "5000"
        volumeMounts:
        - name: run
          mountPath: /run/flannel
        - name: flannel-cfg
          mountPath: /etc/kube-flannel/
        - name: xtables-lock
          mountPath: /run/xtables.lock
      volumes:
      - name: run
        hostPath:
          path: /run/flannel
      - name: cni-plugin
        hostPath:
          path: /opt/cni/bin
      - name: cni
        hostPath:
          path: /etc/cni/net.d
      - name: flannel-cfg
        configMap:
          name: kube-flannel-cfg
      - name: xtables-lock
        hostPath:
          path: /run/xtables.lock
          type: FileOrCreate
FLANNEL_YAML

  echo -e "${CYAN}  Applying Flannel manifests...${NC}"
  kubectl apply -f /tmp/kube-flannel.yaml >> "$LOG_FILE" 2>&1
  echo -e "${GREEN}  ✓ Flannel deployed (VXLAN · CIDR=${POD_CIDR} · Port=8472 · iface=${IFACE})${NC}"
}

# ════════════════════════════════════════════════════════════════════════════
# CALICO DEPLOYMENT
# ════════════════════════════════════════════════════════════════════════════
# CALICO DEPLOYMENT  —  pure VXLAN, no BGP, no IPIP
# Uses calicoctl for Calico-native resources (IPPool, FelixConfiguration)
# to bypass kubectl's REST mapper — eliminates "no matches for kind" errors
# ════════════════════════════════════════════════════════════════════════════
deploy_calico() {
  local CALICO_VERSION="v3.29.3"
  local CALICO_MANIFEST="/tmp/calico.yaml"
  local IFACE="${HOST_ONLY_IFACE:-eth0}"
  local CALICOCTL="/usr/local/bin/calicoctl"

  echo -e "${YELLOW}  Deploying Calico ${CALICO_VERSION} (pure VXLAN · no BGP · no IPIP)...${NC}"

  # ── [1/6] Install calicoctl (matches Calico version) ────────────────────
  # calicoctl speaks the native projectcalico.org/v3 API directly — it does
  # NOT go through kubectl's REST mapper, so "no matches for kind IPPool"
  # errors are impossible regardless of API server discovery timing.
  if ! command -v calicoctl &>/dev/null || \
     ! calicoctl version 2>/dev/null | grep -q "${CALICO_VERSION#v}"; then
    echo -e "${CYAN}  Installing calicoctl ${CALICO_VERSION}...${NC}"
    local _ARCH
    _ARCH=$(uname -m)
    [[ "$_ARCH" == "x86_64" ]]  && _ARCH="amd64"
    [[ "$_ARCH" == "aarch64" ]] && _ARCH="arm64"
    curl -fsSL \
      "https://github.com/projectcalico/calico/releases/download/${CALICO_VERSION}/calicoctl-linux-${_ARCH}" \
      -o "$CALICOCTL" >> "$LOG_FILE" 2>&1 \
      && chmod +x "$CALICOCTL" \
      || { echo -e "${RED}  ❌ calicoctl download failed${NC}"; return 1; }
    echo -e "${GREEN}  ✓ calicoctl ${CALICO_VERSION} installed → ${CALICOCTL}${NC}"
  else
    echo -e "${GREEN}  ✓ calicoctl already present${NC}"
  fi
  # Point calicoctl at the cluster
  export KUBECONFIG=/etc/kubernetes/admin.conf
  export CALICO_DATASTORE_TYPE=kubernetes
  export CALICO_KUBECONFIG=/etc/kubernetes/admin.conf

  # ── [2/6] Download calico.yaml ───────────────────────────────────────────
  curl -fsSL \
    "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml" \
    -o "$CALICO_MANIFEST" 2>/dev/null \
    || { echo -e "${RED}  ❌ Calico manifest download failed${NC}"; return 1; }

  # ── [3/6] Pre-edit manifest for pure VXLAN (DaemonSet env vars + backend) ─
  # calico_backend = "vxlan"  → VXLAN routing engine, BIRD/BGP never starts
  # All IPIP env vars         → Never / false
  # All VXLAN env vars        → Always / true
  # IP_AUTODETECTION_METHOD   → bind to Host-Only NIC, not NAT NIC
  # Health probes removed     → probes check BIRD socket; not present in vxlan mode
  python3 - "$CALICO_MANIFEST" "${POD_CIDR}" "${IFACE}" << 'PYEOF'
import sys, re

manifest_path = sys.argv[1]
pod_cidr      = sys.argv[2]
iface         = sys.argv[3]

with open(manifest_path) as f:
    content = f.read()

# Set calico_backend: "vxlan" in ConfigMap
content = re.sub(r'(calico_backend:\s*)"[^"]*"', r'\1"vxlan"', content)
content = re.sub(r'(calico_backend:\s*)(?!")(\S+)', r'\1"vxlan"', content)

def set_env_value(text, name, value):
    lines = text.split('\n')
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if stripped == f'- name: {name}':
            out.append(line)
            i += 1
            while i < len(lines):
                next_line = lines[i]
                next_stripped = next_line.lstrip()
                next_indent = len(next_line) - len(next_stripped)
                if next_stripped and next_indent <= indent and not next_stripped.startswith('#'):
                    break
                i += 1
            out.append(' ' * (indent + 2) + f'value: "{value}"')
        else:
            out.append(line)
            i += 1
    return '\n'.join(out)

content = set_env_value(content, "CALICO_IPV4POOL_VXLAN",     "Always")
content = set_env_value(content, "CALICO_IPV4POOL_IPIP",      "Never")
content = set_env_value(content, "CALICO_IPV4POOL_CIDR",      pod_cidr)
content = set_env_value(content, "CALICO_NETWORKING_BACKEND", "vxlan")
content = set_env_value(content, "IP_AUTODETECTION_METHOD",   f"interface={iface}")
content = set_env_value(content, "FELIX_IPINIPENABLED",       "false")
content = set_env_value(content, "FELIX_VXLANENABLED",        "true")
content = set_env_value(content, "FELIX_BPFENABLED",          "false")

def remove_probe_block(text, probe_name):
    lines = text.split('\n')
    out = []
    i = 0
    while i < len(lines):
        line = lines[i]
        stripped = line.lstrip()
        indent = len(line) - len(stripped)
        if stripped == f'{probe_name}:':
            i += 1
            while i < len(lines):
                next_line = lines[i]
                next_stripped = next_line.lstrip()
                next_indent = len(next_line) - len(next_stripped)
                if next_stripped and next_indent <= indent:
                    break
                i += 1
        else:
            out.append(line)
            i += 1
    return '\n'.join(out)

content = remove_probe_block(content, "livenessProbe")
content = remove_probe_block(content, "readinessProbe")
content = remove_probe_block(content, "startupProbe")

with open(manifest_path, 'w') as f:
    f.write(content)
PYEOF

  # ── [4/6] Apply Kubernetes resources (DaemonSet, RBAC, CRDs) ────────────
  # Standard k8s resources use kubectl; Calico-native resources use calicoctl
  echo -e "${CYAN}  Applying Calico Kubernetes manifests (CRDs, DaemonSet, RBAC)...${NC}"
  kubectl apply -f "$CALICO_MANIFEST" >> "$LOG_FILE" 2>&1
  local RC=$?
  if [[ $RC -ne 0 ]]; then
    echo -e "${RED}  ❌ kubectl apply failed (RC=${RC}) — check $LOG_FILE${NC}"
    return 1
  fi
  echo -e "${GREEN}  ✓ Calico Kubernetes manifests applied${NC}"

  # ── [5/6] Wait for CRDs + calicoctl connectivity ─────────────────────────
  # Only need CRD Established=True — calicoctl bypasses the REST mapper
  # so there's no need to wait for kubectl API group discovery to refresh.
  echo -e "${CYAN}  ⏳ Waiting for Calico CRDs to establish...${NC}"
  local CRD_TIMEOUT=120 CRD_ELAPSED=0
  while [[ $CRD_ELAPSED -lt $CRD_TIMEOUT ]]; do
    local ALL_READY=true
    for crd in "ippools.crd.projectcalico.org" "felixconfigurations.crd.projectcalico.org"; do
      local STATUS
      STATUS=$(kubectl get crd "$crd" \
        -o jsonpath='{.status.conditions[?(@.type=="Established")].status}' 2>/dev/null)
      [[ "$STATUS" != "True" ]] && { ALL_READY=false; break; }
    done
    [[ "$ALL_READY" == "true" ]] && { log "Calico CRDs established at ${CRD_ELAPSED}s"; break; }
    sleep 5; CRD_ELAPSED=$((CRD_ELAPSED + 5))
    [[ $((CRD_ELAPSED % 15)) -eq 0 ]] && \
      echo -e "${CYAN}    ⟳ CRDs not yet established... [${CRD_ELAPSED}s/${CRD_TIMEOUT}s]${NC}"
  done
  if [[ $CRD_ELAPSED -ge $CRD_TIMEOUT ]]; then
    echo -e "${RED}  ❌ Calico CRDs not established after ${CRD_TIMEOUT}s${NC}"; return 1
  fi
  echo -e "${GREEN}  ✓ Calico CRDs established${NC}"

  # ── [6/6] Apply IPPool + FelixConfiguration via calicoctl ───────────────
  # calicoctl connects directly to the Calico datastore (kubernetes backend)
  # and applies Calico-native resources without going through kubectl's
  # REST mapper — eliminates "no matches for kind" timing errors entirely.
  local _IPPOOL_YAML="/tmp/calico-ippool.yaml"
  local _FELIX_YAML="/tmp/calico-felix.yaml"

  cat > "$_IPPOOL_YAML" << IPPOOL_EOF
apiVersion: projectcalico.org/v3
kind: IPPool
metadata:
  name: default-ipv4-ippool
spec:
  cidr: ${POD_CIDR}
  ipipMode: Never
  vxlanMode: Always
  natOutgoing: true
  disabled: false
IPPOOL_EOF

  cat > "$_FELIX_YAML" << FELIX_EOF
apiVersion: projectcalico.org/v3
kind: FelixConfiguration
metadata:
  name: default
spec:
  ipipEnabled: false
  vxlanEnabled: true
  vxlanPort: 4789
  logSeverityScreen: Info
FELIX_EOF

  echo -e "${CYAN}  Applying IPPool via calicoctl...${NC}"
  local _CT_ATTEMPTS=0
  while [[ $_CT_ATTEMPTS -lt 5 ]]; do
    if $CALICOCTL apply -f "$_IPPOOL_YAML" >> "$LOG_FILE" 2>&1; then
      echo -e "${GREEN}  ✓ IPPool applied (VXLAN=Always · IPIP=Never · CIDR=${POD_CIDR})${NC}"
      break
    fi
    _CT_ATTEMPTS=$((_CT_ATTEMPTS + 1))
    log "calicoctl IPPool retry ${_CT_ATTEMPTS}/5"
    sleep 5
    [[ $_CT_ATTEMPTS -ge 5 ]] && {
      echo -e "${RED}  ❌ calicoctl IPPool failed after 5 attempts — check $LOG_FILE${NC}"
      return 1
    }
  done

  echo -e "${CYAN}  Applying FelixConfiguration via calicoctl...${NC}"
  _CT_ATTEMPTS=0
  while [[ $_CT_ATTEMPTS -lt 5 ]]; do
    if $CALICOCTL apply -f "$_FELIX_YAML" >> "$LOG_FILE" 2>&1; then
      echo -e "${GREEN}  ✓ FelixConfiguration applied (VXLAN=true · IPIP=false · port=4789)${NC}"
      break
    fi
    _CT_ATTEMPTS=$((_CT_ATTEMPTS + 1))
    log "calicoctl FelixConfiguration retry ${_CT_ATTEMPTS}/5"
    sleep 5
    [[ $_CT_ATTEMPTS -ge 5 ]] && {
      echo -e "${RED}  ❌ calicoctl FelixConfiguration failed after 5 attempts — check $LOG_FILE${NC}"
      return 1
    }
  done

  # Restart calico-node to activate all settings
  echo -e "${CYAN}  Restarting calico-node daemonset...${NC}"
  kubectl rollout restart daemonset/calico-node -n kube-system >> "$LOG_FILE" 2>&1
  echo -e "${GREEN}  ✓ calico-node restarted${NC}"

  echo ""
  echo -e "${GREEN}✓ Calico ${CALICO_VERSION} deployed (pure VXLAN):${NC}"
  echo -e "   ${CYAN}Pod CIDR       :${NC} ${WHITE}${POD_CIDR}${NC}"
  echo -e "   ${CYAN}calico_backend :${NC} ${WHITE}vxlan${NC}   ${DIM}(VXLAN routing, BIRD never starts)${NC}"
  echo -e "   ${CYAN}IPIP           :${NC} ${WHITE}Never${NC}   ${DIM}(no tunl0 interface)${NC}"
  echo -e "   ${CYAN}VXLAN          :${NC} ${WHITE}Always${NC}  ${DIM}(UDP 4789 · vxlan.calico)${NC}"
  echo -e "   ${CYAN}BGP            :${NC} ${WHITE}None${NC}    ${DIM}(pure VXLAN — not configured)${NC}"
  echo -e "   ${CYAN}Interface      :${NC} ${WHITE}${IFACE}${NC}    ${DIM}(Host-Only, not NAT)${NC}"
  echo -e "   ${CYAN}calicoctl      :${NC} ${WHITE}${CALICO_VERSION}${NC} ${DIM}(→ ${CALICOCTL})${NC}"
}

# ════════════════════════════════════════════════════════════════════════════
# MASTER BOOTSTRAP
# ════════════════════════════════════════════════════════════════════════════
bootstrap_master() {
  progress
  print_header "INITIALIZING CONTROL PLANE"

  if [[ ! -f /etc/kubernetes/admin.conf ]]; then
    echo -e "${YELLOW}⚙️  Running kubeadm init...${NC}"
    MASTER_IP="${HOST_ONLY_IP}"
    echo -e "${CYAN}  advertiseAddress : ${BOLD}${WHITE}${MASTER_IP}${NC}${CYAN} (Host-Only — not NAT)${NC}"
    echo -e "${CYAN}  podSubnet        : ${WHITE}${POD_CIDR}${NC}"

    local CRI_SOCK="unix:///run/containerd/containerd.sock"
    [[ "$RUNTIME" == "crio" ]] && CRI_SOCK="unix:///var/run/crio/crio.sock"

    # resolvConf: systemd-resolved stub on Ubuntu/Debian, static on RHEL/Rocky
    local RESOLV_CONF="/etc/resolv.conf"
    [[ "$OS" =~ (ubuntu|debian) ]] && {
      [[ -f /run/systemd/resolve/resolv.conf ]] && RESOLV_CONF="/run/systemd/resolve/resolv.conf"
    }

    cat > /root/kubeadm-config.yaml << KCFG_EOF
apiVersion: kubeadm.k8s.io/v1beta3
kind: InitConfiguration
localAPIEndpoint:
  advertiseAddress: "${MASTER_IP}"
  bindPort: 6443
nodeRegistration:
  criSocket: ${CRI_SOCK}
  kubeletExtraArgs:
    node-ip: "${HOST_ONLY_IP}"
---
apiVersion: kubeadm.k8s.io/v1beta3
kind: ClusterConfiguration
kubernetesVersion: v${K8S_VERSION}
networking:
  podSubnet: ${POD_CIDR}
  serviceSubnet: 10.96.0.0/12
controlPlaneEndpoint: "${MASTER_IP}:6443"
apiServer:
  extraArgs:
    bind-address: "0.0.0.0"
    advertise-address: "${MASTER_IP}"
---
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
resolvConf: ${RESOLV_CONF}
KCFG_EOF

    # ── Pre-flight: verify hostname resolves to HOST_ONLY_IP, not loopback ───
    # getent hosts on Rocky/RHEL may return IPv6 link-local (fe80::) first.
    # Use getent ahostsv4 to force IPv4-only resolution, then fall back to
    # /etc/hosts direct grep if ahostsv4 is unavailable.
    local _RESOLVED_IP
    if getent ahostsv4 "$(hostname)" &>/dev/null 2>&1; then
      _RESOLVED_IP=$(getent ahostsv4 "$(hostname)" 2>/dev/null \
        | awk '{print $1}' | grep -v '^127\.' | head -1)
    else
      _RESOLVED_IP=$(getent hosts "$(hostname)" 2>/dev/null \
        | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
        | grep -v '^127\.' | head -1)
    fi
    if [[ "$_RESOLVED_IP" != "$MASTER_IP" ]]; then
      echo -e "${RED}❌ Hostname '$(hostname)' resolves to '${_RESOLVED_IP:-none}' — expected '${MASTER_IP}'${NC}"
      echo -e "${YELLOW}   Fixing /etc/hosts: removing stale entries for $(hostname)...${NC}"
      # Remove ALL stale hostname entries (loopback, wrong IP, IPv6-only aliases)
      sed -i "/[[:space:]]\+$(hostname)\([[:space:]]\|$\)/d" /etc/hosts
      # Write the correct entry
      printf "%s\t%s\n" "${MASTER_IP}" "$(hostname)" >> /etc/hosts
      log "/etc/hosts: replaced stale entries for $(hostname) with ${MASTER_IP}"
      # Re-verify with IPv4-only lookup
      if getent ahostsv4 "$(hostname)" &>/dev/null 2>&1; then
        _RESOLVED_IP=$(getent ahostsv4 "$(hostname)" 2>/dev/null \
          | awk '{print $1}' | grep -v '^127\.' | head -1)
      else
        _RESOLVED_IP=$(getent hosts "$(hostname)" 2>/dev/null \
          | awk '{print $1}' | grep -E '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$' \
          | grep -v '^127\.' | head -1)
      fi
      if [[ "$_RESOLVED_IP" != "$MASTER_IP" ]]; then
        echo -e "${RED}❌ Still resolves to '${_RESOLVED_IP:-none}' — check /etc/hosts manually${NC}"
        cat /etc/hosts
        exit 1
      fi
      echo -e "${GREEN}   ✓ Hostname now resolves to ${MASTER_IP}${NC}"
    else
      echo -e "${GREEN}   ✓ Hostname resolves to ${MASTER_IP} (correct)${NC}"
    fi

    echo -e "${CYAN}  Running kubeadm init (full log → $LOG_FILE)...${NC}"
    echo ""

    # ── Kill any stale process occupying port 6443 ───────────────────────────
    # A previous failed kubeadm init may leave kube-apiserver still running,
    # which causes [ERROR Port-6443] on re-run.
    local _STALE_PID
    _STALE_PID=$(ss -tlnp 'sport = :6443' 2>/dev/null | awk 'NR>1{match($0,/pid=([0-9]+)/,a); if(a[1]) print a[1]}' | head -1)
    if [[ -n "$_STALE_PID" ]]; then
      echo -e "${YELLOW}  ⚠️  Port 6443 in use by PID ${_STALE_PID} — killing stale process...${NC}"
      kill -9 "$_STALE_PID" 2>/dev/null || true
      sleep 2
      log "Killed stale process on port 6443: PID ${_STALE_PID}"
      echo -e "${GREEN}  ✓ Port 6443 freed${NC}"
    fi
    # Run kubeadm init — log everything, show only meaningful phase lines on terminal
    local KINIT_RC=0
    kubeadm init --config=/root/kubeadm-config.yaml 2>&1       | tee -a "$LOG_FILE"       | grep --line-buffered -iE "error|fail|warning|control-plane has initialized"       | while IFS= read -r line; do
          if echo "$line" | grep -qiE "error|fail"; then
            echo -e "  ${RED}${line}${NC}"
          elif echo "$line" | grep -qiE "warning"; then
            echo -e "  ${YELLOW}${line}${NC}"
          elif echo "$line" | grep -qiE "control-plane has initialized"; then
            echo -e "\n  ${GREEN}✔  Your Kubernetes control-plane has initialized successfully!${NC}\n"
          fi
        done
    KINIT_RC=${PIPESTATUS[0]}

    [[ $KINIT_RC -ne 0 ]] && { echo -e "${RED}❌ kubeadm init failed — check $LOG_FILE${NC}"; exit 1; }
  else
    echo -e "${GREEN}✓ Cluster already initialized${NC}"
  fi

  local TARGET_USER="${SUDO_USER:-$(whoami)}"
  local USER_HOME; USER_HOME=$(eval echo "~$TARGET_USER")
  mkdir -p "$USER_HOME/.kube"
  cp -f /etc/kubernetes/admin.conf "$USER_HOME/.kube/config"
  chown -R "$TARGET_USER:$TARGET_USER" "$USER_HOME/.kube"
  export KUBECONFIG=/etc/kubernetes/admin.conf

  echo -e "${YELLOW}⏳ Waiting for API server...${NC}"
  local W=0
  while [[ $W -lt 120 ]]; do
    kubectl get nodes &>/dev/null && { echo -e "${GREEN}✓ API server ready${NC}"; break; }
    sleep 3; W=$((W+3))
  done

  local NN; NN=$(kubectl get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  # Deploy CNI FIRST — while the control-plane taint still blocks scheduling.
  # This ensures calico-node is fully Running and has written the CNI conflist
  # to /etc/cni/net.d/ BEFORE any other pod (coredns, calico-kube-controllers)
  # is allowed to schedule.  If we remove the taint first, coredns races with
  # calico-node init and gets stuck with "cni plugin not initialized".
  progress
  select_and_deploy_cni

  # ── Wait for calico-node to be 1/1 Ready AND CNI conflist on disk ───────────
  # The node won't go Ready until calico-node writes /etc/cni/net.d/*.conflist.
  # We gate on BOTH conditions so there is zero race between CNI init and
  # coredns/calico-kube-controllers being scheduled after taint removal.
  progress
  echo -e "${YELLOW}⏳ Waiting for calico-node Ready and CNI plugin initialized...${NC}"
  local _CW=0 _CMAX=300
  while [[ $_CW -lt $_CMAX ]]; do
    # Check calico-node pod is 1/1 Ready
    local _CN_RDY
    _CN_RDY=$(kubectl get pods -n kube-system -l k8s-app=calico-node \
      -o jsonpath='{.items[0].status.containerStatuses[0].ready}' 2>/dev/null)

    # Check CNI conflist written to disk by calico-node
    local _CONFLIST_OK=false
    ls /etc/cni/net.d/*.conflist &>/dev/null 2>&1 && _CONFLIST_OK=true

    if [[ "$_CN_RDY" == "true" && "$_CONFLIST_OK" == "true" ]]; then
      echo -e "${GREEN}✓ calico-node Ready and CNI conflist present — network initialized${NC}"
      log "calico-node Ready + CNI conflist confirmed at ${_CW}s"
      break
    fi

    if [[ $((_CW % 30)) -eq 0 ]]; then
      echo -e "${CYAN}  ⟳ calico-node ready=${_CN_RDY:-false}  conflist=${_CONFLIST_OK}  [${_CW}s/${_CMAX}s]${NC}"
    fi
    sleep 5; _CW=$((_CW + 5))
  done

  if [[ $_CW -ge $_CMAX ]]; then
    echo -e "${RED}  ❌ calico-node not Ready after ${_CMAX}s — check: kubectl logs -n kube-system -l k8s-app=calico-node${NC}"
    exit 1
  fi

  # ── Wait for node condition Ready ────────────────────────────────────────────
  echo -e "${YELLOW}⏳ Waiting for node Ready condition...${NC}"
  local W=0
  while [[ $W -lt 120 ]]; do
    local ST; ST=$(kubectl get node "$NN" \
      -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}' 2>/dev/null)
    [[ "$ST" == "True" ]] && { echo -e "${GREEN}✓ Node ${NN} Ready${NC}"; break; }
    [[ $((W % 20)) -eq 0 ]] && echo -e "${CYAN}  ⟳ Node condition: ${ST:-Unknown} [${W}s]${NC}"
    sleep 5; W=$((W+5))
  done

  # ── Patch CoreDNS + calico-kube-controllers tolerations instead of removing taint ─
  progress
  # The control-plane taint (node-role.kubernetes.io/control-plane:NoSchedule)
  # is intentionally KEPT on the master node — removing it is unsafe and
  # unnecessary. Calico DaemonSets already tolerate it (operator: Exists).
  # CoreDNS and calico-kube-controllers do NOT tolerate it by default, so we
  # patch their Deployments to add the specific toleration — same result as
  # taint removal but without exposing the master to arbitrary workloads.
  echo -e "${CYAN}  Patching CoreDNS tolerations for control-plane scheduling...${NC}"
  kubectl patch deployment coredns -n kube-system --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}}]' \
    >> "$LOG_FILE" 2>&1 || true
  echo -e "${GREEN}  ✓ CoreDNS toleration added${NC}"

  echo -e "${CYAN}  Patching calico-kube-controllers tolerations...${NC}"
  kubectl patch deployment calico-kube-controllers -n kube-system --type=json \
    -p='[{"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"node-role.kubernetes.io/control-plane","operator":"Exists","effect":"NoSchedule"}}]' \
    >> "$LOG_FILE" 2>&1 || true
  echo -e "${GREEN}  ✓ calico-kube-controllers toleration added${NC}"

  # Restart pods so they re-schedule with the new tolerations
  kubectl rollout restart deployment/coredns -n kube-system >> "$LOG_FILE" 2>&1 || true
  kubectl rollout restart deployment/calico-kube-controllers -n kube-system >> "$LOG_FILE" 2>&1 || true
  echo -e "${GREEN}  ✓ control-plane taint preserved — pods patched to tolerate it${NC}"
  log "control-plane taint kept; CoreDNS + calico-kube-controllers patched with toleration"

  if wait_for_master_pods_ready; then
    progress_complete
    print_bootstrap_complete_master
  else
    echo -e "${RED}❌ Cluster not fully ready — check $LOG_FILE${NC}"; exit 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# WORKER JOIN
# ════════════════════════════════════════════════════════════════════════════
bootstrap_worker() {
  progress
  print_header "WORKER NODE JOIN"
  echo -e "${CYAN}  Worker Host-Only IP : ${BOLD}${WHITE}${HOST_ONLY_IP}${NC}${CYAN} (will be used as node-ip)${NC}"
  echo ""

  if [[ ! -f /etc/kubernetes/kubelet.conf ]]; then
    local JOIN_CMD
    prompt_input "  Paste kubeadm join command from master: " JOIN_CMD

    [[ "$JOIN_CMD" != kubeadm\ join* ]] && \
      { echo -e "${RED}  ❌ Must start with 'kubeadm join ...'${NC}"; exit 1; }

    # Append CRI socket if missing
    if [[ ! "$JOIN_CMD" =~ "cri-socket" ]]; then
      if [[ "$RUNTIME" == "crio" ]]; then
        JOIN_CMD="$JOIN_CMD --cri-socket unix:///var/run/crio/crio.sock"
      else
        JOIN_CMD="$JOIN_CMD --cri-socket unix:///run/containerd/containerd.sock"
      fi
    fi

    # Write --node-ip to kubelet extra-args BEFORE joining.
    # NOTE: --node-ip is NOT a valid kubeadm join flag — it caused the
    # "unknown flag: --node-ip" error. It must be set in kubelet's config
    # so kubelet picks it up when it starts during/after the join.
    echo -e "${CYAN}  Setting kubelet --node-ip=${HOST_ONLY_IP} before join...${NC}"
    if [[ "$OS" =~ (ubuntu|debian) ]]; then
      echo "KUBELET_EXTRA_ARGS=--node-ip=${HOST_ONLY_IP}" > /etc/default/kubelet
    else
      mkdir -p /etc/sysconfig
      echo "KUBELET_EXTRA_ARGS=--node-ip=${HOST_ONLY_IP}" > /etc/sysconfig/kubelet
    fi
    systemctl daemon-reload
    echo -e "${GREEN}  ✓ kubelet extra-args written (node-ip=${HOST_ONLY_IP})${NC}"

    echo -e "${YELLOW}  Joining cluster...${NC}"
    echo -e "${CYAN}  node-ip=${HOST_ONLY_IP} (Host-Only — Calico VXLAN will bind to this)${NC}"

    # Run kubeadm join — output goes to log only
    # Bridge/sysctl preflight checks pass cleanly because configure_kernel()
    # already wrote all required sysctl values earlier in --init.
    # No --ignore-preflight-errors needed.
    eval "${JOIN_CMD}" >> "$LOG_FILE" 2>&1

    if [[ $? -ne 0 ]]; then
      echo -e "${RED}  ❌ Join failed — check $LOG_FILE${NC}"
      tail -30 "$LOG_FILE"
      exit 1
    fi
    sleep 10
  else
    echo -e "${GREEN}✓ Worker already joined${NC}"
  fi

  # Restart kubelet so KUBELET_EXTRA_ARGS (--node-ip) takes full effect
  systemctl daemon-reload
  systemctl restart kubelet
  sleep 5

  echo -e "${GREEN}✓ Worker joined — node-ip=${HOST_ONLY_IP} (Host-Only, never NAT)${NC}"
  echo ""

  # wait_for_worker_pods_ready is the single readiness gate:
  #   1. Waits for kubelet active
  #   2. Patches resolvConf on Rocky/RHEL if needed
  #   3. Waits for CNI agent (calico-node/flannel) Running via crictl --state running
  #   4. Checks vxlan.calico interface after CNI confirmed
  if wait_for_worker_pods_ready; then
    progress_complete
    print_bootstrap_complete_worker
  else
    echo -e "${RED}❌ Worker not fully ready — check: journalctl -u kubelet -n 50${NC}"; exit 1
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# CREDITS
# ════════════════════════════════════════════════════════════════════════════
print_credits() {
  echo -e "${DIM}╔══════════════════════════════════════════════════════════════════╗${NC}"
  echo -e "${DIM}║${NC}                     ${CYAN}Script Information${NC}                         ${DIM}║${NC}"
  echo -e "${DIM}╠══════════════════════════════════════════════════════════════════╣${NC}"
  echo -e "${DIM}║${NC}  ${WHITE}Author  :${NC} ${CYAN}Sreekanth K${NC}                                           ${DIM}║${NC}"
  echo -e "${DIM}║${NC}  ${WHITE}Email   :${NC} ${CYAN}ksk5940@gmail.com${NC}                                     ${DIM}║${NC}"
  echo -e "${DIM}║${NC}  ${WHITE}Script  :${NC} k8s-cluster-bootstrap.sh                             ${DIM}║${NC}"
  echo -e "${DIM}║${NC}  ${WHITE}Version :${NC} 1.0.0                                                ${DIM}║${NC}"
  echo -e "${DIM}║${NC}  ${WHITE}Supports:${NC} Ubuntu · Debian · Rocky · RHEL · AlmaLinux           ${DIM}║${NC}"
  echo -e "${DIM}║${NC}  ${WHITE}CNI     :${NC} Calico (VXLAN) · Flannel                             ${DIM}║${NC}"
  echo -e "${DIM}╚══════════════════════════════════════════════════════════════════╝${NC}"
  echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# COMPLETION BANNERS
# ════════════════════════════════════════════════════════════════════════════
print_bootstrap_complete_master() {
  local ET=$(($(date +%s) - START_TIME))
  print_header "CLUSTER SETUP COMPLETE!"
  echo -e "${CYAN}📊 Master Summary:${NC}"
  echo -e "   ${GREEN}✓${NC} Kubernetes   : ${WHITE}v${K8S_VERSION}${NC}"
  echo -e "   ${GREEN}✓${NC} Runtime      : ${WHITE}$RUNTIME${NC}"
  echo -e "   ${GREEN}✓${NC} Master IP    : ${WHITE}$HOST_ONLY_IP${NC} ${DIM}(Host-Only 192.168.x.x)${NC}"
  echo -e "   ${GREEN}✓${NC} Pod CIDR     : ${WHITE}${POD_CIDR}${NC} ${DIM}(Calico + Flannel unified)${NC}"
  echo -e "   ${GREEN}✓${NC} CNI          : ${WHITE}${CNI_CHOICE^^}${NC}"
  echo -e "   ${GREEN}✓${NC} Interface    : ${WHITE}$HOST_ONLY_IFACE${NC}"
  if [[ "$CNI_CHOICE" == "calico" ]]; then
    echo -e "   ${GREEN}✓${NC} VXLAN        : ${WHITE}Always${NC} ${DIM}(UDP 4789 · vxlan.calico)${NC}"
    echo -e "   ${GREEN}✓${NC} IPIP         : ${WHITE}Never${NC}"
    echo -e "   ${GREEN}✓${NC} BGP          : ${WHITE}None${NC} ${DIM}(pure VXLAN mode)${NC}"
    echo -e "   ${GREEN}✓${NC} Backend      : ${WHITE}vxlan${NC} ${DIM}(BIRD not started)${NC}"
  fi
  echo ""
  echo -e "${YELLOW}🔗 Worker Join Command (run on each worker):${NC}"
  echo -e "${DIM}  ─────────────────────────────────────────────────────────${NC}"
  # Print the raw join command with NO leading spaces, NO color codes, NO trailing chars
  # so it can be copied directly from the console and pasted into any worker node terminal.
  local _JOIN_CMD
  _JOIN_CMD=$(kubeadm token create --print-join-command 2>/dev/null)
  echo "$_JOIN_CMD"
  echo -e "${DIM}  ─────────────────────────────────────────────────────────${NC}"
  echo ""
  echo -e "${DIM}  Script adds --node-ip and --cri-socket automatically${NC}"
  echo ""
  echo -e "${CYAN}⏱️  Total time : ${WHITE}$((ET/60))m $((ET%60))s${NC}"
  echo -e "${CYAN}📄 Log file   : ${WHITE}$LOG_FILE${NC}"
  echo ""
  print_credits
}

print_bootstrap_complete_worker() {
  local ET=$(($(date +%s) - START_TIME))
  print_header "WORKER NODE READY!"
  echo -e "${CYAN}📊 Worker Summary:${NC}"
  echo -e "   ${GREEN}✓${NC} Kubernetes   : ${WHITE}v${K8S_VERSION}${NC}"
  echo -e "   ${GREEN}✓${NC} Runtime      : ${WHITE}$RUNTIME${NC}"
  echo -e "   ${GREEN}✓${NC} Worker IP    : ${WHITE}$HOST_ONLY_IP${NC} ${DIM}(Host-Only 192.168.x.x)${NC}"
  echo ""
  echo -e "${YELLOW}  Check on master: ${WHITE}kubectl get nodes -o wide${NC}"
  echo ""
  echo -e "${CYAN}⏱️  Total time : ${WHITE}$((ET/60))m $((ET%60))s${NC}"
  echo -e "${CYAN}📄 Log file   : ${WHITE}$LOG_FILE${NC}"
  echo ""
  print_credits
}

# ════════════════════════════════════════════════════════════════════════════
# SHARED CLEANUP HELPERS
# ════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════
# CNI CLEANUP HELPERS
#
# Root cause of lingering cali* interfaces:
#   containerd creates pod network namespaces as anonymous bind-mounts under
#   /var/run/netns/<id> — these do NOT appear in 'ip netns list' because they
#   are not registered with iproute2.  Each anonymous netns holds the peer end
#   of a veth pair (cali*@if2).  While that netns reference exists the kernel
#   refuses to delete the host-side cali* interface ("device or resource busy").
#
#   Also: ip -o link show prints "cali1b1727edeb1@if2" — the @if2 suffix must
#   be stripped before passing to 'ip link delete'.
# ════════════════════════════════════════════════════════════════════════════

# ── _ifaces_matching: list host-side interface names matching a pattern ──────
# Strips the @ifN peer suffix so names are usable with ip link delete.
_ifaces_matching() {
  ip -o link show 2>/dev/null \
    | awk '{print $2}' \
    | sed 's/@.*//' \
    | grep -E "$1" || true
}

# ── _del_iface: bring down and delete one interface, retry up to 4x ──────────
_del_iface() {
  local _if="$1" _try _max=4
  ip link show "$_if" &>/dev/null || return 0
  for (( _try=1; _try<=_max; _try++ )); do
    ip link set "$_if" down 2>/dev/null || true
    ip link delete "$_if" 2>/dev/null && { log "deleted iface ${_if}"; return 0; }
    log "iface ${_if}: attempt ${_try}/${_max} failed — waiting 2s"
    sleep 2
  done
  log "WARNING: could not delete iface ${_if} after ${_max} attempts"
}

# ── _del_tunnel: clear IP-in-IP / GRE tunnel and unload its kernel module ───
# tunl0 is created by the 'ipip' kernel module.  'ip tunnel del' only removes
# the named instance; the interface reappears as long as the module is loaded.
# The only clean removal is to unload the module itself.  We bring the
# interface down first, remove the instance, then rmmod ipip (and its dep
# tunnel4).  If the module is in use by something else rmmod will safely fail.
_del_tunnel() {
  local _tun="$1"
  ip link show "$_tun" &>/dev/null || return 0
  ip link set "$_tun" down 2>/dev/null || true
  ip tunnel del "$_tun" 2>/dev/null || true
  # Unload the kernel module so the interface does not persist after removal
  modprobe -r ipip    2>/dev/null || true
  modprobe -r tunnel4 2>/dev/null || true
  log "tunnel ${_tun} cleared and ipip module unloaded"
}

# ── _cleanup_namespaces ──────────────────────────────────────────────────────
# Releases ALL pod network namespaces — both named (ip netns list) and
# anonymous bind-mounts under /var/run/netns/ that containerd creates.
# Once released the kernel drops its reference to the veth peer, making
# the host-side cali* interface deletable.
_cleanup_namespaces() {
  local _f _ns

  # 1. Anonymous bind-mounts — these are the ones holding cali*@if2 peers.
  #    They live under /var/run/netns/ (containerd) or /run/netns/ (symlink).
  for _dir in /var/run/netns /run/netns; do
    [[ -d "$_dir" ]] || continue
    for _f in "$_dir"/*; do
      [[ -e "$_f" ]] || continue
      # umount releases the netns kernel reference
      umount "$_f" 2>/dev/null || umount -l "$_f" 2>/dev/null || true
      rm -f "$_f" 2>/dev/null || true
      log "released anonymous netns ${_f}"
    done
  done

  # 2. Named netns registered with iproute2 (cri-o, older CNI plugins)
  for _ns in $(ip netns list 2>/dev/null | awk '{print $1}'); do
    ip netns delete "$_ns" 2>/dev/null || true
    log "deleted named netns ${_ns}"
  done

  # Give kernel 2 s to garbage-collect veth peers after netns teardown
  sleep 2
}

# ── _cleanup_cni_interfaces ──────────────────────────────────────────────────
# Remove all virtual interfaces left by Calico / Flannel / CNI.
# MUST run after _cleanup_namespaces so veth peers are no longer held.
_cleanup_cni_interfaces() {
  local _if

  # cali* — Calico per-pod host-side veth peers
  while IFS= read -r _if; do
    [[ -n "$_if" ]] && _del_iface "$_if"
  done < <(_ifaces_matching '^cali')

  # veth* — generic CNI bridge plugin veth pairs
  while IFS= read -r _if; do
    [[ -n "$_if" ]] && _del_iface "$_if"
  done < <(_ifaces_matching '^veth')

  # Calico VXLAN overlay
  _del_iface "vxlan.calico"
  _del_iface "vxlan-v6.calico"

  # IP-in-IP tunnel — kernel built-in, use tunnel del
  _del_tunnel "tunl0"

  # Flannel VXLAN / CNI bridge / IPVS dummy / docker bridge
  for _if in flannel.1 cni0 kube-ipvs0 kube-bridge docker0; do
    _del_iface "$_if"
  done

  # Any remaining wireguard / kube-* devices
  while IFS= read -r _if; do
    [[ -n "$_if" ]] && _del_iface "$_if"
  done < <(_ifaces_matching '^(wireguard|kube-)')

  # ── Unload CNI-related kernel modules ─────────────────────────────────────
  # tunl0  → ipip + tunnel4   (Calico IP-in-IP)
  # vxlan* → vxlan            (Calico VXLAN / Flannel VXLAN)
  # bridge → bridge           (CNI bridge plugin / docker0)
  # ip_vs* → IPVS kube-proxy mode
  # modprobe -r is a safe no-op when the module is still in use or not loaded.
  for _mod in ipip tunnel4 vxlan bridge wireguard ip_vs ip_vs_rr ip_vs_wrr ip_vs_sh nf_conntrack; do
    modprobe -r "$_mod" 2>/dev/null || true
  done
  log "CNI kernel modules unloaded"
}

# ── _cleanup_iptables_kube ───────────────────────────────────────────────────
# Flush and remove all KUBE-* and cali*/CALICO* iptables chains.
_cleanup_iptables_kube() {
  local _t _c
  for _t in nat filter; do
    for _c in $(iptables -t "$_t" -nL 2>/dev/null \
                | awk '/^Chain (KUBE|cali|CALICO)/{print $2}'); do
      iptables -t "$_t" -F "$_c" 2>/dev/null || true
      iptables -t "$_t" -X "$_c" 2>/dev/null || true
    done
  done
  command -v ipvsadm &>/dev/null && ipvsadm -C 2>/dev/null || true
}

# ════════════════════════════════════════════════════════════════════════════
# --reset
# ════════════════════════════════════════════════════════════════════════════
run_reset() {
  # Reset has its own step counter — isolated from --init's CURRENT_STEP
  local RESET_STEP=0
  local RESET_TOTAL=6
  _reset_progress() {
    RESET_STEP=$(( RESET_STEP + 1 ))
    local PCT=$(( RESET_STEP * 100 / RESET_TOTAL ))
    local BAR_WIDTH=50
    local FILLED=$(( PCT * BAR_WIDTH / 100 ))
    local EMPTY=$(( BAR_WIDTH - FILLED ))
    [[ $EMPTY -lt 0 ]] && EMPTY=0
    local BAR; BAR=$(printf "%${FILLED}s" | tr ' ' '█')
    local SPC; SPC=$(printf "%${EMPTY}s")
    printf "\n${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║${NC}  ${YELLOW}Reset: [%3d%%]${NC} ${GREEN}%s${DIM}%s${NC}  ${CYAN}║${NC}\n" "$PCT" "$BAR" "$SPC"
    printf "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}\n"
  }
  _reset_progress_complete() {
    local BAR; BAR=$(printf "%50s" | tr ' ' '█')
    printf "\n${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${CYAN}║${NC}  ${YELLOW}Reset: [100%%]${NC} ${GREEN}%s${NC}  ${CYAN}║${NC}\n" "$BAR"
    printf "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}\n"
  }

  print_header "CLUSTER RESET (packages preserved)"

  # ── Detect OS early — needed for OS-specific path decisions ──────────────
  source /etc/os-release; OS="$ID"
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    PKG_MANAGER="apt"
  else
    PKG_MANAGER="dnf"
  fi

  # ── Detect node type ──────────────────────────────────────────────────────
  local HN; HN=$(hostname | tr '[:upper:]' '[:lower:]')
  local RNT="worker"   # safe default
  if [[ -n "${ARG_NODE_TYPE:-}" ]]; then
    RNT="$ARG_NODE_TYPE"
    echo -e "${CYAN}  Node type : ${WHITE}${RNT^^}${GREEN} (--node-type override)${NC}"
  elif [[ "$HN" =~ master|control ]]; then
    RNT="master"
    echo -e "${CYAN}  Node type : ${WHITE}MASTER${NC} ${DIM}(detected from hostname)${NC}"
  elif command -v kubectl &>/dev/null && [[ -f /etc/kubernetes/admin.conf ]]; then
    RNT="master"
    echo -e "${CYAN}  Node type : ${WHITE}MASTER${NC} ${DIM}(detected: kubectl + admin.conf present)${NC}"
  else
    echo -e "${CYAN}  Node type : ${WHITE}WORKER${NC} ${DIM}(detected from hostname)${NC}"
  fi

  # ── Detect installed runtime ──────────────────────────────────────────────
  # Rocky-specific: containerd installed from Docker's repo is packaged as
  # "containerd.io" (rpm name), not "containerd".  Both are checked.
  local RRT=""
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    dpkg-query -W -f='${Status}' containerd    2>/dev/null | grep -q "ok installed" && RRT="containerd"
    dpkg-query -W -f='${Status}' containerd.io 2>/dev/null | grep -q "ok installed" && RRT="containerd"
    [[ -z "$RRT" ]] && \
      dpkg-query -W -f='${Status}' cri-o 2>/dev/null | grep -q "ok installed" && RRT="crio"
  else
    rpm -q containerd    &>/dev/null && RRT="containerd"
    rpm -q containerd.io &>/dev/null && RRT="containerd"
    [[ -z "$RRT" ]] && rpm -q cri-o &>/dev/null && RRT="crio"
  fi
  [[ -z "$RRT" ]] && command -v containerd &>/dev/null && RRT="containerd"
  [[ -z "$RRT" ]] && command -v crio       &>/dev/null && RRT="crio"
  [[ -z "$RRT" && -S /run/containerd/containerd.sock ]] && RRT="containerd"
  [[ -z "$RRT" && -S /var/run/crio/crio.sock          ]] && RRT="crio"
  [[ -z "$RRT" ]] && systemctl list-unit-files 2>/dev/null | grep -q "^containerd" && RRT="containerd"
  [[ -z "$RRT" ]] && systemctl list-unit-files 2>/dev/null | grep -q "^crio"       && RRT="crio"

  echo -e "${CYAN}  Runtime   : ${WHITE}${RRT:-not detected}${NC}"
  echo -e "${CYAN}  OS        : ${WHITE}${OS}${NC}"
  echo ""

  # ── Show what WILL be cleared vs. preserved ───────────────────────────────
  echo -e "${YELLOW}  ⚠️  This will clear (no packages removed):${NC}"
  echo -e "${YELLOW}      • Cluster certs, kubeconfigs, kubelet state${NC}"
  if [[ "$RNT" == "master" ]]; then
    echo -e "${YELLOW}      • etcd data, admin.conf, kubeadm init config${NC}"
  fi
  echo -e "${YELLOW}      • CNI net.d configs, pod network state, /var/lib/calico, iptables KUBE-* chains${NC}"
  echo -e "${YELLOW}      • crictl config, kubelet node-ip extra-args${NC}"
  echo -e "${GREEN}      ✔ PRESERVED: kubelet kubeadm kubectl ${RRT:-runtime} cri-tools${NC}"
  echo -e "${GREEN}      ✔ PRESERVED: repos, GPG keys, kernel modules, sysctl, firewall rules${NC}"
  echo -e "${GREEN}      ✔ PRESERVED: /opt/cni/bin, containerd/crio config, k8sadmins group${NC}"
  echo ""
  printf "${YELLOW}  Type 'yes' to confirm reset: ${NC}"
  local CONF; read -r CONF
  [[ "$CONF" != "yes" ]] && { echo -e "${YELLOW}  Cancelled.${NC}"; exit 0; }
  echo ""

  # ── Protect SSH before touching iptables ─────────────────────────────────
  local SSH_PORT
  SSH_PORT=$(ss -tnlp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
  [[ -z "$SSH_PORT" ]] && SSH_PORT=22
  iptables -C INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT

  # ════════════════════════════════════════════════════════════════════════
  # [1/6] Stop services
  # ════════════════════════════════════════════════════════════════════════
  _reset_progress
  echo -e "${YELLOW}  [1/6] Stopping kubelet and runtime...${NC}"
  systemctl stop kubelet 2>/dev/null || true
  [[ -n "$RRT" ]] && systemctl stop "$RRT" 2>/dev/null || true
  echo -e "${GREEN}  ✓ Services stopped${NC}"

  # ════════════════════════════════════════════════════════════════════════
  # [2/6] kubeadm reset
  # Clears: etcd member state, bootstrap tokens, static pod manifests,
  #         /etc/kubernetes/pki, kubelet.conf, controller-manager.conf,
  #         scheduler.conf (all under /etc/kubernetes/).
  # Does NOT remove packages or repos.
  # ════════════════════════════════════════════════════════════════════════
  _reset_progress
  echo -e "${YELLOW}  [2/6] Running kubeadm reset...${NC}"
  if command -v kubeadm &>/dev/null; then
    kubeadm reset -f --ignore-preflight-errors=all >> "$LOG_FILE" 2>&1 || true
    echo -e "${GREEN}  ✓ kubeadm reset complete${NC}"
  else
    echo -e "${CYAN}  ℹ️  kubeadm not found — skipping${NC}"
  fi

  # ════════════════════════════════════════════════════════════════════════
  # [3/6] Cluster state, certs and configs
  # IMPORTANT: Worker stale-node deletion MUST happen BEFORE /etc/kubernetes
  # is removed — the kubeconfig lives there and is needed to talk to the master.
  # ════════════════════════════════════════════════════════════════════════
  _reset_progress
  echo -e "${YELLOW}  [3/6] Removing cluster state, certs and configs...${NC}"

  # ── Worker-only: remove stale node object from master FIRST ───────────
  # When a worker is reset, its node object stays in etcd on the master.
  # On re-join with the same hostname the new kubelet inherits the stale node —
  # Calico finds a conflicting record in its datastore and stalls marking the
  # node Ready.  Delete it NOW while /etc/kubernetes still exists (kubeconfig
  # is needed to reach the API server on the master).
  if [[ "$RNT" == "worker" ]]; then
    local _WN; _WN=$(hostname)
    local _KCFG=""
    # Search live paths — /etc/kubernetes not yet deleted at this point
    for _kc in /root/.kube/config /home/*/.kube/config /etc/kubernetes/kubelet.conf; do
      [[ -f "$_kc" ]] && { _KCFG="$_kc"; break; }
    done

    if [[ -n "$_KCFG" ]]; then
      echo -e "${CYAN}    Removing stale node '${_WN}' from master (using ${_KCFG})...${NC}"
      if KUBECONFIG="$_KCFG" kubectl delete node "$_WN" \
           --ignore-not-found=true >> "$LOG_FILE" 2>&1; then
        echo -e "${GREEN}    ✓ Stale node '${_WN}' removed — clean re-join guaranteed${NC}"
        log "Deleted stale worker node ${_WN} from master during reset"
      else
        echo -e "${YELLOW}    ⚠️  Could not delete node '${_WN}' — master may be unreachable${NC}"
        echo -e "${YELLOW}    → Run on master before --init: ${WHITE}kubectl delete node ${_WN}${NC}"
        log "WARNING: could not delete stale worker node ${_WN} — master unreachable?"
      fi
    else
      echo -e "${YELLOW}    ⚠️  No kubeconfig found — cannot contact master automatically.${NC}"
      echo -e "${YELLOW}    → Run this on the MASTER before running --init on this worker:${NC}"
      echo -e "${WHITE}       kubectl delete node ${_WN}${NC}"
      log "WARNING: no kubeconfig on worker — operator must manually delete node ${_WN}"
    fi
  fi

  # ── Common (master + worker): remove cluster dirs AFTER stale-node cleanup ─
  # /etc/kubernetes: certs, manifests, kubelet.conf, bootstrap-kubelet.conf,
  #                  admin.conf (master), k8s-version.txt, cni-*.txt
  rm -rf /etc/kubernetes

  # kubelet working dir: pod logs, volumes, device plugins, checkpoint state
  rm -rf /var/lib/kubelet

  rm -rf /var/run/kubernetes
  umount -l /run/calico/cgroup 2>/dev/null || true

  # Unmount active pod sandbox mounts so rm -rf /var/lib/kubelet completes cleanly.
  # IMPORTANT: do NOT touch /var/lib/containers/storage or /var/lib/containerd —
  # those hold the image cache and must survive reset.
  for _mnt in $(mount 2>/dev/null \
      | awk '{print $3}' \
      | grep -E '^/run/containerd/io\.containerd\.runtime|^/run/crio/[a-f0-9]|^/var/lib/kubelet/pods' \
      | sort -r); do
    umount -l "$_mnt" 2>/dev/null || true
  done

  rm -f /etc/crictl.yaml
  rm -f /etc/default/kubelet /etc/sysconfig/kubelet
  rm -f "$K8S_VERSION_FILE" "$CNI_CONFIG_FILE" "$CNI_IFACE_FILE"
  rm -f /etc/fstab.backup-*
  rm -f /tmp/calico*.yaml /tmp/kube-flannel.yaml

  # ── Master-only ────────────────────────────────────────────────────────
  if [[ "$RNT" == "master" ]]; then
    rm -rf /var/lib/etcd
    rm -rf /root/.kube
    for _d in /home/*; do [[ -d "${_d}/.kube" ]] && rm -rf "${_d}/.kube"; done
    rm -f /root/kubeadm-config.yaml
    echo -e "${CYAN}    ✓ Master: etcd, /root/.kube, ~/username/.kube, kubeadm-config.yaml${NC}"
  fi

  echo -e "${GREEN}  ✓ Cluster state, certs and configs removed${NC}"

  # ════════════════════════════════════════════════════════════════════════
  # [4/6] CNI network state
  # Binaries in /opt/cni/bin are preserved — only runtime state is cleared.
  # Order: netns → interfaces → iptables → dirs
  # ════════════════════════════════════════════════════════════════════════
  _reset_progress
  echo -e "${YELLOW}  [4/6] Cleaning CNI network state...${NC}"

  # Release pod network namespaces FIRST so veth peer references are dropped
  _cleanup_namespaces

  # Remove virtual interfaces left by Calico / Flannel
  _cleanup_cni_interfaces

  # Flush KUBE-* and cali*/CALICO* iptables chains
  _cleanup_iptables_kube

  # CNI runtime state dirs (binaries in /opt/cni/bin are preserved)
  rm -rf /etc/cni/net.d \
         /var/lib/cni   \
         /var/lib/calico \
         /run/flannel   \
         /run/calico    \
         /run/nodeagent \
         /run/netns

  # /run/crio/ contains only sockets and ephemeral state — recreated on start
  rm -rf /run/crio 2>/dev/null || true

  echo -e "${GREEN}  ✓ CNI network state cleaned${NC}"

  # ════════════════════════════════════════════════════════════════════════
  # [5/6] Restore runtime config integrity
  # Runtime package stays; ensure config is healthy before restart.
  # ════════════════════════════════════════════════════════════════════════
  _reset_progress
  echo -e "${YELLOW}  [5/6] Restoring runtime config...${NC}"

  if [[ "$RRT" == "containerd" ]]; then
    local _CFG_GOOD=true
    # Check file exists, is non-empty, and has SystemdCgroup = true
    if [[ ! -s /etc/containerd/config.toml ]]; then
      _CFG_GOOD=false
    elif ! grep -q "SystemdCgroup = true" /etc/containerd/config.toml 2>/dev/null; then
      _CFG_GOOD=false
    fi
    if [[ "$_CFG_GOOD" == false ]]; then
      mkdir -p /etc/containerd
      containerd config default > /etc/containerd/config.toml 2>/dev/null
      sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
      echo -e "${CYAN}    ✓ containerd config.toml regenerated (SystemdCgroup=true)${NC}"
    else
      echo -e "${CYAN}    ✓ containerd config.toml intact and correct${NC}"
    fi
  elif [[ "$RRT" == "crio" ]]; then
    echo -e "${CYAN}    ✓ CRI-O config intact — no change${NC}"
  else
    echo -e "${CYAN}    ℹ️  No runtime detected — skipping config check${NC}"
  fi
  echo -e "${GREEN}  ✓ Runtime config verified${NC}"

  # ════════════════════════════════════════════════════════════════════════
  # [6/6] Restart runtime and re-enable kubelet unit
  # kubelet itself is NOT started here — it has nothing to connect to yet.
  # It will be started by kubeadm init/join during the next --init run.
  # ════════════════════════════════════════════════════════════════════════
  _reset_progress
  echo -e "${YELLOW}  [6/6] Restarting runtime and preparing kubelet unit...${NC}"

  # Write crictl.yaml + drop-in BEFORE restarting runtime so that
  # ExecStartPost runs with the drop-in in place and sets socket permissions.
  echo -e "${CYAN}    Writing crictl config and socket drop-in before runtime restart...${NC}"
  _restore_crictl_config "$RRT"
  echo -e "${GREEN}    ✓ /etc/crictl.yaml written, drop-in installed, systemd reloaded${NC}"

  if [[ -n "$RRT" ]]; then
    systemctl restart "$RRT" 2>/dev/null && \
      echo -e "${CYAN}    ✓ ${RRT} restarted (socket permissions applied via ExecStartPost)${NC}" || \
      echo -e "${YELLOW}    ⚠️  ${RRT} restart failed — check: journalctl -u ${RRT} -n 20${NC}"
    sleep 1
    local _SOCK=""
    [[ "$RRT" == "containerd" ]] && _SOCK="/run/containerd/containerd.sock"
    [[ "$RRT" == "crio"       ]] && _SOCK="/var/run/crio/crio.sock"
    if [[ -S "$_SOCK" ]]; then
      local _SOCK_GRP; _SOCK_GRP=$(stat -c '%G' "$_SOCK" 2>/dev/null)
      local _SOCK_MOD; _SOCK_MOD=$(stat -c '%a' "$_SOCK" 2>/dev/null)
      if [[ "$_SOCK_GRP" == "k8sadmins" && "$_SOCK_MOD" == "660" ]]; then
        echo -e "${GREEN}    ✓ Socket permissions confirmed: ${_SOCK} → group=k8sadmins mode=660${NC}"
      else
        chgrp k8sadmins "$_SOCK" && chmod 660 "$_SOCK" 2>/dev/null || true
        echo -e "${CYAN}    ✓ Socket permissions applied directly (group=k8sadmins mode=660)${NC}"
      fi
    fi
  else
    systemctl daemon-reload
    echo -e "${CYAN}    ℹ️  No runtime service detected — skipping restart${NC}"
  fi

  if systemctl list-unit-files kubelet.service &>/dev/null 2>&1; then
    systemctl enable kubelet 2>/dev/null || true
    echo -e "${CYAN}    ✓ kubelet unit enabled (will start on next --init)${NC}"
  else
    echo -e "${CYAN}    ℹ️  kubelet.service unit not found — will be installed by --init${NC}"
  fi
  echo -e "${GREEN}  ✓ Runtime ready, kubelet unit enabled${NC}"

  # ════════════════════════════════════════════════════════════════════════
  # RESET COMPLETE BANNER
  # ════════════════════════════════════════════════════════════════════════
  local _RESET_ET=$(( $(date +%s) - START_TIME ))
  _reset_progress_complete
  print_header "RESET COMPLETE  (${RNT^^})"

  echo -e "${GREEN}  ✔ Cleared (cluster state):${NC}"
  echo -e "     /etc/kubernetes   /var/lib/kubelet   /var/run/kubernetes"
  if [[ "$RNT" == "master" ]]; then
    echo -e "     /var/lib/etcd   /root/.kube   ~/username/.kube   kubeadm-config.yaml"
  fi
  echo -e "     kubelet extra-args   crictl.yaml (deleted then restored)   CNI net.d   CNI IPAM state"
  echo -e "     /var/lib/calico (Calico node identity — prevents stale-node conflicts)"
  echo -e "     CNI virtual interfaces (cali*   vxlan.calico   flannel.1   cni0)"
  echo -e "     iptables KUBE-* and CALICO* chains"
  echo -e "     temp manifests (/tmp/calico*.yaml   /tmp/kube-flannel.yaml)"
  echo ""
  echo -e "${GREEN}  ✔ Preserved (packages + config):${NC}"
  echo -e "     kubelet   kubeadm   kubectl   ${RRT:-runtime}   cri-tools   /opt/cni/bin"
  echo -e "     K8s repos   runtime repos   GPG keys"
  echo -e "     /etc/containerd/config.toml   /etc/crio/   (runtime config)"
  echo -e "     /var/lib/containerd   (containerd image + content store)"
  echo -e "     /var/lib/containers/storage   (CRI-O image layers)"
  echo -e "     /etc/modules-load.d/k8s.conf   /etc/sysctl.d/k8s.conf"
  echo -e "     Firewall rules (ports still open for re-init)"
  echo -e "     k8sadmins group (runtime socket permissions)"
  if [[ "$PKG_MANAGER" == "dnf" ]]; then
    echo -e "     chrony   container-selinux   dnf-plugin-versionlock   (Rocky/RHEL extras)"
  fi
  echo ""

  # ── Show installed K8s component versions ────────────────────────────────
  local _KA_VER; _KA_VER=$(kubeadm version -o short 2>/dev/null | sed 's/^v//')
  local _KL_VER;  _KL_VER=$(kubelet --version 2>/dev/null | awk '{print $2}' | sed 's/^v//')
  local _KT_VER;  _KT_VER=$(kubectl version --client -o json 2>/dev/null \
                             | grep '"gitVersion"' | head -1 | awk -F'"' '{print $4}' | sed 's/^v//')
  local _RT_VER=""
  [[ -n "$RRT" ]] && _RT_VER=$($RRT --version 2>/dev/null | head -1 || true)

  if [[ -n "$_KA_VER" || -n "$_KL_VER" ]]; then
    echo -e "${CYAN}  Installed K8s components (ready for --init):${NC}"
    [[ -n "$_KA_VER" ]] && echo -e "   ${GREEN}✓${NC} kubeadm   : ${WHITE}v${_KA_VER}${NC}"
    [[ -n "$_KL_VER" ]] && echo -e "   ${GREEN}✓${NC} kubelet   : ${WHITE}v${_KL_VER}${NC}"
    [[ -n "$_KT_VER" ]] && echo -e "   ${GREEN}✓${NC} kubectl   : ${WHITE}v${_KT_VER}${NC}"
    [[ -n "$_RT_VER" ]] && echo -e "   ${GREEN}✓${NC} ${RRT}   : ${WHITE}${_RT_VER}${NC}"
    echo ""
    echo -e "${DIM}  Run: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --init${NC}${DIM} to bootstrap again.${NC}"
    echo -e "${DIM}  Run: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --upgrade${NC}${DIM} to change version first.${NC}"
  else
    echo -e "${YELLOW}  ⚠️  kubeadm/kubelet not detected — packages may need re-install (run --init).${NC}"
  fi
  echo ""
  echo -e "${CYAN}⏱️  Total time : ${WHITE}$(( _RESET_ET/60 ))m $(( _RESET_ET%60 ))s${NC}"
  echo -e "${CYAN}📄 Log file   : ${WHITE}${LOG_FILE}${NC}"
  echo ""

  # ── crictl session notice ─────────────────────────────────────────────────
  local _INVOKE_USER="${SUDO_USER:-${LOGNAME:-${USER:-}}}"
  local _IN_GRP=false
  [[ -n "$_INVOKE_USER" ]] && id -nG "$_INVOKE_USER" 2>/dev/null | grep -qw "k8sadmins" && _IN_GRP=true

  if [[ "$_IN_GRP" == "true" ]]; then
    echo -e "${CYAN}╔══════════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${CYAN}║  crictl — use without sudo                                       ║${NC}"
    echo -e "${CYAN}╚══════════════════════════════════════════════════════════════════╝${NC}"
    echo -e "${YELLOW}  Your current shell session needs a group refresh.${NC}"
    echo -e "${YELLOW}  Choose one of:${NC}"
    echo -e "   ${GREEN}A)${NC} Fastest  — run in this terminal: ${WHITE}newgrp k8sadmins${NC}"
    echo -e "   ${GREEN}B)${NC} Clean    — log out and log back in"
    echo -e "   ${GREEN}C)${NC} Use sudo — ${WHITE}sudo crictl ps${NC}  (works immediately)"
    echo ""
    echo -e "  After refresh, ${WHITE}crictl ps${NC} will work without sudo."
  fi
  echo ""
  print_credits
}

# ════════════════════════════════════════════════════════════════════════════
# --destroy
# ════════════════════════════════════════════════════════════════════════════
run_destroy() {
  # Destroy has its own step counter — isolated from --init's CURRENT_STEP
  local DESTROY_STEP=0
  local DESTROY_TOTAL=8
  _destroy_progress() {
    DESTROY_STEP=$(( DESTROY_STEP + 1 ))
    local PCT=$(( DESTROY_STEP * 100 / DESTROY_TOTAL ))
    local BAR_WIDTH=50
    local FILLED=$(( PCT * BAR_WIDTH / 100 ))
    local EMPTY=$(( BAR_WIDTH - FILLED ))
    [[ $EMPTY -lt 0 ]] && EMPTY=0
    local BAR; BAR=$(printf "%${FILLED}s" | tr ' ' '█')
    local SPC; SPC=$(printf "%${EMPTY}s")
    printf "\n${RED}╔══════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${RED}║${NC}  ${YELLOW}Destroy: [%3d%%]${NC} ${RED}%s${DIM}%s${NC}  ${RED}║${NC}\n" "$PCT" "$BAR" "$SPC"
    printf "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}\n"
  }
  _destroy_progress_complete() {
    local BAR; BAR=$(printf "%50s" | tr ' ' '█')
    printf "\n${RED}╔══════════════════════════════════════════════════════════════════╗${NC}\n"
    printf "${RED}║${NC}  ${YELLOW}Destroy: [100%%]${NC} ${RED}%s${NC}  ${RED}║${NC}\n" "$BAR"
    printf "${RED}╚══════════════════════════════════════════════════════════════════╝${NC}\n"
  }

  print_header "FULL UNINSTALL  --destroy"

  # ── Detect OS early (needed for runtime detection below) ─────────────────
  source /etc/os-release; OS="$ID"
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    PKG_MANAGER="apt"; PKG_UPDATE="apt-get update -y"; PKG_INSTALL="apt-get install -y"
  else
    PKG_MANAGER="dnf"; PKG_UPDATE="dnf makecache"; PKG_INSTALL="dnf install -y"
  fi

  # ── Detect node type BEFORE showing the confirmation banner ──────────────
  # Priority: --node-type flag > hostname pattern > admin.conf > k8s-version.txt
  # NOTE: kubectl binary presence alone is NOT used to detect master — a worker
  # may have kubectl installed manually.  We use admin.conf (master-only file)
  # and k8s-version.txt (written by --init on master) as reliable indicators.
  local HN_D; HN_D=$(hostname | tr '[:upper:]' '[:lower:]')
  local NT_D="worker"
  if [[ -n "${ARG_NODE_TYPE:-}" ]]; then
    NT_D="$ARG_NODE_TYPE"
    echo -e "${CYAN}  Node type : ${WHITE}${NT_D^^}${GREEN} (--node-type override)${NC}"
  elif [[ "$HN_D" =~ master|control ]]; then
    NT_D="master"
    echo -e "${CYAN}  Node type : ${WHITE}MASTER${NC} ${DIM}(detected from hostname)${NC}"
  elif [[ -f /etc/kubernetes/admin.conf ]]; then
    NT_D="master"
    echo -e "${CYAN}  Node type : ${WHITE}MASTER${NC} ${DIM}(detected: admin.conf present)${NC}"
  elif [[ -f /etc/kubernetes/k8s-version.txt ]]; then
    NT_D="master"
    echo -e "${CYAN}  Node type : ${WHITE}MASTER${NC} ${DIM}(detected: k8s-version.txt present)${NC}"
  else
    NT_D="worker"
    echo -e "${CYAN}  Node type : ${WHITE}WORKER${NC} ${DIM}(no master indicators found)${NC}"
  fi
  echo ""

  # ── Detect installed runtime for the confirmation banner ─────────────────
  local RRT=""
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    dpkg-query -W -f='${Status}' containerd   2>/dev/null | grep -qE "ok installed" && RRT="containerd"
    dpkg-query -W -f='${Status}' containerd.io 2>/dev/null | grep -qE "ok installed" && RRT="containerd"
    [[ -z "$RRT" ]] && \
      dpkg-query -W -f='${Status}' cri-o 2>/dev/null | grep -qE "ok installed" && RRT="crio"
  else
    rpm -q containerd    &>/dev/null && RRT="containerd"
    rpm -q containerd.io &>/dev/null && RRT="containerd"
    [[ -z "$RRT" ]] && rpm -q cri-o &>/dev/null && RRT="crio"
  fi
  [[ -z "$RRT" ]] && command -v containerd &>/dev/null && RRT="containerd"
  [[ -z "$RRT" ]] && command -v crio       &>/dev/null && RRT="crio"
  [[ -z "$RRT" && -S /run/containerd/containerd.sock ]] && RRT="containerd"
  [[ -z "$RRT" && -S /var/run/crio/crio.sock          ]] && RRT="crio"
  [[ -z "$RRT" ]] && systemctl list-unit-files 2>/dev/null | grep -q "^containerd" && RRT="containerd"
  [[ -z "$RRT" ]] && systemctl list-unit-files 2>/dev/null | grep -q "^crio"       && RRT="crio"

  # ── Show what WILL be removed (node-type aware) ───────────────────────────
  echo -e "${RED}  ⚠️  This will PERMANENTLY remove:${NC}"
  if [[ "$NT_D" == "master" ]]; then
    echo -e "${RED}      • kubelet  kubeadm  kubectl  cri-tools${NC}"
  else
    echo -e "${RED}      • kubelet  kubeadm  cri-tools  (kubectl not installed on workers)${NC}"
  fi
  echo -e "${RED}      • ${RRT:-containerd / crio} (container runtime)${NC}"
  echo -e "${RED}      • K8s, CRI-O and Docker repos / GPG keys${NC}"
  echo -e "${RED}      • All data dirs, certs, configs, CNI state${NC}"
  echo -e "${YELLOW}      ℹ️  curl  wget  ca-certificates  gnupg — preserved (system tools)${NC}"
  echo ""
  printf "${RED}  Type 'yes' to confirm full destroy: ${NC}"
  local CONF; read -r CONF
  [[ "$CONF" != "yes" ]] && { echo -e "${YELLOW}  Cancelled.${NC}"; exit 0; }
  echo ""

  # Function-scope tracking — populated by steps [4] and [5], read by the banner
  local _REMOVED_K8S_PKGS=()
  local _REMOVED_RT_PKGS=()

  # Protect SSH before touching iptables
  local SSH_PORT
  SSH_PORT=$(ss -tnlp 2>/dev/null | grep sshd | awk '{print $4}' | awk -F: '{print $NF}' | head -1)
  [[ -z "$SSH_PORT" ]] && SSH_PORT=22
  iptables -C INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT -p tcp --dport "$SSH_PORT" -j ACCEPT

  # ── [1/8] Stop & disable all services ───────────────────────────────────
  _destroy_progress
  echo -e "${YELLOW}  [1/8] Stopping and disabling services...${NC}"
  systemctl stop    kubelet    2>/dev/null || true
  systemctl disable kubelet    2>/dev/null || true
  systemctl stop    containerd 2>/dev/null || true
  systemctl disable containerd 2>/dev/null || true
  systemctl stop    crio       2>/dev/null || true
  systemctl disable crio       2>/dev/null || true
  echo -e "${GREEN}  ✓ Services stopped and disabled${NC}"

  # ── Release pod netns and CNI interfaces NOW ─────────────────────────────
  # Must happen BEFORE runtime is removed — the anonymous bind-mounts under
  # /var/run/netns/ that hold cali*@ifN veth peer references must be released
  # while the filesystem is still intact.
  echo -e "${CYAN}  Releasing pod network namespaces and CNI interfaces...${NC}"
  _cleanup_namespaces
  _cleanup_cni_interfaces
  _cleanup_iptables_kube
  echo -e "${GREEN}  ✓ CNI interfaces and namespaces cleared${NC}"

  # ── [2/8] kubeadm reset ─────────────────────────────────────────────────
  _destroy_progress
  echo -e "${YELLOW}  [2/8] Running kubeadm reset...${NC}"
  command -v kubeadm &>/dev/null && \
    kubeadm reset -f --ignore-preflight-errors=all >> "$LOG_FILE" 2>&1 || true
  echo -e "${GREEN}  ✓ kubeadm reset complete${NC}"

  # ── [3/8] Drain crictl containers/pods before removing runtime ──────────
  _destroy_progress
  echo -e "${YELLOW}  [3/8] Stopping crictl pods and containers...${NC}"
  if command -v crictl &>/dev/null; then
    local SOCK=""
    [[ "$RRT" == "containerd" ]] && SOCK="unix:///run/containerd/containerd.sock"
    [[ "$RRT" == "crio"       ]] && SOCK="unix:///var/run/crio/crio.sock"
    [[ -n "$SOCK" ]] && export CONTAINER_RUNTIME_ENDPOINT="$SOCK"
    for pod in $(crictl pods -q 2>/dev/null); do
      crictl stopp "$pod" 2>/dev/null || true; crictl rmp "$pod" 2>/dev/null || true
    done
    for ctr in $(crictl ps -aq 2>/dev/null); do
      crictl stop "$ctr" 2>/dev/null || true; crictl rm -f "$ctr" 2>/dev/null || true
    done
  fi
  echo -e "${GREEN}  ✓ Containers and pods stopped${NC}"

  # ── [4/8] Remove Kubernetes packages + crictl ───────────────────────────
  _destroy_progress
  local K8S_PKGS=("kubelet" "kubeadm" "kubernetes-cni" "cri-tools")
  [[ "$NT_D" == "master" ]] && K8S_PKGS+=("kubectl")
  if [[ "$PKG_MANAGER" == "dnf" ]]; then
    K8S_PKGS+=("dnf-plugin-versionlock" "python3-dnf-plugin-versionlock")
  fi
  echo -e "${YELLOW}  [4/8] Removing K8s packages (${NT_D^^}): ${K8S_PKGS[*]}...${NC}"

  if [[ "$PKG_MANAGER" == "apt" ]]; then
    echo -e "${CYAN}    Releasing any version holds...${NC}"
    for _hp in kubelet kubeadm kubectl cri-tools kubernetes-cni; do
      apt-mark unhold "$_hp" >> "$LOG_FILE" 2>&1 || true
    done
    local _K8S_INSTALLED_APT=()
    for _p in "${K8S_PKGS[@]}"; do
      dpkg-query -W -f='${Status}' "$_p" 2>/dev/null \
        | grep -qE "ok installed" && _K8S_INSTALLED_APT+=("$_p")
    done
    if [[ ${#_K8S_INSTALLED_APT[@]} -gt 0 ]]; then
      echo -e "${CYAN}    Purging: ${_K8S_INSTALLED_APT[*]}${NC}"
      DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${_K8S_INSTALLED_APT[@]}" >> "$LOG_FILE" 2>&1 || true
      echo -e "${GREEN}    ✓ Removed: ${_K8S_INSTALLED_APT[*]}${NC}"
      _REMOVED_K8S_PKGS=("${_K8S_INSTALLED_APT[@]}")
    else
      echo -e "${CYAN}    ℹ️  No K8s packages installed — skipping${NC}"
    fi
  else
    mkdir -p /etc/dnf/plugins && touch /etc/dnf/plugins/versionlock.list 2>/dev/null || true
    for _vlpkg in kubelet kubeadm kubectl cri-tools kubernetes-cni; do
      dnf versionlock delete "$_vlpkg" --disablerepo="*" >> "$LOG_FILE" 2>&1 || true
    done
    local _K8S_INSTALLED=()
    for _p in "${K8S_PKGS[@]}"; do
      rpm -q "$_p" &>/dev/null && _K8S_INSTALLED+=("$_p")
    done
    if [[ ${#_K8S_INSTALLED[@]} -gt 0 ]]; then
      echo -e "${CYAN}    Removing: ${_K8S_INSTALLED[*]}${NC}"
      dnf remove -y -q --disablerepo="*" "${_K8S_INSTALLED[@]}" >> "$LOG_FILE" 2>&1 || true
      echo -e "${GREEN}    ✓ Removed: ${_K8S_INSTALLED[*]}${NC}"
      _REMOVED_K8S_PKGS=("${_K8S_INSTALLED[@]}")
    else
      echo -e "${CYAN}    ℹ️  No K8s packages installed — skipping${NC}"
    fi
  fi
  rm -f /usr/local/bin/crictl /usr/bin/crictl
  rm -f /usr/local/bin/calicoctl
  echo -e "${GREEN}  ✓ K8s packages removed${NC}"

  # ── [5/8] Remove container runtime ──────────────────────────────────────
  _destroy_progress
  echo -e "${YELLOW}  [5/8] Removing container runtime...${NC}"
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    local _RT_INSTALLED_APT=()
    for _pkg in containerd containerd.io cri-o runc docker-ce docker-ce-cli \
                docker-buildx-plugin docker-compose-plugin; do
      dpkg-query -W -f='${Status}' "$_pkg" 2>/dev/null \
        | grep -qE "ok installed" && _RT_INSTALLED_APT+=("$_pkg")
    done
    if [[ ${#_RT_INSTALLED_APT[@]} -gt 0 ]]; then
      echo -e "${CYAN}    Purging: ${_RT_INSTALLED_APT[*]}${NC}"
      DEBIAN_FRONTEND=noninteractive apt-get purge -y -qq "${_RT_INSTALLED_APT[@]}" >> "$LOG_FILE" 2>&1 || true
      echo -e "${GREEN}    ✓ Removed: ${_RT_INSTALLED_APT[*]}${NC}"
      _REMOVED_RT_PKGS=("${_RT_INSTALLED_APT[@]}")
    else
      echo -e "${CYAN}    ℹ️  No container runtime packages installed — skipping${NC}"
    fi
  else
    local _RT_INSTALLED=()
    for _p in containerd containerd.io cri-o container-selinux epel-release docker-ce docker-ce-cli; do
      rpm -q "$_p" &>/dev/null && _RT_INSTALLED+=("$_p")
    done
    if [[ ${#_RT_INSTALLED[@]} -gt 0 ]]; then
      echo -e "${CYAN}    Removing: ${_RT_INSTALLED[*]}${NC}"
      dnf remove -y -q --disablerepo="*" "${_RT_INSTALLED[@]}" >> "$LOG_FILE" 2>&1 || true
      echo -e "${GREEN}    ✓ Removed: ${_RT_INSTALLED[*]}${NC}"
      _REMOVED_RT_PKGS=("${_RT_INSTALLED[@]}")
    else
      echo -e "${CYAN}    ℹ️  No container runtime packages installed — skipping${NC}"
    fi
  fi
  echo -e "${GREEN}  ✓ Container runtime removed${NC}"

  # ── [6/8] Remove prerequisite packages installed by --init ───────────────
  _destroy_progress
  echo -e "${YELLOW}  [6/8] Removing prerequisite packages...${NC}"
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    echo -e "${CYAN}    ℹ️  Skipping curl/wget/ca-certificates/gnupg — system packages${NC}"
  else
    echo -e "${CYAN}    ℹ️  Skipping wget/gnupg2 — core system dependencies${NC}"
    if rpm -q chrony &>/dev/null; then
      echo -e "${CYAN}    Removing chrony (installed by --init for time sync)...${NC}"
      dnf remove -y -q --disablerepo="*" chrony >> "$LOG_FILE" 2>&1 || true
      echo -e "${GREEN}    ✓ chrony removed${NC}"
    fi
    rm -rf /var/cache/dnf/epel* 2>/dev/null || true
    find /var/cache/dnf -maxdepth 1 -type d -name 'epel*' -exec rm -rf {} + 2>/dev/null || true
  fi
  echo -e "${GREEN}  ✓ Prerequisite packages handled${NC}"

  # ── [7/8] Remove firewall rules opened for K8s ──────────────────────────
  _destroy_progress
  echo -e "${YELLOW}  [7/8] Removing K8s firewall rules (${NT_D^^})...${NC}"
  if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld; then
    local _FW_PORTS=()
    if [[ "$NT_D" == "master" ]]; then
      _FW_PORTS=(6443/tcp 2379-2380/tcp 10250/tcp 10259/tcp 10257/tcp
                 4789/udp 8472/udp 30000-32767/tcp)
    else
      _FW_PORTS=(10250/tcp 10256/tcp 4789/udp 8472/udp)
    fi
    for p in "${_FW_PORTS[@]}"; do
      firewall-cmd --permanent --remove-port="$p" 2>/dev/null || true
    done
    firewall-cmd --reload 2>/dev/null || true
    echo -e "${GREEN}    ✓ firewalld K8s ports removed (${NT_D^^})${NC}"
  elif command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    local _UFW_PORTS=()
    if [[ "$NT_D" == "master" ]]; then
      _UFW_PORTS=(6443/tcp 2379:2380/tcp 10250/tcp 10259/tcp 10257/tcp
                  4789/udp 8472/udp 30000:32767/tcp)
    else
      _UFW_PORTS=(10250/tcp 10256/tcp 4789/udp 8472/udp)
    fi
    for p in "${_UFW_PORTS[@]}"; do
      ufw delete allow "$p" 2>/dev/null || true
    done
    echo -e "${GREEN}    ✓ ufw K8s rules removed (${NT_D^^})${NC}"
  else
    echo -e "${CYAN}    ℹ️  No active firewall detected — skipping${NC}"
  fi
  echo -e "${GREEN}  ✓ Firewall rules handled${NC}"

  # ── [8/8] Remove repos, GPG keys, data dirs, configs, CNI, iptables ─────
  _destroy_progress
  echo -e "${YELLOW}  [8/8] Removing repos, data directories and configs...${NC}"

  if [[ "$PKG_MANAGER" == "apt" ]]; then
    rm -f /etc/apt/sources.list.d/kubernetes.list
    rm -f /etc/apt/sources.list.d/cri-o.list
    rm -f /etc/apt/keyrings/kubernetes-apt-keyring.gpg
    rm -f /etc/apt/keyrings/cri-o-apt-keyring.gpg
    rm -f /etc/apt/sources.list.d/docker.list
    rm -f /etc/apt/sources.list.d/docker-ce.list
    rm -f /etc/apt/keyrings/docker.gpg
    rm -f /etc/apt/keyrings/docker-archive-keyring.gpg
    rm -f /etc/apt/trusted.gpg.d/docker*.gpg
    rm -f /etc/apt/sources.list.d/docker* 2>/dev/null || true
    rm -f /etc/apt/keyrings/docker* 2>/dev/null || true
    rm -f /var/lib/apt/lists/pkgs.k8s.io_* 2>/dev/null || true
    rm -f /var/lib/apt/lists/download.docker.com_* 2>/dev/null || true
    rm -f /var/lib/apt/lists/lock 2>/dev/null || true
    rm -f /var/cache/apt/archives/lock 2>/dev/null || true
    rm -f /var/lib/needrestart/restart-required.d/containerd* 2>/dev/null || true
    rm -f /var/lib/needrestart/restart-required.d/crio*       2>/dev/null || true
    if [[ -f /etc/needrestart/needrestart.conf ]]; then
      perl -i -pe 's{^\s*\$nrconf\{restart\}.*}{\$nrconf{restart} = q(l);}g' \
        /etc/needrestart/needrestart.conf 2>/dev/null || true
    fi
  else
    rm -f /etc/yum.repos.d/kubernetes.repo
    rm -f /etc/yum.repos.d/cri-o.repo
    rm -f /etc/yum.repos.d/docker-ce.repo
    for _repo_cache in kubernetes docker-ce-stable cri-o epel; do
      rm -rf /var/cache/dnf/${_repo_cache}* 2>/dev/null || true
    done
    find /var/cache/dnf -maxdepth 1 -type d \
      \( -name 'kubernetes*' -o -name 'docker*' -o -name 'cri-o*' -o -name 'epel*' \) \
      -exec rm -rf {} + 2>/dev/null || true
    mkdir -p /etc/dnf/plugins && touch /etc/dnf/plugins/versionlock.list 2>/dev/null || true
    for _pkg in kubelet kubeadm kubectl cri-tools kubernetes-cni; do
      dnf versionlock delete "$_pkg" --disablerepo="*" 2>/dev/null || true
    done
  fi

  echo -e "${CYAN}    Unmounting runtime mounts (shm/rootfs/cgroup)...${NC}"
  umount -l /run/calico/cgroup 2>/dev/null || true
  for _mnt in $(mount 2>/dev/null \
      | awk '{print $3}' \
      | grep -E '^/run/containerd|^/run/crio|^/run/calico/cgroup|^/var/lib/kubelet/pods|^/var/lib/containers' \
      | sort -r); do
    umount -l "$_mnt" 2>/dev/null || true
  done

  rm -rf \
    /etc/kubernetes    /var/lib/kubelet    /var/run/kubernetes \
    /etc/containerd    /var/lib/containerd /run/containerd     \
    /etc/crio          /var/lib/crio       /var/lib/containers /run/crio \
    /var/cache/containers \
    /etc/cni           /opt/cni            /var/lib/cni        /run/flannel \
    /run/calico        /run/nodeagent      /run/netns

  # Rocky/RHEL: remove GPG keys imported to RPM keyring by --init
  if [[ "$PKG_MANAGER" == "dnf" ]]; then
    local _DOCKER_GPGKEY
    _DOCKER_GPGKEY=$(rpm -q gpg-pubkey --qf "%{VERSION}-%{RELEASE}\n" 2>/dev/null \
      | while read -r ver; do
          fingerprint=$(rpm -qi "gpg-pubkey-${ver}" 2>/dev/null | grep -i "docker\|Docker")
          [[ -n "$fingerprint" ]] && echo "$ver"
        done | head -1)
    [[ -n "$_DOCKER_GPGKEY" ]] && \
      rpm -e "gpg-pubkey-${_DOCKER_GPGKEY}" 2>/dev/null || true
    local _CRIO_GPGKEY
    _CRIO_GPGKEY=$(rpm -q gpg-pubkey --qf "%{VERSION}-%{RELEASE}\n" 2>/dev/null \
      | while read -r ver; do
          fingerprint=$(rpm -qi "gpg-pubkey-${ver}" 2>/dev/null | grep -i "cri-o\|kubernetes\|pkgs.k8s.io")
          [[ -n "$fingerprint" ]] && echo "$ver"
        done | head -1)
    [[ -n "$_CRIO_GPGKEY" ]] && \
      rpm -e "gpg-pubkey-${_CRIO_GPGKEY}" 2>/dev/null || true
    rm -f /etc/pki/rpm-gpg/RPM-GPG-KEY-Docker
    rm -f /etc/pki/rpm-gpg/RPM-GPG-KEY-CRI-O
    rm -f /etc/pki/rpm-gpg/RPM-GPG-KEY-kubernetes* 2>/dev/null || true
  fi

  if [[ "$NT_D" == "master" ]]; then
    rm -rf /var/lib/etcd /root/.kube
    for d in /home/*; do [[ -d "${d}/.kube" ]] && rm -rf "${d}/.kube"; done
    rm -f /root/kubeadm-config.yaml
  fi

  rm -f /tmp/calico*.yaml /tmp/kube-flannel.yaml /etc/crictl.yaml
  rm -f /etc/fstab.backup-*
  rm -f /etc/default/kubelet /etc/sysconfig/kubelet
  rm -f /etc/modules-load.d/k8s.conf /etc/sysctl.d/k8s.conf

  groupdel k8sadmins 2>/dev/null || true
  rm -f /etc/systemd/system/containerd.service.d/k8sadmins-socket.conf
  rm -f /etc/systemd/system/crio.service.d/k8sadmins-socket.conf
  rmdir /etc/systemd/system/containerd.service.d 2>/dev/null || true
  rmdir /etc/systemd/system/crio.service.d       2>/dev/null || true

  systemctl daemon-reload
  echo -e "${GREEN}  ✓ Repos, data directories and configs removed${NC}"

  # ════════════════════════════════════════════════════════════════════════
  # DESTROY COMPLETE BANNER
  # ════════════════════════════════════════════════════════════════════════
  local _DESTROY_ET=$(( $(date +%s) - START_TIME ))
  _destroy_progress_complete
  print_header "DESTROY COMPLETE  (${NT_D^^})"

  if [[ ${#_REMOVED_K8S_PKGS[@]} -gt 0 ]]; then
    echo -e "${GREEN}  ✔ K8s packages removed      : ${_REMOVED_K8S_PKGS[*]}${NC}"
  else
    echo -e "${YELLOW}  ℹ️  No K8s packages were found installed${NC}"
  fi
  if [[ ${#_REMOVED_RT_PKGS[@]} -gt 0 ]]; then
    echo -e "${GREEN}  ✔ Runtime removed           : ${_REMOVED_RT_PKGS[*]}${NC}"
  else
    echo -e "${YELLOW}  ℹ️  No container runtime packages were found installed${NC}"
  fi
  if [[ "$NT_D" == "master" ]]; then
    echo -e "${GREEN}  ✔ etcd data                 : removed${NC}"
    echo -e "${GREEN}  ✔ kubeconfig (.kube)         : removed${NC}"
    echo -e "${GREEN}  ✔ Firewall ports removed     : 6443  2379-2380  10250  10259  10257  4789  8472  30000-32767${NC}"
  else
    echo -e "${GREEN}  ✔ Firewall ports removed     : 10250  10256  4789  8472${NC}"
  fi
  echo -e "${GREEN}  ✔ K8s repos / GPG keys       : removed${NC}"
  echo -e "${GREEN}  ✔ Data dirs / configs         : removed${NC}"
  echo -e "${GREEN}  ✔ CNI interfaces / iptables   : cleaned${NC}"
  echo -e "${GREEN}  ✔ Kernel module / sysctl cfg  : removed${NC}"
  if [[ "$PKG_MANAGER" == "dnf" ]]; then
    echo -e "${GREEN}  ✔ Rocky/RHEL extras          : chrony  container-selinux  epel-release  versionlock plugin${NC}"
    echo -e "${GREEN}  ✔ RPM GPG keys               : Docker + CRI-O keys removed from keyring${NC}"
  fi
  echo -e "${GREEN}  ✔ Node is fully clean — ready for a fresh install${NC}"
  echo ""
  echo -e "${CYAN}⏱️  Total time : ${WHITE}$(( _DESTROY_ET/60 ))m $(( _DESTROY_ET%60 ))s${NC}"
  echo -e "${CYAN}📄 Log file   : ${WHITE}${LOG_FILE}${NC}"
  echo ""
  echo -e "${CYAN}  To re-install: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --init${NC}"
  echo ""
  print_credits
}

# ════════════════════════════════════════════════════════════════════════════
# --upgrade
# ════════════════════════════════════════════════════════════════════════════
run_upgrade() {
  print_header "KUBERNETES VERSION UPGRADE"

  source /etc/os-release; OS="$ID"
  if [[ "$OS" =~ (ubuntu|debian) ]]; then
    PKG_MANAGER="apt"; PKG_UPDATE="apt-get update -y"; PKG_INSTALL="apt-get install -y"
  elif [[ "$OS" =~ (rhel|rocky|centos|almalinux) ]]; then
    PKG_MANAGER="dnf"; PKG_UPDATE="dnf makecache"; PKG_INSTALL="dnf install -y"
  else
    echo -e "${RED}  ❌ Unsupported OS: $OS${NC}"; exit 1
  fi

  local HN; HN=$(hostname | tr '[:upper:]' '[:lower:]')
  local UGTYPE="worker"
  if [[ -n "$ARG_NODE_TYPE" ]]; then
    UGTYPE="$ARG_NODE_TYPE"
    echo -e "${CYAN}  Node type : ${WHITE}${UGTYPE^^}${GREEN} (--node-type override)${NC}"
  elif [[ "$HN" =~ master|control ]]; then
    UGTYPE="master"
  fi
  echo -e "${CYAN}  OS        : ${WHITE}${OS}${NC}"
  echo -e "${CYAN}  Node type : ${WHITE}${UGTYPE^^}${NC}"
  echo ""

  # ════════════════════════════════════════════════════════════════════════
  # PRE-FLIGHT: check what is actually installed before doing anything
  # ════════════════════════════════════════════════════════════════════════
  local CURRENT=""
  CURRENT=$(kubelet --version 2>/dev/null | awk '{print $2}' | sed 's/^v//')

  local KA_OK=false KB_OK=false
  command -v kubeadm &>/dev/null && KA_OK=true
  command -v kubelet &>/dev/null && KB_OK=true

  # ── Case 1: Nothing installed at all ─────────────────────────────────────
  if [[ "$KA_OK" == false && "$KB_OK" == false ]]; then
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ❌  NO KUBERNETES INSTALLATION FOUND                         ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${YELLOW}kubeadm and kubelet are not installed on this node.${NC}"
    echo -e "  ${YELLOW}--upgrade requires an existing installation to upgrade from.${NC}"
    echo ""
    echo -e "  ${CYAN}To perform a fresh install:${NC}"
    echo -e "  ${WHITE}  sudo ./k8s-cluster-bootstrap.sh --init${NC}"
    echo ""
    exit 1
  fi

  # ── Case 2: K8s binaries present but NO container runtime ────────────────
  # --upgrade only upgrades kubeadm/kubelet/kubectl — it does not install or
  # repair a missing runtime.  --init is idempotent and will detect the existing
  # K8s version, skip already-done steps, and install the missing runtime + CNI.
  local RRT=""
  systemctl list-unit-files 2>/dev/null | grep -q "^containerd" && \
    systemctl is-active --quiet containerd 2>/dev/null && RRT="containerd"
  systemctl list-unit-files 2>/dev/null | grep -q "^crio" && \
    systemctl is-active --quiet crio 2>/dev/null && RRT="crio"
  RUNTIME="$RRT"

  if [[ -n "$CURRENT" && -z "$RRT" ]]; then
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ❌  CONTAINER RUNTIME NOT RUNNING                            ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Installed K8s version : ${WHITE}v${CURRENT}${NC}"
    echo -e "  ${RED}Container runtime     : not detected / not running${NC}"
    echo ""
    echo -e "  ${YELLOW}--upgrade only upgrades kubeadm / kubelet / kubectl binaries.${NC}"
    echo -e "  ${YELLOW}A running container runtime is required for a healthy upgrade.${NC}"
    echo -e "  ${YELLOW}Upgrading without it will leave the node in a broken state.${NC}"
    echo ""
    echo -e "  ${CYAN}Use --init instead — it is fully idempotent:${NC}"
    echo -e "  ${WHITE}  sudo ./k8s-cluster-bootstrap.sh --init${NC}"
    echo ""
    echo -e "  ${DIM}--init detects your existing v${CURRENT} installation, skips${NC}"
    echo -e "  ${DIM}already-completed steps, and installs the missing runtime + CNI.${NC}"
    echo ""
    exit 1
  fi

  # ── Case 3: Normal upgrade path — K8s + runtime both present ─────────────
  if [[ -z "$CURRENT" ]]; then
    echo -e "${RED}  ❌ Cannot determine installed version — kubelet may be broken.${NC}"
    echo -e "${YELLOW}     Try: sudo ./k8s-cluster-bootstrap.sh --init${NC}"
    exit 1
  fi

  echo -e "${CYAN}  Installed version : ${YELLOW}v${CURRENT}${NC}"
  [[ -n "$RRT" ]] && echo -e "${CYAN}  Runtime           : ${WHITE}${RRT}${NC}"
  echo ""

  show_static_version_table

  local -a ALL_VERSIONS=(
    "1.33.0" "1.33.1" "1.33.2"
    "1.32.0" "1.32.1" "1.32.2" "1.32.3" "1.32.4" "1.32.5"
    "1.31.0" "1.31.1" "1.31.2" "1.31.3" "1.31.4" "1.31.5"
    "1.31.6" "1.31.7" "1.31.8" "1.31.9"
    "1.30.0" "1.30.1" "1.30.2" "1.30.3" "1.30.4" "1.30.5"
    "1.30.6" "1.30.7" "1.30.8" "1.30.9" "1.30.10" "1.30.11"
    "1.30.12" "1.30.13"
    "1.29.0" "1.29.1" "1.29.2" "1.29.3" "1.29.4" "1.29.5"
    "1.29.6" "1.29.7" "1.29.8" "1.29.9" "1.29.10" "1.29.11"
    "1.29.12" "1.29.13" "1.29.14" "1.29.15"
  )

  echo -e "${CYAN}  Versions available above v${CURRENT}:${NC}"
  echo ""
  local N=1
  declare -a VER_MAP
  for v in "${ALL_VERSIONS[@]}"; do
    local highest; highest=$(printf '%s\n%s\n' "$CURRENT" "$v" | sort -V | tail -1)
    if [[ "$highest" == "$v" && "$v" != "$CURRENT" ]]; then
      local CM VM
      CM=$(echo "$CURRENT" | cut -d'.' -f1-2)
      VM=$(echo "$v"       | cut -d'.' -f1-2)
      if [[ "$CM" == "$VM" ]]; then
        echo -e "  ${CYAN}${N}${NC}) ${GREEN}${v}${NC} ${DIM}(Patch — Recommended)${NC}"
      else
        echo -e "  ${CYAN}${N}${NC}) ${YELLOW}${v}${NC} ${DIM}(Minor — Advanced)${NC}"
      fi
      VER_MAP[$N]="$v"; N=$((N+1))
    fi
  done

  if [[ $N -eq 1 ]]; then
    echo -e "${YELLOW}  No upgrades in stable list above v${CURRENT}.${NC}"
    echo -e "${YELLOW}  Enter a version manually below if a newer one exists.${NC}"
    echo ""
  fi

  echo ""
  local SEL
  prompt_input "  Select number or enter version manually (e.g. 1.33.3): " SEL

  local TARGET=""
  if [[ "$SEL" =~ ^[0-9]+$ ]] && [[ -n "${VER_MAP[$SEL]:-}" ]]; then
    TARGET="${VER_MAP[$SEL]}"
  else
    TARGET="${SEL#v}"
  fi

  # ── Version format validation ────────────────────────────────────────────
  if [[ -z "$TARGET" || ! "$TARGET" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo -e "${RED}  ❌ Invalid version format — use x.y.z (e.g. 1.32.3)${NC}"; exit 1
  fi

  # ── Same version (idempotent / already installed) ────────────────────────
  if [[ "$TARGET" == "$CURRENT" ]]; then
    echo ""
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${YELLOW}║  ℹ️   ALREADY INSTALLED                                        ║${NC}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Requested : ${WHITE}v${TARGET}${NC}"
    echo -e "  ${CYAN}Installed : ${WHITE}v${CURRENT}${NC}  ${GREEN}(same version — nothing to do)${NC}"
    echo ""
    echo -e "  ${DIM}Select a version higher than v${CURRENT} to upgrade.${NC}"
    exit 0
  fi

  # ── Downgrade blocked ────────────────────────────────────────────────────
  local highest
  highest=$(printf '%s\n%s\n' "$CURRENT" "$TARGET" | sort -V | tail -1)
  if [[ "$highest" != "$TARGET" ]]; then
    echo ""
    echo -e "${RED}╔══════════════════════════════════════════════════════════════╗${NC}"
    echo -e "${RED}║  ❌  DOWNGRADE BLOCKED                                        ║${NC}"
    echo -e "${RED}╚══════════════════════════════════════════════════════════════╝${NC}"
    echo ""
    echo -e "  ${CYAN}Installed : ${YELLOW}v${CURRENT}${NC}"
    echo -e "  ${CYAN}Requested : ${RED}v${TARGET}${NC}  ${RED}(lower — downgrade not supported)${NC}"
    echo ""
    echo -e "  ${YELLOW}Kubernetes does not support downgrading.${NC}"
    echo -e "  ${DIM}Select a version higher than v${CURRENT}.${NC}"
    exit 1
  fi

  # ── Confirm and proceed ──────────────────────────────────────────────────
  echo ""
  echo -e "  ${CYAN}Installed : ${YELLOW}v${CURRENT}${NC}"
  echo -e "  ${CYAN}Target    : ${GREEN}v${TARGET}${NC}"
  echo ""
  local CONF
  printf "${YELLOW}  Proceed with upgrade? (y/n): ${NC}"; read -r -n 1 CONF; echo
  [[ ! "$CONF" =~ ^[Yy]$ ]] && { echo -e "${YELLOW}  Cancelled${NC}"; exit 0; }

  print_header "EXECUTING UPGRADE"

  local TM; TM=$(echo "$TARGET" | cut -d'.' -f1-2)
  echo -e "${CYAN}  Configuring repo for v${TM}...${NC}"
  configure_k8s_repo_for_version "$TM"

  local UPKGS=("kubelet" "kubeadm")
  [[ "$UGTYPE" == "master" ]] && UPKGS+=("kubectl")

  if [[ "$UGTYPE" == "master" ]]; then
    echo -e "${YELLOW}  Backing up etcd...${NC}"
    local BKP="/var/lib/etcd.backup-$(date +%Y%m%d-%H%M%S)"
    cp -r /var/lib/etcd "$BKP" 2>/dev/null && echo -e "${GREEN}  ✓ Backup: $BKP${NC}"
    export KUBECONFIG=/etc/kubernetes/admin.conf
    kubectl cordon  "$(hostname)" 2>/dev/null || true
    kubectl drain   "$(hostname)" --ignore-daemonsets --delete-emptydir-data 2>/dev/null || true
  fi

  echo -e "${YELLOW}  Removing version pins...${NC}"
  unpin_k8s_packages "${UPKGS[@]}"

  echo -e "${YELLOW}  Upgrading kubeadm → v${TARGET}...${NC}"
  if [[ "$PKG_MANAGER" == "apt" ]]; then
    apt-get install -y "kubeadm=${TARGET}-*"
  else
    dnf install -y --disableexcludes=kubernetes "kubeadm-${TARGET}"
  fi
  echo -e "${GREEN}  ✓ kubeadm v${TARGET}${NC}"

  if [[ "$UGTYPE" == "master" ]]; then
    kubeadm upgrade apply "v${TARGET}" --yes
    echo -e "${GREEN}  ✓ Control-plane upgraded${NC}"
  else
    kubeadm upgrade node
    echo -e "${GREEN}  ✓ Node config upgraded${NC}"
  fi

  echo -e "${YELLOW}  Upgrading kubelet/kubectl → v${TARGET}...${NC}"
  for pkg in "${UPKGS[@]}"; do
    [[ "$pkg" == "kubeadm" ]] && continue
    if [[ "$PKG_MANAGER" == "apt" ]]; then
      apt-get install -y "${pkg}=${TARGET}-*"
    else
      dnf install -y --disableexcludes=kubernetes "${pkg}-${TARGET}"
    fi
    echo -e "   ${GREEN}✓ $pkg v${TARGET}${NC}"
  done

  systemctl daemon-reload
  systemctl restart kubelet
  sleep 5

  echo ""
  echo -e "${YELLOW}  Re-pinning at v${TARGET}...${NC}"
  pin_k8s_packages "${UPKGS[@]}"

  [[ "$UGTYPE" == "master" ]] && kubectl uncordon "$(hostname)" || true

  print_header "UPGRADE VERIFICATION"
  local NEW
  NEW=$(kubelet --version 2>/dev/null | awk '{print $2}' | sed 's/^v//')
  if [[ "$NEW" == "$TARGET" ]]; then
    echo -e "${GREEN}  ✓ Upgrade successful: ${YELLOW}v${CURRENT}${NC} → ${GREEN}v${TARGET}${NC}"
  else
    echo -e "${RED}  ❌ Version mismatch: expected v${TARGET}, got v${NEW}${NC}"
    exit 1
  fi
  echo ""
}

# ════════════════════════════════════════════════════════════════════════════
# MAIN INIT PIPELINE
# ════════════════════════════════════════════════════════════════════════════
# ════════════════════════════════════════════════════════════════════════════
# IDEMPOTENCY GATE
#
# Called at the very start of run_init, BEFORE any install steps.
# Inspects the current state of the node and takes the minimum necessary
# action, exiting early when the cluster is already healthy.
#
# State machine:
#  STATE 1 — Cluster fully running & API responding
#              → Print live cluster status banner → EXIT 0 (nothing to do)
#  STATE 2 — kubelet inactive, cluster previously initialized
#              → Restart kubelet only → monitor pods → print banner → EXIT 0
#  STATE 3 — Partially initialized (admin.conf/kubelet.conf exists but
#             kubelet can't start / API unreachable)
#              → Return 1 (let run_init re-initialize)
#  STATE 4 — Fresh node (no /etc/kubernetes at all)
#              → Return 0 (let run_init proceed normally)
# ════════════════════════════════════════════════════════════════════════════
_check_cluster_idempotent() {

  # ── Shared helpers ────────────────────────────────────────────────────────
  # Recover globals that the banner functions depend on.
  # Safe to call before run_init's full pipeline because we only read files.
  _recover_context() {
    K8S_VERSION=$(_get_installed_k8s_version kubelet 2>/dev/null || echo "unknown")
    [[ -f "$K8S_VERSION_FILE" ]] && K8S_VERSION=$(cat "$K8S_VERSION_FILE")
    RUNTIME="containerd"
    systemctl list-unit-files 2>/dev/null | grep -q "^crio" && RUNTIME="crio"
    CNI_CHOICE="calico"
    [[ -f "$CNI_CONFIG_FILE" ]] && CNI_CHOICE=$(cat "$CNI_CONFIG_FILE")
    HOST_ONLY_IFACE=""
    [[ -f "$CNI_IFACE_FILE"  ]] && HOST_ONLY_IFACE=$(cat "$CNI_IFACE_FILE")
  }

  # ── Determine node type early ─────────────────────────────────────────────
  local _HN; _HN=$(hostname | tr '[:upper:]' '[:lower:]')
  local _NT="worker"
  [[ -n "${ARG_NODE_TYPE:-}" ]]                                    && _NT="$ARG_NODE_TYPE"
  [[ "$_HN" =~ master|control ]]                                   && _NT="master"
  [[ -f /etc/kubernetes/admin.conf ]] && command -v kubectl &>/dev/null && _NT="master"

  # ── Common state probes ───────────────────────────────────────────────────
  local _K8S_VER; _K8S_VER=$(_get_installed_k8s_version kubelet 2>/dev/null || echo "")
  local _KUBELET_ACTIVE=false
  systemctl is-active --quiet kubelet 2>/dev/null && _KUBELET_ACTIVE=true

  # ══════════════════════════════════════════════════════════════════════════
  # MASTER STATE MACHINE
  # ══════════════════════════════════════════════════════════════════════════
  if [[ "$_NT" == "master" ]]; then

    local _INIT_DONE=false _API_UP=false
    [[ -f /etc/kubernetes/admin.conf ]] && _INIT_DONE=true
    if [[ "$_INIT_DONE" == true ]]; then
      export KUBECONFIG=/etc/kubernetes/admin.conf
      kubectl get nodes &>/dev/null 2>&1 && _API_UP=true
    fi

    # ── MASTER STATE 1: kubelet active + API responding ─────────────────────
    # → cluster is fully healthy, nothing to do
    if [[ "$_KUBELET_ACTIVE" == true && "$_API_UP" == true ]]; then
      _recover_context
      print_header "CLUSTER ALREADY RUNNING  (MASTER)"
      echo -e "${GREEN}  ✔ kubelet     : active${NC}"
      echo -e "${GREEN}  ✔ API server  : reachable${NC}"
      echo -e "${GREEN}  ✔ K8s version : ${WHITE}v${K8S_VERSION}${NC}"
      echo -e "${GREEN}  ✔ Runtime     : ${WHITE}${RUNTIME}${NC}"
      echo -e "${GREEN}  ✔ CNI         : ${WHITE}${CNI_CHOICE^^}${NC}"
      echo ""
      echo -e "${CYAN}  Cluster nodes:${NC}"
      kubectl get nodes -o wide 2>/dev/null | while IFS= read -r _L; do echo -e "  $_L"; done
      echo ""
      echo -e "${CYAN}  System pod status:${NC}"
      printf "${CYAN}  %-34s %s${NC}\n" "Component" "Ready/Total"
      printf "${CYAN}  %-34s %s${NC}\n" "─────────────────────────────────" "──────────"
      local _DR _DT _PR _PT _NR _NT2 _CR _CT
      pod_ready_count "kube-system" "k8s-app=kube-dns"   _DR _DT
      pod_ready_count "kube-system" "k8s-app=kube-proxy" _PR _PT
      if [[ "$CNI_CHOICE" == "flannel" ]]; then
        pod_ready_count "kube-flannel" "app=flannel"           _NR _NT2
        _pod_status_line "Flannel (node)"             $_NR $_NT2
      else
        pod_ready_count "kube-system" "k8s-app=calico-node"             _NR _NT2
        pod_ready_count "kube-system" "k8s-app=calico-kube-controllers" _CR _CT
        _pod_status_line "Calico (node)"              $_NR $_NT2
        _pod_status_line "Calico (kube-controllers)"  $_CR $_CT
      fi
      _pod_status_line "CoreDNS"                      $_DR $_DT
      _pod_status_line "kube-proxy"                   $_PR $_PT
      echo ""
      echo -e "${YELLOW}  Nothing to do — cluster is healthy.${NC}"
      echo -e "${DIM}  To re-initialize : ${WHITE}sudo ./k8s-cluster-bootstrap.sh --reset${NC}${DIM} then --init${NC}"
      echo -e "${DIM}  To upgrade        : ${WHITE}sudo ./k8s-cluster-bootstrap.sh --upgrade${NC}"
      echo ""
      exit 0
    fi

    # ── MASTER STATE 2: init done, kubelet inactive ─────────────────────────
    # → restart kubelet, wait for API, monitor pods, print recovery banner
    if [[ "$_INIT_DONE" == true && "$_KUBELET_ACTIVE" == false ]]; then
      print_header "MASTER INITIALIZED — KUBELET STOPPED"
      echo -e "${YELLOW}  ⚠️  kubelet is inactive but cluster was previously initialized.${NC}"
      echo -e "${CYAN}  ℹ️  K8s version : ${WHITE}v${_K8S_VER}${NC}"
      echo ""
      echo -e "${YELLOW}  Restarting kubelet...${NC}"
      systemctl daemon-reload
      systemctl enable kubelet 2>/dev/null || true
      systemctl start  kubelet 2>/dev/null
      local _W=0
      while [[ $_W -lt 30 ]]; do
        systemctl is-active --quiet kubelet && break
        sleep 3; _W=$((_W+3))
      done
      if ! systemctl is-active --quiet kubelet; then
        echo -e "${RED}  ❌ kubelet failed to start — check: journalctl -u kubelet -n 30${NC}"
        echo -e "${YELLOW}  If cluster is broken: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --reset${NC}"
        exit 1
      fi
      echo -e "${GREEN}  ✓ kubelet restarted${NC}"
      echo ""
      export KUBECONFIG=/etc/kubernetes/admin.conf
      echo -e "${YELLOW}  ⏳ Waiting for API server (max 90s)...${NC}"
      local _AW=0
      while [[ $_AW -lt 90 ]]; do
        kubectl get nodes &>/dev/null && { echo -e "${GREEN}  ✓ API server ready${NC}"; break; }
        sleep 3; _AW=$((_AW+3))
      done
      if ! kubectl get nodes &>/dev/null; then
        echo -e "${RED}  ❌ API server not responding after 90s${NC}"
        echo -e "${YELLOW}  If cluster is broken: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --reset${NC}"
        exit 1
      fi
      echo ""
      _recover_context
      wait_for_master_pods_ready && {
        print_header "CLUSTER RECOVERED  (MASTER)"
        echo -e "${CYAN}  Action performed  :${NC} ${WHITE}kubelet restarted${NC}"
        echo -e "${CYAN}  K8s version       :${NC} ${WHITE}v${K8S_VERSION}${NC}"
        echo -e "${CYAN}  Runtime           :${NC} ${WHITE}${RUNTIME}${NC}"
        echo -e "${CYAN}  CNI               :${NC} ${WHITE}${CNI_CHOICE^^}${NC}"
        echo ""
        echo -e "${CYAN}  Cluster nodes:${NC}"
        kubectl get nodes -o wide 2>/dev/null | while IFS= read -r _L; do echo -e "  $_L"; done
        echo ""
        echo -e "${DIM}  Log: ${WHITE}${LOG_FILE}${NC}"
        echo ""
        print_credits
      } || {
        echo -e "${RED}  ❌ Pods not fully ready after recovery${NC}"
        echo -e "${YELLOW}  Run: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --reset${NC}${YELLOW} then --init${NC}"
      }
      exit 0
    fi

    # ── MASTER STATE 3: admin.conf present, kubelet active but API unreachable
    # → something is wrong (static pod crash, etcd issue). Fall through so
    #   run_init can attempt re-init (bootstrap_master skips kubeadm init if
    #   admin.conf already exists, so the user should --reset first).
    if [[ "$_INIT_DONE" == true && "$_KUBELET_ACTIVE" == true && "$_API_UP" == false ]]; then
      echo -e "${YELLOW}  ⚠️  kubelet is active but API server is not responding.${NC}"
      echo -e "${YELLOW}  Cluster may be in a broken state.${NC}"
      echo -e "${YELLOW}  Recommended: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --reset${NC}${YELLOW} then --init${NC}"
      echo ""
      exit 1
    fi

    # ── MASTER STATE 4: /etc/kubernetes missing entirely ───────────────────
    # → fresh master, let run_init proceed normally
    return 0
  fi

  # ══════════════════════════════════════════════════════════════════════════
  # WORKER STATE MACHINE
  # Workers never run an API server — health is determined by:
  #   • kubelet.service active
  #   • calico-node (or flannel) container Running in crictl
  # ══════════════════════════════════════════════════════════════════════════

  local _JOINED=false   # kubelet.conf written by kubeadm join
  [[ -f /etc/kubernetes/kubelet.conf ]] && _JOINED=true

  # Helper: check if the CNI agent container is Running on this worker.
  # Uses crictl --state running (built-in filter) to avoid the variable-width
  # CREATED column parsing bug — see wait_for_worker_pods_ready for details.
  _worker_cni_running() {
    crictl ps --state running 2>/dev/null | grep -qE "calico-node|flannel"
  }

  # Helper: check if VXLAN interface is up (Calico only)
  _vxlan_up() { ip link show vxlan.calico &>/dev/null; }

  # ── WORKER STATE 1: kubelet active + CNI agent Running ─────────────────
  # → worker fully healthy, nothing to do
  if [[ "$_JOINED" == true && "$_KUBELET_ACTIVE" == true ]] && _worker_cni_running; then
    _recover_context
    print_header "WORKER ALREADY RUNNING"
    echo -e "${GREEN}  ✔ kubelet      : active${NC}"
    echo -e "${GREEN}  ✔ CNI agent    : Running (${CNI_CHOICE})${NC}"
    echo -e "${GREEN}  ✔ K8s version  : ${WHITE}v${K8S_VERSION}${NC}"
    echo -e "${GREEN}  ✔ Runtime      : ${WHITE}${RUNTIME}${NC}"
    echo -e "${GREEN}  ✔ Worker IP    : ${WHITE}$(hostname -I | awk '{print $1}')${NC}"
    if _vxlan_up; then
      echo -e "${GREEN}  ✔ vxlan.calico : up${NC}"
    fi
    echo ""
    echo -e "${CYAN}  Node status:${NC}"
    echo -e "  ${DIM}(run on master: kubectl get nodes -o wide)${NC}"
    echo ""
    echo -e "${YELLOW}  Nothing to do — worker is healthy.${NC}"
    echo -e "${DIM}  To re-initialize: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --reset${NC}${DIM} then --init${NC}"
    echo -e "${DIM}  To upgrade:       ${WHITE}sudo ./k8s-cluster-bootstrap.sh --upgrade${NC}"
    echo ""
    exit 0
  fi

  # ── WORKER STATE 2: kubelet active but CNI agent not yet Running ────────
  # → worker joined, kubelet running, just waiting for calico-node to start
  # → monitor and print banner — no action needed
  if [[ "$_JOINED" == true && "$_KUBELET_ACTIVE" == true ]] && ! _worker_cni_running; then
    _recover_context
    print_header "WORKER RUNNING — WAITING FOR CNI"
    echo -e "${CYAN}  ℹ️  kubelet is active but CNI agent (${CNI_CHOICE}) not yet Running.${NC}"
    echo -e "${CYAN}  ℹ️  K8s version : ${WHITE}v${K8S_VERSION}${NC}"
    echo -e "${CYAN}  ℹ️  Runtime     : ${WHITE}${RUNTIME}${NC}"
    echo ""
    echo -e "${YELLOW}  Monitoring CNI agent startup (this is normal after a node restart)...${NC}"
    echo ""
    # Reuse wait_for_worker_pods_ready — it handles resolvConf patch + calico wait
    if wait_for_worker_pods_ready; then
      _print_worker_recovered_banner "kubelet already running — CNI agent monitored"
    else
      echo -e "${RED}  ❌ CNI agent not Running after timeout${NC}"
      echo -e "${YELLOW}  Check: journalctl -u kubelet -n 50${NC}"
      echo -e "${YELLOW}  Or reset: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --reset${NC}${YELLOW} then --init${NC}"
    fi
    exit 0
  fi

  # ── WORKER STATE 3: joined but kubelet inactive ─────────────────────────
  # → restart kubelet, apply resolvConf patch (Rocky), monitor CNI, banner
  if [[ "$_JOINED" == true && "$_KUBELET_ACTIVE" == false ]]; then
    _recover_context
    print_header "WORKER INITIALIZED — KUBELET STOPPED"
    echo -e "${YELLOW}  ⚠️  kubelet is inactive but worker was previously joined.${NC}"
    echo -e "${CYAN}  ℹ️  K8s version : ${WHITE}v${K8S_VERSION}${NC}"
    echo -e "${CYAN}  ℹ️  Runtime     : ${WHITE}${RUNTIME}${NC}"
    echo ""
    echo -e "${YELLOW}  Restarting kubelet...${NC}"
    systemctl daemon-reload
    systemctl enable kubelet 2>/dev/null || true
    systemctl start  kubelet 2>/dev/null
    local _W=0
    while [[ $_W -lt 30 ]]; do
      systemctl is-active --quiet kubelet && break
      sleep 3; _W=$((_W+3))
    done
    if ! systemctl is-active --quiet kubelet; then
      echo -e "${RED}  ❌ kubelet failed to start — check: journalctl -u kubelet -n 30${NC}"
      echo -e "${YELLOW}  If cluster is broken: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --reset${NC}"
      exit 1
    fi
    echo -e "${GREEN}  ✓ kubelet restarted${NC}"
    echo ""
    # wait_for_worker_pods_ready handles Rocky resolvConf patch + calico-node monitoring
    if wait_for_worker_pods_ready; then
      _print_worker_recovered_banner "kubelet restarted"
    else
      echo -e "${RED}  ❌ Worker not fully ready after kubelet restart${NC}"
      echo -e "${YELLOW}  Check: journalctl -u kubelet -n 50${NC}"
      echo -e "${YELLOW}  Or reset: ${WHITE}sudo ./k8s-cluster-bootstrap.sh --reset${NC}${YELLOW} then --init${NC}"
    fi
    exit 0
  fi

  # ── WORKER STATE 4: kubelet.conf missing ────────────────────────────────
  # → fresh worker, has never joined — let run_init proceed to bootstrap_worker
  return 0
}

# Banner printed after a worker recovery (STATE 2 or STATE 3)
_print_worker_recovered_banner() {
  local _action="$1"
  local ET=$(($(date +%s) - START_TIME))
  print_header "WORKER RECOVERED"
  echo -e "${CYAN}  Action performed  :${NC} ${WHITE}${_action}${NC}"
  echo -e "${CYAN}  K8s version       :${NC} ${WHITE}v${K8S_VERSION}${NC}"
  echo -e "${CYAN}  Runtime           :${NC} ${WHITE}${RUNTIME}${NC}"
  echo -e "${CYAN}  Worker IP         :${NC} ${WHITE}${HOST_ONLY_IP:-$(hostname -I | awk '{print $1}')}${NC}"
  if ip link show vxlan.calico &>/dev/null; then
    echo -e "${CYAN}  VXLAN interface   :${NC} ${WHITE}vxlan.calico up${NC}"
  fi
  echo ""
  echo -e "${YELLOW}  Check on master: ${WHITE}kubectl get nodes -o wide${NC}"
  echo ""
  echo -e "${CYAN}⏱️  Total time : ${WHITE}$((ET/60))m $((ET%60))s${NC}"
  echo -e "${CYAN}📄 Log file   : ${WHITE}${LOG_FILE}${NC}"
  echo ""
  print_credits
}

run_init() {
  print_header "ENTERPRISE KUBERNETES BOOTSTRAP  --init"

  # ── Show effective configuration (flag overrides) ────────────────────────
  echo -e "${CYAN}  Effective configuration:${NC}"
  echo -e "  ${DIM}─────────────────────────────────────────────────${NC}"
  if [[ -n "$ARG_NODE_TYPE" ]]; then
    echo -e "  ${CYAN}Node type  :${NC} ${WHITE}${ARG_NODE_TYPE}${NC} ${DIM}(--node-type override)${NC}"
  else
    echo -e "  ${CYAN}Node type  :${NC} ${DIM}auto-detect from hostname${NC}"
  fi
  if [[ -n "$ARG_HOST_CIDR" ]]; then
    echo -e "  ${CYAN}Host CIDR  :${NC} ${WHITE}${ARG_HOST_CIDR}${NC} ${DIM}(--host-cidr override)${NC}"
  else
    echo -e "  ${CYAN}Host CIDR  :${NC} ${DIM}auto-detect 192.168.x.x${NC}"
  fi
  echo -e "  ${CYAN}Pod CIDR   :${NC} ${WHITE}${POD_CIDR}${NC}$([ -n "$ARG_POD_CIDR" ] && echo " ${DIM}(--pod-cidr override)${NC}" || echo " ${DIM}(default)${NC}")"
  if [[ "${ARG_TIMEZONE,,}" == "skip" || -z "$ARG_TIMEZONE" ]]; then
    echo -e "  ${CYAN}Timezone   :${NC} ${DIM}unchanged (use --timezone to set)${NC}"
  else
    echo -e "  ${CYAN}Timezone   :${NC} ${WHITE}${ARG_TIMEZONE}${NC} ${DIM}(--timezone override)${NC}"
  fi
  echo -e "  ${DIM}─────────────────────────────────────────────────${NC}"
  echo ""

  detect_os
  _check_cluster_idempotent   # exits early if cluster already healthy or recovers kubelet
  configure_timezone
  validate_network_config || exit 1
  validate_hostname
  disable_swap
  configure_firewall
  install_prerequisites
  configure_kernel
  configure_dns
  setup_k8s_repositories
  select_k8s_version
  setup_container_runtime
  install_k8s_components
  configure_crictl
  detect_network_interfaces

  if [[ "$NODE_TYPE" == "master" ]]; then
    bootstrap_master
  else
    bootstrap_worker
  fi
}

# ════════════════════════════════════════════════════════════════════════════
# ENTRY POINT
# ════════════════════════════════════════════════════════════════════════════
parse_arguments "$@"
check_root "$@"
setup_logging "$@"

if   [[ "$INIT_MODE"    == true ]]; then run_init
elif [[ "$UPGRADE_MODE" == true ]]; then run_upgrade
elif [[ "$RESET_MODE"   == true ]]; then run_reset
elif [[ "$DESTROY_MODE" == true ]]; then run_destroy
fi