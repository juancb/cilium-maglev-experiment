#!/usr/bin/env bash
# Test VIP connectivity from each node
set -uo pipefail
VIP="192.0.2.10"
PORT="8080"
for n in clab-maglev-clos-node1 clab-maglev-clos-node2 clab-maglev-clos-node3; do
  echo -n "  $n → VIP: "
  RES=$(docker exec "$n" bash -c "exec 3<>/dev/tcp/${VIP}/${PORT}; head -c 50 <&3 2>/dev/null" 2>/dev/null)
  if [ -n "$RES" ]; then
    echo "$RES"
  else
    # Try with a longer read to see if it's a timing issue
    RES2=$(docker exec "$n" bash -c "exec 3<>/dev/tcp/${VIP}/${PORT}; timeout 3 cat <&3 2>/dev/null | head -c 50" 2>/dev/null)
    [ -n "$RES2" ] && echo "$RES2" || echo "no response"
  fi
done
echo "=== Cilium BPF LB on node1 (confirm Maglev) ==="
docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml clab-maglev-clos-node1 k3s kubectl -n kube-system exec cilium-7fxg4 -- cilium-dbg bpf lb list 2>/dev/null | grep 192.0.2 | head -8
