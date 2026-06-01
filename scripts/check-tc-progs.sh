#!/usr/bin/env bash
set -euo pipefail
N1="clab-maglev-clos-node1"
echo "=== TC programs on node1 interfaces ==="
docker exec "$N1" bash -c "for iface in \$(ip link show | grep '^[0-9]' | awk -F': ' '{print \$2}' | tr -d '@' | cut -d@ -f1); do
  echo -n \"\$iface: \"
  tc filter show dev \$iface ingress 2>/dev/null | grep -c bpf || echo 0
done"

echo ""
echo "=== Cilium detected devices ==="
CPOD=$(docker exec "$N1" bash -c 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system get pod -l k8s-app=cilium -o name 2>/dev/null' | head -1 | sed 's|pod/||')
docker exec "$N1" bash -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system exec $CPOD -- cilium-dbg config 2>/dev/null" | grep -iE "device|interface" | head -10
