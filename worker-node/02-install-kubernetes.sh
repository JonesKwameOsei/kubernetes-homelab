#!/bin/bash
set -e

# Must run as root
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

echo "=== Installing containerd.io (Docker repo) + Kubernetes ==="

# Update package cache first
apt-get update -y

# --- Disable swap --------------------------------------------
echo "Disabling swap..."
swapoff -a
sed -i '/\bswap\b/ s/^/#/' /etc/fstab

# Disable zram swap if present (Debian 13)
if systemctl list-units --type=swap --state=active 2>/dev/null | grep -q zram; then
  systemctl stop "$(systemctl list-units --type=swap --state=active | grep zram | awk '{print $1}')" || true
  systemctl mask zramswap.service 2>/dev/null || true
fi

SWAP_TOTAL=$(free -m | awk '/^Swap:/ {print $2}')
if [[ "$SWAP_TOTAL" -gt 0 ]]; then
  echo "WARN: Swap still active (${SWAP_TOTAL} MB). You may need to reboot or manually disable zram."
else
  echo "Swap is fully disabled."
fi

# --- containerd.io from Docker repo ---------------------------
apt-get install -y -q ca-certificates curl gnupg lsb-release

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/debian/gpg \
  | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
chmod a+r /etc/apt/keyrings/docker.gpg

echo \
  "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
  https://download.docker.com/linux/debian \
  $(lsb_release -cs) stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update -y
apt-get install -y containerd.io

# Configure containerd: systemd cgroup driver + correct pause image
mkdir -p /etc/containerd
containerd config default | tee /etc/containerd/config.toml

# Enable SystemdCgroup (required for Kubernetes)
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

# Fix pause (sandbox) image to match Kubernetes v1.35
sed -i 's|sandbox_image = "registry.k8s.io/pause:[^"]*"|sandbox_image = "registry.k8s.io/pause:3.10"|' /etc/containerd/config.toml

systemctl restart containerd && systemctl enable containerd
echo "containerd is running: $(systemctl is-active containerd)"

# --- Kubernetes repo (v1.35) ----------------------------------
mkdir -p /etc/apt/keyrings
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.35/deb/Release.key \
  | gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.35/deb/ /" \
  | tee /etc/apt/sources.list.d/kubernetes.list

apt-get update -y
apt-get install -y kubelet kubeadm kubectl
apt-mark hold kubelet kubeadm kubectl

echo "=== Runtime and Kubernetes installed successfully ==="
