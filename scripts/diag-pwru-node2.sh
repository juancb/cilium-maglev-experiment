#!/usr/bin/env bash
# Run pwru on node2 and tcpdump on fab0/fab1 while sending a few test flows.
# Goal: confirm whether VIP packets arrive at node2 and how they're processed.
set -euo pipefail
CLIENT="clab-maglev-clos-client"
N2="clab-maglev-clos-node2"

echo "=== cleaning up old captures ==="
docker exec "$N2" rm -f /tmp/pwru.log /tmp/fab0.pcap /tmp/fab1.pcap 2>/dev/null || true

echo "=== starting tcpdump on node2 fab0 and fab1 (any src/dst 203.0.113.1 or 192.0.2.10) ==="
docker exec -d "$N2" bash -c \
  "tcpdump -i fab0 -nn -s 100 '(host 203.0.113.1 or host 192.0.2.10)' -w /tmp/fab0.pcap 2>/tmp/fab0.log"
docker exec -d "$N2" bash -c \
  "tcpdump -i fab1 -nn -s 100 '(host 203.0.113.1 or host 192.0.2.10)' -w /tmp/fab1.pcap 2>/tmp/fab1.log"

echo "=== starting pwru on node2 (filter: 203.0.113.1) ==="
docker exec -d "$N2" bash -c \
  "pwru --filter-src-ip 203.0.113.1 --output-file /tmp/pwru.log 2>/tmp/pwru.err"

sleep 2

echo "=== sending 20 test flows from client ==="
docker exec "$CLIENT" rm -f /tmp/pw.json /tmp/pw.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 20 --duration 15 \
  --src 203.0.113.1 --out /tmp/pw.json --ready-file /tmp/pw.ready

for i in $(seq 1 15); do
  docker exec "$CLIENT" test -f /tmp/pw.ready 2>/dev/null && break; sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/pw.ready 2>/dev/null || echo 0)
echo "$EST/20 flows established"
sleep 8

echo ""
echo "=== killing pwru and tcpdump ==="
docker exec "$N2" pkill pwru 2>/dev/null || true
docker exec "$N2" pkill tcpdump 2>/dev/null || true
docker exec "$CLIENT" pkill -f flowgen.py 2>/dev/null || true
sleep 2

echo ""
echo "=== fab0 capture (first 20 packets) ==="
docker exec "$N2" bash -c "tcpdump -r /tmp/fab0.pcap -nn 2>/dev/null | head -20 || echo 'no packets or error'"

echo ""
echo "=== fab1 capture (first 20 packets) ==="
docker exec "$N2" bash -c "tcpdump -r /tmp/fab1.pcap -nn 2>/dev/null | head -20 || echo 'no packets or error'"

echo ""
echo "=== pwru output (first 40 lines) ==="
docker exec "$N2" head -40 /tmp/pwru.log 2>/dev/null || echo "no pwru output"

echo ""
echo "=== pwru stderr ==="
docker exec "$N2" cat /tmp/pwru.err 2>/dev/null | head -10
