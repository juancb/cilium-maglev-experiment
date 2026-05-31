#!/usr/bin/env bash
# Check if the LoadBalancer service and Cilium BPF programming look correct
set -uo pipefail
N1="clab-maglev-clos-node1"
CLIENT="clab-maglev-clos-client"
VIP="192.0.2.10"
PORT=8080

KC() { docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" k3s kubectl "$@"; }
CIL() { docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" cilium "$@" 2>&1; }

echo "=== k8s service ==="
KC get svc echo

echo
echo "=== Cilium service list (VIP entry) ==="
docker exec "$N1" cilium-dbg service list 2>/dev/null | grep -E "${VIP}|ID" | head -10

echo
echo "=== Cilium BPF lb list (VIP) ==="
docker exec "$N1" cilium-dbg bpf lb list 2>/dev/null | grep "$VIP" | head -5

echo
echo "=== echo pods ==="
KC get pods -l app=echo -o wide --no-headers 2>/dev/null | awk '{print "  "$8": "$1" "$6}'

echo
echo "=== TCP connect test from client to VIP:${PORT} ==="
docker exec "$CLIENT" bash -c "timeout 5 bash -c 'echo > /dev/tcp/${VIP}/${PORT}' && echo 'TCP OPEN' || echo 'TCP FAILED'"

echo
echo "=== Cilium status on node1 ==="
docker exec "$N1" cilium-dbg status 2>/dev/null | grep -E "KubeProxy|State|BPF|Error" | head -10
