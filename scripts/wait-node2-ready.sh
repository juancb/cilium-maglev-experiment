#!/usr/bin/env bash
N1="clab-maglev-clos-node1"
for i in $(seq 1 60); do
  out=$(docker exec "$N1" k3s kubectl get node node2 --no-headers 2>/dev/null)
  echo "[$i] $out"
  echo "$out" | grep -q ' Ready' && exit 0
  sleep 3
done
echo "node2 did not become Ready"
exit 1
