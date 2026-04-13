#!/bin/bash
# cspell:ignore homelab socat conntrack ipvsadm chrony chronyc makestep netfilter zram zramswap kubeadm netsh portproxy wslconfig ipset
set -euo pipefail

# ============================================================
# 01-prepare-os.sh
# Prepares Debian 13 nodes for Kubernetes homelab installation.
# Supports: bare-metal Debian 13, and Debian 13 in WSL2/VM on Windows.
#
# Usage: sudo bash 01-prepare-os.sh [--node-name <name>]
# ============================================================

# --- Logging helpers -----------------------------------------
log()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*"; }
warn() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] WARN: $*" >&2; }
die()  { echo "[$(date '+%Y-%m-%d %H:%M:%S')] ERROR: $*" >&2; exit 1; }

# --- Root check ----------------------------------------------
[[ $EUID -eq 0 ]] || die "Run this script as root: sudo bash $0"

# --- Parse args ----------------------------------------------
NODE_NAME=""
while [[ $# -gt 0 ]]; do
  case $1 in
    --node-name) NODE_NAME="$2"; shift 2 ;;
    *) die "Unknown argument: $1" ;;
  esac
done

# --- Detect environment (bare-metal vs WSL2) -----------------
IS_WSL=false
if grep -qi microsoft /proc/version 2>/dev/null; then
  IS_WSL=true
  warn "Running inside WSL2. Some steps (swap, kernel modules) behave differently."
fi

log "=== Preparing OS for Kubernetes homelab ==="
[[ -n "$NODE_NAME" ]] && log "Node name: $NODE_NAME"
log "WSL2 environment: $IS_WSL"

# --- Optional: set hostname ----------------------------------
if [[ -n "$NODE_NAME" ]]; then
  log "Setting hostname to '$NODE_NAME'"
  hostnamectl set-hostname "$NODE_NAME"
fi

# --- System update & packages --------------------------------
log "Updating package lists and upgrading system..."
apt-get update -q
apt-get upgrade -y -q

log "Installing required packages..."
apt-get install -y -q \
  curl \
  git \
  ca-certificates \
  gnupg \
  lsb-release \
  socat \
  conntrack \
  ipset \
  ipvsadm \
  ethtool \
  chrony

# --- Time sync -----------------------------------------------
log "Ensuring time sync is active (chrony)..."
systemctl enable --now chrony
chronyc makestep || warn "chronyc makestep failed — time may be slightly off"

# --- Kernel modules ------------------------------------------
log "Configuring required kernel modules..."
cat <<EOF > /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF

# Load modules immediately if not already loaded
for mod in overlay br_netfilter; do
  if ! lsmod | grep -q "^${mod}"; then
    modprobe "$mod"
    log "Loaded kernel module: $mod"
  else
    log "Kernel module already loaded: $mod"
  fi
done

# --- Sysctl --------------------------------------------------
log "Applying sysctl settings for Kubernetes networking..."
cat <<EOF > /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sysctl --system -q

# --- Disable swap --------------------------------------------
log "Disabling swap..."
swapoff -a

# Disable swap in fstab (standard swap entries)
sed -i '/\bswap\b/ s/^/#/' /etc/fstab

# Debian 13 may use zram-based swap — disable it if present
if systemctl list-units --type=swap --state=active 2>/dev/null | grep -q zram; then
  log "Disabling zram swap..."
  systemctl stop "$(systemctl list-units --type=swap --state=active | grep zram | awk '{print $1}')" || true
  systemctl mask zramswap.service 2>/dev/null || true
fi

# Verify swap is off
SWAP_TOTAL=$(free -m | awk '/^Swap:/ {print $2}')
if [[ "$SWAP_TOTAL" -gt 0 ]]; then
  warn "Swap still active ($SWAP_TOTAL MB). You may need to reboot or manually disable zram."
else
  log "Swap is fully disabled."
fi

# --- Container runtime: containerd ---------------------------
log "Installing containerd..."
if command -v containerd &>/dev/null; then
  log "containerd already installed, skipping."
else
  # Add Docker's official GPG key and repo (containerd comes from Docker repo)
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian \
    $(lsb_release -cs) stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -q
  apt-get install -y -q containerd.io
fi

# Configure containerd to use systemd cgroup driver (required for kubeadm)
log "Configuring containerd (systemd cgroup driver)..."
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml

systemctl enable --now containerd
systemctl restart containerd
log "containerd is running: $(systemctl is-active containerd)"

# --- WSL2-specific notes -------------------------------------
if [[ "$IS_WSL" == true ]]; then
  log ""
  warn "========================================="
  warn "WSL2 NODE — additional manual steps required:"
  warn "  1. Ensure WSL2 kernel supports 'overlay' and 'br_netfilter'."
  warn "     Check with: uname -r (should be 5.15+ for Kubernetes support)"
  warn "  2. Ports 6443, 10250, 10255 must be forwarded from Windows host."
  warn "     Use: netsh interface portproxy add v4tov4 ..."
  warn "  3. WSL2 IP changes on restart — consider a static IP via .wslconfig"
  warn "     or use the Windows host IP with NodePort services."
  warn "  4. Systemd must be enabled in /etc/wsl.conf:"
  warn "     [boot]"
  warn "     systemd=true"
  warn "========================================="
fi

log ""
log "=== OS preparation completed successfully ==="
log "Next step: run 02-install-kubernetes.sh"
