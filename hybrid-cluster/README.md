# k8s-cluster-bootstrap

Automated Kubernetes cluster lifecycle management via Jenkins CI/CD.  
Supports **bootstrap · destroy · reset · upgrade** on bare-metal and VM-based Linux nodes.

---

## Table of Contents

1. [Supported OS and Runtimes](#supported-os-and-runtimes)
2. [Repository Structure](#repository-structure)
3. [Step 0 — Pre-flight: Create the k8sadmin User](#step-0--pre-flight-create-the-k8sadmin-user)
4. [Step 1 — Set Static IP and Hostname on Each Node](#step-1--set-static-ip-and-hostname-on-each-node)
5. [Step 2 — Jenkins Setup](#step-2--jenkins-setup)
6. [Step 3 — Create Jenkins Pipeline Job](#step-3--create-jenkins-pipeline-job)
7. [Step 4 — Run the Pipeline](#step-4--run-the-pipeline)
8. [Pipeline Actions Explained](#pipeline-actions-explained)
9. [Standalone Script Usage (Without Jenkins)](#standalone-script-usage-without-jenkins)
10. [Troubleshooting](#troubleshooting)
11. [Bug Fixes Changelog](#bug-fixes-changelog)
12. [Architecture Overview](#architecture-overview)
13. [Security Notes](#security-notes)

---

## Supported OS and Runtimes

| Family | Distributions |
|---|---|
| **Debian / Ubuntu** | Ubuntu 20.04, 22.04, 24.04 · Debian 10/11/12 · Raspberry Pi OS · Kali |
| **RHEL / CentOS** | Rocky Linux 8/9 · AlmaLinux 8/9 · RHEL 8/9 · CentOS Stream 8/9 · Fedora 36+ |
| **SUSE** | openSUSE Leap 15 · SLES 15 |

Container runtimes: `containerd` (default) · `cri-o`  
CNI plugins: `calico` (default) · `flannel` · `weave`

---

## Repository Structure

```
hybrid-cluster/
├── Jenkinsfile                    ← Main pipeline (bootstrap | destroy | reset | upgrade)
├── 00-set-static-ip-hostname.sh  ← Static IP + hostname configuration
├── 01-linux-master-setup.sh      ← Control-plane bootstrap
├── 02-linux-worker-setup.sh      ← Worker node bootstrap
├── 03-linux-destroy.sh           ← Full node teardown and cleanup
├── 04-linux-upgrade.sh           ← In-place K8s version upgrade
├── 07-validate.sh                ← Post-install validation
└── README.md                     ← This file
```

---

## Step 0 — Pre-flight: Create the k8sadmin User

> **This is the most common reason the pipeline fails.**  
> The SSH user (`k8sadmin` by default) must exist on **every node** before the pipeline runs.
> The SSH connectivity check will time out or refuse connection if this user is missing.

Run the following on **each node** (master and all workers) as root or a user with sudo:

### Ubuntu / Debian

```bash
# Create user with home directory, no password login
sudo useradd -m -s /bin/bash k8sadmin

# Set a password (Jenkins will use this to SSH in)
sudo passwd k8sadmin
# Enter your chosen password twice when prompted

# Grant passwordless sudo — required by all bootstrap scripts
echo "k8sadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/k8sadmin
sudo chmod 0440 /etc/sudoers.d/k8sadmin

# Verify sudo works without a password prompt
sudo -u k8sadmin sudo -n whoami
# Expected output: root
```

### Rocky Linux / RHEL / AlmaLinux

```bash
# Create user
sudo useradd -m -s /bin/bash k8sadmin
sudo passwd k8sadmin

# Grant passwordless sudo
echo "k8sadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/k8sadmin
sudo chmod 0440 /etc/sudoers.d/k8sadmin

# On RHEL/Rocky, also disable requiretty in sudoers if present
sudo sed -i 's/^Defaults.*requiretty/# &/' /etc/sudoers

# Verify
sudo -u k8sadmin sudo -n whoami
# Expected output: root
```

### Verify SSH access from Jenkins host

Before running the pipeline, manually verify SSH connectivity from the Jenkins machine:

```bash
# Replace 192.168.56.11 with each node's IP
ssh k8sadmin@192.168.56.11 "echo SSH OK && sudo -n whoami"
# Expected output:
# SSH OK
# root
```

If SSH is refused, ensure:
- Port 22 is open on the node: `sudo ss -tlnp | grep :22`
- sshd is running: `sudo systemctl status sshd`
- The password you set matches what you store in Jenkins credentials

---

## Step 1 — Set Static IP and Hostname on Each Node

Each node needs a static IP so that the cluster addresses don't change across reboots. Run this on each node **before** the Jenkins pipeline, or enable `SET_STATIC_IP=true` in the pipeline parameters to do it automatically.

### Manual (recommended for first-time setup)

SSH into each node and run as root:

```bash
# Download the script to the node first
curl -fsSL https://raw.githubusercontent.com/ksk5940/k8s-cluster-bootstrap/main/hybrid-cluster/00-set-static-ip-hostname.sh \
  -o /tmp/00-set-static-ip-hostname.sh

# On the master node (192.168.56.11)
sudo STATIC_IP=192.168.56.11 \
     GATEWAY=192.168.56.1 \
     NEW_HOSTNAME=k8s-master \
     NODE_ROLE=master \
     bash /tmp/00-set-static-ip-hostname.sh

# On worker-1 (192.168.56.12)
sudo STATIC_IP=192.168.56.12 \
     GATEWAY=192.168.56.1 \
     NEW_HOSTNAME=k8s-worker-1 \
     NODE_ROLE=worker \
     bash /tmp/00-set-static-ip-hostname.sh

# On worker-2 (192.168.56.13)
sudo STATIC_IP=192.168.56.13 \
     GATEWAY=192.168.56.1 \
     NEW_HOSTNAME=k8s-worker-2 \
     NODE_ROLE=worker \
     bash /tmp/00-set-static-ip-hostname.sh
```

### Environment Variables for the Static IP Script

| Variable | Default | Description |
|---|---|---|
| `STATIC_IP` | **required** | Target static IP address |
| `GATEWAY` | auto-detect | Network gateway (router IP) |
| `DNS_SERVERS` | `8.8.8.8 1.1.1.1` | Space-separated DNS servers |
| `PREFIX_LENGTH` | `24` | Subnet prefix (24 = /24 = 255.255.255.0) |
| `NETWORK_IFACE` | auto-detect | NIC name (e.g. `eth0`, `ens33`, `enp0s3`) |
| `NEW_HOSTNAME` | unchanged | Desired hostname for this node |
| `NODE_ROLE` | `worker` | Informational: `master` or `worker` |

The script auto-detects and configures: `netplan` (Ubuntu), `nmcli` (Rocky/RHEL), `wicked` (openSUSE), `dhcpcd` (Raspbian), or `ifupdown` (Debian classic). It is idempotent — safe to run multiple times.

### Verify After Running

```bash
ip addr show          # Check the static IP is applied on the correct interface
hostname              # Should print the new hostname (e.g. k8s-master)
ping 8.8.8.8 -c 3    # Verify internet access still works
```

---

## Step 2 — Jenkins Setup

### 2.1 Install Jenkins

**Ubuntu / Debian:**

```bash
# Install Java (Jenkins requires JDK 17+)
sudo apt-get update
sudo apt-get install -y openjdk-17-jdk

# Add Jenkins APT repo and key
curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null
echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

sudo apt-get update
sudo apt-get install -y jenkins
sudo systemctl enable --now jenkins
```

**Rocky Linux / RHEL:**

```bash
sudo dnf install -y java-17-openjdk
sudo wget -O /etc/yum.repos.d/jenkins.repo \
  https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key
sudo dnf install -y jenkins
sudo systemctl enable --now jenkins
```

Jenkins runs on port `8080`. Get the initial admin password:

```bash
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Open `http://<jenkins-host>:8080` in your browser and complete the setup wizard.

---

### 2.2 Install Required Jenkins Plugins

Go to **Manage Jenkins → Plugins → Available plugins** and install:

| Plugin | Why it's needed |
|---|---|
| **SSH Pipeline Steps** | Provides `sshCommand` and `sshPut` used by every stage |
| **Credentials Binding** | Provides `withCredentials` for secure password injection |
| **Pipeline** | Core declarative pipeline support |
| **Git** | Clones the Jenkinsfile from GitHub |
| **Timestamper** | Adds timestamps to console output |
| **AnsiColor** *(optional)* | Renders ANSI color codes in console output |

After installing, restart Jenkins: `sudo systemctl restart jenkins`

---

### 2.3 Add SSH Credentials to Jenkins

The pipeline uses **Username with Password** credentials where:
- The **password** field is used as the SSH password for all nodes.
- The **username** field in the credential is **not used for SSH login** — the `SSH_USER` pipeline parameter controls the actual login user.

Steps:

1. Go to **Manage Jenkins → Credentials → System → Global credentials (unrestricted)**
2. Click **Add Credentials**
3. Set the following:

| Field | Value |
|---|---|
| **Kind** | `Username with password` |
| **Scope** | `Global` |
| **Username** | `k8sadmin` *(or any value — it is not used by the pipeline)* |
| **Password** | The password you set for `k8sadmin` on your nodes |
| **ID** | `K8S_SSH_CREDS` *(must match the `SSH_CREDS_ID` pipeline default)* |
| **Description** | `K8s node SSH credentials` |

4. Click **Create**

> **Important:** The `SSH_USER` parameter in the pipeline (default: `k8sadmin`) controls which OS user Jenkins SSHs as. This was a bug in the original pipeline — the credential's username field was incorrectly used instead. This version always uses `params.SSH_USER`.

---

### 2.4 Add GitHub Credentials (if repository is private)

If your fork of this repository is private:

1. Go to **Manage Jenkins → Credentials → System → Global credentials**
2. Click **Add Credentials**
3. Set:

| Field | Value |
|---|---|
| **Kind** | `Username with password` |
| **Username** | Your GitHub username |
| **Password** | A GitHub [Personal Access Token](https://github.com/settings/tokens) with `repo` scope |
| **ID** | `github-creds` |

---

## Step 3 — Create Jenkins Pipeline Job

1. From the Jenkins dashboard, click **New Item**
2. Enter name: `k8s-cluster-bootstrap`
3. Select **Pipeline** → click **OK**
4. Scroll to the **Pipeline** section and configure:

| Field | Value |
|---|---|
| **Definition** | `Pipeline script from SCM` |
| **SCM** | `Git` |
| **Repository URL** | `https://github.com/ksk5940/k8s-cluster-bootstrap.git` |
| **Credentials** | Select `github-creds` if the repo is private; leave blank if public |
| **Branch Specifier** | `*/main` |
| **Script Path** | `hybrid-cluster/Jenkinsfile` |

5. Click **Save**

The pipeline will appear with a **Build with Parameters** button after the first scan.

> **First build note:** Jenkins needs to parse the Jenkinsfile once to register the parameters. The very first build (triggered by "Build Now") will fail immediately with "Started by user" — this is normal. After that, "Build with Parameters" appears with all the fields.

---

## Step 4 — Run the Pipeline

1. Click **Build with Parameters** on the `k8s-cluster-bootstrap` job
2. Fill in the parameters:

| Parameter | Default | Description |
|---|---|---|
| `ACTION` | `bootstrap` | `bootstrap` / `destroy` / `reset` / `upgrade` |
| `MASTER_IP` | `192.168.56.11` | Control-plane node IP |
| `WORKER_IPS` | `192.168.56.12,192.168.56.13` | Comma-separated worker IPs |
| `SSH_USER` | `k8sadmin` | Linux OS user on all nodes (must have NOPASSWD sudo) |
| `SSH_CREDS_ID` | `K8S_SSH_CREDS` | Jenkins credential ID (password used for SSH auth) |
| `RUNTIME` | `containerd` | `containerd` or `crio` |
| `CNI_PLUGIN` | `calico` | `calico`, `flannel`, or `weave` |
| `K8S_VERSION` | `1.32.3` | Target Kubernetes version (`MAJOR.MINOR.PATCH`) |
| `K8S_CURRENT_VERSION` | *(blank)* | `[upgrade only]` Current installed version. Blank = auto-detect |
| `POD_CIDR` | `10.244.0.0/16` | Pod network CIDR |
| `SET_STATIC_IP` | `false` | Set `true` to auto-configure static IPs via script 00 |

3. Click **Build**
4. Click the build number → **Console Output** to follow progress

A successful bootstrap takes approximately **8–15 minutes** depending on network speed and node hardware.

---

## Pipeline Actions Explained

### `bootstrap`

Provisions a brand-new cluster from scratch:

1. Validates all parameters
2. SSH connectivity and `sudo` check — all nodes in parallel
3. *(Optional)* Sets static IP + hostname via `00-set-static-ip-hostname.sh`
4. Uploads and runs `01-linux-master-setup.sh` on the master:
   - Disables swap, loads kernel modules, applies sysctl
   - Installs containerd or cri-o
   - Installs kubeadm / kubelet / kubectl
   - Runs `kubeadm init` with the specified CNI and CIDR
   - Installs the CNI plugin (calico / flannel / weave)
   - Saves the join command to `/tmp/k8s-join-command.sh`
5. Fetches the join command from master
6. Uploads and runs `02-linux-worker-setup.sh` on all workers in parallel
7. Polls until all nodes reach `Ready` state (up to 3 minutes)

### `destroy`

Full teardown on every node in parallel:

- `kubeadm reset --force`
- Removes: kubelet, kubeadm, kubectl, containerd/crio and all their data
- Removes: CNI interfaces (vxlan.calico, flannel.1, weave, cali*) and iptables rules
- Removes: all package repos, keyrings, systemd units, logs, and temp files
- Flushes: iptables, ip6tables, ipvs, pod/service routes
- Restores swap from `fstab.bak` if present

### `reset`

Runs `destroy` immediately followed by `bootstrap` in a single pipeline run. Use when the cluster state is corrupted or you want a clean re-provision without manually triggering two builds.

### `upgrade`

Version-gap-aware in-place upgrade. Kubernetes only allows upgrading **one minor version at a time**. If you are on `1.30.x` and want `1.32.x`, the pipeline automatically hops:

```
1.30.x → 1.31.0 → 1.32.3
```

Per hop, per node:

1. Updates apt/dnf repo to the target minor version
2. Upgrades `kubeadm`, runs `kubeadm upgrade apply` (master) or `kubeadm upgrade node` (workers)
3. Drains the node gracefully
4. Upgrades `kubelet` + `kubectl`, restarts kubelet
5. Uncordons the node

Master is always upgraded before workers. Workers within the same hop run in parallel.

---

## Standalone Script Usage (Without Jenkins)

All scripts accept environment variables and can be run directly on the target nodes.

### Create k8sadmin user (prerequisite)

```bash
sudo useradd -m -s /bin/bash k8sadmin
sudo passwd k8sadmin
echo "k8sadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/k8sadmin
sudo chmod 0440 /etc/sudoers.d/k8sadmin
```

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
# Get the join command from the master first:
# ssh k8sadmin@192.168.56.11 "sudo cat /tmp/k8s-join-command.sh"

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

### Upgrade a node (one minor at a time)

```bash
# Master — hop 1
sudo K8S_VERSION=1.31.0 NODE_ROLE=master RUNTIME=containerd \
     SETUP_USER=k8sadmin bash 04-linux-upgrade.sh

# Master — hop 2 (final target)
sudo K8S_VERSION=1.32.3 NODE_ROLE=master RUNTIME=containerd \
     SETUP_USER=k8sadmin bash 04-linux-upgrade.sh

# Workers — must run AFTER each master hop completes
sudo K8S_VERSION=1.31.0 NODE_ROLE=worker RUNTIME=containerd \
     MASTER_IP=192.168.56.11 SETUP_USER=k8sadmin bash 04-linux-upgrade.sh
```

### Run validation after bootstrap

```bash
# Run on the master node
sudo bash 07-validate.sh
```

---

## Troubleshooting

### SSH connection timed out (most common failure)

The pipeline's SSH connectivity stage will fail with `Connection timed out: connect` if:

1. **The VM/node is not running** — verify the node is powered on and accessible
2. **The k8sadmin user does not exist** — follow [Step 0](#step-0--pre-flight-create-the-k8sadmin-user)
3. **Port 22 is blocked** — check firewall on the node: `sudo ufw status` or `sudo firewall-cmd --list-all`
4. **Wrong IP in pipeline parameters** — verify `MASTER_IP` and `WORKER_IPS` match the actual node IPs
5. **Wrong password in Jenkins credential** — re-test manually: `ssh k8sadmin@<node-ip>`

```bash
# Quick check from Jenkins host
ssh k8sadmin@192.168.56.11 "echo OK && sudo -n whoami"
# Expected: OK\nroot
```

---

### Nodes stuck in `NotReady`

```bash
# On master
kubectl get nodes
kubectl describe node <node-name>

# Check kubelet
sudo journalctl -u kubelet -n 100 --no-pager

# Check containerd
sudo journalctl -u containerd -n 50 --no-pager

# Check CNI pods
kubectl get pods -n kube-system -o wide
```

Common causes: CNI pod not yet ready, wrong `POD_CIDR` for the CNI chosen, or `br_netfilter` module not loaded.

---

### kubeadm init fails: "port already in use" or "etcd already exists"

The destroy script cleans this up. If running manually:

```bash
sudo kubeadm reset -f --cri-socket unix:///run/containerd/containerd.sock
sudo rm -rf /etc/kubernetes /var/lib/etcd /var/lib/kubelet/config.yaml
```

---

### SUDO FAILED during SSH check

The `k8sadmin` user exists but doesn't have passwordless sudo:

```bash
# Fix on the failing node
echo "k8sadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/k8sadmin
sudo chmod 0440 /etc/sudoers.d/k8sadmin
# Verify
sudo -u k8sadmin sudo -n whoami   # must print: root
```

---

### Upgrade stuck: node not draining

Pods with `PodDisruptionBudget` can block drain. Force it:

```bash
kubectl drain <node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --disable-eviction
```

---

### `kubectl version --short` deprecated warning during upgrade

This has been fixed in the current `04-linux-upgrade.sh`. The auto-detection now uses `kubectl version -o json` (available in K8s 1.20+) and falls back to `kubelet --version`.

---

## Bug Fixes Changelog

The following issues from the original scripts have been fixed in this version:

| # | File | Issue | Fix |
|---|---|---|---|
| 1 | `Jenkinsfile` | `SSH_USER` param was shadowed by `SSH_USER_VAR` from `withCredentials`. The credential's username was used as `remote.user` instead of the OS login user, causing SSH failures when the two differ. | Introduced `makeRemote()` helper that always uses `params.SSH_USER` for `remote.user`. `SSH_USER_VAR` is bound but intentionally unused. |
| 2 | `Jenkinsfile` | `echo sshCommand(...)` in Verify stage can throw NPE when the command returns null/empty output. | Captured result to a variable first, then echoed with a null-safe `?.toString() ?: "(no output)"`. |
| 3 | `Jenkinsfile` | `kubectl version --short` is deprecated since K8s 1.28 and removed in 1.29+. | Version auto-detection now uses `kubectl version -o json \| python3` with a `kubelet --version` fallback. |
| 4 | `Jenkinsfile` | `SETUP_USER` was not passed to the upgrade script, so the kubeconfig path defaulted to `k8sadmin` even when a different user was specified. | `SETUP_USER` is now exported in all upgrade `sshCommand` calls. |
| 5 | `04-linux-upgrade.sh` | `KUBECONFIG` was hardcoded to `/etc/kubernetes/admin.conf` for all node roles. Workers don't have this file — they need the kubeconfig from the `SETUP_USER`'s home directory. | `KUBECONFIG` is now set conditionally: master uses `/etc/kubernetes/admin.conf`; workers use `~SETUP_USER/.kube/config` with a `/root/.kube/config` fallback. |
| 6 | `04-linux-upgrade.sh` | `NODE_NAME` detection used `awk -v ip="${HOSTNAME}"` trying to match a hostname variable against node names — logic always fell through to the hostname fallback, but the awk expression was semantically wrong. | Replaced with `kubectl get nodes \| grep -Fx "$(hostname)"` for exact hostname match. |

---

## Architecture Overview

```
Jenkins Agent (Windows/Linux)
        │
        │  SSH (password auth, params.SSH_USER)
        │
        ├──────────────────────► Master Node (192.168.56.11)
        │                          1. kubeadm init
        │                          2. CNI install (calico/flannel/weave)
        │                          3. Write /tmp/k8s-join-command.sh
        │
        │  (reads join command from master)
        │
        ├──────────────────────► Worker-1 (192.168.56.12)   ─┐
        │                          kubeadm join               │ parallel
        └──────────────────────► Worker-2 (192.168.56.13)   ─┘
                                   kubeadm join
```

Workers are always provisioned **in parallel** to minimize total bootstrap time. The master must complete and produce a join command before workers start — the `Extract Join Command` stage enforces this sequencing.

---

## Security Notes

- This setup is designed for **lab and development environments**. The firewall (`ufw`/`firewalld`) is disabled on all nodes for simplicity.
- For production deployments: enable the firewall with explicit K8s port rules, restrict sudo scope, use SSH key authentication instead of passwords, and use a private CA for cluster certificates.
- Join tokens expire after **24 hours**. Re-running `bootstrap` or `reset` generates a fresh token.
- Credentials are never written to disk by Jenkins. They are passed via `withCredentials` and exist only as environment variables for the duration of the pipeline run.
- The `NOPASSWD` sudoers entry is required by the bootstrap scripts. After provisioning, you may want to tighten this to specific commands only.
