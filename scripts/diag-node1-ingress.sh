#!/usr/bin/env bash
# tcpdump on node1 fab0/fab1 to see how VIP traffic arrives.
set -euo pipefail
CLIENT="clab-maglev-clos-client"
N1="clab-maglev-clos-node1"
N2="clab-maglev-clos-node2"

echo "=== node1 fab0/fab1 addresses ==="
docker exec "$N1" ip addr show fab0 | grep inet | head -2
docker exec "$N1" ip addr show fab1 | grep inet | head -2

echo ""
echo "=== starting tcpdump on node1 fab0 (dst 192.0.2.10) ==="
docker exec -d "$N1" bash -c "tcpdump -i fab0 -nn -c 100 dst 192.0.2.10 -w /tmp/n1fab0.pcap 2>/tmp/n1fab0.log"
docker exec -d "$N1" bash -c "tcpdump -i fab1 -nn -c 100 dst 192.0.2.10 -w /tmp/n1fab1.pcap 2>/tmp/n1fab1.log"

sleep 1

echo "=== sending 20 flows ==="
docker exec "$CLIENT" rm -f /tmp/ni.json /tmp/ni.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 20 --duration 15 \
  --src 203.0.113.1 --out /tmp/ni.json --ready-file /tmp/ni.ready

for i in $(seq 1 15); do
  docker exec "$CLIENT" test -f /tmp/ni.ready 2>/dev/null && break; sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/ni.ready 2>/dev/null || echo 0)
echo "$EST/20 flows established"
sleep 5

docker exec "$N1" pkill tcpdump 2>/dev/null || true
docker exec "$CLIENT" pkill -f flowgen.py 2>/dev/null || true
sleep 1

echo ""
echo "=== node1 fab0 capture (first 20) ==="
docker exec "$N1" bash -c "tcpdump -r /tmp/n1fab0.pcap -nn 2>/dev/null | head -20 || echo 'empty/error'"
echo "=== node1 fab0 log ==="
docker exec "$N1" cat /tmp/n1fab0.log 2>/dev/null

echo ""
echo "=== node1 fab1 capture (first 20) ==="
docker exec "$N1" bash -c "tcpdump -r /tmp/n1fab1.pcap -nn 2>/dev/null | head -20 || echo 'empty/error'"
echo "=== node1 fab1 log ==="
docker exec "$N1" cat /tmp/n1fab1.log 2>/dev/null
