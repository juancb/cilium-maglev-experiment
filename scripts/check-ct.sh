#!/usr/bin/env bash
# Check Cilium BPF conntrack to see which node has entries for VIP flows
set -uo pipefail
LAB="maglev-clos"
VIP="192.0.2.10"
CLIENT="clab-${LAB}-client"
KC="docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml clab-${LAB}-node1 k3s kubectl"

# Get the cilium pod names
POD1=$($KC -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=node1 -o name 2>/dev/null | head -1 | sed 's|pod/||')
POD2=$($KC -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=node2 -o name 2>/dev/null | head -1 | sed 's|pod/||')
POD3=$($KC -n kube-system get pods -l k8s-app=cilium --field-selector spec.nodeName=node3 -o name 2>/dev/null | head -1 | sed 's|pod/||')

echo "Cilium pods: node1=$POD1 node2=$POD2 node3=$POD3"

echo "=== Starting 5 flows from client ==="
for i in $(seq 1 5); do
  docker exec -d "$CLIENT" bash -c "exec 3<>/dev/tcp/${VIP}/8080; sleep 30 <&3 >/dev/null 2>&1" 2>/dev/null
done
sleep 4

echo "=== Cilium BPF CT table entries for VIP on each node ==="
for pod in "$POD1" "$POD2" "$POD3"; do
  [ -z "$pod" ] && continue
  ct=$($KC -n kube-system exec "$pod" -- cilium-dbg bpf ct list global 2>/dev/null | grep -c "$VIP" || echo 0)
  echo "  $pod: $ct BPF CT entries for VIP"
done

echo "=== Direct test: which node's Cilium service sees incoming flow ==="
for pod in "$POD1" "$POD2" "$POD3"; do
  [ -z "$pod" ] && continue
  nat=$($KC -n kube-system exec "$pod" -- cilium-dbg bpf nat list 2>/dev/null | grep "$VIP" | head -2)
  [ -n "$nat" ] && echo "  $pod NAT: $nat"
done

docker exec "$CLIENT" pkill -f "sleep 30" 2>/dev/null || true
echo "done"
