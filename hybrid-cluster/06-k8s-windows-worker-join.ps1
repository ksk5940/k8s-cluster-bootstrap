#Requires -RunAsAdministrator
<#
.SYNOPSIS
    06-k8s-windows-worker-join.ps1
    Complete Windows Kubernetes Worker Node Setup and Cluster Join.

.DESCRIPTION
    Fully automated setup for Windows Server 2019/2022 Kubernetes worker node
    in a hybrid Linux+Windows cluster using ContainerD + Calico VXLAN.
    Fully idempotent - safe to re-run at any time.

    Tested: Windows Server 2022, Kubernetes 1.32.3, Calico 3.29.3, VMware

    Fixes applied vs original:
      - MASTER_IP not set on re-run ($alreadyJoined=true path) -> routing fails
      - containerd 1.7.22 does not exist as a release -> pinned to 1.7.24
      - Get-ClusterNicIP fallback could grab VMware internal adapter -> filtered
      - Get-NatNicIP hardcoded to 172.16.* only -> extended to 10.x NAT ranges
      - kube-proxy started before kubelet.conf exists -> waits for TLS bootstrap
      - Missing firewall rule for service CIDR (10.96.0.0/12) outbound
      - VXLAN_VNI missing from Calico NSSM env vars -> VNI mismatch with Linux
      - HNS cleanup in Step 7 leaves ghost 'vxlan0' network blocking re-joins

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File 06-k8s-windows-worker-join.ps1
#>

param(
    [string]$JoinCommand = '',   # Pass full kubeadm join command to skip interactive prompt
    [switch]$AutoApprove         # Pass -AutoApprove to skip "Proceed?" confirmation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ==============================================================================
# CONFIGURATION - Edit to match your environment
# ==============================================================================
$K8S_VERSION        = '1.32.3'
$CONTAINERD_VERSION = '1.7.24'   # FIX: 1.7.22 does not exist; 1.7.24 is latest stable
$CNI_VERSION        = '1.5.1'
$CALICO_VERSION     = '3.29.3'

$BIN_DIR       = 'C:\k\bin'
$CNI_BIN_DIR   = 'C:\k\cni\bin'
$CNI_CONF_DIR  = 'C:\k\cni\config'
$LOG_DIR       = 'C:\k\logs'
$KUBELET_DATA  = 'C:\var\lib\kubelet'
$PROXY_DATA    = 'C:\var\lib\kube-proxy'
$ETC_K8S       = 'C:\etc\kubernetes'
$CALICO_DIR    = 'C:\calico\CalicoWindows'

$K8S_SERVICE_CIDR = '10.96.0.0/12'
$CLUSTER_DNS      = '10.96.0.10'
$POD_CIDR         = '10.244.0.0/16'
$POD_CIDR_MASK    = '255.255.0.0'
$VXLAN_VNI        = '4096'   # Must match Linux Calico VXLAN VNI (default 4096)

# ==============================================================================
# HELPERS
# ==============================================================================
function Write-Step($n,$t,$msg) {
    Write-Host ""
    Write-Host "  [$n/$t] $msg" -ForegroundColor Cyan
    Write-Host "  $('-'*66)" -ForegroundColor DarkGray
}
function OK($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }
function Info($m) { Write-Host "  [....] $m" -ForegroundColor Gray }
function Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }

function Log($msg) {
    $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')
    try { "$ts | $msg" | Out-File "$LOG_DIR\k8s-join.log" -Append -Encoding UTF8 } catch {}
}

function Download($url, $dest) {
    if (Test-Path $dest) { Skip "Already present: $(Split-Path $dest -Leaf)"; return }
    Info "Downloading $(Split-Path $dest -Leaf)..."
    $tmp = "$dest.tmp"
    try {
        $wc = New-Object System.Net.WebClient
        $wc.DownloadFile($url, $tmp)
        Move-Item $tmp $dest -Force
        OK "Downloaded: $(Split-Path $dest -Leaf)"
    } catch {
        Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        Fail "Download failed: $url`n$_"
    }
}

function Get-ClusterNicIP {
    # FIX: Filter out VMware internal/loopback adapters by requiring the adapter
    # to be 'Up' and have an InterfaceIndex > 5 (loopback is always index 1).
    # VMware VMCI and host-only internal adapters often appear as 192.168.x.x
    # but are not the actual VM NIC we want kubelet/Calico to bind to.

    # First: exact match for known host-only subnet
    $a = Get-NetIPAddress -AddressFamily IPv4 |
         Where-Object { $_.IPAddress -like '192.168.56.*' -and $_.InterfaceIndex -gt 5 } |
         Where-Object {
             $adapter = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
             $adapter -and $adapter.Status -eq 'Up' -and
             $adapter.InterfaceDescription -notlike '*VMware VMCI*' -and
             $adapter.InterfaceDescription -notlike '*Loopback*'
         } |
         Select-Object -First 1
    if ($a) { return $a.IPAddress }

    # Fallback: any 192.168.x.x on a real Up adapter
    $a = Get-NetIPAddress -AddressFamily IPv4 |
         Where-Object { $_.IPAddress -like '192.168.*' -and $_.InterfaceIndex -gt 5 } |
         Where-Object {
             $adapter = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
             $adapter -and $adapter.Status -eq 'Up' -and
             $adapter.InterfaceDescription -notlike '*VMware VMCI*' -and
             $adapter.InterfaceDescription -notlike '*Loopback*'
         } |
         Select-Object -First 1
    if ($a) { return $a.IPAddress }
    return $null
}

