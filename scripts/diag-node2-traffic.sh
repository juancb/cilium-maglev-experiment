#!/usr/bin/env bash
# Run 300 flows and check if ANY VIP traffic arrives on node2's fabric interfaces.
set -euo pipefail
CLIENT="clab-maglev-clos-client"
N2="clab-maglev-clos-node2"

echo "=== starting tcpdump on node2 fab0 and fab1 for VIP traffic ==="
docker exec -d "$N2" bash -c "tcpdump -i fab0 -nn -c 500 dst 192.0.2.10 -w /tmp/fab0_vip.pcap 2>/tmp/fab0_vip.log"
docker exec -d "$N2" bash -c "tcpdump -i fab1 -nn -c 500 dst 192.0.2.10 -w /tmp/fab1_vip.pcap 2>/tmp/fab1_vip.log"

echo "=== starting 300 flows from client ==="
docker exec "$CLIENT" rm -f /tmp/t2.json /tmp/t2.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 300 --duration 20 \
  --src 203.0.113.1 --out /tmp/t2.json --ready-file /tmp/t2.ready

echo "waiting for flows..."
for i in $(seq 1 20); do
  docker exec "$CLIENT" test -f /tmp/t2.ready 2>/dev/null && break; sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/t2.ready 2>/dev/null || echo 0)
echo "$EST/300 flows established"
sleep 10

echo ""
echo "=== node2 tcpdump stats ==="
docker exec "$N2" cat /tmp/fab0_vip.log 2>/dev/null || echo "fab0: no output yet"
docker exec "$N2" cat /tmp/fab1_vip.log 2>/dev/null || echo "fab1: no output yet"

# Also check packet counts directly
echo ""
echo "=== node2 fab0/fab1 RX packet counts now vs start ==="
docker exec "$N2" cat /proc/net/dev | grep -E "fab0|fab1"

echo ""
echo "killing flowgen and tcpdump"
docker exec "$CLIENT" pkill -f flowgen.py 2>/dev/null || true
docker exec "$N2" pkill tcpdump 2>/dev/null || true

sleep 2
echo ""
echo "=== pcap packet counts ==="
docker exec "$N2" bash -c "tcpdump -r /tmp/fab0_vip.pcap --count 2>/dev/null | tail -1 || echo 'fab0: 0 packets or error'"
docker exec "$N2" bash -c "tcpdump -r /tmp/fab1_vip.pcap --count 2>/dev/null | tail -1 || echo 'fab1: 0 packets or error'"
