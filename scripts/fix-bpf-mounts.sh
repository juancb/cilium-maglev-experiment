#!/usr/bin/env bash
set -uo pipefail
LAB="maglev-clos"
for ID in 1 2 3; do
  N="clab-${LAB}-node${ID}"
  docker exec "$N" bash -c '
    mount --make-shared /sys/fs/bpf 2>/dev/null || true
    mkdir -p /run/cilium/cgroupv2
    mount -t cgroup2 none /run/cilium/cgroupv2 2>/dev/null || true
    mount --make-shared /run/cilium/cgroupv2 2>/dev/null || true
    mount | grep -E "bpf|cgroupv2" | grep -v clab
  '
  echo "  node${ID} done"
done
