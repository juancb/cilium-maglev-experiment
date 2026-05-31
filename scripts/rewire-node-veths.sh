#!/usr/bin/env bash
# Recreate fabric veth pairs for a node after docker stop/start.
#
# When a node container is stopped its netns is destroyed, which destroys fab0/fab1
# inside it AND the peer leaf eth interfaces (they are the same veth pair).
# This script creates fresh veth pairs and places them correctly.
#
# Usage: bash scripts/rewire-node-veths.sh <node>   e.g.  node2  or  clab-maglev-clos-node2
#
# After this runs:
#   - startup.sh inside the node will configure fab0/fab1 IPs + bird
#   - FRR/zebra in the leaves detects the new interface via netlink and applies
#     the ip-address config from frr.conf automatically

set -euo pipefail
LAB="maglev-clos"
NODE="${1:?Usage: rewire-node-veths.sh <node>}"
NODE="${NODE#clab-${LAB}-}"  # strip prefix if passed

case "$NODE" in
  node1) LEAF_ETH=4 ;;
  node2) LEAF_ETH=5 ;;
  node3) LEAF_ETH=6 ;;
  *) echo "Unknown node: $NODE (expected node1/node2/node3)"; exit 1 ;;
esac

LEAF1="clab-${LAB}-leaf1"
LEAF2="clab-${LAB}-leaf2"
NODE_CTR="clab-${LAB}-${NODE}"
LEAF_IFACE="eth${LEAF_ETH}"

LEAF1_PID=$(docker inspect "$LEAF1"   --format '{{.State.Pid}}')
LEAF2_PID=$(docker inspect "$LEAF2"   --format '{{.State.Pid}}')
NODE_PID=$(docker inspect  "$NODE_CTR" --format '{{.State.Pid}}')

echo "=== recreating fabric veths for ${NODE} (LEAF_ETH=${LEAF_IFACE}) ==="

link_node_to_leaf() {
  local LEAF_CTR="$1" LEAF_PID="$2" FAB="$3"
  local TMP_L="v${NODE}-${FAB}-l" TMP_N="v${NODE}-${FAB}-n"

  echo "  ${LEAF_CTR}:${LEAF_IFACE} <-> ${NODE_CTR}:${FAB}"

  # Clean up any stale half-pairs from a previous failed attempt
  ip link del "$TMP_L" 2>/dev/null || true
  ip link del "$TMP_N" 2>/dev/null || true

  # Create pair in host namespace
  ip link add "$TMP_L" type veth peer name "$TMP_N"

  # Move leaf-side end into leaf container, rename to ethN
  ip link set "$TMP_L" netns "$LEAF_PID"
  nsenter -t "$LEAF_PID" -n ip link set "$TMP_L" name "$LEAF_IFACE"
  nsenter -t "$LEAF_PID" -n ip link set "$LEAF_IFACE" up

  # Move node-side end into node container, rename to fabN
  ip link set "$TMP_N" netns "$NODE_PID"
  nsenter -t "$NODE_PID" -n ip link set "$TMP_N" name "$FAB"
  nsenter -t "$NODE_PID" -n ip link set "$FAB" up

  echo "    moved and up"
}

link_node_to_leaf "$LEAF1" "$LEAF1_PID" "fab0"
link_node_to_leaf "$LEAF2" "$LEAF2_PID" "fab1"

echo "=== verifying ==="
echo -n "  ${NODE_CTR}: "
nsenter -t "$NODE_PID"  -n ip -br link show fab0  2>/dev/null | awk '{print "fab0="$2}' | tr -d '\n'
nsenter -t "$NODE_PID"  -n ip -br link show fab1  2>/dev/null | awk '{print " fab1="$2}' | tr -d '\n'
echo
echo -n "  ${LEAF1}: "
nsenter -t "$LEAF1_PID" -n ip -br link show "$LEAF_IFACE" 2>/dev/null | awk '{print "'"$LEAF_IFACE"'="$2}'
echo -n "  ${LEAF2}: "
nsenter -t "$LEAF2_PID" -n ip -br link show "$LEAF_IFACE" 2>/dev/null | awk '{print "'"$LEAF_IFACE"'="$2}'

echo "=== done ==="
echo "  FRR/zebra will configure leaf-side IPs from frr.conf automatically."
echo "  Now run:  docker exec -d ${NODE_CTR} bash /opt/startup.sh"
