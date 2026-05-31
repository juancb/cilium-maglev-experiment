#!/usr/bin/env bash
# trace-flow.sh — start one flow, find which Cilium node is handling it.
# Checks CT/NAT on ALL 3 nodes immediately after flow establishes.
set -uo pipefail

N1="clab-maglev-clos-node1"
CLIENT="clab-maglev-clos-client"
VIP="192.0.2.10"
KC="docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml $N1 k3s kubectl"

echo "=== getting cilium pod names ==="
POD1=$($KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers | awk '/node1/{print $1}')
POD2=$($KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers | awk '/node2/{print $1}')
POD3=$($KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers | awk '/node3/{print $1}')
echo "node1=$POD1  node2=$POD2  node3=$POD3"

# start one persistent flow from client, keep it alive
docker exec "$CLIENT" rm -f /tmp/trace.ready /tmp/trace.json
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
    --vip "$VIP" --port 8080 --count 1 --duration 20 \
    --out /tmp/trace.json --ready-file /tmp/trace.ready

for _ in $(seq 1 10); do
  docker exec "$CLIENT" test -f /tmp/trace.ready && break
  sleep 1
done
echo "flow established"
sleep 1

echo ""
echo "=== CT/NAT snapshot on ALL nodes while flow is live ==="
for tuple in "node1:$POD1" "node2:$POD2" "node3:$POD3"; do
  node="${tuple%%:*}"
  pod="${tuple##*:}"
  [ -z "$pod" ] && echo "=== $node: NO POD ===" && continue

  echo "--- CT on $node ($pod): port-8080 entries ---"
  $KC -n kube-system exec "$pod" -- cilium-dbg bpf ct list global 2>/dev/null \
    | grep ":8080" || echo "  (none)"

  echo "--- NAT on $node ($pod) ---"
  $KC -n kube-system exec "$pod" -- cilium-dbg bpf nat list 2>/dev/null \
    | grep -E "10\.0\.0|192\.0\.2|203\.0" || echo "  (none)"
  echo ""
done

echo "=== tcpdump on each node fab0 for 2 seconds ==="
for node in node1 node2 node3; do
  echo "--- $node fab0 ---"
  timeout 2 docker exec "clab-maglev-clos-$node" tcpdump -i fab0 -nn -c 5 "dst port 8080" 2>/dev/null \
    | head -5 || echo "  (no packets or timeout)"
done

echo ""
echo "=== leaf1: packet count on each interface to VIP ==="
for iface in eth4 eth5 eth6; do
  echo -n "  $iface → "
  docker exec clab-maglev-clos-leaf1 ip -s link show "$iface" 2>/dev/null | grep -A1 "RX:" | tail -1 | awk '{print "RX pkts="$1}'
done
