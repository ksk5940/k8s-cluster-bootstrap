# Kubernetes Cluster Bootstrap

A single-node bootstrap utility for preparing and initializing Kubernetes nodes across Ubuntu/Debian and RHEL-family systems such as Rocky Linux.

This repository provides a monolithic `k8s-cluster-bootstrap.sh` workflow that can initialize a Kubernetes control-plane/worker node, upgrade Kubernetes, reset cluster state, or completely uninstall Kubernetes-related components.

> **Important:** This README describes the current `k8s-cluster-bootstrap.sh` implementation in the repository. Always review your environment, network policy, firewall requirements, and Kubernetes/CNI versions before using it in production.

## Features

- Kubernetes node bootstrap using `kubeadm`
- Supports control-plane and worker roles
- Ubuntu/Debian support
- Rocky/RHEL/CentOS/AlmaLinux-family support
- Automatic host-only network/interface detection
- Optional host CIDR override
- Optional pod CIDR override
- Optional node-role override
- Time synchronization configuration
- Kernel modules and Kubernetes sysctl configuration
- DNS resolver configuration
- Kubernetes package repository configuration
- Kubernetes version selection by full patch version
- `containerd` or CRI-O runtime selection
- Calico or other supported CNI selection through the interactive workflow
- Idempotent behavior for already-installed Kubernetes components
- Dedicated logs for init, reset, upgrade, and destroy operations
- Cluster reset without removing installed packages
- Full destroy/uninstall mode

The script documents idempotent behavior and host-only network handling directly in its built-in usage information. urlSource scripthttps://github.com/ksk5940/k8s-cluster-bootstrap/blob/main/k8s-cluster-bootstrap.sh

## Requirements

### Operating systems

The script detects and handles:

- Ubuntu / Debian
- Rocky Linux
- RHEL-family systems including CentOS and AlmaLinux

### Required access

Run the script as root or through `sudo`.

```bash
sudo -v
```

The host needs network access to the repositories and container registries required by the selected Kubernetes version, runtime, and CNI.

### Recommended host prerequisites

- Working hostname
- Working DNS
- Correct default route
- Stable node IP
- Internet/repository access
- Sufficient CPU, RAM, and disk for Kubernetes
- Swap disabled or otherwise handled according to Kubernetes requirements
- Required firewall ports permitted between cluster nodes

## Installation

Clone the repository:

```bash
git clone https://github.com/ksk5940/k8s-cluster-bootstrap.git
cd k8s-cluster-bootstrap
```

Make the script executable:

```bash
chmod +x k8s-cluster-bootstrap.sh
```

Check the built-in help:

```bash
sudo ./k8s-cluster-bootstrap.sh --help
```

## Usage

```text
sudo ./k8s-cluster-bootstrap.sh <mode> [flags]
```

### Modes

#### Initialize

```bash
sudo ./k8s-cluster-bootstrap.sh --init
```

Initializes the node and performs the appropriate control-plane or worker bootstrap workflow.

#### Upgrade

```bash
sudo ./k8s-cluster-bootstrap.sh --upgrade
```

Runs the Kubernetes upgrade workflow.

#### Reset

```bash
sudo ./k8s-cluster-bootstrap.sh --reset
```

Resets Kubernetes cluster state while keeping installed packages.

#### Destroy

```bash
sudo ./k8s-cluster-bootstrap.sh --destroy
```

Performs the full uninstall workflow.

> **Warning:** `--reset` and especially `--destroy` are destructive operations. Review the script and verify the target node before running them.

These four modes are implemented by the script's argument parser. urlScript usage and modeshttps://github.com/ksk5940/k8s-cluster-bootstrap/blob/main/k8s-cluster-bootstrap.sh

## Command-line flags

### Node type

Override automatic role detection:

```bash
sudo ./k8s-cluster-bootstrap.sh --init --node-type master
```

or:

```bash
sudo ./k8s-cluster-bootstrap.sh --init --node-type worker
```

Valid values are:

```text
master
worker
```

