#!/usr/bin/env bash
# With cgroupns=host, container processes live in the HOST cgroup tree (/sys/fs/cgroup).
# Cilium attaches socket BPF programs to /run/cilium/cgroupv2 (a separate mount).
# Bind /sys/fs/cgroup over /run/cilium/cgroupv2 so Cilium attaches to the right cgroup.
# Then restart Cilium to reload the BPF programs at the correct attachment point.
set -uo pipefail
LAB="maglev-clos"
KC="docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml clab-${LAB}-node1 k3s kubectl"

for ID in 1 2 3; do
  N="clab-${LAB}-node${ID}"
  echo "=== fixing cgroup on node${ID} ==="
  docker exec "$N" bash -c '
    umount /run/cilium/cgroupv2 2>/dev/null || true
    mkdir -p /run/cilium/cgroupv2
    mount --bind /sys/fs/cgroup /run/cilium/cgroupv2
    echo "  cgroup bind mount: $(mount | grep cgroupv2 | head -2)"
  '
done

echo "=== restarting Cilium daemonset to reload BPF at correct cgroup ==="
$KC -n kube-system rollout restart ds/cilium 2>/dev/null
echo "waiting 60s for Cilium to restart..."
sleep 60
$KC -n kube-system rollout status ds/cilium --timeout=120s 2>/dev/null || true
$KC -n kube-system get pods -l k8s-app=cilium 2>/dev/null
