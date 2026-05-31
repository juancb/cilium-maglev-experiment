#!/usr/bin/env bash
# Wait for Cilium to be Running on node2
set -euo pipefail
for i in $(seq 1 60); do
  READY=$(docker exec clab-maglev-clos-node1 k3s kubectl -n kube-system get pods \
    -l app.kubernetes.io/name=cilium-agent -o wide --no-headers 2>/dev/null | \
    awk '$8=="node2" && $3=="Running" {print "yes"}')
  if [ "$READY" = "yes" ]; then
    echo "Cilium Running on node2 after $((i*5))s"
    break
  fi
  echo "  waiting... ($((i*5))s)"
  sleep 5
done
docker exec clab-maglev-clos-node1 k3s kubectl -n kube-system get pods \
  -l app.kubernetes.io/name=cilium-agent -o wide
