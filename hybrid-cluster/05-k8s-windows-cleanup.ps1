#Requires -RunAsAdministrator
<#
.SYNOPSIS
    05-k8s-windows-cleanup.ps1
    Full cleanup of all Kubernetes and Calico state on this Windows node.

.DESCRIPTION
    Run this before every fresh join attempt.
    After running this, also run on the Linux master:
        kubectl delete node <node-name>
        kubectl delete caliconodes.crd.projectcalico.org <node-name>
        kubeadm token create --print-join-command

    Fix applied vs original:
      - HNS network removal extended to include 'vxlan0' and 'External'
        ghost networks left by failed Calico installs on WS2022 that block
        re-join attempts ("network already exists" error).

.EXAMPLE
    powershell -ExecutionPolicy Bypass -File 05-k8s-windows-cleanup.ps1
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$NODE_NAME = $env:COMPUTERNAME.ToLower()
$NSSM      = 'C:\calico\CalicoWindows\nssm\win64\nssm.exe'

# ==============================================================================
# HELPERS
# ==============================================================================
function OK($m)   { Write-Host "  [OK]   $m" -ForegroundColor Green }
function Skip($m) { Write-Host "  [SKIP] $m" -ForegroundColor Yellow }
function Info($m) { Write-Host "  [....] $m" -ForegroundColor Gray }
function Warn($m) { Write-Host "  [WARN] $m" -ForegroundColor Yellow }
function Fail($m) { Write-Host "  [FAIL] $m" -ForegroundColor Red; exit 1 }

# ==============================================================================
# BANNER + CONFIRMATION
# ==============================================================================
Write-Host ""
Write-Host "  +============================================================+" -ForegroundColor Cyan
Write-Host "  |        WINDOWS K8S WORKER - FULL CLEANUP                   |" -ForegroundColor Cyan
Write-Host "  +============================================================+" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Node: $NODE_NAME" -ForegroundColor DarkGray
Write-Host ""
Write-Host "  This will stop and remove:" -ForegroundColor Yellow
Write-Host "    - kubelet, kube-proxy, CalicoNode, CalicoFelix, containerd" -ForegroundColor White
Write-Host "    - All scheduled tasks and NSSM/SC services" -ForegroundColor White
Write-Host "    - HNS networks (Calico, nat, cbr0, vxlan0, External)" -ForegroundColor White
Write-Host "    - All config under C:\etc\kubernetes, C:\var\lib\kubelet, C:\var\lib\kube-proxy" -ForegroundColor White
Write-Host "    - Pod and service routes" -ForegroundColor White
Write-Host ""

$ans = Read-Host "  Proceed with full cleanup? [y/N]"
if ($ans -notmatch '^[Yy]') {
    Write-Host "  Cancelled." -ForegroundColor Yellow
    exit 0
}
Write-Host ""

# ==============================================================================
# [1/7] Stop all services and processes
# ==============================================================================
Write-Host "  [1/7] Stopping services and processes" -ForegroundColor Cyan
Write-Host "  $('-'*60)" -ForegroundColor DarkGray

Info "Stopping Calico services..."
Stop-Service CalicoFelix -Force -ErrorAction SilentlyContinue
Stop-Service CalicoNode  -Force -ErrorAction SilentlyContinue
Stop-Service containerd  -Force -ErrorAction SilentlyContinue

Info "Stopping scheduled tasks..."
Stop-ScheduledTask -TaskName 'kubelet'    -ErrorAction SilentlyContinue
Stop-ScheduledTask -TaskName 'kube-proxy' -ErrorAction SilentlyContinue

Info "Killing any remaining processes..."
Get-Process kubelet    -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Get-Process kube-proxy -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

Start-Sleep 3
OK "Services and processes stopped"

# ==============================================================================
# [2/7] Remove scheduled tasks
# ==============================================================================
Write-Host ""
Write-Host "  [2/7] Removing scheduled tasks" -ForegroundColor Cyan
Write-Host "  $('-'*60)" -ForegroundColor DarkGray

foreach ($task in @('kubelet','kube-proxy')) {
    if (Get-ScheduledTask -TaskName $task -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $task -Confirm:$false -ErrorAction SilentlyContinue
        OK "Scheduled task removed: $task"
    } else {
        Skip "Scheduled task not found: $task"
    }
}

# ==============================================================================
# [3/7] Remove NSSM / SC services
# ==============================================================================
Write-Host ""
Write-Host "  [3/7] Removing NSSM and SC services" -ForegroundColor Cyan
Write-Host "  $('-'*60)" -ForegroundColor DarkGray

if (Test-Path $NSSM) {
    foreach ($svc in @('CalicoNode','CalicoFelix','kube-proxy')) {
        & $NSSM remove $svc confirm 2>&1 | Out-Null
        OK "NSSM service removed: $svc"
    }
} else {
    Skip "NSSM not found - skipping NSSM service removal"
}

foreach ($svc in @('kubelet','kube-proxy')) {
    if (Get-Service $svc -ErrorAction SilentlyContinue) {
        & sc.exe delete $svc 2>&1 | Out-Null
        OK "SC service removed: $svc"
    } else {
        Skip "SC service not present: $svc"
    }
}