### Host CIDR

Override automatic host-only network detection:

```bash
sudo ./k8s-cluster-bootstrap.sh \
  --init \
  --host-cidr 192.168.56.0/24
```

This is useful for VirtualBox/VMware host-only networks or environments where automatic interface detection cannot identify the intended cluster network.

### Pod CIDR

Override the default pod network CIDR:

```bash
sudo ./k8s-cluster-bootstrap.sh \
  --init \
  --pod-cidr 10.244.0.0/16
```

The current default is:

```text
10.244.0.0/16
```

Do not select a pod CIDR that overlaps with the node/host network or another routed network.

### Timezone

Set the system timezone:

```bash
sudo ./k8s-cluster-bootstrap.sh \
  --init \
  --timezone Asia/Kolkata
```

The script validates the requested timezone before applying it. If no timezone is supplied, the existing timezone is retained. citeturn2view2

## Example: Ubuntu control-plane node

```bash
sudo ./k8s-cluster-bootstrap.sh \
  --init \
  --node-type master \
  --host-cidr 192.168.56.0/24 \
  --pod-cidr 10.244.0.0/16 \
  --timezone Asia/Kolkata
```

## Example: worker node

```bash
sudo ./k8s-cluster-bootstrap.sh \
  --init \
  --node-type worker \
  --host-cidr 192.168.56.0/24 \
  --timezone Asia/Kolkata
```

For a worker to join an existing cluster, the required cluster/master information must be available through the workflow used by the repository.

## Kubernetes version selection

The script supports selecting a full Kubernetes patch version such as:

```text
1.32.3
```

It validates the requested minor-version repository channel before continuing.

The current built-in version table contains Kubernetes minor versions `1.30` through `1.35`, with patch versions listed by the script. Because Kubernetes repositories and support status change over time, verify the selected version before deployment rather than treating the static table as an authoritative current-release list. citeturn1view0

For unattended execution, the script has a default version selection when no input is provided.

## Container runtime

The script detects an already-installed runtime when possible.

If no runtime is detected, the interactive workflow offers:

```text
1) containerd
2) CRI-O
```

`containerd` is presented as the default/recommended option, while CRI-O is available as an OCI-native Kubernetes-focused alternative. citeturn2view3

For containerd, the script configures:

```text
SystemdCgroup = true
```

and pins the sandbox/pause image configuration to:

```text
registry.k8s.io/pause:3.10
```

citeturn1view0

## Networking

The bootstrap performs network preparation before Kubernetes installation.

It configures:

```text
overlay
br_netfilter
```

and Kubernetes-related sysctls including:

```text
net.bridge.bridge-nf-call-iptables = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward = 1
```

citeturn1view0

The script also attempts to identify the intended host-only interface and persist node/network information for subsequent operations.

## DNS

On Ubuntu/Debian, the script enables `systemd-resolved` and uses:

```text
/run/systemd/resolve/resolv.conf
```

when available.

On RHEL-family systems, it ensures a nameserver is present in `/etc/resolv.conf`.

Review this behavior if your organization manages DNS through NetworkManager, systemd-resolved, DHCP, VPN software, or another configuration-management system. citeturn1view0

## Idempotency

The script attempts to avoid unnecessary reinstallation.

When Kubernetes components are already installed, it detects installed versions and can reuse them instead of forcing a fresh version selection. Workers can also consume the Kubernetes version persisted by the control-plane workflow.

The script stores state such as:

```text
/etc/kubernetes/k8s-version.txt
/etc/kubernetes/cni-config.txt
/etc/kubernetes/cni-iface.txt
/etc/kubernetes/node-type.txt
```

This state is used by subsequent operations. citeturn3view0

## Logs

The script uses separate log files by operation:

```text
/var/log/k8s-init.log
/var/log/k8s-reset.log
/var/log/k8s-upgrade.log
/var/log/k8s-destroy.log
```

A fallback/default log path is also defined before the active mode is selected. citeturn3view0

Inspect logs with:

