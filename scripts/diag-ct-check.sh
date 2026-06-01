#!/usr/bin/env bash
# Check CT entry distribution across nodes to verify traffic ingress split.
set -euo pipefail
CLIENT="clab-maglev-clos-client"
N1="clab-maglev-clos-node1"
N2="clab-maglev-clos-node2"
N3="clab-maglev-clos-node3"

echo "=== starting 300 flows from 203.0.113.1 ==="
docker exec "$CLIENT" rm -f /tmp/diag.json /tmp/diag.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 300 --duration 60 \
  --src 203.0.113.1 --out /tmp/diag.json --ready-file /tmp/diag.ready

echo "waiting for flows to establish..."
for i in $(seq 1 20); do
  docker exec "$CLIENT" test -f /tmp/diag.ready 2>/dev/null && break
  sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/diag.ready 2>/dev/null || echo 0)
echo "$EST/300 flows established"
sleep 2

echo ""
echo "=== CT entries per node (src=203.0.113.1 → VIP) ==="
for NODE in $N1 $N2 $N3; do
  COUNT=$(docker exec "$NODE" cilium bpf ct list global 2>/dev/null \
    | grep -c "203.0.113.1" 2>/dev/null || echo 0)
  echo "  $NODE: $COUNT"
done

echo ""
echo "=== fab interface rx packets on node2 ==="
docker exec "$N2" cat /proc/net/dev | grep fab || true

echo ""
echo "killing flowgen"
docker exec "$CLIENT" pkill -f flowgen.py 2>/dev/null || true
