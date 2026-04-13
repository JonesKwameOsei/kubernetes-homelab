#!/bin/bash
set -e

# Must run as root
if [[ $EUID -ne 0 ]]; then
  echo "Run as root: sudo bash $0"
  exit 1
fi

# ── Configuration ────────────────────────────────────────────────────────────
# Free IP range on your LAN, outside your router's DHCP range.
# MetalLB will hand these out to LoadBalancer Services.
METALLB_IP_RANGE="192.168.1.220-192.168.1.240"
# ─────────────────────────────────────────────────────────────────────────────

if [[ -z "$METALLB_IP_RANGE" ]]; then
  echo "ERROR: Set METALLB_IP_RANGE at the top of this script."
  echo "  Example: METALLB_IP_RANGE=\"192.168.1.240-192.168.1.250\""
  exit 1
fi

# ── Helm ─────────────────────────────────────────────────────────────────────
if ! command -v helm &>/dev/null; then
  echo "=== Helm not found — installing ==="
  curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
else
  echo "=== Helm $(helm version --short) already installed ==="
fi

# ── kubectx + kubens ─────────────────────────────────────────────────────────
# CLI tools for switching contexts and namespaces quickly.
# Installed on the control plane only (where kubectl is used interactively).
if ! command -v kubectx &>/dev/null; then
  echo "=== Installing kubectx and kubens ==="
  KUBECTX_VERSION=$(curl -fsSL https://api.github.com/repos/ahmetb/kubectx/releases/latest \
    | grep '"tag_name"' | cut -d'"' -f4)
  curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/${KUBECTX_VERSION}/kubectx_${KUBECTX_VERSION}_linux_x86_64.tar.gz" \
    | tar xz -C /usr/local/bin kubectx
  curl -fsSL "https://github.com/ahmetb/kubectx/releases/download/${KUBECTX_VERSION}/kubens_${KUBECTX_VERSION}_linux_x86_64.tar.gz" \
    | tar xz -C /usr/local/bin kubens
  chmod +x /usr/local/bin/kubectx /usr/local/bin/kubens
else
  echo "=== kubectx $(kubectx --version 2>/dev/null || echo 'already installed') ==="
fi

# Longhorn requires open-iscsi on ALL nodes before this script runs.
echo "=== Checking Longhorn prerequisites ==="
if ! command -v iscsiadm &>/dev/null; then
  echo "WARNING: iscsiadm not found."
  echo "  Run on ALL nodes first: apt-get install -y open-iscsi nfs-common"
  echo "  Then re-run this script."
  exit 1
fi

echo "=== Adding Helm repositories ==="
helm repo add metallb         https://metallb.github.io/metallb
helm repo add longhorn         https://charts.longhorn.io
helm repo add jetstack         https://charts.jetstack.io
helm repo add argo             https://argoproj.github.io/argo-helm
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana          https://grafana.github.io/helm-charts
helm repo add kyverno          https://kyverno.github.io/kyverno
helm repo add falcosecurity    https://falcosecurity.github.io/charts
helm repo add aqua             https://aquasecurity.github.io/helm-charts/
helm repo add kv2              https://code.benco.io/kubeview/deploy/helm
helm repo add kedacore          https://kedacore.github.io/charts
helm repo update

# ── MetalLB ──────────────────────────────────────────────────────────────────
echo "=== Installing MetalLB ==="
helm upgrade --install metallb metallb/metallb \
  --namespace metallb-system --create-namespace \
  --wait   # controller must be running before CRs below are applied

kubectl apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: homelab-pool
  namespace: metallb-system
spec:
  addresses:
  - ${METALLB_IP_RANGE}
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: homelab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - homelab-pool
EOF

# ── Longhorn ─────────────────────────────────────────────────────────────────
# Note: "unrecognized format int64" warnings are harmless Kubernetes 1.34+
# OpenAPI validation notices — they do not affect Longhorn functionality.
echo "=== Installing Longhorn ==="
helm upgrade --install longhorn longhorn/longhorn \
  --namespace longhorn-system --create-namespace \
  --version 1.11.1 \
  --timeout 10m \
  --wait

