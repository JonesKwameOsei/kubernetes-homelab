#!/bin/bash
# Run on control plane after all nodes have joined and Cilium is installed.

echo "=== Node status ==="
kubectl get nodes -o wide

echo ""
echo "=== Cilium status ==="
cilium status

echo ""
echo "=== GatewayClass (expect 'cilium' with ACCEPTED=True) ==="
kubectl get gatewayclass

echo ""
echo "=== Core system pods ==="
kubectl get pods -n kube-system

echo ""
echo "=== MetalLB pods ==="
kubectl get pods -n metallb-system

echo ""
echo "=== All namespaces overview ==="
kubectl get pods -A --field-selector=status.phase!=Running 2>/dev/null | head -40
echo "(Only non-Running pods shown above — empty means all healthy)"
