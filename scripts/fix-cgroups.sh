#!/usr/bin/env bash
# Apply cgroupv2 fix to already-running node containers, then restart k3s.
# Moves container processes to system.slice so the root cgroup is empty,
# letting k3s create kubepods as a domain child cgroup.
set -uo pipefail
. "$(dirname "$0")/../tests/lib/common.sh"

fix_cgroup() {
  local node="$1"
  echo "  fixing cgroup on $(basename "$node")..."
  docker exec "$node" bash -c '
    [ -e /sys/fs/cgroup/cgroup.controllers ] || { echo "no cgroupv2"; exit 0; }
    mkdir -p /sys/fs/cgroup/system.slice
    grep -o "[a-z]*" /sys/fs/cgroup/cgroup.controllers | while read ctrl; do
      echo "+${ctrl}" >> /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
    done
    while read -r pid; do
      echo "$pid" > /sys/fs/cgroup/system.slice/cgroup.procs 2>/dev/null || true
    done < /sys/fs/cgroup/cgroup.procs
    echo "done (root procs remaining: $(wc -l < /sys/fs/cgroup/cgroup.procs))"
  ' 2>&1
}

echo "=== applying cgroupv2 fix to all nodes ==="
for n in "${NODES[@]}"; do
  fix_cgroup "$n"
done
echo "=== cgroup fix done ==="
