#!/usr/bin/env bash
# Wait for SONiC ToR BGP to come up, then show full status.
set -uo pipefail
TOR="clab-maglev-clos-tor"
MAX=30  # 5 minutes

echo "Waiting for SONiC ToR to boot BGP (up to ${MAX}x10s)..."
for i in $(seq 1 $MAX); do
  if docker exec "$TOR" show ip bgp summary 2>/dev/null | grep -q "BGP router"; then
    echo "ToR BGP up after ${i}x10s"
    docker exec "$TOR" show ip bgp summary 2>/dev/null
    echo
    echo "=== Spine1 → ToR session ==="
    docker exec clab-maglev-clos-spine1 vtysh -c "show bgp neighbor 10.1.1.0" 2>/dev/null | grep -E "BGP state|MsgRcvd|MsgSent|Prefixes"
    exit 0
  fi
  # Check if SONiC services are starting
  PROCS=$(docker exec "$TOR" ps aux 2>/dev/null | grep -cE "bgp|zebra|sonic" || true)
  echo "  [${i}/${MAX}] BGP not ready yet (sonic procs: ${PROCS})"
  sleep 10
done
echo "ToR BGP did not come up after ${MAX}x10s — showing SONiC logs:"
docker logs "$TOR" 2>&1 | tail -30
docker exec "$TOR" ps aux 2>/dev/null | head -20
