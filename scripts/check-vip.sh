#!/usr/bin/env bash
# Quick VIP connectivity and pod distribution check
set -uo pipefail
N1="clab-maglev-clos-node1"
CLIENT="clab-maglev-clos-client"
VIP="192.0.2.10"
PORT=8080

echo "=== echo pod distribution ==="
docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" k3s kubectl \
  get pods -l app=echo -o wide 2>/dev/null | grep -v "^NAME" | \
  awk '{printf "  %-45s  node=%-6s  status=%s\n", $1, $7, $3}'

echo
echo "=== VIP test from client (5 probes) ==="
docker exec "$CLIENT" python3 - << 'PYEOF'
import socket, time

VIP = "192.0.2.10"
PORT = 8080

for i in range(5):
    s = socket.socket()
    s.settimeout(5)
    try:
        s.connect((VIP, PORT))
        data = b''
        while len(data) < 500:
            chunk = s.recv(256)
            if not chunk:
                break
            data += chunk
            if b'POD=' in data:
                break
        line = data.decode('utf-8', 'replace').strip().split('\n')[0]
        print(f"  probe {i+1}: {line}")
    except Exception as e:
        print(f"  probe {i+1}: FAILED ({e})")
    finally:
        s.close()
    time.sleep(0.5)
PYEOF
