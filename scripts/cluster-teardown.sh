#!/usr/bin/env bash
# Kill k3s server/agent processes on all nodes to allow a clean restart.
set -uo pipefail
. "$(dirname "$0")/../tests/lib/common.sh"
for n in "${NODES[@]}"; do
  docker exec "$n" k3s-killall.sh 2>/dev/null || docker exec "$n" pkill -f "k3s" 2>/dev/null || true
  docker exec "$n" rm -rf /var/lib/rancher/k3s/server /var/lib/rancher/k3s/agent 2>/dev/null || true
  echo "  $(basename "$n") cleaned"
done
echo "done"
