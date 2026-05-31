#!/usr/bin/env bash
# Restart echo deployment to redistribute pods across all nodes after a node recovery
set -euo pipefail
N1="clab-maglev-clos-node1"
KC() { docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" k3s kubectl "$@"; }

echo "=== testing VIP HTTP response ==="
python3 - << 'PYEOF'
import socket
s = socket.socket()
s.settimeout(5)
try:
    s.connect(('192.0.2.10', 8080))
    data = b''
    while b'POD=' not in data:
        chunk = s.recv(256)
        if not chunk: break
        data += chunk
    print("  VIP response:", data.decode().strip())
except Exception as e:
    print("  FAILED:", e)
finally:
    s.close()
PYEOF

echo
echo "=== pod distribution before restart ==="
KC get pods -l app=echo -o wide --no-headers 2>/dev/null | awk '{print "  " $8 ": " $1}'

echo
echo "=== rolling restart echo deployment ==="
KC rollout restart deploy/echo
KC rollout status deploy/echo --timeout=120s

echo
echo "=== pod distribution after restart ==="
KC get pods -l app=echo -o wide --no-headers 2>/dev/null | awk '{print "  " $8 ": " $1}' | sort
