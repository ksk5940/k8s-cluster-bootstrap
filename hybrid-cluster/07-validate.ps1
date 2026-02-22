#Requires -RunAsAdministrator
<#
.SYNOPSIS
    07-validate.ps1
    Hybrid Cluster Validation - Run on Windows Worker Node
.EXAMPLE
    powershell -ExecutionPolicy Bypass -File 07-validate.ps1
#>

$ErrorActionPreference = 'SilentlyContinue'
$FAILURES = 0

function Pass($m) { Write-Host "  [PASS]  $m" -ForegroundColor Green }
function Fail($m) { Write-Host "  [FAIL]  $m" -ForegroundColor Red; $script:FAILURES++ }
function Info($m) { Write-Host "  [INFO]  $m" -ForegroundColor Cyan }

Write-Host ""
Write-Host "  +================================================================+" -ForegroundColor Cyan
Write-Host "  |          WINDOWS NODE VALIDATION                               |" -ForegroundColor Cyan
Write-Host "  +================================================================+" -ForegroundColor Cyan
Write-Host ""

# =============================================================================
Write-Host "  [1/5] Services running" -ForegroundColor Cyan
# =============================================================================
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
    if ($st -eq 'Running') { Pass "$($_.N): Running" }
    else { Fail "$($_.N): $st (expected Running)" }
}

# =============================================================================
Write-Host ""
Write-Host "  [2/5] kubelet healthz" -ForegroundColor Cyan
# =============================================================================
try {
    $r = Invoke-WebRequest http://127.0.0.1:10248/healthz -UseBasicParsing -EA Stop
    if ($r.StatusCode -eq 200) { Pass "kubelet healthz: OK" }
    else { Fail "kubelet healthz: HTTP $($r.StatusCode)" }
} catch { Fail "kubelet healthz: not responding ($_)" }

# =============================================================================
Write-Host ""
Write-Host "  [3/5] HNS Calico network" -ForegroundColor Cyan
# =============================================================================
$calico = Get-HnsNetwork | Where-Object Name -eq 'Calico'
if ($calico) {
    Pass "HNS Calico network exists (Type: $($calico.Type))"
    Info "  Subnet       : $($calico.Subnets.AddressPrefix)"
    Info "  ManagementIP : $($calico.ManagementIP)"
} else { Fail "HNS Calico network NOT found" }

# =============================================================================
Write-Host ""
Write-Host "  [4/5] Routing (pod traffic must use cluster NIC)" -ForegroundColor Cyan
# =============================================================================
$route = Get-NetRoute | Where-Object { $_.DestinationPrefix -like '10.244.*' }
if ($route) {
    Pass "Pod CIDR route exists: $($route.DestinationPrefix) -> $($route.NextHop) ($($route.InterfaceAlias))"
    # Verify source IP for pod CIDR traffic
    $srcAddr = $null
    try {
        $conn = Find-NetRoute -RemoteIPAddress '10.244.0.1' -EA Stop
        $srcAddr = $conn.IPAddress
    } catch {}
    if ($srcAddr -like '192.168.*') {
        Pass "Pod traffic source IP: $srcAddr (cluster NIC - correct)"
    } elseif ($srcAddr) {
        Fail "Pod traffic source IP: $srcAddr (expected 192.168.x.x - wrong NIC!)"
    }
} else { Fail "No route for pod CIDR 10.244.0.0/16" }

$defaultRoute = Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Sort-Object RouteMetric | Select-Object -First 1
Info "Default route: $($defaultRoute.NextHop) ($($defaultRoute.InterfaceAlias)) metric=$($defaultRoute.RouteMetric)"

# =============================================================================
Write-Host ""
Write-Host "  [5/5] Connectivity tests" -ForegroundColor Cyan
# =============================================================================
$masterIP = (Get-NetRoute | Where-Object { $_.DestinationPrefix -like '10.244.*' } | Select-Object -First 1).NextHop
if ($masterIP) {
    $ping = Test-Connection $masterIP -Count 2 -Quiet -EA SilentlyContinue
    if ($ping) { Pass "Ping master ($masterIP): OK" }
    else { Fail "Ping master ($masterIP): FAILED" }

    $tcp = Test-NetConnection $masterIP -Port 6443 -EA SilentlyContinue
    if ($tcp.TcpTestSucceeded) { Pass "API server ($masterIP:6443): reachable" }
    else { Fail "API server ($masterIP:6443): NOT reachable" }
}

$internet = Test-NetConnection 'google.com' -Port 443 -EA SilentlyContinue
if ($internet.TcpTestSucceeded) {
    Pass "Internet (google.com:443): OK (source: $($internet.SourceAddress.IPAddress))"
    if ($internet.SourceAddress.IPAddress -like '172.16.*') {
        Pass "Internet uses NAT NIC (correct)"
    }
} else { Info "Internet test: skipped (no connectivity or firewall)" }

# =============================================================================
Write-Host ""
Write-Host "  CNI config:" -ForegroundColor Cyan
# =============================================================================
$cniConf = 'C:\k\cni\config\10-calico.conf'
if (Test-Path $cniConf) { Pass "CNI config present: $cniConf" }
else { Fail "CNI config missing: $cniConf" }

$cniBin = Get-ChildItem 'C:\k\cni\bin\calico.exe' -EA SilentlyContinue
if ($cniBin) { Pass "CNI binary present: calico.exe" }
else { Fail "CNI binary missing: C:\k\cni\bin\calico.exe" }

# =============================================================================
Write-Host ""
if ($FAILURES -eq 0) {
    Write-Host "  +--------------------------------------------------+" -ForegroundColor Green
    Write-Host "  |  ALL CHECKS PASSED - Windows node is healthy!    |" -ForegroundColor Green
    Write-Host "  +--------------------------------------------------+" -ForegroundColor Green
} else {
    Write-Host "  +--------------------------------------------------+" -ForegroundColor Red
    Write-Host "  |  $FAILURES CHECK(S) FAILED - see output above     |" -ForegroundColor Red
    Write-Host "  +--------------------------------------------------+" -ForegroundColor Red
    Write-Host ""
    Write-Host "  Troubleshooting:" -ForegroundColor Yellow
    Write-Host "    Calico log   : Get-Content C:\calico\CalicoWindows\logs\calico-node.log -Tail 20" -ForegroundColor White
    Write-Host "    kubelet log  : Get-EventLog -LogName System -Source kubelet -Newest 10" -ForegroundColor White
    Write-Host "    kube-proxy   : Get-ScheduledTask kube-proxy | Select State" -ForegroundColor White
    Write-Host "    Routes       : Get-NetRoute | Where DestinationPrefix -like '10*'" -ForegroundColor White
}
Write-Host ""
