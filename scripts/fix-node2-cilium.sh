#!/usr/bin/env bash
# fix-node2-cilium.sh — restart the stuck Cilium pod on node2.
set -uo pipefail

N1="clab-maglev-clos-node1"
KC="docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml $N1 k3s kubectl"

echo "=== current cilium pods ==="
$KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers

# Find the pod on node2
NODE2_POD=$($KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers | awk '/node2/{print $1}')
echo ""
echo "=== deleting node2 cilium pod: $NODE2_POD ==="
$KC -n kube-system delete pod "$NODE2_POD" --force --grace-period=0 || true

echo ""
echo "=== waiting for replacement (up to 90s) ==="
for i in $(seq 1 30); do
  sleep 3
  STATUS=$($KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers | awk '/node2/{print $2}')
  POD=$($KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers | awk '/node2/{print $1}')
  echo "  t=$((i*3))s: pod=$POD status=$STATUS"
  [ "$STATUS" = "1/1" ] && break
done

echo ""
echo "=== final cilium pod status ==="
$KC -n kube-system get pods -l k8s-app=cilium -o wide --no-headers

echo ""
echo "=== check cilium-agent in node2 container ==="
docker exec clab-maglev-clos-node2 ps aux 2>/dev/null | grep cilium | grep -v grep | head -3 || echo "(no cilium process visible)"

echo ""
echo "=== node2 interfaces (cilium_host should appear if Cilium is up) ==="
docker exec clab-maglev-clos-node2 ip -br addr show | grep -E "cilium|fab"
