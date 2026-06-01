#!/usr/bin/env bash
# Start flows and observe Hubble to see which node is ingressing traffic.
set -euo pipefail
CLIENT="clab-maglev-clos-client"
N1="clab-maglev-clos-node1"
RELAY="10.244.2.14:4245"

echo "=== starting 300 flows ==="
docker exec "$CLIENT" rm -f /tmp/hn.json /tmp/hn.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 300 --duration 30 \
  --src 203.0.113.1 --out /tmp/hn.json --ready-file /tmp/hn.ready

for i in $(seq 1 20); do
  docker exec "$CLIENT" test -f /tmp/hn.ready 2>/dev/null && break; sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/hn.ready 2>/dev/null || echo 0)
echo "$EST/300 flows established"
sleep 1

echo ""
echo "=== Hubble: SYN flows to echo pods — which nodes ingress? ==="
docker exec "$N1" bash -c \
  "HUBBLE_SERVER=${RELAY} hubble observe --from-ip 203.0.113.1 --last 400 --output json 2>/dev/null" \
| python3 -c "
import sys, json
from collections import Counter
nodes = Counter()
for line in sys.stdin:
    try:
        f = json.loads(line)
        node = f.get('node_name', '?')
        fl = (f.get('l4') or {}).get('TCP', {}).get('flags', {})
        if fl.get('SYN') and not fl.get('ACK'):
            nodes[node] += 1
    except:
        pass
print('Ingress node distribution (SYN packets):')
for n, c in sorted(nodes.items(), key=lambda x: -x[1]):
    print(f'  {n}: {c}')
"

echo ""
echo "=== also check CT on node2 for 203.0.113.1 ==="
docker exec "$N1" bash -c \
  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system exec cilium-qvm7h -- cilium-dbg bpf ct list global 2>/dev/null | grep 203.0.113.1 | head -5"

docker exec "$CLIENT" pkill -f flowgen.py 2>/dev/null || true
