#!/usr/bin/env bash
# Check which nodes are actually serving as ingress for VIP flows,
# and verify what source IP the echo pods see (SNAT or client IP preserved).
set -uo pipefail
LAB="maglev-clos"
VIP="192.0.2.10"
CLIENT="clab-${LAB}-client"
KC="docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml clab-${LAB}-node1 k3s kubectl"

echo "=== 1. Start 10 background flows from client ==="
for i in $(seq 1 10); do
  docker exec -d "$CLIENT" bash -c "exec 3<>/dev/tcp/${VIP}/8080; cat <&3 > /tmp/flow_${i}.out 2>/dev/null" 2>/dev/null
done
sleep 3

echo "=== 2. Conntrack entries on each node (who is serving the flows) ==="
for n in node1 node2 node3; do
  N="clab-${LAB}-${n}"
  ct=$(docker exec "$N" conntrack -L 2>/dev/null | grep -c "${VIP}" || echo 0)
  echo "  ${n}: ${ct} conntrack entries for VIP"
done

echo "=== 3. What IP does the echo pod see as source? ==="
# Check pod logs for the connection source IP
echo "    Checking Cilium BPF nat table on node3 (maps flow through ingress nodes):"
$KC -n kube-system exec cilium-bz9hr -- cilium-dbg bpf nat list 2>/dev/null | grep "192.0.2.10" | head -5

echo "=== 4. Kill background flows ==="
docker exec "$CLIENT" pkill -f "cat <&3" 2>/dev/null || true
