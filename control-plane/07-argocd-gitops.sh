#!/bin/bash
set -e

# ── Configuration ────────────────────────────────────────────────────────────
# Your Git repo where Argo CD will watch for manifests.
# Create a repo at GitHub/Gitea and set the URL here before running.
ARGOCD_REPO_URL="https://github.com/JonesKwameOsei/homelab-gitops"
ARGOCD_HOSTNAME="argocd.homelab.local"   # hostname for the Argo CD UI HTTPRoute
GATEWAY_NAME="homelab-gateway"
GATEWAY_NAMESPACE="kube-system"
# ─────────────────────────────────────────────────────────────────────────────

if [[ -z "$ARGOCD_REPO_URL" ]]; then
  echo "ERROR: Set ARGOCD_REPO_URL at the top of this script."
  exit 1
fi

echo "=== Exposing Argo CD UI via HTTPRoute ==="
# Argo CD server must be in insecure mode when TLS is terminated at the Gateway.
kubectl patch configmap argocd-cmd-params-cm -n argocd \
  --type merge \
  -p '{"data":{"server.insecure":"true"}}'

kubectl rollout restart deployment argo-cd-argocd-server -n argocd
kubectl rollout status deployment argo-cd-argocd-server -n argocd --timeout=120s

kubectl apply -f - <<EOF
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: argocd
  namespace: argocd
spec:
  parentRefs:
  - name: ${GATEWAY_NAME}
    namespace: ${GATEWAY_NAMESPACE}
  hostnames:
  - "${ARGOCD_HOSTNAME}"
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /
    backendRefs:
    - name: argo-cd-argocd-server
      port: 80
EOF

echo "=== Bootstrapping Argo CD with your GitOps repo ==="
# Log in with the initial admin password
ARGOCD_PASSWORD=$(kubectl get secret argocd-initial-admin-secret -n argocd \
  -o jsonpath='{.data.password}' | base64 -d)

argocd login --port-forward \
  --port-forward-namespace argocd \
  --username admin \
  --password "${ARGOCD_PASSWORD}" \
  --plaintext

# Register the GitOps repo
argocd repo add "${ARGOCD_REPO_URL}" \
  --port-forward --port-forward-namespace argocd --plaintext

# Create the root App-of-Apps pointing at the repo root.
# Your repo should have an 'apps/' folder with Application manifests.
argocd app create root \
  --repo "${ARGOCD_REPO_URL}" \
  --path apps \
  --dest-server https://kubernetes.default.svc \
  --dest-namespace argocd \
  --sync-policy automated \
  --auto-prune \
  --self-heal \
  --port-forward --port-forward-namespace argocd --plaintext

argocd app sync root \
  --port-forward --port-forward-namespace argocd --plaintext

echo ""
echo "=== Argo CD GitOps bootstrap complete ==="
echo ""
echo "UI:      http://${ARGOCD_HOSTNAME}"
echo "User:    admin"
echo "Pass:    ${ARGOCD_PASSWORD}"
echo ""
echo "Recommended: change the password immediately:"
echo "  argocd account update-password"
echo ""
echo "GitOps repo layout expected:"
echo "  ${ARGOCD_REPO_URL}"
echo "  └── apps/"
echo "      ├── app1.yaml   (Argo CD Application manifest)"
echo "      └── app2.yaml"
