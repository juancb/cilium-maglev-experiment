#!/usr/bin/env bash
# Quick 30-flow, 25s verification. Fails node1 at 10s (node1 actually gets ingress traffic).
set -euo pipefail

CLIENT="clab-maglev-clos-client"
FAIL_NODE="clab-maglev-clos-node1"
DUR=25
COUNT=30

info() { echo "[$(date +%H:%M:%S)] $*"; }

# Restore all nodes
for n in node1 node2 node3; do
  docker exec "clab-maglev-clos-$n" ip link set fab0 up 2>/dev/null || true
  docker exec "clab-maglev-clos-$n" ip link set fab1 up 2>/dev/null || true
done
sleep 3

info "=== ECMP distribution: 30 quick connections ==="
for n in node1 node2 node3; do
  docker exec -d "clab-maglev-clos-$n" bash -c \
    "tcpdump -i fab0 -nn 'dst 192.0.2.10 and tcp[tcpflags] & tcp-syn != 0' -w /tmp/syn.pcap 2>/dev/null"
done
sleep 1
docker exec "$CLIENT" python3 -c "
import socket, time
for i in range(30):
    try:
        s = socket.socket()
        s.bind(('203.0.113.1', 51000+i))
        s.settimeout(1)
        s.connect(('192.0.2.10', 8080))
        s.recv(64)
        s.close()
    except: pass
    time.sleep(0.05)
" 2>/dev/null
sleep 2
for n in node1 node2 node3; do
  docker exec "clab-maglev-clos-$n" pkill tcpdump 2>/dev/null || true
done
sleep 1
for n in node1 node2 node3; do
  CNT=$(docker exec "clab-maglev-clos-$n" \
    bash -c "tcpdump -r /tmp/syn.pcap -nn 2>/dev/null | wc -l" 2>/dev/null || echo 0)
  echo "  $n: $CNT SYNs on fab0"
done

info ""
info "=== Failover test: fail $FAIL_NODE at 10s ==="

# Write the parser script into the client
docker exec "$CLIENT" bash -c 'cat > /tmp/parse.py << '"'"'EOF'"'"'
import json, sys
fail_time = int(sys.argv[1])
try:
    data = json.load(open("/tmp/qv.json"))
    flows = data.get("flows", [])
    total = len(flows)
    est = [f for f in flows if f.get("established_at")]
    broken = [f for f in flows if f.get("status") == "broken"
              and f.get("established_at")
              and (f.get("broke_at") or 0) >= fail_time]
    survived = [f for f in est if f.get("status") == "ok"]
    print(f"  established:          {len(est)}/{total}")
    print(f"  broken after failover:{len(broken)}/{len(est)}")
    print(f"  survived:             {len(survived)}/{len(est)}")
    print(f"  backends: {data.get(\"summary\",{}).get(\"backend_distribution\",{})}")
except Exception as e:
    print(f"  error reading results: {e}")
EOF'

docker exec "$CLIENT" rm -f /tmp/qv.json /tmp/qv.ready

# Run flowgen in background using nohup inside the container
docker exec "$CLIENT" bash -c "nohup python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count $COUNT --duration $DUR \
  --src 203.0.113.1 --out /tmp/qv.json --ready-file /tmp/qv.ready \
  > /tmp/qv.log 2>&1 &"

# Wait for establish
for i in $(seq 1 15); do
  sleep 1
  docker exec "$CLIENT" test -f /tmp/qv.ready 2>/dev/null && break
done
EST=$(docker exec "$CLIENT" cat /tmp/qv.ready 2>/dev/null || echo 0)
info "$EST/$COUNT flows established"

sleep 3
FAIL_TIME=$(date +%s)
info "failing $FAIL_NODE (fab0+fab1 down)"
docker exec "$FAIL_NODE" ip link set fab0 down
docker exec "$FAIL_NODE" ip link set fab1 down

# Wait for rest of test
sleep $((DUR - 13 + 4))

info "=== Results ==="
docker exec "$CLIENT" python3 /tmp/parse.py "$FAIL_TIME" 2>&1

info "restoring nodes"
for n in node1 node2 node3; do
  docker exec "clab-maglev-clos-$n" ip link set fab0 up 2>/dev/null || true
  docker exec "clab-maglev-clos-$n" ip link set fab1 up 2>/dev/null || true
done
