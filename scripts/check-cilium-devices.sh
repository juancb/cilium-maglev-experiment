#!/usr/bin/env bash
set -euo pipefail
N1="clab-maglev-clos-node1"
CPOD=$(docker exec "$N1" bash -c 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system get pod -l k8s-app=cilium -o name 2>/dev/null' | head -1 | sed 's|pod/||')

echo "=== Cilium agent config (devices/interfaces) ==="
docker exec "$N1" bash -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system exec $CPOD -- cilium-dbg config 2>/dev/null" | grep -iE "device|interface|native|nodeport" | head -20

echo ""
echo "=== Cilium node addresses ==="
docker exec "$N1" bash -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system exec $CPOD -- cilium-dbg node list 2>/dev/null" | head -5

echo ""
echo "=== node1 default route ==="
docker exec "$N1" ip route show default

echo ""
echo "=== tc ingress on eth0 and fab0 (full) ==="
docker exec "$N1" tc filter show dev eth0 ingress 2>/dev/null | head -10 || echo "eth0: none"
docker exec "$N1" tc filter show dev fab0 ingress 2>/dev/null | head -10 || echo "fab0: none"
