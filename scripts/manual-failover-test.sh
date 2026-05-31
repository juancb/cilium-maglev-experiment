#!/usr/bin/env bash
# Manual failover test: single connection, node2 down, see if it breaks
set -uo pipefail
LAB="maglev-clos"
VIP="192.0.2.10"
CLIENT="clab-${LAB}-client"

echo "=== restart node2 if needed ==="
docker start "clab-${LAB}-node2" 2>/dev/null || true
docker exec -d "clab-${LAB}-node2" bash /opt/startup.sh 2>/dev/null || true
sleep 12

echo "=== wait for leaf ECMP to have 3 nexthops ==="
for i in $(seq 1 20); do
  n=$(docker exec "clab-${LAB}-leaf1" vtysh -c "show ip route ${VIP}/32" 2>/dev/null | grep -cE '^\s+\* 10\.' || true)
  [ "${n:-0}" -ge 3 ] && { echo "  leaf1 has 3 nexthops"; break; }
  echo "  waiting [$i]: $n nexthops"
  sleep 3
done

echo "=== which ingress node serves a single flow? ==="
# Start one background flow, check conntrack
docker exec -d "$CLIENT" bash -c 'exec 3<>/dev/tcp/${VIP}/8080; while true; do echo -n "."; sleep 1; read -t 2 -u 3 x || break; done > /tmp/flow1.log 2>&1' 2>/dev/null
sleep 2
echo "=== BPF CT on each node ==="
for n in node1 node2 node3; do
  POD=$(docker exec clab-maglev-clos-node1 k3s kubectl -n kube-system get pod \
    --field-selector "spec.nodeName=${n}" -l k8s-app=cilium -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  CT=$(docker exec clab-maglev-clos-node1 k3s kubectl -n kube-system exec "$POD" \
    -- cilium-dbg bpf ct list global 2>/dev/null | grep -c "$VIP" || echo "?")
  echo "  ${n} ($POD): ${CT} CT entries for VIP"
done

echo "=== stop node2 ==="
docker stop "clab-${LAB}-node2" >/dev/null

echo "=== waiting 15s for BGP reconverge ==="
sleep 15

echo "=== flow still alive? ==="
docker exec "$CLIENT" test -f /tmp/flow1.log && tail -c 20 /tmp/flow1.log || echo "log missing"

echo "=== kill flow ==="
docker exec "$CLIENT" pkill -f 'exec 3<>/dev/tcp' 2>/dev/null || true
