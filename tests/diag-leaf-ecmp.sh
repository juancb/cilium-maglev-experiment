#!/usr/bin/env bash
# diag-leaf-ecmp.sh — does the fabric actually load-balance the VIP across nodes,
# and do leaf1 and leaf2 agree on the node for a given 5-tuple?
#
# If leaf1 and leaf2 pick the SAME node for each flow, then killing one leaf just
# reroutes to the same node via the other leaf → no re-homing (explains 04b). If
# they pick DIFFERENT nodes, a leaf failure should scramble node assignment.
set -uo pipefail
cd "$(dirname "$0")"
. lib/common.sh
set +e

echo "=== VIP route + nexthops at each leaf (how many nodes does it ECMP across?) ==="
for l in "${LEAVES[@]}"; do
  echo "--- $(basename "$l") ---"
  docker exec "$l" vtysh -c "show ip route ${VIP}/32" 2>/dev/null | sed 's/^/  /'
done

echo
echo "=== VIP path split at a spine (leaf1 vs leaf2) ==="
docker exec "${SPINES[0]}" vtysh -c "show ip route ${VIP}/32" 2>/dev/null | sed 's/^/  /'

echo
echo "=== per-5-tuple node selection: does leaf1 == leaf2? (the decisive test) ==="
# Forwarded-packet multipath hash needs iif (a spine-facing ingress port = eth1).
# Nexthop subnets differ per leaf (10.3.1.x vs 10.3.2.x); map last octet to node:
#   .1 -> node1, .3 -> node2, .5 -> node3
node_of() { case "${1##*.}" in 1) echo node1;; 3) echo node2;; 5) echo node3;; *) echo "?($1)";; esac; }
nh_node() {  # leaf-container, sport
  local ip
  ip=$(docker exec "$1" ip route get "${VIP}" from 203.0.113.1 iif eth1 \
        sport "$2" dport "${VIP_PORT}" ipproto tcp 2>/dev/null \
        | grep -oE 'via [0-9.]+' | head -1 | awk '{print $2}')
  [ -n "$ip" ] && node_of "$ip" || echo "?"
}
printf '  %-8s %-10s %-10s %s\n' "sport" "leaf1" "leaf2" "same?"
same=0; diff=0
for sp in 20001 20002 20003 20004 20005 20006 20007 20008 20009 20010 20011 20012 20013 20014 20015; do
  n1=$(nh_node "${LEAVES[0]}" "$sp"); n2=$(nh_node "${LEAVES[1]}" "$sp")
  mark="DIFFER"; if [ "$n1" = "$n2" ]; then mark="same"; same=$((same+1)); else diff=$((diff+1)); fi
  printf '  %-8s %-10s %-10s %s\n' "$sp" "$n1" "$n2" "$mark"
done
echo
echo "  leaf1 and leaf2 pick the SAME node for ${same}/$((same+diff)) tuples; DIFFER for ${diff}"
if [ "$diff" -eq 0 ]; then
  echo "  => both leaves map every flow to the SAME node: killing a leaf reroutes via the"
  echo "     other leaf to the SAME node → NO re-homing. This is why 04b never re-homes."
else
  echo "  => leaves map ~${diff}/$((same+diff)) flows to DIFFERENT nodes: a leaf failure"
  echo "     should re-home that fraction. (Then 04b would exercise Maglev.)"
fi
