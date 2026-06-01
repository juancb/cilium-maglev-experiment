#!/usr/bin/env bash
# Check what the client actually sends on eth1 when connecting to the VIP.
# If socket-LB is intercepting, packets will go to a pod IP, not 192.0.2.10.
set -euo pipefail
CLIENT="clab-maglev-clos-client"

echo "=== client interfaces ==="
docker exec "$CLIENT" ip addr show | grep -E "^[0-9]|inet " | head -20

echo ""
echo "=== starting tcpdump on client eth1 ==="
docker exec "$CLIENT" rm -f /tmp/cli.pcap /tmp/cli.log
docker exec -d "$CLIENT" bash -c \
  "tcpdump -i eth1 -nn -c 30 '(tcp and not port 22) or port 53' -w /tmp/cli.pcap 2>/tmp/cli.log"

sleep 1

echo "=== single connection from 203.0.113.1 to VIP ==="
docker exec "$CLIENT" python3 -c "
import socket
s = socket.socket()
s.bind(('203.0.113.1', 55555))
s.settimeout(3)
try:
    s.connect(('192.0.2.10', 8080))
    d = s.recv(64)
    print('backend said:', d[:60].decode())
    s.close()
except Exception as e:
    print('error:', e)
" 2>/dev/null

sleep 2
docker exec "$CLIENT" pkill tcpdump 2>/dev/null || true
sleep 1

echo ""
echo "=== client eth1 capture ==="
docker exec "$CLIENT" bash -c "tcpdump -r /tmp/cli.pcap -nn 2>/dev/null | head -20 || echo 'no packets'"
echo ""
echo "=== tcpdump log ==="
docker exec "$CLIENT" cat /tmp/cli.log 2>/dev/null

echo ""
echo "=== check cgroup BPF on client ==="
docker exec "$CLIENT" bash -c "ls /sys/fs/bpf/ 2>/dev/null"
docker exec "$CLIENT" bash -c "mount | grep cgroup" | head -5