# ==============================================================================
# [4/7] Remove HNS networks
# ==============================================================================
Write-Host ""
Write-Host "  [4/7] Removing HNS networks" -ForegroundColor Cyan
Write-Host "  $('-'*60)" -ForegroundColor DarkGray

# FIX: Added 'vxlan0' and 'External' to the removal list.
# On WS2022, a failed or partial Calico install leaves a 'vxlan0' HNS network
# that is NOT cleaned up by the Calico uninstaller.  On the next join attempt,
# Calico's install-calico.ps1 tries to create the same network and gets:
#   "HNS failed with error: The parameter is incorrect"
# or "network already exists" — blocking the entire install.
# 'External' is created by some containerd versions and also blocks re-creates.
$hnsToRemove = @('Calico','nat','cbr0','vxlan0','External')

$removedAny = $false
foreach ($netName in $hnsToRemove) {
    $hnsNet = Get-HnsNetwork -ErrorAction SilentlyContinue |
              Where-Object { $_.Name -eq $netName }
    if ($hnsNet) {
        $hnsNet | ForEach-Object {
            $_ | Remove-HnsNetwork -ErrorAction SilentlyContinue
            OK "HNS network removed: $netName"
            $removedAny = $true
        }
    }
}
if (-not $removedAny) {
    Skip "No matching HNS networks found (Calico/nat/cbr0/vxlan0/External)"
}

# Give HNS time to settle after network removal — vSwitch teardown is async
# on WS2022 and the next containerd start can race against it.
if ($removedAny) { Start-Sleep 3 }

# ==============================================================================
# [5/7] Remove routes
# ==============================================================================
Write-Host ""
Write-Host "  [5/7] Removing pod and service routes" -ForegroundColor Cyan
Write-Host "  $('-'*60)" -ForegroundColor DarkGray

foreach ($prefix in @('10.244.0.0/16','10.96.0.0/12')) {
    if (Get-NetRoute -DestinationPrefix $prefix -ErrorAction SilentlyContinue) {
        Remove-NetRoute -DestinationPrefix $prefix -Confirm:$false -ErrorAction SilentlyContinue
        OK "Route removed: $prefix"
    } else {
        Skip "Route not present: $prefix"
    }
}

# ==============================================================================
# [6/7] Remove config directories and state
# ==============================================================================
Write-Host ""
Write-Host "  [6/7] Removing config directories and state" -ForegroundColor Cyan
Write-Host "  $('-'*60)" -ForegroundColor DarkGray

foreach ($d in @('C:\etc\kubernetes','C:\var\lib\kubelet','C:\var\lib\kube-proxy')) {
    if (Test-Path $d) {
        Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue
        OK "Removed: $d"
    } else {
        Skip "Not present: $d"
    }
}

$cniConf = 'C:\k\cni\config'
if (Test-Path $cniConf) {
    Remove-Item "$cniConf\*" -Force -ErrorAction SilentlyContinue
    OK "CNI config dir cleared: $cniConf"
} else {
    Skip "CNI config dir not present: $cniConf"
}

if (Test-Path 'C:\k\bin\kubeadm.exe') {
    & 'C:\k\bin\kubeadm.exe' reset --force 2>&1 | Out-Null
    OK "kubeadm reset complete"
} else {
    Skip "kubeadm.exe not found - skipping reset"
}

# ==============================================================================
# [7/7] Restart containerd cleanly
# ==============================================================================
Write-Host ""
Write-Host "  [7/7] Restarting containerd" -ForegroundColor Cyan
Write-Host "  $('-'*60)" -ForegroundColor DarkGray

$cdSvc = Get-Service containerd -ErrorAction SilentlyContinue
if ($cdSvc) {
    Start-Service containerd -ErrorAction SilentlyContinue

    $socketWait = 0
    while (-not (Test-Path '\\.\pipe\containerd-containerd') -and $socketWait -lt 30) {
        Start-Sleep 1; $socketWait++
    }
    if (Test-Path '\\.\pipe\containerd-containerd') {
        OK "containerd restarted and pipe ready"
    } else {
        Warn "containerd started but pipe not ready after 30s - check manually"
    }
} else {
    Skip "containerd service not installed - nothing to restart"
}

# ==============================================================================
# SUMMARY
# ==============================================================================
Write-Host ""
Write-Host "  +------------------------------------------------------------+" -ForegroundColor Green
Write-Host "  |  Cleanup complete. Now on Linux master run:                |" -ForegroundColor Green
Write-Host "  |                                                            |" -ForegroundColor Green
Write-Host "  |  NODE=$NODE_NAME" -ForegroundColor White
Write-Host "  |  kubectl delete node `$NODE 2>/dev/null                    |" -ForegroundColor White
Write-Host "  |  kubectl delete caliconodes.crd.projectcalico.org \       |" -ForegroundColor White
Write-Host "  |    `$NODE 2>/dev/null                                      |" -ForegroundColor White
Write-Host "  |  kubeadm token create --print-join-command                |" -ForegroundColor White
Write-Host "  |                                                            |" -ForegroundColor Green
Write-Host "  |  Then run: 06-k8s-windows-worker-join.ps1                 |" -ForegroundColor Green
Write-Host "  +------------------------------------------------------------+" -ForegroundColor Green
Write-Host ""