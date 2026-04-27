# k8s-cluster-bootstrap

Automated Kubernetes cluster lifecycle management via Jenkins.  
Supports **bootstrap · destroy · reset · upgrade** on any Linux distribution.

---

## Supported Operating Systems

| Family | Distributions |
|---|---|
| **Debian / Ubuntu** | Ubuntu 20.04, 22.04, 24.04 · Debian 10/11/12 · Raspberry Pi OS · Kali |
| **RHEL / CentOS** | Rocky Linux 8/9 · AlmaLinux 8/9 · RHEL 8/9 · CentOS Stream 8/9 · Fedora 36+ |
| **SUSE** | openSUSE Leap 15 · SLES 15 |

Container runtimes: `containerd` (default) · `cri-o`  
CNI plugins: `calico` (default) · `flannel` · `weave`

---

## File Overview

```
hybrid-cluster/
├── Jenkinsfile                    ← Main pipeline (all 4 actions)
├── 00-set-static-ip-hostname.sh  ← Static IP + hostname setup
├── 01-linux-master-setup.sh      ← Control-plane bootstrap
├── 02-linux-worker-setup.sh      ← Worker node bootstrap
├── 03-linux-destroy.sh           ← Full node teardown
├── 04-linux-upgrade.sh           ← In-place version upgrade
└── 07-validate.sh                ← Post-install validation
```

---

## Part 1 — Set Static IP and Hostname on Each Node

Run this **before** running the Jenkins pipeline. You can do it manually or let Jenkins do it automatically (enable the `SET_STATIC_IP` parameter).

### Manual (recommended for first-time setup)

SSH into each node and run:

```bash
# On the master node
sudo STATIC_IP=192.168.56.11 \
     GATEWAY=192.168.56.1 \
     NEW_HOSTNAME=k8s-master \
     NODE_ROLE=master \
     bash /path/to/00-set-static-ip-hostname.sh

# On worker-1
sudo STATIC_IP=192.168.56.12 \
     GATEWAY=192.168.56.1 \
     NEW_HOSTNAME=k8s-worker-1 \
     NODE_ROLE=worker \
     bash /path/to/00-set-static-ip-hostname.sh

# On worker-2
sudo STATIC_IP=192.168.56.13 \
     GATEWAY=192.168.56.1 \
     NEW_HOSTNAME=k8s-worker-2 \
     NODE_ROLE=worker \
     bash /path/to/00-set-static-ip-hostname.sh
```

### Environment variables for the static IP script

| Variable | Default | Description |
|---|---|---|
| `STATIC_IP` | **required** | Target static IP address |
| `GATEWAY` | auto-detect | Network gateway (router IP) |
| `DNS_SERVERS` | `8.8.8.8 1.1.1.1` | Space-separated DNS servers |
| `PREFIX_LENGTH` | `24` | Subnet prefix length (24 = /24 = 255.255.255.0) |
| `NETWORK_IFACE` | auto-detect | NIC name (e.g. `eth0`, `ens33`, `enp0s3`) |
| `NEW_HOSTNAME` | unchanged | Desired hostname for this node |
| `NODE_ROLE` | `worker` | Informational: `master` or `worker` |

The script auto-detects the network manager (`netplan`, `nmcli`, `wicked`, `dhcpcd`, `ifupdown`) and applies the correct configuration. It is **idempotent** — safe to run multiple times.

### Verify after running

```bash
ip addr show          # Check IP is applied
hostname              # Check hostname is set
ping 8.8.8.8 -c 3    # Check internet access
```

---

## Part 2 — Jenkins Setup

### Step 1: Install Jenkins

```bash
# Ubuntu/Debian
sudo apt-get update && sudo apt-get install -y openjdk-17-jdk
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key | sudo tee \
  /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" | sudo tee \
  /etc/apt/sources.list.d/jenkins.list > /dev/null
sudo apt-get update && sudo apt-get install -y jenkins
sudo systemctl enable --now jenkins

# RHEL/Rocky
sudo dnf install -y java-17-openjdk
sudo wget -O /etc/yum.repos.d/jenkins.repo https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo dnf install -y jenkins
sudo systemctl enable --now jenkins
```

