# Hybrid Kubernetes Cluster — Linux + Windows
## Complete Setup Guide with All Known Issues Fixed

## For Jenkins Automation 
#### Create user with bash shell (needed for SSH commands)
useradd -m -s /bin/bash k8sadmin

#### Set a password (Jenkins uses this for SSH auth)
echo "k8sadmin:StrongPassword123" | chpasswd

#### Grant passwordless sudo
echo "k8sadmin ALL=(ALL) NOPASSWD:ALL" | tee /etc/sudoers.d/k8sadmin
chmod 440 /etc/sudoers.d/k8sadmin

#### Lock interactive terminal login (can't login via console/TTY)
#### But SSH remote commands still work
echo "k8sadmin" | tee -a /etc/security/access.conf
cat >> /etc/security/access.conf <<EOF
-:k8sadmin:LOCAL
EOF

#### Verify sudo works
su -s /bin/bash k8sadmin -c "sudo whoami"
#### Should print: root

---

## Architecture

| Node         | OS                  | IP             | Role          |
|-------------|---------------------|----------------|---------------|
| k8s-master   | Ubuntu 22.04        | 192.168.56.11  | control-plane |
| ubuntu-node  | Ubuntu 22.04        | 192.168.56.12  | worker        |
| rocky-node   | Rocky Linux 9       | 192.168.56.13  | worker        |
| win-node     | Windows Server 2022 | 192.168.56.14  | worker        |

| Parameter      | Value            |
|---------------|------------------|
| Pod CIDR       | 10.244.0.0/16    |
| Service CIDR   | 10.96.0.0/12     |
| Cluster DNS    | 10.96.0.10       |
| CNI            | Calico VXLAN     |
| K8s version    | 1.32.3           |
| Calico version | 3.29.3           |

---

## Files in This Package

```
01-linux-master-setup.sh       Linux master: install + kubeadm init + Calico + RBAC
02-linux-worker-setup.sh       Linux workers: install + join
05-k8s-windows-cleanup.ps1    Windows: full cleanup before fresh join
06-k8s-windows-worker-join.ps1 Windows: complete setup + join (all fixes applied)
07-validate.sh                 Linux master: cluster health check
07-validate.ps1                Windows: node health check
```

---

## Execution Order

### Step 1 — Linux Master

```bash
sudo bash 01-linux-master-setup.sh
```

What it does:
- Disables swap
- Sets kernel modules (overlay, br_netfilter)
- Sets sysctl including **rp_filter=0** (critical for Windows VXLAN)
- Installs ContainerD with SystemdCgroup=true
- Installs kubelet, kubeadm, kubectl
- Runs kubeadm init with pod-network-cidr and service-cidr
- Installs Calico
- Patches IPAMConfig: **strictAffinity=true** (Windows requirement)
- Applies RBAC for Windows node (Calico + kube-proxy)
- Prints join command

---

### Step 2 — Linux Workers (each node)

```bash
sudo bash 02-linux-worker-setup.sh
```

Paste the join command from Step 1 when prompted.

---

### Step 3 — Windows Node (cleanup first)

```powershell
powershell -ExecutionPolicy Bypass -File 05-k8s-windows-cleanup.ps1
```

Then on Linux master generate a fresh token:
```bash
kubectl delete node <win-node-name> 2>/dev/null
kubectl delete caliconodes.crd.projectcalico.org <win-node-name> 2>/dev/null
kubeadm token create --print-join-command
```

---

### Step 4 — Windows Node (join)

```powershell
powershell -ExecutionPolicy Bypass -File 06-k8s-windows-worker-join.ps1
```

When prompted:
1. Enter master IP: `192.168.56.11`
2. Paste the kubeadm join command

The script does everything automatically.

---

### Step 5 — Validate

On Linux master:
```bash
bash 07-validate.sh
```

On Windows:
```powershell
powershell -ExecutionPolicy Bypass -File 07-validate.ps1
```

---

## All Known Issues and Fixes

### Kubelet Issues

| Problem | Root Cause | Fix Applied |
|---------|-----------|-------------|
| Crash: `cgroupDriver: systemd` | systemd doesn't exist on Windows | `cgroupDriver: ""` in config.yaml |
| Crash: `/etc/resolv.conf` | File doesn't exist on Windows | `resolvConf: ""` in config.yaml |
| CNI not initialised | `--network-plugin` flag removed in K8s 1.24 | `cniBinDir`/`cniConfDir` in config.yaml |
| Bad cert paths in kubelet.conf | kubeadm writes relative paths | Post-bootstrap patch adds `C:\` prefix |
| Service timeout (Error 1053) | Windows SCM requires 30s response | Use scheduled task instead of sc.exe |
| `clientCAFile` path error | Missing `C:\` prefix | Full path written in config.yaml |

### Calico Issues

| Problem | Root Cause | Fix Applied |
|---------|-----------|-------------|
| ErrImagePull / platform mismatch | Linux image used for Windows | Native install via install-calico.ps1 |
| Wrong management IP (172.16.x) | NAT NIC selected | `VXLAN_ADAPTER` + `IP` set to cluster NIC |
| IPAM error: strictAffinity | Windows requires strict affinity | `kubectl patch ipamconfig` |
| CRD forbidden error | Missing RBAC for system:nodes | ClusterRoleBinding for calico-node |
| Env vars lost on reboot | NSSM doesn't persist session env | `nssm set AppEnvironmentExtra` |

### kube-proxy Issues

| Problem | Root Cause | Fix Applied |
|---------|-----------|-------------|
| Platform mismatch in DaemonSet | Linux image used | Installed as Windows binary + scheduled task |
| `KUBE_NETWORK not initialized` | Missing Machine env var | `[Environment]::SetEnvironmentVariable('KUBE_NETWORK','Calico.*','Machine')` |
| DNS failing in Windows pods | kube-proxy not running | kube-proxy as scheduled task |

### Networking / Routing Issues

| Problem | Root Cause | Fix Applied |
|---------|-----------|-------------|
| VXLAN packets dropped by Linux | rp_filter rejects asymmetric routes | `net.ipv4.conf.all.rp_filter=0` on all Linux nodes |
| Pod-to-pod comm fails | Pod traffic leaves via NAT NIC (172.16.x) instead of cluster NIC (192.168.x) | Static route: `10.244.0.0/16` via master on cluster NIC |
| Wrong source IP in connections | Default route via NAT NIC | Interface metric: cluster NIC metric=10 |

---

## Manual RBAC YAMLs (applied automatically by master script)

### Calico Windows RBAC

```yaml
# 03-calico-rbac-windows.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: calico-node-windows
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: calico-node
subjects:
- kind: Group
  name: system:nodes
  apiGroup: rbac.authorization.k8s.io
