#!/usr/bin/env bash
# Restart k3s-agent on a node after docker stop/start.
# Usage: bash scripts/restart-k3s-agent.sh <node-id>   e.g.  2  or  node2
set -euo pipefail
ID="${1:?Usage: restart-k3s-agent.sh <node-id>}"
ID="${ID#node}"  # strip "node" prefix if passed
CTR="clab-maglev-clos-node${ID}"

TOKEN=$(docker exec clab-maglev-clos-node1 cat /var/lib/rancher/k3s/server/node-token)
if [ -z "$TOKEN" ]; then
  echo "ERROR: could not read token from node1"
  exit 1
fi

echo "=== killing any stale k3s process on ${CTR} ==="
docker exec "$CTR" pkill -f "k3s agent" 2>/dev/null || true

echo "=== starting k3s-agent on ${CTR} ==="
docker exec -d "$CTR" bash -lc \
  "k3s agent --server https://10.10.0.1:6443 --token ${TOKEN} --node-ip 10.10.0.${ID} \
   --snapshotter=native >/var/log/k3s.log 2>&1"

echo "agent started — watch: docker exec ${CTR} tail -f /var/log/k3s.log"
