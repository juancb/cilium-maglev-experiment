#!/usr/bin/env bash
# Start flows and snapshot CT tables per node via cilium-dbg inside DaemonSet pods.
set -euo pipefail
N1="clab-maglev-clos-node1"
CLIENT="clab-maglev-clos-client"
KC="KUBECONFIG=/etc/rancher/k3s/k3s.yaml"

echo "=== starting 300 flows from 203.0.113.1 ==="
docker exec "$CLIENT" rm -f /tmp/ct2.json /tmp/ct2.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 300 --duration 60 \
  --src 203.0.113.1 --out /tmp/ct2.json --ready-file /tmp/ct2.ready

echo "waiting for flows..."
for i in $(seq 1 20); do
  docker exec "$CLIENT" test -f /tmp/ct2.ready 2>/dev/null && break; sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/ct2.ready 2>/dev/null || echo 0)
echo "$EST/300 flows established"
sleep 2

echo ""
echo "=== CT entries per node (via cilium-dbg in DaemonSet pod) ==="
for CILIUM_POD in cilium-5ws7n cilium-hjb8m cilium-qvm7h; do
  LINES=$(docker exec "$N1" bash -c \
    "$KC kubectl -n kube-system exec $CILIUM_POD -- cilium-dbg bpf ct list global 2>/dev/null | wc -l")
  VIP_ENTRIES=$(docker exec "$N1" bash -c \
    "$KC kubectl -n kube-system exec $CILIUM_POD -- cilium-dbg bpf ct list global 2>/dev/null | grep -c 192.0.2.10" || echo 0)
  echo "  $CILIUM_POD: total_lines=$LINES  VIP_entries=$VIP_ENTRIES"
done

echo ""
echo "=== node2 (cilium-qvm7h) CT sample ==="
docker exec "$N1" bash -c \
  "$KC kubectl -n kube-system exec cilium-qvm7h -- cilium-dbg bpf ct list global 2>/dev/null | grep 192.0.2.10 | head -10"

echo ""
echo "killing flowgen"
docker exec "$CLIENT" pkill -f flowgen.py 2>/dev/null || true
