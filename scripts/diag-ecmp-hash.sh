#!/usr/bin/env bash
# Verify L4 ECMP hash policy and test which nexthop different src ports use.
set -euo pipefail

echo "=== fib_multipath_hash_policy per fabric node ==="
for CNAME in clab-maglev-clos-leaf1 clab-maglev-clos-leaf2 clab-maglev-clos-tor clab-maglev-clos-spine1 clab-maglev-clos-spine2 clab-maglev-clos-spine3; do
  VAL=$(docker exec "$CNAME" sysctl -n net.ipv4.fib_multipath_hash_policy 2>/dev/null || echo "error")
  echo "  $CNAME: $VAL"
done

echo ""
echo "=== ToR: ECMP routes for VIP ==="
docker exec clab-maglev-clos-tor ip route show 192.0.2.10 2>/dev/null

echo ""
echo "=== leaf1: nexthop per src port (ip route get) ==="
for PORT in 10000 20000 30000 40000 50000 60000; do
  docker exec clab-maglev-clos-leaf1 bash -c \
    "ip route get 192.0.2.10 sport $PORT dport 8080 from 203.0.113.1 2>/dev/null | grep -E 'via|dev'" \
    | awk '{printf "  src_port='$PORT' → %s\n", $0}'
done

echo ""
echo "=== leaf1: route table for VIP ==="
docker exec clab-maglev-clos-leaf1 ip route show 192.0.2.10 2>/dev/null
