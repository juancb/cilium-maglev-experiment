#!/usr/bin/env bash
set -uo pipefail
LAB="maglev-clos"
REPO="/mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment"
for ID in 1 2 3; do
  N="clab-${LAB}-node${ID}"
  docker cp "${REPO}/nodes/bird/node${ID}.conf" "${N}:/etc/bird/bird.conf"
  docker exec "$N" birdc configure 2>/dev/null | tail -2
  echo "  node${ID} bird reloaded"
done
sleep 5
for ID in 1 2 3; do
  N="clab-${LAB}-node${ID}"
  echo "=== ${N} ==="
  docker exec "$N" birdc show protocols 2>/dev/null | grep -E "uplink|cilium"
done
