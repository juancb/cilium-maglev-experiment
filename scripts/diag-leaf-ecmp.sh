#!/usr/bin/env bash
# Trace ECMP distribution at the leaf level: tcpdump on each leaf port going to each node.
# leaf1: eth4=node1, eth5=node2, eth6=node3
# leaf2: eth4=node1, eth5=node2, eth6=node3
set -euo pipefail
CLIENT="clab-maglev-clos-client"

echo "=== leaf1 interface -> node mapping ==="
docker exec clab-maglev-clos-leaf1 bash -c '
for iface in eth4 eth5 eth6; do
  peer_mac=$(ip -j neigh show dev $iface 2>/dev/null | python3 -c "import json,sys; n=json.load(sys.stdin); print(n[0][\"lladdr\"] if n else \"?\")" 2>/dev/null)
  ip=$(ip route show dev $iface 2>/dev/null | head -1)
  echo "  $iface: peer=$peer_mac route=$ip"
done
'

echo ""
echo "=== starting tcpdump on leaf1 eth4/eth5/eth6 for VIP traffic ==="
docker exec -d clab-maglev-clos-leaf1 bash -c \
  "tcpdump -i eth4 -nn -c 200 dst 192.0.2.10 2>/tmp/l1e4.log; echo eth4_done > /tmp/l1e4.done" &
docker exec -d clab-maglev-clos-leaf1 bash -c \
  "tcpdump -i eth5 -nn -c 200 dst 192.0.2.10 2>/tmp/l1e5.log; echo eth5_done > /tmp/l1e5.done" &
docker exec -d clab-maglev-clos-leaf1 bash -c \
  "tcpdump -i eth6 -nn -c 200 dst 192.0.2.10 2>/tmp/l1e6.log; echo eth6_done > /tmp/l1e6.done" &

sleep 1

echo "=== sending 300 flows from client ==="
docker exec "$CLIENT" rm -f /tmp/le.json /tmp/le.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 300 --duration 20 \
  --src 203.0.113.1 --out /tmp/le.json --ready-file /tmp/le.ready

for i in $(seq 1 20); do
  docker exec "$CLIENT" test -f /tmp/le.ready 2>/dev/null && break; sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/le.ready 2>/dev/null || echo 0)
echo "$EST/300 flows established"
sleep 5

echo ""
echo "=== killing tcpdump ==="
docker exec clab-maglev-clos-leaf1 pkill tcpdump 2>/dev/null || true
docker exec "$CLIENT" pkill -f flowgen.py 2>/dev/null || true
wait
sleep 1

echo ""
echo "=== packet counts per leaf1 port (dst 192.0.2.10) ==="
docker exec clab-maglev-clos-leaf1 bash -c 'for f in /tmp/l1e4.log /tmp/l1e5.log /tmp/l1e6.log; do echo "  $f:"; grep "packets captured\|packets received" $f 2>/dev/null; done'
