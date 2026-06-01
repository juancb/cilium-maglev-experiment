#!/usr/bin/env bash
# Check cgroup BPF programs from inside the Cilium DaemonSet pod.
set -euo pipefail
N1="clab-maglev-clos-node1"
KC="KUBECONFIG=/etc/rancher/k3s/k3s.yaml"

echo "=== bpftool version in cilium pod ==="
docker exec "$N1" bash -c "$KC kubectl -n kube-system exec cilium-5ws7n -- bpftool version 2>/dev/null | head -2"

echo ""
echo "=== cgroup BPF at cilium cgroup root (/run/cilium/cgroupv2) ==="
docker exec "$N1" bash -c "$KC kubectl -n kube-system exec cilium-5ws7n -- bpftool cgroup list /run/cilium/cgroupv2 2>/dev/null | head -30"

echo ""
echo "=== cgroup BPF at /sys/fs/cgroup ==="
docker exec "$N1" bash -c "$KC kubectl -n kube-system exec cilium-5ws7n -- bpftool cgroup list /sys/fs/cgroup 2>/dev/null | head -30"

echo ""
echo "=== cilium status: sockops/LB ==="
docker exec "$N1" bash -c "$KC kubectl -n kube-system exec cilium-5ws7n -- cilium-dbg status 2>/dev/null | grep -iE 'sock|LB|cgroup'" | head -10
