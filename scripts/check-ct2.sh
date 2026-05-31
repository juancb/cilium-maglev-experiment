#!/usr/bin/env bash
# check-ct2.sh — start flows to VIP, inspect Cilium CT/NAT tables on each node.
set -uo pipefail

CLIENT="clab-maglev-clos-client"
N1="clab-maglev-clos-node1"
VIP="192.0.2.10"
KC="docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml $N1 k3s kubectl"

# Start 20 persistent TCP flows to VIP using flowgen
echo "=== starting 20 flows to VIP ==="
docker exec "$CLIENT" rm -f /tmp/ct_test.json /tmp/ct_test.ready 2>/dev/null || true
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
    --vip "$VIP" --port 8080 --count 20 --duration 30 \
    --out /tmp/ct_test.json --ready-file /tmp/ct_test.ready

# wait for flows to establish
for _ in $(seq 1 15); do
  docker exec "$CLIENT" test -f /tmp/ct_test.ready 2>/dev/null && break
  sleep 1
done
echo "flows established (or timed out)"

# get cilium pod names
NODE1_POD=$($KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers 2>/dev/null | awk '/node1/{print $1}')
NODE2_POD=$($KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers 2>/dev/null | awk '/node2/{print $1}')
NODE3_POD=$($KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers 2>/dev/null | awk '/node3/{print $1}')
echo "Cilium pods: node1=$NODE1_POD  node2=$NODE2_POD  node3=$NODE3_POD"
echo ""

for tuple in "node1:$NODE1_POD" "node2:$NODE2_POD" "node3:$NODE3_POD"; do
  node="${tuple%%:*}"
  pod="${tuple##*:}"
  [ -z "$pod" ] && echo "=== $node: no pod found ===" && continue

  echo "=== CT on $node ($pod) ==="
  total=$($KC -n kube-system exec "$pod" -- cilium-dbg bpf ct list global 2>/dev/null | wc -l || echo 0)
  echo "  total CT entries: $total"
  $KC -n kube-system exec "$pod" -- cilium-dbg bpf ct list global 2>/dev/null \
    | grep -E "203.0.113|192.0.2.10" | head -5 || echo "  (no entries matching client/VIP)"
  echo ""

  echo "=== NAT on $node ($pod) ==="
  nat=$($KC -n kube-system exec "$pod" -- cilium-dbg bpf nat list 2>/dev/null | wc -l || echo 0)
  echo "  total NAT entries: $nat"
  $KC -n kube-system exec "$pod" -- cilium-dbg bpf nat list 2>/dev/null \
    | grep -E "203.0.113|192.0.2.10" | head -5 || echo "  (no entries matching client/VIP)"
  echo ""
done

# wait for flowgen to finish, report
sleep 5
docker cp "$CLIENT:/tmp/ct_test.json" /tmp/ct_test_result.json 2>/dev/null || true
if [ -s /tmp/ct_test_result.json ]; then
  echo "=== flowgen summary ==="
  python3 -c "import json; d=json.load(open('/tmp/ct_test_result.json')); print(d['summary'])"
fi
