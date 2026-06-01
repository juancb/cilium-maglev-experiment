#!/usr/bin/env bash
# Capture VIP traffic on ALL interfaces on node1 to find the ingress path.
set -euo pipefail
CLIENT="clab-maglev-clos-client"
N1="clab-maglev-clos-node1"

echo "=== starting tcpdump on node1 any interface ==="
docker exec "$N1" rm -f /tmp/any.pcap /tmp/any.log
docker exec -d "$N1" bash -c \
  "tcpdump -i any -nn -c 50 'dst 192.0.2.10 and tcp' -w /tmp/any.pcap 2>/tmp/any.log"

sleep 1

echo "=== sending single connection from client ==="
docker exec "$CLIENT" python3 -c "
import socket
s = socket.socket()
s.bind(('203.0.113.1', 0))
s.settimeout(3)
try:
    s.connect(('192.0.2.10', 8080))
    d = s.recv(64)
    print('got:', d[:40])
    s.close()
except Exception as e:
    print('error:', e)
" 2>/dev/null

sleep 3
docker exec "$N1" pkill tcpdump 2>/dev/null || true
sleep 1

echo ""
echo "=== any-interface capture on node1 ==="
docker exec "$N1" bash -c "tcpdump -r /tmp/any.pcap -nn -e 2>/dev/null | head -20 || echo 'no packets'"
echo ""
echo "=== tcpdump log ==="
docker exec "$N1" cat /tmp/any.log 2>/dev/null

echo ""
echo "=== client routing: how does client reach 192.0.2.10? ==="
docker exec "$CLIENT" ip route get 192.0.2.10 from 203.0.113.1 2>/dev/null
docker exec "$CLIENT" ip route show default 2>/dev/null | head -3