Jenkins runs on port `8080`. Unlock with:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

### Step 2: Install Required Jenkins Plugins

Go to **Manage Jenkins → Plugins → Available** and install:

| Plugin | Purpose |
|---|---|
| **SSH Pipeline Steps** | `sshCommand` / `sshPut` used by the pipeline |
| **Credentials Binding** | `withCredentials` block |
| **Pipeline** | Core pipeline support |
| **Git** | Pull Jenkinsfile from GitHub |
| **Timestamper** | Adds timestamps to console output |
| **AnsiColor** *(optional)* | Colored console output |

### Step 3: Add SSH Credentials

1. Go to **Manage Jenkins → Credentials → System → Global credentials**
2. Click **Add Credentials**
3. Fill in:
   - **Kind**: Username with password
   - **ID**: `K8S_SSH_CREDS` *(must match the pipeline default)*
   - **Username**: `k8sadmin` *(your SSH user on nodes)*
   - **Password**: your sudo-capable user's password
4. Click **Save**

> The SSH user must have **passwordless sudo** (`NOPASSWD`). Add this on each node:
> ```bash
> echo "k8sadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/k8sadmin
> sudo chmod 0440 /etc/sudoers.d/k8sadmin
> ```

### Step 4: Create the Jenkins Pipeline Job

1. Click **New Item** → name it `k8s-cluster-bootstrap` → select **Pipeline** → OK
2. Under **Pipeline**:
   - **Definition**: Pipeline script from SCM
   - **SCM**: Git
   - **Repository URL**: `https://github.com/ksk5940/k8s-cluster-bootstrap.git`
   - **Branch**: `*/main`
   - **Script Path**: `hybrid-cluster/Jenkinsfile`
3. Click **Save**

### Step 5: Run the Pipeline

1. Click **Build with Parameters**
2. Fill in the parameters:

| Parameter | Example | Notes |
|---|---|---|
| `ACTION` | `bootstrap` | bootstrap / destroy / reset / upgrade |
| `MASTER_IP` | `192.168.56.11` | Control-plane node IP |
| `WORKER_IPS` | `192.168.56.12,192.168.56.13` | Comma-separated |
| `SSH_USER` | `k8sadmin` | Must have NOPASSWD sudo |
| `SSH_CREDS_ID` | `K8S_SSH_CREDS` | Jenkins credential ID |
| `RUNTIME` | `containerd` | containerd or crio |
| `CNI_PLUGIN` | `calico` | calico, flannel, or weave |
| `K8S_VERSION` | `1.32.3` | Target version |
| `POD_CIDR` | `10.244.0.0/16` | Pod network CIDR |
| `SET_STATIC_IP` | `false` | Set to true to auto-configure static IPs |

3. Click **Build**

---

## Part 3 — Pipeline Actions Explained

### `bootstrap`

Provisions a brand-new cluster:

1. SSH connectivity check (all nodes in parallel)
2. Optionally sets static IP + hostname
3. Installs container runtime + Kubernetes on master
4. Runs `kubeadm init` and installs CNI
5. Extracts the join command
6. Installs runtime + K8s on all workers, joins them
7. Waits for all nodes to be `Ready`

### `destroy`

Full teardown on all nodes (parallel):

- `kubeadm reset`
- Removes: kubelet, kubeadm, kubectl, containerd/crio
- Removes: CNI (calico/flannel/weave interfaces + iptables)
- Removes: all repos, keyrings, systemd units, logs, temp files
- Flushes: iptables, ip6tables, ipvs, pod routes

### `reset`

Runs `destroy` then `bootstrap` — clean re-provision in one pipeline run.  
Useful when cluster state is corrupted or you need a full fresh start.

### `upgrade`

Version-gap aware in-place upgrade.

**Key rule**: Kubernetes only supports upgrading **one minor version at a time**.  
If you are on `1.30.x` and want `1.32.x`, the pipeline automatically upgrades:
`1.30.x → 1.31.0 → 1.32.3`

