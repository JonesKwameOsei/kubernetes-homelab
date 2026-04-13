#!/bin/bash
set -e

# ── Configuration ────────────────────────────────────────────────────────────
# The Gateway will get an IP from MetalLB. All HTTPRoutes in the cluster
# will point here as their parentRef.
GATEWAY_NAMESPACE="kube-system"
GATEWAY_NAME="homelab-gateway"
# ─────────────────────────────────────────────────────────────────────────────

echo "=== Creating Cilium GatewayClass ==="
# Cilium registers itself as the controller for this class during install.
kubectl apply --server-side -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: cilium
spec:
  controllerName: io.cilium/gateway-controller
EOF

echo "=== Creating homelab Gateway ==="
# Single Gateway for the whole cluster — MetalLB assigns it one external IP.
# All services are routed through HTTPRoutes hanging off this Gateway.
kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: ${GATEWAY_NAME}
  namespace: ${GATEWAY_NAMESPACE}
spec:
  gatewayClassName: cilium
  listeners:
  - name: http
    port: 80
    protocol: HTTP
    allowedRoutes:
      namespaces:
        from: All       # allows HTTPRoutes from any namespace
EOF

echo "=== Waiting for Gateway to get an external IP ==="
kubectl wait --for=condition=Programmed \
  gateway/${GATEWAY_NAME} \
  -n ${GATEWAY_NAMESPACE} \
  --timeout=120s

GATEWAY_IP=$(kubectl get gateway ${GATEWAY_NAME} -n ${GATEWAY_NAMESPACE} \
  -o jsonpath='{.status.addresses[0].value}')

echo ""
echo "Gateway is ready."
echo "External IP: ${GATEWAY_IP}"
echo ""
echo "Add DNS entries (or /etc/hosts on each machine) pointing your service"
echo "hostnames to: ${GATEWAY_IP}"
echo ""
echo "Example HTTPRoute (for any service in any namespace):"
cat <<EXAMPLE
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: my-app
  namespace: my-namespace
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    namespace: ${GATEWAY_NAMESPACE}
  hostnames:
  - "my-app.homelab.local"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: my-app-service
      port: 80
EXAMPLE
