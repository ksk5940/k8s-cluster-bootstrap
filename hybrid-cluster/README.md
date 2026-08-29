# k8s-cluster-bootstrap

Automated Kubernetes cluster lifecycle management via Jenkins.  
Supports **bootstrap · destroy · reset · upgrade** on any Linux distribution.

---

## Table of Contents

1. [Supported Operating Systems](#1-supported-operating-systems)
2. [File Overview](#2-file-overview)
3. [Pre-Flight: Create the Bootstrap User on Every Node](#3-pre-flight-create-the-bootstrap-user-on-every-node)
4. [Pre-Flight: Set Static IP and Hostname](#4-pre-flight-set-static-ip-and-hostname)
5. [Jenkins Install](#5-jenkins-install)
6. [Jenkins: Install Plugins](#6-jenkins-install-plugins)
7. [Jenkins: Add SSH Credentials](#7-jenkins-add-ssh-credentials)
8. [Jenkins: Add GitHub Credentials](#8-jenkins-add-github-credentials-private-repo-only)
9. [Jenkins: Create the Pipeline Job](#9-jenkins-create-the-pipeline-job)
10. [Jenkins: Run the Pipeline](#10-jenkins-run-the-pipeline)
11. [Pipeline Parameters Reference](#11-pipeline-parameters-reference)
12. [Pipeline Actions Explained](#12-pipeline-actions-explained)
13. [Standalone Script Usage](#13-standalone-script-usage-without-jenkins)
14. [Troubleshooting](#14-troubleshooting)
15. [Architecture Overview](#15-architecture-overview)
16. [Node IP Planning](#16-node-ip-planning)
17. [Security Notes](#17-security-notes)

---

## 1. Supported Operating Systems

| Family | Distributions |
|---|---|
| **Debian / Ubuntu** | Ubuntu 20.04, 22.04, 24.04 · Debian 10/11/12 · Raspberry Pi OS · Kali |
| **RHEL / CentOS** | Rocky Linux 8/9 · AlmaLinux 8/9 · RHEL 8/9 · CentOS Stream 8/9 · Fedora 36+ |
| **SUSE** | openSUSE Leap 15 · SLES 15 |

Container runtimes: `containerd` (default) · `cri-o`  
CNI plugins: `calico` (default) · `flannel` · `weave`

---

## 2. File Overview

```
hybrid-cluster/
├── Jenkinsfile                    ← Main pipeline (all 4 actions)
├── 00-set-static-ip-hostname.sh  ← Static IP + hostname (all network managers)
├── 01-linux-master-setup.sh      ← Control-plane bootstrap
├── 02-linux-worker-setup.sh      ← Worker node bootstrap
├── 03-linux-destroy.sh           ← Full node teardown
├── 04-linux-upgrade.sh           ← In-place version upgrade (minor-by-minor)
├── 07-validate.sh                ← Post-install cluster validation
└── README.md                     ← This file
```

---

## 3. Pre-Flight: Create the Bootstrap User on Every Node

> **Do this first — on every node (master + all workers).**  
> Jenkins SSHes into each node as a dedicated user (`k8sadmin`).  
> That user must exist, have a password, and have **passwordless sudo**.

---

### 3a. One-Shot Setup Script (recommended)

Copy the script below, save it as `create-k8sadmin.sh` on each node, and run it as root. It handles all four required steps automatically.

```bash
#!/bin/bash
# create-k8sadmin.sh
# Run as root (or with sudo) on EVERY node — master and each worker
set -euo pipefail

USERNAME="k8sadmin"
PASSWORD="YourStr0ngP@ssword"   # ← CHANGE THIS before running

echo "=== Creating bootstrap user: ${USERNAME} ==="

# Step 1 — Create user if not already present
if id "${USERNAME}" &>/dev/null; then
  echo "[SKIP] User ${USERNAME} already exists"
else
  useradd -m -s /bin/bash "${USERNAME}"
  echo "[OK]   User ${USERNAME} created"
fi

# Set password
echo "${USERNAME}:${PASSWORD}" | chpasswd
echo "[OK]   Password set"

# Step 2 — Passwordless sudo
echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/${USERNAME}
chmod 0440 /etc/sudoers.d/${USERNAME}
# Validate sudoers file syntax
visudo -c -f /etc/sudoers.d/${USERNAME} >/dev/null 2>&1 \
  && echo "[OK]   Sudoers entry validated" \
  || { echo "[FAIL] Sudoers syntax error — check /etc/sudoers.d/${USERNAME}"; exit 1; }

# Step 3 — Enable SSH password authentication
SSHD_CFG="/etc/ssh/sshd_config"
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' "${SSHD_CFG}"
sed -i 's/^#*PermitRootLogin.*/PermitRootLogin no/' "${SSHD_CFG}"
# Restart SSH service (name varies by distro)
systemctl restart sshd 2>/dev/null \
  || systemctl restart ssh 2>/dev/null \
  || service ssh restart 2>/dev/null \
  || true
echo "[OK]   SSH password authentication enabled"

# Step 4 — Verify sudo works without password
RESULT=$(sudo -u "${USERNAME}" sudo -n whoami 2>&1)
if [[ "${RESULT}" == "root" ]]; then
  echo "[OK]   NOPASSWD sudo verified: sudo whoami → root"
else
  echo "[WARN] sudo check returned: ${RESULT}"
  echo "       Check /etc/sudoers.d/${USERNAME}"
fi

NODE_IP=$(hostname -I | awk '{print $1}')
echo ""
echo "======================================================"
echo "  Bootstrap user ready: ${USERNAME}@${NODE_IP}"
echo "  Password:             ${PASSWORD}"
echo "  Add this to Jenkins:  ID=K8S_SSH_CREDS"
echo "======================================================"
```

Run on each node:

```bash
sudo bash create-k8sadmin.sh
```

---

### 3b. Manual Steps (if you prefer step by step)

**Step 1 — Create the user:**
```bash
sudo useradd -m -s /bin/bash k8sadmin
sudo passwd k8sadmin
# Enter and confirm the password
```

**Step 2 — Grant passwordless sudo:**
```bash
echo "k8sadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/k8sadmin
sudo chmod 0440 /etc/sudoers.d/k8sadmin
```

**Step 3 — Enable SSH password auth:**
```bash
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart sshd || sudo service ssh restart
```

**Step 4 — Verify everything works:**
```bash
# Must print "root" with no password prompt
sudo -u k8sadmin sudo -n whoami
```

---

### 3c. Verify from the Jenkins server

From your Jenkins machine, test SSH connectivity to every node:

```bash
ssh k8sadmin@192.168.56.11 "sudo whoami && echo SSH+SUDO_OK"
ssh k8sadmin@192.168.56.12 "sudo whoami && echo SSH+SUDO_OK"
ssh k8sadmin@192.168.56.13 "sudo whoami && echo SSH+SUDO_OK"
```

Every node must return `root` followed by `SSH+SUDO_OK`. If any node fails, do not proceed until the issue is fixed.

---

## 4. Pre-Flight: Set Static IP and Hostname

Kubernetes requires stable IPs. Set a static IP and hostname on every node before bootstrapping. You can run `00-set-static-ip-hostname.sh` manually, or enable the `SET_STATIC_IP=true` pipeline parameter to have Jenkins do it automatically.

### Manual method

```bash
# On master node
sudo STATIC_IP=192.168.56.11 \
     GATEWAY=192.168.56.1 \
     NEW_HOSTNAME=k8s-master \
     NODE_ROLE=master \
     bash 00-set-static-ip-hostname.sh

# On worker-1
sudo STATIC_IP=192.168.56.12 \
     GATEWAY=192.168.56.1 \
     NEW_HOSTNAME=k8s-worker-1 \
     NODE_ROLE=worker \
     bash 00-set-static-ip-hostname.sh

# On worker-2
sudo STATIC_IP=192.168.56.13 \
     GATEWAY=192.168.56.1 \
     NEW_HOSTNAME=k8s-worker-2 \
     NODE_ROLE=worker \
     bash 00-set-static-ip-hostname.sh
```

### Environment variables

| Variable | Default | Description |
|---|---|---|
| `STATIC_IP` | **required** | IP address to assign to this node |
| `GATEWAY` | auto-detected | Default gateway / router IP |
| `DNS_SERVERS` | `8.8.8.8 1.1.1.1` | Space-separated DNS server IPs |
| `PREFIX_LENGTH` | `24` | Subnet mask length (`24` = `/24` = `255.255.255.0`) |
| `NETWORK_IFACE` | auto-detected | NIC name — e.g. `eth0`, `ens33`, `enp0s3` |
| `NEW_HOSTNAME` | unchanged | New hostname to set |
| `NODE_ROLE` | `worker` | Informational only: `master` or `worker` |

The script auto-detects the network manager (`netplan` / `nmcli` / `wicked` / `dhcpcd` / `ifupdown`) and applies the correct configuration. It is **idempotent** — safe to run multiple times.

### Verify

```bash
ip addr show       # Confirm static IP is applied to the NIC
hostname           # Confirm hostname matches NEW_HOSTNAME
ping 8.8.8.8 -c 3 # Confirm internet access
```

---

## 5. Jenkins Install

### Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install -y openjdk-17-jdk

curl -fsSL https://pkg.jenkins.io/debian-stable/jenkins.io-2023.key \
  | sudo tee /usr/share/keyrings/jenkins-keyring.asc > /dev/null

echo "deb [signed-by=/usr/share/keyrings/jenkins-keyring.asc] \
  https://pkg.jenkins.io/debian-stable binary/" \
  | sudo tee /etc/apt/sources.list.d/jenkins.list > /dev/null

sudo apt-get update && sudo apt-get install -y jenkins
sudo systemctl enable --now jenkins
```

### RHEL / Rocky / AlmaLinux

```bash
sudo dnf install -y java-17-openjdk

sudo wget -O /etc/yum.repos.d/jenkins.repo \
  https://pkg.jenkins.io/redhat-stable/jenkins.repo
sudo rpm --import https://pkg.jenkins.io/redhat-stable/jenkins.io-2023.key

sudo dnf install -y jenkins
sudo systemctl enable --now jenkins
```

### Unlock Jenkins

Jenkins starts on port **8080**. Open `http://<jenkins-ip>:8080` in a browser.

```bash
# Get the unlock password
sudo cat /var/lib/jenkins/secrets/initialAdminPassword
```

Paste it into the browser, choose **Install suggested plugins**, and create an admin user.

---

## 6. Jenkins: Install Plugins

Go to **Manage Jenkins → Plugins → Available plugins**, search for each plugin, tick it, and click **Install without restart**.

| Plugin Name | Search Term | Why Needed |
|---|---|---|
| **SSH Pipeline Steps** | `ssh pipeline steps` | Provides `sshCommand` and `sshPut` — the core of the pipeline |
| **Credentials Binding** | `credentials binding` | Enables `withCredentials` block to safely inject passwords |
| **Pipeline** | `pipeline` | Core declarative pipeline engine |
| **Pipeline: Stage View** | `stage view` | Renders the visual stage progress in the Jenkins UI |
| **Git** | `git` | Clones the Jenkinsfile and scripts from your GitHub repo |
| **Timestamper** | `timestamper` | Prepends timestamps to every console line |
| **Build With Parameters** | `build with parameters` | Renders parameter dropdowns in the Build UI |
| **AnsiColor** *(optional)* | `ansicolor` | Renders the colored output from the bash scripts |

After installing all plugins, go to **Manage Jenkins → Plugins → Installed** and confirm all appear. Restart Jenkins if prompted:

```bash
sudo systemctl restart jenkins
```

---

## 7. Jenkins: Add SSH Credentials

This stores the `k8sadmin` username and password inside Jenkins so the pipeline can SSH into your nodes without hardcoding secrets.

**Navigation:** Manage Jenkins → Credentials → System → Global credentials (unrestricted) → + Add Credentials

| Field | Value | Notes |
|---|---|---|
| **Kind** | `Username with password` | Must be this type — not SSH key |
| **Scope** | `Global` | Makes it available to the pipeline job |
| **Username** | `k8sadmin` | Must match the user you created on the nodes |
| **Password** | `YourStr0ngP@ssword` | The password set in `create-k8sadmin.sh` |
| **ID** | `K8S_SSH_CREDS` | **Critical — must match exactly.** This is what the Jenkinsfile looks up |
| **Description** | `K8s node SSH credentials (k8sadmin)` | Human-readable label |

Click **Create**.

> **Important:** The credential **ID** (`K8S_SSH_CREDS`) is referenced in the Jenkinsfile as the default value for the `SSH_CREDS_ID` parameter. If you change the ID here, you must also change `defaultValue: 'K8S_SSH_CREDS'` in the Jenkinsfile, or select the correct credential ID each time you run the pipeline.

---

## 8. Jenkins: Add GitHub Credentials (private repo only)

Skip this section if your repository is **public**.

**Navigation:** Manage Jenkins → Credentials → System → Global credentials → + Add Credentials

| Field | Value |
|---|---|
| **Kind** | `Username with password` |
| **Username** | Your GitHub username |
| **Password** | A GitHub **Personal Access Token (PAT)** — not your GitHub account password |
| **ID** | `github-creds` |
| **Description** | `GitHub PAT for k8s-cluster-bootstrap` |

**To create a GitHub PAT:**

1. Go to GitHub.com → click your profile picture → **Settings**
2. Left sidebar → **Developer settings** → **Personal access tokens** → **Tokens (classic)**
3. Click **Generate new token (classic)**
4. Set **Note**: `Jenkins k8s-cluster-bootstrap`
5. Set **Expiration**: 90 days (or longer for long-lived setups)
6. Check scope: **repo** (grants full private repo access)
7. Click **Generate token** — copy it immediately (shown only once)

Paste the token as the **Password** in the Jenkins credential form.

---

## 9. Jenkins: Create the Pipeline Job

### 9a. Create the item

1. From the Jenkins dashboard, click **+ New Item**
2. Enter name: `k8s-cluster-bootstrap`
3. Select **Pipeline**
4. Click **OK**

---

### 9b. General section

| Setting | Value |
|---|---|
| **Description** | `Kubernetes cluster: bootstrap / destroy / reset / upgrade` |
| **Discard old builds** | ✅ Enable — set Max builds to keep: `10` |

---

### 9c. Build Triggers section

Leave all triggers **unchecked** for manual execution. Optional:

- **GitHub hook trigger for GITScm polling** — triggers the pipeline on every `git push` to the repo (requires configuring a GitHub webhook: Settings → Webhooks → Add webhook → Payload URL = `http://<jenkins-ip>:8080/github-webhook/`)

---

### 9d. Pipeline section — fill in exactly as shown

| Field | Value |
|---|---|
| **Definition** | `Pipeline script from SCM` |
| **SCM** | `Git` |
| **Repository URL** | `https://github.com/ksk5940/k8s-cluster-bootstrap.git` |
| **Credentials** | `github-creds` if private, or `- none -` if public |
| **Branch Specifier** | `*/main` |
| **Repository browser** | `(Auto)` |
| **Script Path** | `hybrid-cluster/Jenkinsfile` |
| **Lightweight checkout** | ✅ Check — faster, only fetches the Jenkinsfile for SCM polling |

Click **Save**.

---

### 9e. Set up global Git identity (one-time)

Jenkins needs a Git identity to perform checkouts.

1. Go to **Manage Jenkins → System**
2. Scroll to the **Git plugin** section
3. Set:
   - **Global Config user.name**: `Jenkins`
   - **Global Config user.email**: `jenkins@k8s-bootstrap`
4. Click **Save**

---

## 10. Jenkins: Run the Pipeline

### First run

On the first run, Jenkins clones the repo and reads the Jenkinsfile parameters. The first execution may show just **Build Now** with no parameter UI — that is normal.

1. Click **Build Now** once
2. The build will fail immediately (no parameters yet) — that is expected
3. After this first run, the job learns its parameters
4. Click **Build with Parameters** — the full parameter UI now appears

### Every run after the first

1. Click **Build with Parameters**
2. Fill in parameters (see [Section 11](#11-pipeline-parameters-reference))
3. Click **Build**
4. Watch progress in **Stage View** or **Console Output**

### Successful bootstrap console output pattern

```
[Validate Inputs]                 ✔  1s
[Verify SSH Connectivity]         ✔  4s    ← all nodes checked in parallel
[Set Static IP and Hostname]      ✔  skipped  (SET_STATIC_IP=false)
[Provision Master Node]           ✔  4m 28s
[Extract Join Command]            ✔  2s
[Provision Worker Nodes]          ✔  3m 12s  ← workers run in parallel
[Verify Cluster]                  ✔  38s

BOOTSTRAP TIMING SUMMARY
  master            4m 28s
  worker-192.168.56.12  3m 05s
  worker-192.168.56.13  3m 12s
  TOTAL             8m 22s

[OK]  K8s Cluster BOOTSTRAP — SUCCESS
```

---

## 11. Pipeline Parameters Reference

| Parameter | Type | Default | Description |
|---|---|---|---|
| `ACTION` | Choice | `bootstrap` | `bootstrap` — fresh cluster · `destroy` — full teardown · `reset` — destroy + bootstrap · `upgrade` — in-place version upgrade |
| `MASTER_IP` | String | `192.168.56.11` | IP address of the control-plane node |
| `WORKER_IPS` | String | `192.168.56.12,192.168.56.13` | Comma-separated IPs of all worker nodes |
| `SSH_USER` | String | `k8sadmin` | SSH username — must be the user created in Section 3 |
| `SSH_CREDS_ID` | Credential | `K8S_SSH_CREDS` | Jenkins credential ID — must match what you created in Section 7 |
| `RUNTIME` | Choice | `containerd` | Container runtime: `containerd` or `crio` |
| `CNI_PLUGIN` | Choice | `calico` | CNI plugin: `calico`, `flannel`, or `weave` |
| `K8S_VERSION` | String | `1.32.3` | Target Kubernetes version in `MAJOR.MINOR.PATCH` format |
| `K8S_CURRENT_VERSION` | String | *(blank)* | **Upgrade only** — current version. Leave blank to auto-detect from the master |
| `POD_CIDR` | String | `10.244.0.0/16` | Pod network CIDR. Use `10.244.0.0/16` for all CNI plugins |
| `SET_STATIC_IP` | Boolean | `false` | Run `00-set-static-ip-hostname.sh` on all nodes before provisioning |

---

## Jenkins Job: Parameters to Pass

After creating the Jenkins Pipeline job, use **Build with Parameters**.

### Bootstrap — required values

For a normal 3-node cluster, use:

| Parameter | Value |
|---|---|
| `ACTION` | `bootstrap` |
| `MASTER_IP` | `192.168.56.11` |
| `WORKER_IPS` | `192.168.56.12,192.168.56.13` |
| `SSH_USER` | `k8sadmin` |
| `SSH_CREDS_ID` | `K8S_SSH_CREDS` |
| `RUNTIME` | `containerd` |
| `CNI_PLUGIN` | `calico` |
| `K8S_VERSION` | `1.32.3` |
| `K8S_CURRENT_VERSION` | leave blank |
| `POD_CIDR` | `10.244.0.0/16` |
| `SET_STATIC_IP` | `false` |

If the nodes already have the correct static IP addresses and hostnames, keep `SET_STATIC_IP=false`.

If Jenkins should configure the node IP/hostname before bootstrap, set:

```text
SET_STATIC_IP=true
```

and make sure the Jenkinsfile contains the corresponding static-IP configuration for every node.

### Destroy

For a complete teardown:

| Parameter | Value |
|---|---|
| `ACTION` | `destroy` |
| `MASTER_IP` | `192.168.56.11` |
| `WORKER_IPS` | `192.168.56.12,192.168.56.13` |
| `SSH_USER` | `k8sadmin` |
| `SSH_CREDS_ID` | `K8S_SSH_CREDS` |
| `RUNTIME` | **the runtime actually installed on the cluster** |
| `CNI_PLUGIN` | **the CNI actually installed** |
| `K8S_VERSION` | can remain at the job default |
| `K8S_CURRENT_VERSION` | leave blank |
| `POD_CIDR` | can remain at the job default |
| `SET_STATIC_IP` | `false` |

**Important:** `RUNTIME` is significant for destroy. If the cluster uses `containerd`, select `containerd`; if it uses CRI-O, select `crio`.

The updated destroy script is runtime-aware: it removes only the selected runtime and does not blindly delete the other runtime's data. In particular, a `containerd` destroy does not remove `/var/lib/containers`, which can be shared by Podman/Buildah/CRI-O.

### Reset

For a clean rebuild:

| Parameter | Value |
|---|---|
| `ACTION` | `reset` |
| `MASTER_IP` | `192.168.56.11` |
| `WORKER_IPS` | `192.168.56.12,192.168.56.13` |
| `SSH_USER` | `k8sadmin` |
| `SSH_CREDS_ID` | `K8S_SSH_CREDS` |
| `RUNTIME` | `containerd` |
| `CNI_PLUGIN` | `calico` |
| `K8S_VERSION` | `1.32.3` |
| `K8S_CURRENT_VERSION` | leave blank |
| `POD_CIDR` | `10.244.0.0/16` |
| `SET_STATIC_IP` | `false` |

Reset performs the teardown/rebuild workflow, so verify the target IPs before starting it.

### Upgrade

For an upgrade:

| Parameter | Value |
|---|---|
| `ACTION` | `upgrade` |
| `MASTER_IP` | `192.168.56.11` |
| `WORKER_IPS` | `192.168.56.12,192.168.56.13` |
| `SSH_USER` | `k8sadmin` |
| `SSH_CREDS_ID` | `K8S_SSH_CREDS` |
| `RUNTIME` | current runtime |
| `CNI_PLUGIN` | current CNI |
| `K8S_VERSION` | target version, e.g. `1.32.3` |
| `K8S_CURRENT_VERSION` | current version, or leave blank for auto-detection |
| `POD_CIDR` | existing pod CIDR |
| `SET_STATIC_IP` | `false` |

Example:

```text
Current cluster: 1.30.5
Target:          1.32.3

K8S_CURRENT_VERSION=1.30.5
K8S_VERSION=1.32.3
```

The pipeline should perform the upgrade one minor version at a time rather than attempting to skip directly across unsupported minor-version gaps.

### Minimum parameters you normally change

For your normal lab cluster, you generally only need to verify/change:

```text
ACTION
MASTER_IP
WORKER_IPS
RUNTIME
CNI_PLUGIN
K8S_VERSION
```

Keep these unchanged unless your environment requires otherwise:

```text
SSH_USER=k8sadmin
SSH_CREDS_ID=K8S_SSH_CREDS
POD_CIDR=10.244.0.0/16
SET_STATIC_IP=false
```

### Before clicking Build

Confirm:

```text
[ ] Master IP is correct
[ ] Every worker IP is correct
[ ] All nodes are reachable from Jenkins
[ ] k8sadmin exists on every node
[ ] k8sadmin has passwordless sudo
[ ] K8S_SSH_CREDS exists in Jenkins
[ ] RUNTIME matches the cluster
[ ] CNI_PLUGIN matches the cluster
[ ] K8S_VERSION is the intended target
```

For `bootstrap`, workers are provisioned in parallel according to the pipeline design. For `destroy`, nodes are also processed in parallel; each node runs its own runtime-aware teardown.

## 12. Pipeline Actions Explained

### `bootstrap`

Provisions a complete Kubernetes cluster from scratch:

```
1. SSH connectivity + sudo check on all nodes (parallel)
2. Optional static IP + hostname (if SET_STATIC_IP=true)
3. Master: install runtime, kubeadm, kubelet, kubectl → kubeadm init → CNI
4. Extract join command from master
5. Workers: install runtime + K8s → kubeadm join (parallel)
6. Poll until all nodes are Ready (max 3 minutes)
```

### `destroy`

Completely wipes Kubernetes from every node (all nodes in parallel):

- `kubeadm reset -f` with CRI socket
- Remove: kubelet, kubeadm, kubectl, and the selected container runtime
- Remove: all CNI network interfaces and iptables rules
- Remove: all repos, keyrings, systemd units, data directories, logs, temp files
- Remove: kubeconfig files for all users
- Flush: iptables, ip6tables, ipvs, pod network routes
- Restore: swap if `fstab.bak` was created by the bootstrap

### `reset`

Runs `destroy` then `bootstrap` in a single pipeline execution. Use when:
- Cluster is broken and needs a clean rebuild
- You are changing the CNI plugin or runtime
- You want a completely fresh cluster without manually running two pipelines

### `upgrade`

Version-gap-aware in-place upgrade. Kubernetes supports upgrading **one minor version at a time**.

**Example:** Current `1.30.5`, target `1.32.3`  
Pipeline automatically builds the path: `1.30.5 → 1.31.0 → 1.32.3`

Per-hop sequence:
1. Update apt/dnf repo to the new minor version
2. Upgrade `kubeadm` → run `kubeadm upgrade apply` (master) or `kubeadm upgrade node` (workers)
3. Drain the node
4. Upgrade `kubelet` + `kubectl`
5. Restart `kubelet`
6. Uncordon the node

Master upgrades first. Workers run in parallel per hop.

---

## 13. Standalone Script Usage (Without Jenkins)

### Create bootstrap user

```bash
sudo bash create-k8sadmin.sh
```

### Set static IP

```bash
sudo STATIC_IP=192.168.56.11 GATEWAY=192.168.56.1 NEW_HOSTNAME=k8s-master \
     bash 00-set-static-ip-hostname.sh
```

### Bootstrap master

```bash
sudo MASTER_IP=192.168.56.11 K8S_VERSION=1.32.3 RUNTIME=containerd \
     CNI_PLUGIN=calico POD_CIDR=10.244.0.0/16 SETUP_USER=k8sadmin \
     bash 01-linux-master-setup.sh
```

### Bootstrap worker

```bash
# Get the join command from master
JOIN=$(ssh k8sadmin@192.168.56.11 "sudo cat /tmp/k8s-join-command.sh")

sudo K8S_VERSION=1.32.3 RUNTIME=containerd \
     JOIN_COMMAND="${JOIN}" NODE_IP=192.168.56.12 SETUP_USER=k8sadmin \
     bash 02-linux-worker-setup.sh
```

### Destroy a node

```bash
sudo RUNTIME=containerd CNI_PLUGIN=calico bash 03-linux-destroy.sh
```

### Upgrade (one hop at a time)

```bash
# Master — hop 1
sudo K8S_VERSION=1.31.0 NODE_ROLE=master RUNTIME=containerd bash 04-linux-upgrade.sh
# Master — hop 2
sudo K8S_VERSION=1.32.3 NODE_ROLE=master RUNTIME=containerd bash 04-linux-upgrade.sh

# Each worker — hop 1
sudo K8S_VERSION=1.31.0 NODE_ROLE=worker RUNTIME=containerd \
     MASTER_IP=192.168.56.11 bash 04-linux-upgrade.sh
# Each worker — hop 2
sudo K8S_VERSION=1.32.3 NODE_ROLE=worker RUNTIME=containerd \
     MASTER_IP=192.168.56.11 bash 04-linux-upgrade.sh
```

---

## 14. Troubleshooting

### `SUDO FAILED` in the Jenkins SSH connectivity stage

The user exists but NOPASSWD sudo is not configured correctly.

```bash
# On the failing node
ssh k8sadmin@<node-ip>
sudo -n whoami      # If this asks for a password, sudoers is wrong

# Fix
echo "k8sadmin ALL=(ALL) NOPASSWD:ALL" | sudo tee /etc/sudoers.d/k8sadmin
sudo chmod 0440 /etc/sudoers.d/k8sadmin
sudo visudo -c      # Verify no syntax errors — must print "parsed OK"
```

### `Permission denied (publickey,gssapi-keyex,gssapi-with-mic)`

SSH password authentication is disabled on the node.

```bash
sudo sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
sudo systemctl restart sshd
```

### `Connection refused` on port 22

SSH is not running or the port is blocked.

```bash
# Check SSH service
sudo systemctl status sshd

# Start if not running
sudo systemctl start sshd
sudo systemctl enable sshd

# Check firewall (Ubuntu)
sudo ufw status
sudo ufw allow 22

# Check firewall (RHEL/Rocky)
sudo firewall-cmd --permanent --add-service=ssh
sudo firewall-cmd --reload
```

### Jenkins credential ID mismatch

`CredentialsUnavailableException` or similar in the pipeline.

1. Go to **Manage Jenkins → Credentials → System → Global credentials**
2. Find the row with Username `k8sadmin` — check the **ID** column
3. The ID must be exactly `K8S_SSH_CREDS`
4. If it is different (e.g. `k8s-creds`), either:
   - Edit the credential and change the ID to `K8S_SSH_CREDS`, **or**
   - Edit the Jenkinsfile `defaultValue` in the `SSH_CREDS_ID` parameter to match

### `dpkg was interrupted` on Ubuntu master

```bash
sudo dpkg --configure -a
sudo apt-get install -f
```

The scripts now do this automatically at startup, but running it manually clears the state immediately.

### `dnf: command not found` on Ubuntu

This was caused by the `&&/||` dispatch bug in older script versions. This version uses proper `if/else` for all package manager calls. Ensure you are using the latest scripts.

### Nodes stuck in `NotReady`

```bash
# On master — check node and system pod state
kubectl get nodes -o wide
kubectl get pods -n kube-system -o wide

# On the stuck node — check kubelet
sudo journalctl -u kubelet -n 100 --no-pager | grep -E 'error|Error|fail|FAIL'

# Check container runtime
sudo journalctl -u containerd -n 50 --no-pager
sudo crictl info 2>/dev/null | head -20

# Common fix: CNI not ready yet — wait 60s then retry
kubectl describe node <node-name> | grep -A5 Conditions
```

### `kubeadm init` fails: address already in use

Leftover state from a previous run:

```bash
sudo kubeadm reset -f
sudo rm -rf /etc/kubernetes /var/lib/etcd
sudo systemctl restart containerd
# Then re-run the master bootstrap
```

### Upgrade stuck: node not draining

Pods with PodDisruptionBudgets blocking eviction:

```bash
kubectl drain <node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --force \
  --disable-eviction     # bypasses PodDisruptionBudgets
```

### Join token expired

Tokens expire after 24 hours. Generate a fresh one:

```bash
# On master
kubeadm token create --print-join-command
```

Use the output as `JOIN_COMMAND` in the worker script, or simply re-run the full bootstrap pipeline.

### `synchronized is unsupported for CPS transformation`

This was the original Jenkinsfile bug. Fixed: all `synchronized(timings)` blocks replaced with `@NonCPS`-annotated `recordTiming()` helper. Ensure you are using the latest Jenkinsfile.

---

## 15. Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│  Jenkins Server  (192.168.56.10 or wherever Jenkins runs)       │
│                                                                 │
│  Reads:  hybrid-cluster/Jenkinsfile  from GitHub                │
│  Uses:   K8S_SSH_CREDS  (k8sadmin username + password)         │
│                                                                 │
│        ┌──────────────────────────────────────────────┐        │
│        │  Stage: Provision Master Node                │        │
│        │  SSH → 192.168.56.11 as k8sadmin             │        │
│        │  → 01-linux-master-setup.sh                  │        │
│        │    ├── containerd install                     │        │
│        │    ├── kubeadm init                           │        │
│        │    ├── CNI install (calico/flannel/weave)     │        │
│        │    └── /tmp/k8s-join-command.sh  (written)   │        │
│        └──────────────────────────────────────────────┘        │
│                                                                 │
│        ┌──────────────────────────────────────────────┐        │
│        │  Stage: Extract Join Command                 │        │
│        │  SSH → master → cat /tmp/k8s-join-command.sh │        │
│        └──────────────────────────────────────────────┘        │
│                                                                 │
│        ┌──────────────────────────────────────────────┐        │
│        │  Stage: Provision Worker Nodes (PARALLEL)    │        │
│        │                                              │        │
│        │  SSH → 192.168.56.12 ─┐                     │        │
│        │  SSH → 192.168.56.13 ─┤ simultaneous        │        │
│        │  SSH → 192.168.56.14 ─┘ (all workers)       │        │
│        │  → 02-linux-worker-setup.sh                  │        │
│        │    ├── containerd install                     │        │
│        │    └── kubeadm join                           │        │
│        └──────────────────────────────────────────────┘        │
└─────────────────────────────────────────────────────────────────┘

Resulting cluster:
  k8s-master    192.168.56.11   control-plane   Ready
  k8s-worker-1  192.168.56.12   worker          Ready
  k8s-worker-2  192.168.56.13   worker          Ready
```

---

## 16. Node IP Planning

Plan static IPs before running anything. All IPs must be on the same subnet and reachable from Jenkins.

| Role | Hostname | IP | Notes |
|---|---|---|---|
| Jenkins server | `jenkins` | `192.168.56.10` | Can be DHCP — it only makes outbound SSH |
| Control plane | `k8s-master` | `192.168.56.11` | Must be static — never changes |
| Worker 1 | `k8s-worker-1` | `192.168.56.12` | Must be static |
| Worker 2 | `k8s-worker-2` | `192.168.56.13` | Must be static |
| Gateway | — | `192.168.56.1` | Your hypervisor NAT or physical router |
| DNS | — | `8.8.8.8` | Or your internal DNS |

**Port requirements between nodes** (if you re-enable the firewall later):

| Port | Protocol | Direction | Purpose |
|---|---|---|---|
| 6443 | TCP | Workers → Master | Kubernetes API server |
| 2379-2380 | TCP | Master internal | etcd |
| 10250 | TCP | All → All | kubelet API |
| 10256 | TCP | All → All | kube-proxy |
| 179 | TCP | All → All | Calico BGP (if using calico) |
| 4789 | UDP | All → All | VXLAN overlay (calico/flannel) |
| 8285/8472 | UDP | All → All | Flannel overlay |

---

## 17. Security Notes

- This setup is designed for **lab / dev / CI environments**. Firewalls are disabled on cluster nodes for simplicity.
- For **production hardening**: restrict sudo to specific binaries, switch to SSH key authentication, enable firewall with only the ports listed in Section 16, and use a private CA for the Kubernetes API server.
- The kubeadm join token expires after **24 hours**. Re-running bootstrap always generates a fresh token.
- Credentials are never written to disk during a Jenkins run — they are injected via `withCredentials` and exist only in the remote shell environment for the duration of the SSH session.
- The `k8sadmin` NOPASSWD sudo grant uses `ALL=(ALL)` for simplicity. In production, restrict it to: `kubeadm`, `kubelet`, `apt-get`/`dnf`, `systemctl`, `bash /tmp/0*.sh`.


## 15. Architecture Design

### High-Level Architecture

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│                           JENKINS SERVER                                     │
│                                                                              │
│  Jenkinsfile  ────────►  Pipeline Engine  ◄────────  K8S_SSH_CREDS         │
│       │                         │                              │              │
│       └────────────── GitHub Repository ──────────────────────┘              │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │
                                   │ 1. Pre-flight
                                   │    Validate inputs / SSH / sudo / OS
                                   ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                         CONTROL PLANE / MASTER                              │
│                              192.168.56.11                                   │
│                                                                              │
│   OS Preparation → Runtime → kubeadm init → CNI → Readiness Validation      │
│                                          │                                   │
│                                          ▼                                   │
│                              Secure Join Command                             │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │
                                   │ 2. Master Ready
                                   │    Join command available
                                   │
                 ┌─────────────────┴─────────────────┐
                 │                                   │
                 │       3. WORKER PROVISIONING     │
                 │            PARALLEL               │
                 │                                   │
        ┌────────▼─────────┐               ┌────────▼─────────┐
        │     WORKER 1     │               │     WORKER 2     │
        │   192.168.56.12  │               │   192.168.56.13  │
        │                  │               │                  │
        │ Runtime          │               │ Runtime          │
        │ Kubernetes       │               │ Kubernetes       │
        │ kubelet          │               │ kubelet          │
        │ kube-proxy       │               │ kube-proxy       │
        │ CNI              │               │ CNI              │
        │ kubeadm join     │               │ kubeadm join     │
        │       │          │               │       │          │
        │       ▼          │               │       ▼          │
        │  Node Ready      │               │  Node Ready      │
        └────────┬─────────┘               └────────┬─────────┘
                 │                                   │
                 └─────────────────┬─────────────────┘
                                   │
                                   ▼
┌──────────────────────────────────────────────────────────────────────────────┐
│                     4. FINAL READINESS GATE                                  │
│                                                                              │
│  ✓ Every expected node is Ready                                             │
│  ✓ CNI pods are Running / Ready                                             │
│  ✓ CoreDNS is Running / Ready                                               │
│  ✓ kube-proxy is Running / Ready                                            │
│  ✓ Required system pods are Running / Ready                                │
│  ✓ Pod/network connectivity checks pass                                    │
│  ✓ DNS resolution checks pass                                               │
└──────────────────────────────────┬───────────────────────────────────────────┘
                                   │
                                   ▼
                         ┌─────────────────────┐
                         │  CLUSTER SUCCESS    │
                         │                     │
                         │  Healthy + Ready    │
                         └─────────────────────┘
```

### Jenkins Pipeline Flow

```text
                         ┌──────────────────────┐
                         │   Build with Params  │
                         └──────────┬───────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │   Pre-flight Checks  │
                         │                      │
                         │ Inputs / SSH / Sudo  │
                         └──────────┬───────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │  Provision Master    │
                         │                      │
                         │ Runtime + kubeadm    │
                         │ CNI + Control Plane  │
                         └──────────┬───────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │  Master Ready Gate   │
                         │                      │
                         │ CNI + CoreDNS +      │
                         │ kube-proxy healthy   │
                         └──────────┬───────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │ Extract Join Command │
                         └──────────┬───────────┘
                                    │
                     ┌──────────────┼──────────────┐
                     │              │              │
                     ▼              ▼              ▼
                ┌─────────┐    ┌─────────┐    ┌─────────┐
                │Worker 1 │    │Worker 2 │    │Worker N │
                │ PARALLEL│    │ PARALLEL│    │ PARALLEL│
                └────┬────┘    └────┬────┘    └────┬────┘
                     │              │              │
                     └──────────────┼──────────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │  Worker Ready Gate   │
                         │                      │
                         │ Every expected node  │
                         │ must become Ready    │
                         └──────────┬───────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │  Pod Readiness Gate  │
                         │                      │
                         │ All required pods   │
                         │ Running + Ready     │
                         └──────────┬───────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │ Final Validation     │
                         │                      │
                         │ DNS / Network / API  │
                         └──────────┬───────────┘
                                    │
                                    ▼
                         ┌──────────────────────┐
                         │       SUCCESS        │
                         └──────────────────────┘
```

### Lifecycle Actions

```text
┌──────────────┐
│   bootstrap  │
└──────┬───────┘
       │
       ▼
  Create Cluster
       │
       ├──────────────► Master first
       │
       └──────────────► Workers in PARALLEL
                              │
                              ▼
                       Final Readiness Gate


┌──────────────┐
│    destroy   │
└──────┬───────┘
       │
       ▼
  Teardown Cluster
       │
       ├──────────────► Master
       │
       └──────────────► Workers in PARALLEL


┌──────────────┐
│     reset    │
└──────┬───────┘
       │
       ▼
    Destroy
       │
       ▼
    Bootstrap


┌──────────────┐
│    upgrade   │
└──────┬───────┘
       │
       ▼
 Upgrade Master
       │
       ▼
 Upgrade Workers
     PARALLEL
       │
       ▼
 Final Validation
```

### Component Responsibilities

| Component | Responsibility |
|---|---|
| **Jenkins** | Orchestrates the Kubernetes lifecycle |
| **GitHub** | Stores the Jenkinsfile and automation scripts |
| **Jenkins Credentials** | Provides protected SSH credentials |
| **Master / Control Plane** | Runs Kubernetes control-plane components |
| **Worker Nodes** | Run Kubernetes workloads |
| **kubeadm** | Initializes the control plane and joins workers |
| **containerd / CRI-O** | Provides the container runtime |
| **Calico / Flannel / Weave** | Provides CNI networking |
| **kubelet** | Manages pods on each node |
| **kube-proxy** | Provides Kubernetes service networking |
| **CoreDNS** | Provides cluster DNS |
| **etcd** | Stores Kubernetes cluster state |

### Success Criteria

Jenkins should report **SUCCESS only after the final readiness checks pass**:

```text
✓ Master / control plane healthy
✓ All expected worker nodes joined
✓ All expected nodes Ready
✓ CNI healthy
✓ CoreDNS healthy
✓ kube-proxy healthy
✓ Required system pods Running and Ready
✓ Network connectivity checks passed
✓ DNS checks passed
✓ Final cluster validation passed
```

> **Jenkins SUCCESS means the cluster passed the health gates. It does not merely mean that the installation commands exited successfully.**

---

## Script Credits

**Sreekanth K**  
**Lead DevSecOps and Site Reliability Engineer**