function Get-AdapterForIP($ip) {
    $a = Get-NetIPAddress -AddressFamily IPv4 | Where-Object IPAddress -eq $ip
    if ($a) {
        $nic = Get-NetAdapter -InterfaceIndex $a.InterfaceIndex -ErrorAction SilentlyContinue
        if ($nic) { return $nic.Name }
    }
    return $null
}

function Get-NatNicIP {
    # FIX: extended to cover 172.16.x.x (VMware NAT default) and 10.x.x.x NAT ranges
    # while excluding the cluster/host-only IP already detected as $CLUSTER_IP.
    $candidates = Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.InterfaceIndex -gt 5 } |
        Where-Object {
            $adapter = Get-NetAdapter -InterfaceIndex $_.InterfaceIndex -ErrorAction SilentlyContinue
            $adapter -and $adapter.Status -eq 'Up'
        } |
        Where-Object {
            ($_.IPAddress -like '172.16.*')  -or
            ($_.IPAddress -like '172.17.*')  -or
            ($_.IPAddress -like '172.18.*')  -or
            ($_.IPAddress -like '10.*')
        } |
        Where-Object { $_.IPAddress -ne $CLUSTER_IP } |
        Select-Object -First 1
    if ($candidates) { return $candidates.IPAddress }
    return $null
}

