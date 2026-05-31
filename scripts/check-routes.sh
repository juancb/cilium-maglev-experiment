#!/usr/bin/env bash
# Check VIP route propagation across the fabric
set -uo pipefail
PFX="clab-maglev-clos"
VIP="192.0.2.10"

echo "=== bird routing table for VIP on each node ==="
for n in node1 node2 node3; do
  echo "  --- $n ---"
  docker exec "${PFX}-${n}" birdc "show route for ${VIP}" 2>/dev/null | grep -v "^BIRD" | sed 's/^/    /'
done

echo
echo "=== kernel route for VIP on each node ==="
for n in node1 node2 node3; do
  echo -n "  $n: "
  docker exec "${PFX}-${n}" bash -c "ip route show ${VIP}" 2>/dev/null || echo "MISSING"
done

echo
echo "=== leaf1 BGP RIB: VIP ==="
docker exec "${PFX}-leaf1" vtysh -c "show ip bgp ${VIP}" 2>/dev/null | tail -20

echo
echo "=== tor BGP RIB: VIP ==="
docker exec "${PFX}-tor" vtysh -c "show ip bgp ${VIP}" 2>/dev/null | tail -20

echo
echo "=== client route for VIP ==="
docker exec "${PFX}-client" bash -c "ip route show ${VIP}" 2>/dev/null || echo "MISSING"