Upgrade flow per node:
1. Updates apt/dnf repo to target minor version
2. Upgrades `kubeadm`, runs `kubeadm upgrade apply` (master) or `kubeadm upgrade node` (workers)
3. Drains the node
4. Upgrades `kubelet` + `kubectl`
5. Restarts kubelet
6. Uncordons the node

Master is always upgraded before workers. Workers run in parallel per hop.

---

## Part 4 — Standalone Script Usage (Without Jenkins)

All scripts can be run directly on the target machines.

### Bootstrap master node

```bash
sudo MASTER_IP=192.168.56.11 \
     K8S_VERSION=1.32.3 \
     RUNTIME=containerd \
     CNI_PLUGIN=calico \
     POD_CIDR=10.244.0.0/16 \
     SETUP_USER=k8sadmin \
     bash 01-linux-master-setup.sh
```

### Bootstrap worker node

```bash
sudo K8S_VERSION=1.32.3 \
     RUNTIME=containerd \
     JOIN_COMMAND="kubeadm join 192.168.56.11:6443 --token abc123 --discovery-token-ca-cert-hash sha256:..." \
     NODE_IP=192.168.56.12 \
     SETUP_USER=k8sadmin \
     bash 02-linux-worker-setup.sh
```

### Destroy a node

```bash
sudo RUNTIME=containerd \
     CNI_PLUGIN=calico \
     bash 03-linux-destroy.sh
```

### Upgrade a node

```bash
# On master
sudo K8S_VERSION=1.31.0 NODE_ROLE=master RUNTIME=containerd bash 04-linux-upgrade.sh
sudo K8S_VERSION=1.32.3 NODE_ROLE=master RUNTIME=containerd bash 04-linux-upgrade.sh

# On each worker
sudo K8S_VERSION=1.31.0 NODE_ROLE=worker RUNTIME=containerd MASTER_IP=192.168.56.11 bash 04-linux-upgrade.sh
```

---

## Part 5 — Troubleshooting

### Jenkins: `synchronized is unsupported for CPS transformation`

**Fixed in this version.** The original `synchronized(timings)` blocks were replaced with a `@NonCPS`-annotated helper method `recordTiming()`. Do not use `synchronized` anywhere inside Jenkins CPS pipelines.

### Nodes stuck in `NotReady`

```bash
# On master
kubectl get nodes
kubectl describe node <node-name>
kubectl get pods -n kube-system

# Check kubelet
sudo journalctl -u kubelet -n 50 --no-pager

# Check containerd
sudo journalctl -u containerd -n 50 --no-pager
```

### kubeadm init fails: port already in use

The destroy script cleans these up. If running manually:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd
```

### SSH connection refused from Jenkins

- Verify the node is running and port 22 is open
- Verify the credential ID matches what's in Jenkins
- Verify the user has NOPASSWD sudo:
  ```bash
  sudo -n whoami   # should print: root
  ```

### Upgrade stuck: node not draining

Pods with PodDisruptionBudgets can block drain. Force it:

```bash
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data --force --disable-eviction
```

---

## Part 6 — Architecture Overview

```
Jenkins Agent
     │
     ├── SSH ──► Master Node (192.168.56.11)
     │              kubeadm init
     │              CNI install
     │              join command
     │
     ├── SSH ──► Worker-1 (192.168.56.12)
     │              kubeadm join
     │
     └── SSH ──► Worker-2 (192.168.56.13)
                    kubeadm join
```

Workers are always provisioned in **parallel** to minimize total time. The master must complete and produce a join command before workers start.

---

## Part 7 — Security Notes

- This setup is designed for **lab / dev environments**. The firewall is disabled on all nodes for simplicity.
- For production: enable firewall, restrict sudo, use SSH key auth instead of password, use a private CA.
- The join token expires after 24 hours — re-running bootstrap generates a fresh one.
- Credentials are never written to disk; they are passed via Jenkins `withCredentials` and exported as env vars.