```bash
sudo less /var/log/k8s-init.log
```

or:

```bash
sudo tail -f /var/log/k8s-init.log
```

## Validation after bootstrap

After initialization, verify:

```bash
kubectl get nodes -o wide
```

Then:

```bash
kubectl get pods -A -o wide
```

For a healthy cluster, verify that:

- Control-plane components are running
- Every expected node is `Ready`
- CNI pods are running/ready
- CoreDNS is running/ready
- kube-proxy is running/ready
- No unexpected `Pending`
- No `ImagePullBackOff`
- No `ErrImagePull`
- No `CrashLoopBackOff`

For troubleshooting:

```bash
kubectl get events -A --sort-by=.lastTimestamp
```

and:

```bash
kubectl describe pod <pod-name> -n <namespace>
```

## Common image-pull issue

A node can successfully join Kubernetes but remain `NotReady` if it cannot pull the CNI or other required images.

Check:

```bash
kubectl get pods -A -o wide
```

Then inspect the affected node/pod:

```bash
kubectl describe pod <calico-pod> -n kube-system
```

Also test registry connectivity directly from the affected node.

For environments with IPv6 DNS resolution but no usable IPv6 route, container image pulls can fail even though other parts of the bootstrap work. Ensure the node has working registry connectivity before expecting CNI pods to become ready.

## Reset vs Destroy

### `--reset`

Use when you want to remove/reset Kubernetes cluster state but retain installed packages.

```bash
sudo ./k8s-cluster-bootstrap.sh --reset
```

This is useful when rebuilding cluster state without reinstalling the operating-system packages.

### `--destroy`

Use when you want a much more complete Kubernetes uninstall.

```bash
sudo ./k8s-cluster-bootstrap.sh --destroy
```

Treat this as destructive. Do not run it against a production node unless you have verified exactly what data and services must be preserved.

## Security considerations

- Run only on intended Kubernetes nodes.
- Review firewall changes before production use.
- Do not expose bootstrap tokens or kubeadm join commands in public logs.
- Protect `/etc/kubernetes` and `/var/log/k8s-*`.
- Use least-privilege SSH/sudo access where possible.
- Verify repository signing keys and package sources.
- Use pinned Kubernetes patch versions for repeatable deployments.
- Test upgrades in a non-production environment first.
- Do not assume internet access is available on every cluster node.

## Troubleshooting checklist

### Node is `NotReady`

```bash
kubectl describe node <node>
```

Then:

```bash
kubectl get pods -A -o wide
```

Check CNI pods first.

### Calico is stuck in `ImagePullBackOff`

```bash
kubectl describe pod <calico-pod> -n kube-system
```

Check:

```bash
ip route
ip -6 route
curl -4 -I https://registry-1.docker.io/v2/
```

and container-runtime status:

```bash
sudo systemctl status crio
```

or:

```bash
sudo systemctl status containerd
```

### Kubelet problems

```bash
sudo systemctl status kubelet
sudo journalctl -u kubelet -n 100 --no-pager
```

### Runtime problems

CRI-O:

```bash
sudo systemctl status crio
sudo journalctl -u crio -n 100 --no-pager
```

containerd:

```bash
sudo systemctl status containerd
sudo journalctl -u containerd -n 100 --no-pager
```

### DNS problems

```bash
resolvectl status
cat /etc/resolv.conf
getent hosts registry-1.docker.io
```

## Repository

Project:

urlksk5940/k8s-cluster-bootstraphttps://github.com/ksk5940/k8s-cluster-bootstrap

Monolithic bootstrap script:

urlk8s-cluster-bootstrap.shhttps://github.com/ksk5940/k8s-cluster-bootstrap/blob/main/k8s-cluster-bootstrap.sh

## License

Add the repository's chosen license here if/when one is formally defined for the project.

## Disclaimer

This script performs system-level changes including package installation, runtime configuration, kernel/sysctl configuration, networking, Kubernetes initialization, reset, upgrade, and destruction.

Test changes on disposable/lab nodes before using them on production systems.
