#!/bin/bash
set -e

# Must run as root
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

# ── Configuration ────────────────────────────────────────────────────────────
CILIUM_VERSION="1.19.2"
GATEWAY_API_VERSION="v1.2.1"
# ─────────────────────────────────────────────────────────────────────────────

echo "=== Installing Gateway API CRDs ==="
# Must be installed BEFORE Cilium when gatewayAPI.enabled=true
kubectl apply -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/${GATEWAY_API_VERSION}/standard-install.yaml"

echo "=== Installing Cilium CLI ==="
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH="amd64" ;;
  aarch64) ARCH="arm64" ;;
  *)       echo "Unsupported architecture: $ARCH"; exit 1 ;;
esac

CILIUM_CLI_VERSION=$(curl -fsSL https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
curl -L --fail --remote-name-all \
  "https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${ARCH}.tar.gz{,.sha256sum}"
sha256sum --check "cilium-linux-${ARCH}.tar.gz.sha256sum"
tar xzvfC "cilium-linux-${ARCH}.tar.gz" /usr/local/bin
rm "cilium-linux-${ARCH}.tar.gz"*

echo "=== Installing Cilium ${CILIUM_VERSION} ==="
# kubeProxyReplacement=true: Cilium fully replaces kube-proxy (must match --skip-phases=addon/kube-proxy in control-plane.sh)
cilium install \
  --version="${CILIUM_VERSION}" \
  --namespace=kube-system \
  --set kubeProxyReplacement=true \
  --set gatewayAPI.enabled=true \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set prometheus.enabled=true \
  --set operator.prometheus.enabled=true

cilium status --wait
echo "Cilium ${CILIUM_VERSION} installed with Gateway API and Hubble."