# ── Cert-Manager ─────────────────────────────────────────────────────────────
echo "=== Installing cert-manager ==="
helm upgrade --install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true \
  --wait

# ── Argo CD ──────────────────────────────────────────────────────────────────
echo "=== Installing Argo CD ==="
helm upgrade --install argo-cd argo/argo-cd \
  --namespace argocd --create-namespace \
  --wait

# ── Observability ─────────────────────────────────────────────────────────────
# kube-prometheus-stack bundles Prometheus + Alertmanager + Grafana.
# Do NOT add a separate Grafana install.
echo "=== Installing observability stack ==="
helm upgrade --install prometheus prometheus-community/kube-prometheus-stack \
  --namespace monitoring --create-namespace \
  --wait

# Loki in singleBinary + filesystem mode (suitable for homelab; not HA)
helm upgrade --install loki grafana/loki \
  --namespace monitoring \
  --set deploymentMode=SingleBinary \
  --set loki.commonConfig.replication_factor=1 \
  --set loki.storage.type=filesystem \
  --set loki.schemaConfig.configs[0].from=2024-01-01 \
  --set loki.schemaConfig.configs[0].store=tsdb \
  --set loki.schemaConfig.configs[0].object_store=filesystem \
  --set loki.schemaConfig.configs[0].schema=v13 \
  --set loki.schemaConfig.configs[0].index.prefix=loki_index_ \
  --set loki.schemaConfig.configs[0].index.period=24h \
  --set singleBinary.replicas=1 \
  --set backend.replicas=0 \
  --set read.replicas=0 \
  --set write.replicas=0

helm upgrade --install promtail grafana/promtail \
  --namespace monitoring \
  --set config.lokiAddress=http://loki:3100/loki/api/v1/push

# ── Security ─────────────────────────────────────────────────────────────────
echo "=== Installing security tooling ==="
helm upgrade --install kyverno kyverno/kyverno \
  --namespace kyverno --create-namespace \
  --wait

# modern_ebpf driver works on Debian 13 (kernel 6.x) without kernel headers
helm upgrade --install falco falcosecurity/falco \
  --namespace falco --create-namespace \
  --set driver.kind=modern_ebpf \
  --set tty=true

helm upgrade --install trivy-operator aqua/trivy-operator \
  --namespace trivy-system --create-namespace \
  --set trivy.ignoreUnfixed=true

# ── Prometheus Adapter ───────────────────────────────────────────────────────
# Replaces metrics-server. Bridges Prometheus metrics into the Kubernetes
# Metrics API (resource + custom + external), enabling HPA on any Prometheus
# metric — not just CPU/memory.
# prometheus.url points at the kube-prometheus-stack service in monitoring ns.
echo "=== Installing Prometheus Adapter ==="
helm upgrade --install prometheus-adapter prometheus-community/prometheus-adapter \
  --namespace monitoring \
  --set prometheus.url=http://prometheus-kube-prometheus-prometheus.monitoring.svc \
  --set prometheus.port=9090 \
  --wait

# ── KEDA ─────────────────────────────────────────────────────────────────────
# Event-driven autoscaler. Works alongside HPA to scale on external triggers:
# Prometheus metrics, HTTP traffic, queues, etc.
echo "=== Installing KEDA ==="
helm upgrade --install keda kedacore/keda \
  --namespace keda --create-namespace \
  --wait

# ── KubeView ─────────────────────────────────────────────────────────────────
# Dedicated namespace keeps cluster visualisation isolated from other tooling.
echo "=== Installing KubeView ==="
helm upgrade --install kubeview kv2/kubeview \
  --namespace kubeview --create-namespace \
  --set service.type=LoadBalancer

# ── Post-install credentials ──────────────────────────────────────────────────
echo ""
echo "=== Core addons installed ==="
echo ""
echo "Argo CD initial admin password:"
echo "  kubectl get secret argocd-initial-admin-secret -n argocd \\"
echo "    -o jsonpath='{.data.password}' | base64 -d && echo"
echo ""
echo "Grafana initial admin password:"
echo "  kubectl get secret prometheus-grafana -n monitoring \\"
echo "    -o jsonpath='{.data.admin-password}' | base64 -d && echo"
