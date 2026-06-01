#!/usr/bin/env bash
# After enabling L4 ECMP hash, verify flows distribute across all 3 nodes.
set -euo pipefail
CLIENT="clab-maglev-clos-client"
N1="clab-maglev-clos-node1"
KC="KUBECONFIG=/etc/rancher/k3s/k3s.yaml"

docker exec "$N1" bash -c "$KC kubectl -n kube-system get pod -l k8s-app=cilium --no-headers 2>/dev/null" \
  | awk '{print $1, $7}' | head -5 || true

echo "=== starting 300 flows ==="
docker exec "$CLIENT" rm -f /tmp/chk.json /tmp/chk.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 300 --duration 30 \
  --src 203.0.113.1 --out /tmp/chk.json --ready-file /tmp/chk.ready

for i in $(seq 1 20); do
  docker exec "$CLIENT" test -f /tmp/chk.ready 2>/dev/null && break; sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/chk.ready 2>/dev/null || echo 0)
echo "$EST/300 flows established"
sleep 2

echo ""
echo "=== CT entries with VIP (192.0.2.10) per cilium pod ==="
for POD in cilium-5ws7n cilium-hjb8m cilium-qvm7h; do
  COUNT=$(docker exec "$N1" bash -c \
    "$KC kubectl -n kube-system exec $POD -- cilium-dbg bpf ct list global 2>/dev/null | grep -c 192.0.2.10")
  echo "  $POD: $COUNT"
done

docker exec "$CLIENT" pkill -f flowgen.py 2>/dev/null || true
