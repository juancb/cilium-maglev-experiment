#!/usr/bin/env bash
# Test VIP connectivity and debug why it fails
set -uo pipefail
VIP="192.0.2.10"
PORT="8080"
N1="clab-maglev-clos-node1"
N3="clab-maglev-clos-node3"
KC="docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml ${N1} k3s kubectl"

echo "=== 1. check if LB service has ExternalIPs ==="
$KC get svc echo 2>/dev/null

echo "=== 2. check Cilium endpoint routing ==="
$KC -n kube-system exec cilium-tzh9w -- cilium-dbg bpf lb list 2>/dev/null | grep -E "192.0.2|BACKEND" | head -10

echo "=== 3. check if pods are Endpoints ==="
$KC get endpoints echo 2>/dev/null

echo "=== 4. direct curl from node3 to pod IP ==="
docker exec "$N3" bash -c "exec 3<>/dev/tcp/10.244.0.10/8080; head -c 30 <&3; echo" 2>/dev/null

echo "=== 5. check if cgroup mount is correct for BPF sockops ==="
docker exec "$N3" mount 2>/dev/null | grep cgroup | head -3

echo "=== 6. check if cilium bpf sockops is loaded ==="
$KC -n kube-system exec cilium-tzh9w -- cilium-dbg status --verbose 2>/dev/null | grep -iE "BPF|masquerade|kube-proxy" | head -5
