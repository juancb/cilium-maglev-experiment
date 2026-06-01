#!/usr/bin/env bash
# Run pwru on node1 to trace ingress path of VIP packets.
# pwru uses pcap-filter syntax as positional arg.
set -euo pipefail
CLIENT="clab-maglev-clos-client"
N1="clab-maglev-clos-node1"
N2="clab-maglev-clos-node2"

echo "=== node1 interfaces ==="
docker exec "$N1" ip -o link show | awk -F'[ :@]+' '{print $2}' | grep -v lo | head -15

echo ""
echo "=== starting pwru on node1 (src host 203.0.113.1) ==="
docker exec -d "$N1" bash -c \
  "pwru 'src host 203.0.113.1 and dst port 8080' > /tmp/pwru_n1.log 2>/tmp/pwru_n1.err"

echo "=== starting tcpdump on spine1 for VIP packets ==="
docker exec -d clab-maglev-clos-spine1 bash -c \
  "tcpdump -i any -nn -c 200 'dst 192.0.2.10' -w /tmp/sp1.pcap 2>/tmp/sp1.log" 2>/dev/null || echo "spine1 tcpdump failed"

sleep 2

echo "=== sending 10 flows ==="
docker exec "$CLIENT" rm -f /tmp/pw1.json /tmp/pw1.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 10 --duration 15 \
  --src 203.0.113.1 --out /tmp/pw1.json --ready-file /tmp/pw1.ready

for i in $(seq 1 15); do
  docker exec "$CLIENT" test -f /tmp/pw1.ready 2>/dev/null && break; sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/pw1.ready 2>/dev/null || echo 0)
echo "$EST/10 flows established"
sleep 5

echo ""
echo "=== killing pwru + tcpdump ==="
docker exec "$N1" pkill pwru 2>/dev/null || true
docker exec clab-maglev-clos-spine1 pkill tcpdump 2>/dev/null || true
docker exec "$CLIENT" pkill -f flowgen.py 2>/dev/null || true
sleep 2

echo ""
echo "=== pwru node1 output (first 30 lines) ==="
docker exec "$N1" head -30 /tmp/pwru_n1.log 2>/dev/null || echo "no output"

echo ""
echo "=== pwru node1 errors ==="
docker exec "$N1" cat /tmp/pwru_n1.err 2>/dev/null | head -5

echo ""
echo "=== spine1 capture stats ==="
docker exec clab-maglev-clos-spine1 bash -c \
  "tcpdump -r /tmp/sp1.pcap -nn 2>/dev/null | wc -l; cat /tmp/sp1.log 2>/dev/null | tail -3" || echo "no pcap"
