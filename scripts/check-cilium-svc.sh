#!/usr/bin/env bash
set -euo pipefail
N1="clab-maglev-clos-node1"
CPOD=$(docker exec "$N1" bash -c 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system get pod -l k8s-app=cilium -o name 2>/dev/null' | head -1 | sed 's|pod/||')
echo "pod: $CPOD"
docker exec "$N1" bash -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system exec $CPOD -- cilium-dbg service list 2>/dev/null" | grep -A3 "192.0.2" || echo "192.0.2.10 not in service map"
echo ""
docker exec "$N1" bash -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system exec $CPOD -- cilium-dbg status --brief 2>/dev/null" | head -10
