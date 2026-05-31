#!/usr/bin/env bash
# Diagnose Cilium BGP peering issues
set -uo pipefail
N1="clab-maglev-clos-node1"
KC() { docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" k3s kubectl "$@"; }

echo "=== CiliumBGPPeerConfig ==="
KC get ciliumbgppeerconfig -o yaml 2>&1 | head -40

echo
echo "=== node labels (hostname) ==="
KC get nodes --show-labels --no-headers 2>/dev/null | awk '{print $1, $6}' | tr ',' '\n' | grep "hostname"

echo
echo "=== Cilium BGP peers (per-node) ==="
KC get ciliumbgpnodeconfig -o yaml 2>/dev/null | grep -E "peeringState|peerAddress|routeCount|advertised|received" | head -30

echo
echo "=== bird log on node1 (last 10 lines) ==="
docker exec clab-maglev-clos-node1 birdc log 2>/dev/null | tail -10 || \
  docker exec clab-maglev-clos-node1 cat /var/log/bird.log 2>/dev/null | tail -10 || \
  echo "(no bird log found)"
