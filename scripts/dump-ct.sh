#!/usr/bin/env bash
# dump-ct.sh — dump raw CT and NAT tables while flows are active.
set -uo pipefail

N1="clab-maglev-clos-node1"
CLIENT="clab-maglev-clos-client"
VIP="192.0.2.10"
KC="docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml $N1 k3s kubectl"

# Start 5 flows
echo "=== starting 5 flows to VIP ==="
docker exec "$CLIENT" rm -f /tmp/dct.ready /tmp/dct.json 2>/dev/null || true
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
    --vip "$VIP" --port 8080 --count 5 --duration 40 \
    --src 203.0.113.1 \
    --out /tmp/dct.json --ready-file /tmp/dct.ready

for _ in $(seq 1 15); do
  docker exec "$CLIENT" test -f /tmp/dct.ready && break
  sleep 1
done
echo "flows established"
sleep 1

echo ""
echo "=== CT on node2 (ingress for ~1/3 of flows) ==="
$KC -n kube-system exec cilium-dqc2b -- cilium-dbg bpf ct list global

echo ""
echo "=== NAT on node2 ==="
$KC -n kube-system exec cilium-dqc2b -- cilium-dbg bpf nat list

echo ""
echo "=== CT on node1 ==="
$KC -n kube-system exec cilium-g82vg -- cilium-dbg bpf ct list global

echo ""
echo "=== CT on node3 ==="
$KC -n kube-system exec cilium-h9zz7 -- cilium-dbg bpf ct list global

echo ""
echo "=== checking WHICH node each flow went through (source IP probe) ==="
# Each flow should have received POD= greeting. flowgen records the backend.
# Now check which NODE has a CT entry for that flow by looking at NAT tables.
echo "=== NAT on node1 ==="
$KC -n kube-system exec cilium-g82vg -- cilium-dbg bpf nat list

echo "=== NAT on node3 ==="
$KC -n kube-system exec cilium-h9zz7 -- cilium-dbg bpf nat list
