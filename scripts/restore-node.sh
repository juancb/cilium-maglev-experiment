#!/usr/bin/env bash
# Restore a stopped node container: start, fix veths, run startup.sh
# Usage: bash scripts/restore-node.sh <node-shortname>   e.g. node2
set -euo pipefail
NODE="${1:?Usage: restore-node.sh <node>}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"
CTR="clab-maglev-clos-${NODE}"

echo "=== starting ${CTR} ==="
docker start "$CTR"
echo "=== wiring fabric veths for ${NODE} ==="
# Check if the leaf's fabric interface exists (i.e., peer is in the host namespace).
# If not, the veth pair was destroyed when the node stopped — recreate it from scratch.
case "$NODE" in node1) LEAF_ETH=eth4;; node2) LEAF_ETH=eth5;; node3) LEAF_ETH=eth6;; esac
if docker exec "clab-maglev-clos-leaf1" ip link show "$LEAF_ETH" >/dev/null 2>&1; then
  # Leaf interface exists — its peer may be in the host ns; use the normal mover
  bash "${REPO}/scripts/fix-node-veths.sh" "$NODE" || \
    bash "${REPO}/scripts/rewire-node-veths.sh" "$NODE"
else
  # Leaf interface gone — full recreate needed
  bash "${REPO}/scripts/rewire-node-veths.sh" "$NODE"
fi
echo "=== running startup.sh inside ${CTR} ==="
docker exec -d "$CTR" bash /opt/startup.sh
echo "done — wait ~15s for bird/BGP to converge before checking routes"
