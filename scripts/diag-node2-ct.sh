#!/usr/bin/env bash
# Check how many CT entries node2 holds vs node1/node3 during active flows.
set -euo pipefail
CLIENT="clab-maglev-clos-client"
N1="clab-maglev-clos-node1"
N2="clab-maglev-clos-node2"
N3="clab-maglev-clos-node3"

echo "=== starting 300 flows from 203.0.113.1 ==="
docker exec "$CLIENT" rm -f /tmp/ct.json /tmp/ct.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 300 --duration 60 \
  --src 203.0.113.1 --out /tmp/ct.json --ready-file /tmp/ct.ready

echo "waiting for flows..."
for i in $(seq 1 20); do
  docker exec "$CLIENT" test -f /tmp/ct.ready 2>/dev/null && break; sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/ct.ready 2>/dev/null || echo 0)
echo "$EST/300 flows established"
sleep 2

echo ""
echo "=== CT table snapshot (SYN/ESTABLISHED entries per node) ==="
for NODE in $N1 $N2 $N3; do
  TOTAL=$(docker exec "$NODE" cilium bpf ct list global 2>/dev/null | wc -l || echo 0)
  VIP=$(docker exec "$NODE" cilium bpf ct list global 2>/dev/null \
    | grep -c "192.0.2.10" 2>/dev/null || echo 0)
  CLIENT_IP=$(docker exec "$NODE" cilium bpf ct list global 2>/dev/null \
    | grep -c "203.0.113.1" 2>/dev/null || echo 0)
  echo "  $NODE: total=$TOTAL  with-VIP=$VIP  with-client-IP=$CLIENT_IP"
done

echo ""
echo "=== node2 CT entries sample (first 20 lines) ==="
docker exec "$N2" cilium bpf ct list global 2>/dev/null | head -20

echo ""
echo "killing flowgen"
docker exec "$CLIENT" pkill -f flowgen.py 2>/dev/null || true