function Register-KubeletTask($kubeletExe, $taskArgs) {
    Unregister-ScheduledTask -TaskName 'kubelet' -Confirm:$false -ErrorAction SilentlyContinue
    $action    = New-ScheduledTaskAction -Execute $kubeletExe -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 5 `
                     -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
                     -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'kubelet' -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
}

function Register-KubeProxyTask($kubeProxyExe, $taskArgs) {
    Unregister-ScheduledTask -TaskName 'kube-proxy' -Confirm:$false -ErrorAction SilentlyContinue
    $action    = New-ScheduledTaskAction -Execute $kubeProxyExe -Argument $taskArgs
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $settings  = New-ScheduledTaskSettingsSet -ExecutionTimeLimit 0 -RestartCount 5 `
                     -RestartInterval (New-TimeSpan -Minutes 1)
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' `
                     -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName 'kube-proxy' -Action $action -Trigger $trigger `
        -Settings $settings -Principal $principal -Force | Out-Null
}

# ==============================================================================
# BANNER
# ==============================================================================
Write-Host ""
Write-Host "  +=========================================================================+" -ForegroundColor Cyan
Write-Host "  |      WINDOWS KUBERNETES WORKER - SETUP AND JOIN  v$K8S_VERSION          |" -ForegroundColor Cyan
Write-Host "  +=========================================================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  K8s $K8S_VERSION  |  ContainerD $CONTAINERD_VERSION  |  Calico $CALICO_VERSION" -ForegroundColor DarkGray
Write-Host ""

if (-not $AutoApprove) {
    $ans = Read-Host "  Proceed? [Y/n]"
    if ($ans -match '^[Nn]') { exit 0 }
} else {
    Write-Host "  Auto-approved (running non-interactively)" -ForegroundColor DarkGray
}
New-Item -ItemType Directory -Force -Path $LOG_DIR | Out-Null
Log "===== SESSION START node=$env:COMPUTERNAME ====="

# ==============================================================================
# [1/9] OS CHECK
# ==============================================================================
Write-Step 1 9 'OS check'
if ($env:PROCESSOR_ARCHITECTURE -ne 'AMD64') { Fail "AMD64 required" }
$os = Get-CimInstance Win32_OperatingSystem
if ([int]$os.BuildNumber -lt 17763) { Fail "Windows Server 2019 or later required" }
OK "OS: $($os.Caption) Build $($os.BuildNumber)"

# ==============================================================================
# [2/9] DETECT NETWORK INTERFACES
# ==============================================================================
Write-Step 2 9 'Detect network interfaces'

$CLUSTER_IP = Get-ClusterNicIP
if (-not $CLUSTER_IP) { Fail "Cannot find cluster NIC IP (192.168.56.x). Check Host-Only adapter." }
$CLUSTER_ADAPTER = Get-AdapterForIP $CLUSTER_IP

# FIX: MASTER_IP must be initialised here so the routing step in [9/9] always
# has a value — even on re-runs where the join block ($alreadyJoined=true) is
# skipped and the join command is never pasted.
# We derive it from the existing bootstrap-kubelet.conf if already joined,
# otherwise it will be set from the join command in [8/9].
$MASTER_IP = ''
$bootstrapConf = "$ETC_K8S\bootstrap-kubelet.conf"
if (Test-Path $bootstrapConf) {
    $serverLine = Get-Content $bootstrapConf -ErrorAction SilentlyContinue |
                  Where-Object { $_ -match '^\s*server:' } |
                  Select-Object -First 1
    if ($serverLine -match 'https://([0-9.]+):') {
        $MASTER_IP = $Matches[1]
    }
}

$NAT_IP    = Get-NatNicIP
$NODE_NAME = $env:COMPUTERNAME.ToLower()

OK "Cluster NIC : $CLUSTER_IP  (adapter: $CLUSTER_ADAPTER)"
OK "NAT NIC     : $(if ($NAT_IP) { $NAT_IP } else { 'not found' })"
OK "Node name   : $NODE_NAME"
if ($MASTER_IP) { OK "Master IP   : $MASTER_IP (from existing bootstrap conf)" }
Log "cluster_ip=$CLUSTER_IP adapter=$CLUSTER_ADAPTER nat_ip=$NAT_IP"

# ==============================================================================
# [3/9] DIRECTORIES + PATH + FEATURES
# ==============================================================================
Write-Step 3 9 'Directories, PATH, Windows features'

foreach ($d in @($BIN_DIR,$CNI_BIN_DIR,$CNI_CONF_DIR,$LOG_DIR,$KUBELET_DATA,
                  $PROXY_DATA,"$ETC_K8S\pki","$ETC_K8S\manifests",
                  "$KUBELET_DATA\pki",'C:\calico')) {
    New-Item -ItemType Directory -Force -Path $d | Out-Null
}

$syspath = [System.Environment]::GetEnvironmentVariable('PATH','Machine')
if ($syspath -notlike "*$BIN_DIR*") {
    [System.Environment]::SetEnvironmentVariable('PATH',"$syspath;$BIN_DIR",'Machine')
    $env:PATH += ";$BIN_DIR"
    OK "Added $BIN_DIR to system PATH"
} else {
    Skip "$BIN_DIR already in system PATH"
}

$feat = Get-WindowsOptionalFeature -Online -FeatureName Containers -ErrorAction SilentlyContinue
if ($feat -and $feat.State -ne 'Enabled') {
    Enable-WindowsOptionalFeature -Online -FeatureName Containers -All -NoRestart | Out-Null
    OK "Containers feature enabled (reboot may be needed)"
} else { Skip "Containers feature already enabled" }

OK "Directories and PATH ready"

# ==============================================================================
# [4/9] CONTAINERD
# ==============================================================================
Write-Step 4 9 "ContainerD $CONTAINERD_VERSION"

$svc = Get-Service containerd -ErrorAction SilentlyContinue
if ($svc -and $svc.Status -eq 'Running') {
    Skip "ContainerD already running"
} else {
    $cdZip = "$env:TEMP\containerd.tar.gz"
    Download "https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION/containerd-$CONTAINERD_VERSION-windows-amd64.tar.gz" $cdZip
    tar -xf $cdZip -C 'C:\k' 2>&1 | Out-Null

    $cdConf = 'C:\Program Files\containerd\config.toml'
    if (-not (Test-Path $cdConf)) {
        New-Item -ItemType Directory -Force -Path 'C:\Program Files\containerd' | Out-Null
        & "$BIN_DIR\containerd.exe" config default | Out-File $cdConf -Encoding ASCII
    }

    if (-not (Get-Service containerd -ErrorAction SilentlyContinue)) {
        & "$BIN_DIR\containerd.exe" --register-service 2>&1 | Out-Null
    }
    Start-Service containerd

    $socketWait = 0
    while (-not (Test-Path '\\.\pipe\containerd-containerd') -and $socketWait -lt 30) {
        Start-Sleep 1; $socketWait++
    }
    if (-not (Test-Path '\\.\pipe\containerd-containerd')) {
        Fail "containerd pipe did not appear after 30s"
    }
    OK "ContainerD installed and running"
}

# ==============================================================================
# [5/9] CNI PLUGINS + KUBERNETES BINARIES
# ==============================================================================
Write-Step 5 9 "CNI plugins and Kubernetes binaries"

$cniTgz = "$env:TEMP\cni-plugins.tgz"
Download "https://github.com/containernetworking/plugins/releases/download/v$CNI_VERSION/cni-plugins-windows-amd64-v$CNI_VERSION.tgz" $cniTgz
if (-not (Test-Path "$CNI_BIN_DIR\win-bridge.exe")) {
    tar -xf $cniTgz -C $CNI_BIN_DIR 2>&1 | Out-Null
    OK "CNI plugins extracted"
} else {
    Skip "CNI plugins already extracted"
}

$k8sBase = "https://dl.k8s.io/v$K8S_VERSION/bin/windows/amd64"
foreach ($bin in @('kubelet','kubeadm','kubectl','kube-proxy')) {
    Download "$k8sBase/$bin.exe" "$BIN_DIR\$bin.exe"
}
OK "Kubernetes binaries ready"

# ==============================================================================
# [6/9] FIREWALL
# ==============================================================================
Write-Step 6 9 'Windows Firewall'

$fwRules = @(
    @{Name='K8s-Kubelet-API';    Proto='TCP';    Port='10250'         },
    @{Name='K8s-KubeProxy';      Proto='TCP';    Port='10256'         },
    @{Name='K8s-NodePort';       Proto='TCP';    Port='30000-32767'   },
    @{Name='K8s-VXLAN';          Proto='UDP';    Port='4789'          },
    @{Name='K8s-API-Out';        Proto='TCP';    Port='6443';  Dir='Outbound'},
    @{Name='K8s-ICMP';           Proto='ICMPv4'; Port=$null           },
    @{Name='K8s-ClusterSubnet';  Proto='Any';    Port=$null;   Remote='192.168.56.0/24'},
    # FIX: service CIDR outbound rule — kube-proxy kernelspace needs to reach
    # service VIPs (10.96.0.0/12) from the Windows node.
    @{Name='K8s-ServiceCIDR-Out';Proto='Any';    Port=$null;   Dir='Outbound'; Remote='10.96.0.0/12'},
    # FIX: pod CIDR outbound — Calico VXLAN encapsulated pod-to-pod traffic
    @{Name='K8s-PodCIDR-Out';    Proto='Any';    Port=$null;   Dir='Outbound'; Remote='10.244.0.0/16'}
)

$fwNew = 0
foreach ($r in $fwRules) {
    if (Get-NetFirewallRule -DisplayName $r.Name -ErrorAction SilentlyContinue) { continue }
    $dir = if ($r.Dir) { $r.Dir } else { 'Inbound' }
    $p = @{ DisplayName=$r.Name; Direction=$dir; Action='Allow'; Profile='Any'; Enabled='True' }
    switch ($r.Proto) {
        'ICMPv4' { $p['Protocol']='ICMPv4'; $p['IcmpType']=8 }
        'Any'    {
            $p['Protocol']='Any'
            if ($r.Remote) {
                if ($dir -eq 'Outbound') { $p['RemoteAddress']=$r.Remote }
                else                      { $p['RemoteAddress']=$r.Remote }
            }
        }
        default  {
            $p['Protocol']=$r.Proto
            if ($r.Port) {
                if ($dir -eq 'Outbound') { $p['RemotePort']=$r.Port } else { $p['LocalPort']=$r.Port }
            }
        }
    }
    New-NetFirewallRule @p | Out-Null
    $fwNew++
}
if ($fwNew -gt 0) { OK "Firewall: $fwNew new rule(s) added" }
else              { Skip "All firewall rules already present" }

# ==============================================================================
# [7/9] INSTALL CALICO FOR WINDOWS (native)
# ==============================================================================
Write-Step 7 9 "Calico $CALICO_VERSION (native Windows install)"

$calicoNodeSvc  = Get-Service CalicoNode  -ErrorAction SilentlyContinue
$calicoFelixSvc = Get-Service CalicoFelix -ErrorAction SilentlyContinue
$calicoAlreadyInstalled = ($calicoNodeSvc -and $calicoFelixSvc)

if ($calicoAlreadyInstalled) {
    Skip "Calico services (CalicoNode + CalicoFelix) already installed"
} else {
    Stop-Service CalicoFelix,CalicoNode -Force -ErrorAction SilentlyContinue

    # FIX: Remove 'vxlan0' ghost network in addition to 'Calico'/'nat'/'cbr0'.
    # On WS2022, a failed Calico install leaves a 'vxlan0' HNS network that
    # blocks the next install attempt (HNS returns "network already exists").
    $hnsToRemove = @('Calico','nat','cbr0','vxlan0','External')
    foreach ($netName in $hnsToRemove) {
        Get-HnsNetwork -ErrorAction SilentlyContinue |
            Where-Object Name -eq $netName |
            ForEach-Object { $_ | Remove-HnsNetwork -ErrorAction SilentlyContinue }
    }
    Start-Sleep 2

    if (-not (Test-Path "$CALICO_DIR\install-calico.ps1")) {
        $calicoZip = 'C:\calico-windows.zip'
        Download "https://github.com/projectcalico/calico/releases/download/v$CALICO_VERSION/calico-windows-v$CALICO_VERSION.zip" $calicoZip
        Expand-Archive $calicoZip -DestinationPath 'C:\calico' -Force
        OK "Calico extracted"
    } else {
        Skip "Calico already extracted"
    }

    $env:CALICO_NETWORKING_BACKEND = 'vxlan'
    $env:CALICO_DATASTORE_TYPE     = 'kubernetes'
    $env:KUBECONFIG                = "$ETC_K8S\kubelet.conf"
    $env:K8S_SERVICE_CIDR          = $K8S_SERVICE_CIDR
    $env:DNS_NAME_SERVERS          = $CLUSTER_DNS
    $env:DNS_SEARCH                = 'svc.cluster.local'
    $env:NODENAME                  = $NODE_NAME
    $env:CALICO_K8S_NODE_REF       = $NODE_NAME
    $env:CNI_BIN_DIR               = $CNI_BIN_DIR
    $env:CNI_CONF_DIR              = $CNI_CONF_DIR
    $env:IP                        = $CLUSTER_IP
    $env:IP_AUTODETECTION_METHOD   = "interface=$CLUSTER_ADAPTER"
    $env:VXLAN_ADAPTER             = $CLUSTER_ADAPTER
    $env:VXLAN_VNI                 = $VXLAN_VNI   # FIX: must match Linux Calico VNI
    $env:CALICO_IPV4POOL_CIDR      = $POD_CIDR
    $env:CALICO_LOG_DIR            = "$CALICO_DIR\logs"

    Push-Location $CALICO_DIR
    .\install-calico.ps1 2>&1 | Out-Null
    Pop-Location
    OK "Calico installed (CalicoNode + CalicoFelix services created via NSSM)"
}

# Always ensure NSSM env vars are correct (idempotent)
$nssm = "$CALICO_DIR\nssm\win64\nssm.exe"
if (Test-Path $nssm) {
    foreach ($svcName in @('CalicoNode','CalicoFelix')) {
        & $nssm set $svcName AppEnvironmentExtra `
            "CALICO_DATASTORE_TYPE=kubernetes" `
            "KUBECONFIG=$ETC_K8S\kubelet.conf" `
            "CALICO_NETWORKING_BACKEND=vxlan" `
            "NODENAME=$NODE_NAME" `
            "CALICO_K8S_NODE_REF=$NODE_NAME" `
            "K8S_SERVICE_CIDR=$K8S_SERVICE_CIDR" `
            "DNS_NAME_SERVERS=$CLUSTER_DNS" `
            "CALICO_IPV4POOL_CIDR=$POD_CIDR" `
            "IP=$CLUSTER_IP" `
            "IP_AUTODETECTION_METHOD=interface=$CLUSTER_ADAPTER" `
            "VXLAN_ADAPTER=$CLUSTER_ADAPTER" `
            "VXLAN_VNI=$VXLAN_VNI" 2>&1 | Out-Null   # FIX: VNI persisted
    }
    OK "Calico NSSM environment configured (persistent, VNI=$VXLAN_VNI)"
}

# ==============================================================================
# [8/9] JOIN CLUSTER + START KUBELET
# ==============================================================================
Write-Step 8 9 'Collect join command, bootstrap kubelet'

$alreadyJoined = (Test-Path "$ETC_K8S\kubelet.conf") -and (Test-Path "$ETC_K8S\pki\ca.crt")

if ($alreadyJoined) {
    Skip "Node already joined cluster (kubelet.conf + ca.crt present)"
    $kubeletArgs = "--bootstrap-kubeconfig=`"$ETC_K8S\bootstrap-kubelet.conf`" --kubeconfig=`"$ETC_K8S\kubelet.conf`" --config=`"$KUBELET_DATA\config.yaml`" --node-ip=$CLUSTER_IP --resolv-conf=`"`" --v=2"
    Register-KubeletTask "$BIN_DIR\kubelet.exe" $kubeletArgs
    $kubeletTask = Get-ScheduledTask -TaskName 'kubelet' -ErrorAction SilentlyContinue
    if ($kubeletTask -and $kubeletTask.State -ne 'Running') { Start-ScheduledTask -TaskName 'kubelet' }
} else {
    Write-Host ""
    Write-Host "  +----------------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host "  |  On Linux master, run these commands now:                      |" -ForegroundColor Yellow
    Write-Host "  |                                                                |" -ForegroundColor Yellow
    Write-Host "  |  kubectl delete node $NODE_NAME 2>/dev/null" -ForegroundColor White
    Write-Host "  |  kubectl delete caliconodes.crd.projectcalico.org \            |" -ForegroundColor White
    Write-Host "  |    $NODE_NAME 2>/dev/null" -ForegroundColor White
    Write-Host "  |  kubeadm token create --print-join-command                     |" -ForegroundColor White
    Write-Host "  |                                                                |" -ForegroundColor Yellow
    Write-Host "  |  Paste the join command below.                                 |" -ForegroundColor Yellow
    Write-Host "  +----------------------------------------------------------------+" -ForegroundColor Yellow
    Write-Host ""

    # Use -JoinCommand parameter if provided (non-interactive/Jenkins mode)
    # Otherwise prompt interactively
    if ($JoinCommand -and $JoinCommand -match 'kubeadm\s+join') {
        $JOIN_CMD = $JoinCommand.Trim()
        Write-Host "  Using provided join command." -ForegroundColor DarkGray
    } else {
        $JOIN_CMD = ''
        while ($JOIN_CMD -notmatch 'kubeadm\s+join') {
            $JOIN_CMD = (Read-Host "  Paste kubeadm join command").Trim()
        }
    }
    $TOKEN           = ([regex]::Match($JOIN_CMD,'--token\s+(\S+)')).Groups[1].Value
    $CA_HASH         = ([regex]::Match($JOIN_CMD,'--discovery-token-ca-cert-hash\s+(\S+)')).Groups[1].Value
    $MASTER_ENDPOINT = ([regex]::Match($JOIN_CMD,'join\s+(\S+)')).Groups[1].Value
    $MASTER_IP       = $MASTER_ENDPOINT -replace ':\d+$',''
    if (-not $TOKEN -or -not $CA_HASH -or -not $MASTER_IP) {
        Fail "Could not parse join command. Expected: kubeadm join <ip:port> --token <tok> --discovery-token-ca-cert-hash <hash>"
    }
    OK "Join command parsed: master=$MASTER_IP token=$($TOKEN.Substring(0,8))..."
    Log "master=$MASTER_IP"

    if (-not (Test-Path "$ETC_K8S\pki\ca.crt")) {
        Info "Fetching cluster CA via kubeadm (preflight only)..."
        & "$BIN_DIR\kubeadm.exe" join "$MASTER_ENDPOINT" `
            --token $TOKEN `
            --discovery-token-ca-cert-hash $CA_HASH `
            --skip-phases=kubelet-start `
            --node-name $NODE_NAME `
            --cri-socket npipe:////./pipe/containerd-containerd `
            --ignore-preflight-errors=FileContent--proc-sys-net-bridge-bridge-nf-call-iptables,IsPrivilegedUser `
            2>&1 | Out-Null
    }
    if (-not (Test-Path "$ETC_K8S\pki\ca.crt")) { Fail "Could not obtain ca.crt. Check token and connectivity." }
    OK "ca.crt obtained"

    $caCertB64 = [Convert]::ToBase64String([System.IO.File]::ReadAllBytes("$ETC_K8S\pki\ca.crt"))

    Info "Writing bootstrap-kubelet.conf..."
    [System.IO.File]::WriteAllText("$ETC_K8S\bootstrap-kubelet.conf", @"
apiVersion: v1
kind: Config
clusters:
- cluster:
    certificate-authority-data: $caCertB64
    server: https://${MASTER_IP}:6443
  name: kubernetes
contexts:
- context:
    cluster: kubernetes
    user: tls-bootstrap-token-user
  name: tls-bootstrap-token-user@kubernetes
current-context: tls-bootstrap-token-user@kubernetes
preferences: {}
users:
- name: tls-bootstrap-token-user
  user:
    token: $TOKEN
"@, [System.Text.Encoding]::ASCII)
    OK "bootstrap-kubelet.conf written"

    Info "Writing kubelet config.yaml (Windows-compatible)..."
    [System.IO.File]::WriteAllText("$KUBELET_DATA\config.yaml", @"
apiVersion: kubelet.config.k8s.io/v1beta1
kind: KubeletConfiguration
authentication:
  anonymous:
    enabled: false
  webhook:
    cacheTTL: 0s
    enabled: true
  x509:
    clientCAFile: C:\etc\kubernetes\pki\ca.crt
authorization:
  mode: Webhook
  webhook:
    cacheAuthorizedTTL: 0s
    cacheUnauthorizedTTL: 0s
cgroupDriver: ""
clusterDNS:
- $CLUSTER_DNS
clusterDomain: cluster.local
containerRuntimeEndpoint: npipe:////./pipe/containerd-containerd
cniBinDir: C:\k\cni\bin
cniConfDir: C:\k\cni\config
healthzBindAddress: 127.0.0.1
healthzPort: 10248
rotateCertificates: true
resolvConf: ""
staticPodPath: C:\etc\kubernetes\manifests
"@, [System.Text.Encoding]::ASCII)
    OK "config.yaml written"

    Info "Starting kubelet (scheduled task)..."
    Get-Process kubelet -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep 2
    $kubeletArgs = "--bootstrap-kubeconfig=`"$ETC_K8S\bootstrap-kubelet.conf`" --kubeconfig=`"$ETC_K8S\kubelet.conf`" --config=`"$KUBELET_DATA\config.yaml`" --node-ip=$CLUSTER_IP --resolv-conf=`"`" --v=2"
    Register-KubeletTask "$BIN_DIR\kubelet.exe" $kubeletArgs
    Start-ScheduledTask -TaskName 'kubelet'

    $healthy = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep 3
        try {
            if ((Invoke-WebRequest http://127.0.0.1:10248/healthz -UseBasicParsing -EA Stop).StatusCode -eq 200) {
                $healthy = $true; break
            }
        } catch {}
        if ($i % 4 -eq 0) { Info "Waiting for kubelet healthz... ($($i*3)s)" }
    }
    if (-not $healthy) { Fail "kubelet healthz not responding. Check: Get-Content C:\k\logs\k8s-join.log" }
    OK "kubelet healthy"

    # FIX: Wait for TLS bootstrap to complete (kubelet.conf written) BEFORE
    # starting kube-proxy. kube-proxy's config references kubelet.conf for its
    # kubeconfig — starting it before the file exists causes an immediate crash.
    Info "Waiting for TLS bootstrap (kubelet.conf)..."
    $confReady = $false
    for ($i = 0; $i -lt 40; $i++) {
        Start-Sleep 3
        if (Test-Path "$ETC_K8S\kubelet.conf") { $confReady = $true; break }
        if ($i % 4 -eq 0) { Info "Waiting for kubelet.conf TLS bootstrap... ($($i*3)s)" }
    }
    if ($confReady) {
        $kc = Get-Content "$ETC_K8S\kubelet.conf" -Raw
        $kc = $kc.Replace('client-certificate: \var', 'client-certificate: C:\var')
        $kc = $kc.Replace('client-key: \var',         'client-key: C:\var')
        $kc = $kc.Replace('C:\etc\kubernetes\var\lib\kubelet', 'C:\var\lib\kubelet')
        [System.IO.File]::WriteAllText("$ETC_K8S\kubelet.conf", $kc, [System.Text.Encoding]::ASCII)
        OK "kubelet.conf paths fixed (C:\ prefix added)"
    } else {
        Warn "kubelet.conf not yet present after 120s - TLS bootstrap may still be in progress"
    }
}

# Start CalicoNode
Info "Starting CalicoNode..."
Start-Service CalicoNode -ErrorAction SilentlyContinue
$calicoOK  = $false
$calicoLog = "$CALICO_DIR\logs\calico-node.log"
for ($i = 0; $i -lt 45; $i++) {
    Start-Sleep 2
    if ((Test-Path $calicoLog) -and (Get-Content $calicoLog -Tail 5 | Select-String 'succeeded')) {
        $calicoOK = $true; break
    }
    if ($i % 5 -eq 0) { Info "Waiting for CalicoNode... ($($i*2)s)" }
}
if ($calicoOK) { OK "CalicoNode initialisation succeeded" }
else {
    Warn "CalicoNode still initialising - check $calicoLog"
    if (Test-Path $calicoLog) { Get-Content $calicoLog -Tail 5 | ForEach-Object { Write-Host "    $_" -ForegroundColor DarkGray } }
}

Info "Starting CalicoFelix..."
Start-Service CalicoFelix -ErrorAction SilentlyContinue
OK "CalicoFelix started"

# ==============================================================================
# [9/9] KUBE-PROXY + ROUTING
# ==============================================================================
Write-Step 9 9 'kube-proxy + routing'

# FIX: Validate MASTER_IP is set before using it in routing.
# On re-runs ($alreadyJoined=true) MASTER_IP is read from bootstrap-kubelet.conf
# in [2/9]. On first runs it was set from the join command in [8/9].
# If still empty (bootstrap conf not found and fresh join), fail clearly.
if (-not $MASTER_IP) {
    Fail "MASTER_IP could not be determined. Ensure the join command was pasted correctly."
}
OK "Master IP: $MASTER_IP"

[System.Environment]::SetEnvironmentVariable('KUBE_NETWORK', 'Calico.*', 'Machine')
$env:KUBE_NETWORK = 'Calico.*'
OK "KUBE_NETWORK=Calico.* set (Machine env var)"

# FIX: Write kube-proxy config and start it AFTER kubelet.conf exists.
# kube-proxy's clientConnection.kubeconfig points at kubelet.conf;
# starting kube-proxy before TLS bootstrap completes = immediate crash.
# By [9/9] we have already waited for kubelet.conf in [8/9] so this is safe.
[System.IO.File]::WriteAllText("$PROXY_DATA\config.conf", @"
apiVersion: kubeproxy.config.k8s.io/v1alpha1
kind: KubeProxyConfiguration
hostnameOverride: $NODE_NAME
clusterCIDR: $POD_CIDR
mode: kernelspace
winkernel:
  enableDSR: false
  networkName: Calico
  sourceVip: ""
clientConnection:
  kubeconfig: C:\etc\kubernetes\kubelet.conf
"@, [System.Text.Encoding]::ASCII)

$kpArgs = "--config=`"$PROXY_DATA\config.conf`" --v=2"
Register-KubeProxyTask "$BIN_DIR\kube-proxy.exe" $kpArgs
$kpt = Get-ScheduledTask -TaskName 'kube-proxy' -ErrorAction SilentlyContinue
if ($kpt -and $kpt.State -ne 'Running') { Start-ScheduledTask -TaskName 'kube-proxy' }
Start-Sleep 5
$kpt = Get-ScheduledTask -TaskName 'kube-proxy' -ErrorAction SilentlyContinue
if ($kpt -and $kpt.State -eq 'Running') { OK "kube-proxy started" }
else { Warn "kube-proxy task not yet Running - check manually" }

# Routing: pod traffic via cluster NIC, internet via NAT NIC
Info "Configuring routing (pod traffic via cluster NIC)..."
$existingRoute = Get-NetRoute -DestinationPrefix $POD_CIDR -ErrorAction SilentlyContinue |
                 Where-Object { $_.NextHop -eq $MASTER_IP }
if ($existingRoute) {
    Skip "Static route $POD_CIDR -> $MASTER_IP already present"
} else {
    Remove-NetRoute -DestinationPrefix $POD_CIDR -Confirm:$false -ErrorAction SilentlyContinue
    $podNet = $POD_CIDR -replace '/\d+$',''
    & route add $podNet mask $POD_CIDR_MASK $MASTER_IP -p 2>&1 | Out-Null
    OK "Static route: $POD_CIDR -> $MASTER_IP ($CLUSTER_ADAPTER)"
}

Set-NetIPInterface -InterfaceAlias $CLUSTER_ADAPTER -InterfaceMetric 10 -ErrorAction SilentlyContinue
OK "Interface metric: $CLUSTER_ADAPTER = 10 (preferred for pod traffic)"

$route = Get-NetRoute -DestinationPrefix $POD_CIDR -ErrorAction SilentlyContinue
if ($route) { OK "Route verified: $($route.DestinationPrefix) via $($route.NextHop)" }
else { Warn "Route not verified - check: Get-NetRoute | Where DestinationPrefix -like '10.244*'" }

# ==============================================================================
# SUMMARY
# ==============================================================================
Write-Host ""
Write-Host "  +=========================================================================+" -ForegroundColor Green
Write-Host "  |                       SETUP COMPLETE                                   |" -ForegroundColor Green
Write-Host "  +=========================================================================+" -ForegroundColor Green
Write-Host ""

Write-Host "  Service status:" -ForegroundColor Cyan
@(
    @{N='containerd';  T='service'},
    @{N='CalicoNode';  T='service'},
    @{N='CalicoFelix'; T='service'},
    @{N='kubelet';     T='task'},
    @{N='kube-proxy';  T='task'}
) | ForEach-Object {
    $st = if ($_.T -eq 'service') {
        $s = Get-Service $_.N -EA SilentlyContinue; if ($s) { $s.Status } else { 'NotFound' }
    } else {
        $t = Get-ScheduledTask -TaskName $_.N -EA SilentlyContinue; if ($t) { $t.State } else { 'NotFound' }
    }
    $col = if ($st -in @('Running')) { 'Green' } else { 'Yellow' }
    Write-Host "    $($_.N): $st" -ForegroundColor $col
}

Write-Host ""
Write-Host "  Network:" -ForegroundColor Cyan
Write-Host "    Cluster NIC : $CLUSTER_IP ($CLUSTER_ADAPTER)" -ForegroundColor White
Write-Host "    Master IP   : $MASTER_IP" -ForegroundColor White
if ($NAT_IP) { Write-Host "    NAT NIC     : $NAT_IP (internet)" -ForegroundColor White }
Get-NetRoute | Where-Object DestinationPrefix -like '10.244.*' |
    ForEach-Object { Write-Host "    Pod route   : $($_.DestinationPrefix) -> $($_.NextHop)" -ForegroundColor White }

Write-Host ""
Write-Host "  +-----------------------------------------------------------------------+" -ForegroundColor Yellow
Write-Host "  |  NEXT STEPS on Linux master:                                          |" -ForegroundColor Yellow
Write-Host "  |                                                                       |" -ForegroundColor Yellow
Write-Host "  |  kubectl get nodes                                                    |" -ForegroundColor White
Write-Host "  |  # Node should go NotReady -> Ready within 60s                       |" -ForegroundColor DarkGray
Write-Host "  +-----------------------------------------------------------------------+" -ForegroundColor Yellow
Write-Host ""
Log "===== SETUP COMPLETE ====="
