#!/usr/bin/env bash
# Quick state check: VIP routes, BGP, pod distribution, VIP reachability, Cilium pod status
set -uo pipefail
PFX="clab-maglev-clos"
VIP="192.0.2.10"
CLIENT="${PFX}-client"
N1="${PFX}-node1"
KC="docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml $N1 k3s kubectl"

echo "=== k8s nodes ==="
$KC get nodes 2>/dev/null || echo "(kubectl failed)"

echo ""
echo "=== cilium pods ==="
$KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers 2>/dev/null || echo "(kubectl failed)"

echo "=== VIP route on each node ==="
for n in node1 node2 node3; do
  echo -n "  $n: "
  docker exec "${PFX}-$n" ip route show "$VIP" 2>/dev/null || echo "MISSING"
done

echo
echo "=== bird BGP status on each node ==="
for n in node1 node2 node3; do
  echo "  --- $n ---"
  docker exec "${PFX}-$n" birdc show protocols 2>/dev/null | grep -E "uplink|cilium" | sed 's/^/    /'
done

echo
echo "=== leaf1 BGP neighbors (node-facing) ==="
docker exec "${PFX}-leaf1" vtysh -c "show bgp summary" 2>/dev/null | grep -E "10\.3\.1\."

echo
echo "=== echo pod distribution ==="
docker exec "${PFX}-node1" k3s kubectl get pods -l app=echo -o wide --no-headers 2>/dev/null | \
  awk '{print "  " $8 ": " $1 " " $7}' | sort

echo
echo "=== VIP reachability from client ==="
docker exec "$CLIENT" ping -c2 -W2 "$VIP" 2>/dev/null | tail -2 || echo "  (ping failed)"
