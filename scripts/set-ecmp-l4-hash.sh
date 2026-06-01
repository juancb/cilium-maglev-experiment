#!/usr/bin/env bash
# Set L4 ECMP hash policy on all fabric nodes (leaf, spine, tor).
# Without this, all flows from the same src/dst IP hash to the same node.
set -euo pipefail
for CNAME in \
  clab-maglev-clos-leaf1 \
  clab-maglev-clos-leaf2 \
  clab-maglev-clos-tor \
  clab-maglev-clos-spine1 \
  clab-maglev-clos-spine2 \
  clab-maglev-clos-spine3; do
  echo -n "  $CNAME: "
  docker exec "$CNAME" sysctl -w net.ipv4.fib_multipath_hash_policy=1
done
echo "Done. Verifying leaf1:"
docker exec clab-maglev-clos-leaf1 sysctl net.ipv4.fib_multipath_hash_policy
