#!/bin/bash
set -e

# Must run as root
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

# ── Configuration ────────────────────────────────────────────────────────────
# Copy these values from the 'kubeadm join' output on the control plane.
# On the control plane run: kubeadm token create --print-join-command
CONTROL_PLANE_IP=""       # e.g. 192.168.1.100
JOIN_TOKEN=""             # e.g. abcdef.0123456789abcdef
CA_CERT_HASH=""           # e.g. sha256:abc123...
# ─────────────────────────────────────────────────────────────────────────────

if [[ -z "$CONTROL_PLANE_IP" || -z "$JOIN_TOKEN" || -z "$CA_CERT_HASH" ]]; then
  echo "ERROR: Set CONTROL_PLANE_IP, JOIN_TOKEN, and CA_CERT_HASH at the top of this script."
  echo ""
  echo "On the control plane, run:"
  echo "  kubeadm token create --print-join-command"
  exit 1
fi

echo "=== Joining as Worker ==="
echo "Control plane: ${CONTROL_PLANE_IP}:6443"

kubeadm join "${CONTROL_PLANE_IP}:6443" \
  --token "${JOIN_TOKEN}" \
  --discovery-token-ca-cert-hash "${CA_CERT_HASH}"

echo ""
echo "Worker joined. Verify from control plane:"
echo "  kubectl get nodes"
