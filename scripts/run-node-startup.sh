#!/usr/bin/env bash
set -uo pipefail
LAB="maglev-clos"
for ID in 1 2 3; do
  N="clab-${LAB}-node${ID}"
  echo "=== starting ${N} ==="
  docker exec -d "$N" bash /opt/startup.sh
done
echo "waiting 12s for bird to start..."
sleep 12
for ID in 1 2 3; do
  N="clab-${LAB}-node${ID}"
  echo "=== ${N} bird ==="
  docker exec "$N" birdc show protocols 2>/dev/null | grep -E "uplink|cilium"
done
