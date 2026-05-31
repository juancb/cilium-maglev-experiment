#!/usr/bin/env bash
# Check Cilium BGP status and bird sessions on all nodes
set -uo pipefail
PFX="clab-maglev-clos"
N1="${PFX}-node1"

echo "=== Cilium BGP peers (via cilium CLI) ==="
docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" cilium bgp peers 2>&1 | head -30

echo
echo "=== CiliumBGPNodeConfig node1 status ==="
docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
  k3s kubectl get ciliumbgpnodeconfig node1 -o yaml 2>/dev/null | \
  grep -A 30 "status:" | head -35

echo
echo "=== bird protocols on each node ==="
for n in node1 node2 node3; do
  echo "  --- $n ---"
  docker exec "${PFX}-${n}" birdc show protocols 2>/dev/null | grep -v "^BIRD" | sed 's/^/    /'
done

echo
echo "=== bird neighbors on node1 (cilium session detail) ==="
docker exec "${PFX}-node1" birdc "show protocols" 2>/dev/null | head -20