```

Apply:
```bash
kubectl apply -f 03-calico-rbac-windows.yaml
```

### kube-proxy Windows RBAC

```yaml
# 04-kube-proxy-rbac-windows.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: kube-proxy-windows
roleRef:
  apiGroup: rbac.authorization.k8s.io
  kind: ClusterRole
  name: system:node-proxier
subjects:
- kind: Group
  name: system:nodes
  apiGroup: rbac.authorization.k8s.io
```

Apply:
```bash
kubectl apply -f 04-kube-proxy-rbac-windows.yaml
```

### Strict Affinity (IPAMConfig patch)

```bash
kubectl patch ipamconfigs.crd.projectcalico.org default \
  --type=merge \
  -p '{"spec":{"strictAffinity":true,"autoAllocateBlocks":true}}'
```

---

## Verification Commands

### Linux Master

```bash
# Node status
kubectl get nodes -o wide

# All pods running
kubectl get pods -A

# Windows node Calico annotations
kubectl get node <win-node> -o jsonpath='{.metadata.annotations}' | python3 -m json.tool | grep calico

# IPAMConfig
kubectl get ipamconfigs.crd.projectcalico.org default -o yaml | grep -E 'strict|auto'

# Pod-to-pod test
kubectl exec -it <linux-pod> -- ping <windows-pod-ip>
```

### Windows Node

```powershell
# Service status
Get-Service CalicoNode, CalicoFelix, containerd
Get-ScheduledTask kubelet, kube-proxy | Select TaskName, State

# kubelet health
Invoke-WebRequest http://127.0.0.1:10248/healthz -UseBasicParsing

# HNS network
Get-HnsNetwork | Where Name -eq 'Calico' | Select Name, Type, ManagementIP

# Routing - pod traffic source MUST be 192.168.56.x
Find-NetRoute -RemoteIPAddress 10.244.0.1 | Select IPAddress

# Routing table
Get-NetRoute | Where DestinationPrefix -like '10.244*'

# Calico log
Get-Content C:\calico\CalicoWindows\logs\calico-node.log -Tail 20

# Expected connectivity:
Test-NetConnection 10.244.0.1 -Port 80     # pod traffic via 192.168.56.x
Test-NetConnection google.com -Port 443    # internet via 172.16.x.x
```

---

## Dual-NIC Routing Design

```
Windows node has two NICs:
  Ethernet0  192.168.56.14  (Host-Only / Kubernetes cluster)
  Ethernet1  172.16.56.14   (NAT / Internet)

Desired traffic flow:
  Pod traffic  (10.244.x.x) -> Ethernet0 -> 192.168.56.11 (master) -> overlay
  Internet     (0.0.0.0/0)  -> Ethernet1 -> 172.16.56.2 (NAT GW)

Fix applied:
  route add 10.244.0.0 mask 255.255.0.0 192.168.56.11 -p
  Set-NetIPInterface -InterfaceAlias Ethernet0 -InterfaceMetric 10
```

---

## Troubleshooting

### Node stuck NotReady

```bash
# Check node conditions
kubectl describe node <win-node> | grep -A10 Conditions

# Common causes:
# 1. CNI not initialised -> check kubelet config.yaml has cniBinDir/cniConfDir
# 2. NetworkUnavailable -> Calico not running -> check CalicoNode service
# 3. kubelet not reporting -> check scheduled task is Running
```

### Pod-to-pod fails after node is Ready

```powershell
# Check source IP for pod traffic
Find-NetRoute -RemoteIPAddress 10.244.0.1 | Select IPAddress
# Must show 192.168.56.14, not 172.16.56.14

# If wrong:
route add 10.244.0.0 mask 255.255.0.0 192.168.56.11 -p
```

```bash
# On Linux: check rp_filter
sysctl net.ipv4.conf.all.rp_filter
# Must be 0, not 1 or 2

# Fix:
sudo sysctl -w net.ipv4.conf.all.rp_filter=0
sudo sysctl -w net.ipv4.conf.default.rp_filter=0
```

### DNS fails in Windows pod

```powershell
# Check kube-proxy
Get-ScheduledTask kube-proxy | Select State
# Must be Running

# Check KUBE_NETWORK env var
[Environment]::GetEnvironmentVariable('KUBE_NETWORK', 'Machine')
# Must be "Calico.*"

# Check HNS network
Get-HnsNetwork | Select Name, Type
# Must show "Calico" type Overlay
```
