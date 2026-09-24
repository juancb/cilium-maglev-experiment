#!/usr/bin/env bash
# Set L4 ECMP hashing on all fabric nodes (leaf, spine, tor).
# Without this, all flows from the same src/dst IP hash to the same node.
#
# Policy 3 (custom fields) over the 5-tuple, NOT policy 1. Policy 1 short-circuits to
# skb->hash whenever the packet already carries an L4 hash, and in this lab every hop shares
# one kernel over veth pairs, so the client socket's tx hash rides along with the packet.
# Linux re-randomizes that hash on every TCP retransmission timeout (net.core.txrehash), so
# under policy 1 a flow that merely stalls gets re-hashed to a different ECMP member, i.e.
# it re-homes. Real switches hash headers; policy 3 does too.
#   fields 0x37 = src IP | dst IP | IP proto | src port | dst port
set -euo pipefail
for CNAME in \
  clab-maglev-clos-leaf1 \
  clab-maglev-clos-leaf2 \
  clab-maglev-clos-tor \
  clab-maglev-clos-spine1 \
  clab-maglev-clos-spine2 \
  clab-maglev-clos-spine3; do
  echo -n "  $CNAME: "
  docker exec "$CNAME" sysctl -w net.ipv4.fib_multipath_hash_fields=0x0037 >/dev/null
  docker exec "$CNAME" sysctl -w net.ipv4.fib_multipath_hash_policy=3
done
echo "Done. Verifying leaf1:"
docker exec clab-maglev-clos-leaf1 sysctl net.ipv4.fib_multipath_hash_policy net.ipv4.fib_multipath_hash_fields
