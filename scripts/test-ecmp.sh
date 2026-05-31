#!/usr/bin/env bash
# Test 10 connections to VIP from client, show which echo pod serves each
VIP="192.0.2.10"
CLIENT="clab-maglev-clos-client"
echo "=== 10 VIP connections — pod distribution ==="
for i in $(seq 1 10); do
  docker exec "$CLIENT" bash -c "exec 3<>/dev/tcp/${VIP}/8080; head -c 40 <&3" 2>/dev/null
  echo
done
echo "=== fabric routing (ToR ECMP) ==="
docker exec clab-maglev-clos-tor vtysh -c "show ip route 192.0.2.10" 2>/dev/null | grep -E "via|best"
