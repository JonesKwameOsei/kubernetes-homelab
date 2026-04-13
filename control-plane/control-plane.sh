#!/bin/bash
set -e

# Must run as root
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

# ── Configuration ────────────────────────────────────────────────────────────
K8S_VERSION="1.35.3"
POD_CIDR="10.244.0.0/16"
# ─────────────────────────────────────────────────────────────────────────────

echo "=== Initializing Control Plane ==="

# Use the IP of the interface that routes to the outside world (reliable on multi-NIC machines)
CONTROL_PLANE_IP=$(ip route get 1.1.1.1 | awk 'NR==1 {print $7}')
echo "Detected control plane IP: $CONTROL_PLANE_IP"

# kube-proxy is skipped because Cilium will run in kube-proxy replacement mode.
# Do NOT remove --skip-phases=addon/kube-proxy unless switching CNI.
kubeadm init \
  --kubernetes-version="${K8S_VERSION}" \
  --pod-network-cidr="${POD_CIDR}" \
  --apiserver-advertise-address="${CONTROL_PLANE_IP}" \
  --control-plane-endpoint="${CONTROL_PLANE_IP}" \
  --skip-phases=addon/kube-proxy

# Setup kubeconfig for current user (or root if running as root)
mkdir -p "$HOME/.kube"
cp -f /etc/kubernetes/admin.conf "$HOME/.kube/config"
chown "$(id -u):$(id -g)" "$HOME/.kube/config"

echo ""
echo "=== Control plane initialized ==="
echo ""
echo "Next steps:"
echo "  1. Install Cilium CNI (kube-proxy replacement mode) before joining workers"
echo "  2. Save the 'kubeadm join' command shown above for worker nodes"
echo ""
echo "Verify control plane pods are running:"
echo "  kubectl get pods -n kube-system"
