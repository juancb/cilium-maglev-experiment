#!/usr/bin/env bash
# Investigate why socket-LB rewrites are happening despite bpf-lb-sock: false.
set -euo pipefail

echo "=== cgroup of client container ==="
CLIENT_PID=$(docker inspect clab-maglev-clos-client -f '{{.State.Pid}}' 2>/dev/null)
echo "client PID: $CLIENT_PID"
cat /proc/${CLIENT_PID}/cgroup 2>/dev/null | head -5

echo ""
echo "=== cgroup of node1 container ==="
NODE1_PID=$(docker inspect clab-maglev-clos-node1 -f '{{.State.Pid}}' 2>/dev/null)
echo "node1 PID: $NODE1_PID"
cat /proc/${NODE1_PID}/cgroup 2>/dev/null | head -5

echo ""
echo "=== cilium's cgroup sockmap BPF pins ==="
ls /sys/fs/bpf/tc/globals/ 2>/dev/null | grep -iE "sock|cgroup" | head -20 || echo "none"
ls /sys/fs/bpf/ 2>/dev/null | head -20

echo ""
echo "=== Cilium helm values (all) - socket related ==="
docker exec clab-maglev-clos-node1 bash -c \
  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm get values cilium -n kube-system --all 2>/dev/null" \
  | grep -iE "sock|cgroup|lb" | head -20

echo ""
echo "=== client container cgroup parent (docker inspect) ==="
docker inspect clab-maglev-clos-client -f '{{.HostConfig.CgroupParent}}'

echo ""
echo "=== node1 container cgroup parent ==="
docker inspect clab-maglev-clos-node1 -f '{{.HostConfig.CgroupParent}}'

echo ""
echo "=== BPF maps related to socket-LB ==="
ls /sys/fs/bpf/tc/globals/ 2>/dev/null | grep -E "lb4_sock|SOCK|affin" | head -10 || echo "none found"
