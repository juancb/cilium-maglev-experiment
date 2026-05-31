#!/usr/bin/env bash
# fix-ecmp-hash.sh — set fib_multipath_hash_policy=1 on all FRR forwarding nodes.
#
# Leaf1's default L3-only hashing (policy=0) causes ALL flows from 10.0.0.0→192.0.2.10
# to deterministically select the same ECMP nexthop (node3), so stopping node2 has no
# effect. L4 hashing (policy=1) distributes flows by 5-tuple, spreading them across
# node1/node2/node3 proportionally.
set -euo pipefail

green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }

yellow "[*] setting fib_multipath_hash_policy=1 on all forwarding nodes"
for node in leaf1 leaf2 spine1 spine2 spine3; do
  docker exec "clab-maglev-clos-$node" sysctl -w net.ipv4.fib_multipath_hash_policy=1
done

echo ""
yellow "[*] verifying"
for node in leaf1 leaf2 spine1 spine2 spine3; do
  val=$(docker exec "clab-maglev-clos-$node" sysctl -n net.ipv4.fib_multipath_hash_policy 2>/dev/null)
  printf "  %-10s  policy=%s\n" "$node" "$val"
done

echo ""
green "Done. Flows will now distribute by 5-tuple across all ECMP nexthops."
green "Expected: ~1/3 of flows on each of node1/node2/node3."
