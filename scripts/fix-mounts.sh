#!/usr/bin/env bash
# Make all mounts shared inside node containers so Cilium can bind-mount
# /sys/fs/bpf, /var/run/netns, etc. into its containers.
# k3d handles this with --tmpfs /run --tmpfs /var/run + make-rshared.
set -uo pipefail
LAB="maglev-clos"
for ID in 1 2 3; do
  N="clab-${LAB}-node${ID}"
  docker exec "$N" bash -c '
    mount --make-rshared /
    mkdir -p /var/run/netns /var/run/cilium /sys/fs/bpf /run/cilium/cgroupv2
    mount bpffs -t bpf /sys/fs/bpf 2>/dev/null || true
    mount -t cgroup2 none /run/cilium/cgroupv2 2>/dev/null || true
    mount --make-shared /sys/fs/bpf /run/cilium/cgroupv2 2>/dev/null || true
    echo "ok"
  '
  echo "  node${ID} mounts fixed"
done
