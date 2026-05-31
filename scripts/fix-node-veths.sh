#!/usr/bin/env bash
# Move the node-facing fabric veth interfaces from the host namespace into the
# correct node containers and rename them to fab0/fab1.
# containerlab's ext-container kind places them in the host ns instead of the container.
#
# Topology (see docs/ADDRESSING.md):
#   leaf1:eth4 <-> node1:fab0    leaf2:eth4 <-> node1:fab1
#   leaf1:eth5 <-> node2:fab0    leaf2:eth5 <-> node2:fab1
#   leaf1:eth6 <-> node3:fab0    leaf2:eth6 <-> node3:fab1
set -uo pipefail
LAB="maglev-clos"

# Optional: only rewire a specific node (e.g., "node2" or "clab-maglev-clos-node2").
# When omitted, all three nodes are rewired.
NODE_FILTER="${1:-}"
NODE_FILTER="${NODE_FILTER#clab-${LAB}-}"  # strip prefix if caller passes full container name

should_move() { [ -z "$NODE_FILTER" ] || [ "$NODE_FILTER" = "$1" ]; }

move_veth() {
  local LEAF_CTR="clab-${LAB}-${1}"  # e.g. leaf1
  local LEAF_IFACE="$2"              # e.g. eth4
  local NODE_CTR="clab-${LAB}-${3}"  # e.g. node1
  local NODE_IFACE="$4"              # e.g. fab0

  # Find the peer index of LEAF_CTR:LEAF_IFACE — that peer is in the host ns
  local PEER_IDX
  PEER_IDX=$(docker exec "$LEAF_CTR" ip link show "$LEAF_IFACE" 2>/dev/null | \
             grep -oP '@if\K[0-9]+' | head -1)
  [ -n "${PEER_IDX:-}" ] || { echo "  ERROR: could not find peer of ${LEAF_CTR}:${LEAF_IFACE}"; return 1; }

  # Find the host interface with that index
  local HOST_IFACE
  HOST_IFACE=$(ip link show | grep "^${PEER_IDX}:" | grep -oP '^\d+:\s+\K\S+' | cut -d@ -f1)
  [ -n "${HOST_IFACE:-}" ] || { echo "  ERROR: no host interface at index ${PEER_IDX}"; return 1; }

  echo "  ${LEAF_CTR}:${LEAF_IFACE} peer idx=${PEER_IDX} → host:${HOST_IFACE} → ${NODE_CTR}:${NODE_IFACE}"

  # Get node's PID for netns
  local NODE_PID
  NODE_PID=$(docker inspect "$NODE_CTR" --format '{{.State.Pid}}')

  # Move and rename
  ip link set "$HOST_IFACE" netns "$NODE_PID" name "$NODE_IFACE"
  docker exec "$NODE_CTR" ip link set "$NODE_IFACE" up
  echo "    moved and renamed to ${NODE_IFACE}"
}

echo "=== moving fabric veths into node containers${NODE_FILTER:+ (${NODE_FILTER} only)} ==="
should_move node1 && { move_veth leaf1 eth4 node1 fab0; move_veth leaf2 eth4 node1 fab1; }
should_move node2 && { move_veth leaf1 eth5 node2 fab0; move_veth leaf2 eth5 node2 fab1; }
should_move node3 && { move_veth leaf1 eth6 node3 fab0; move_veth leaf2 eth6 node3 fab1; }

echo "=== verifying ==="
for n in node1 node2 node3; do
  should_move "$n" || continue
  echo -n "  ${n}: "
  docker exec "clab-${LAB}-${n}" ip -br link show fab0 2>/dev/null | awk '{print "fab0="$2}' | tr -d '\n'
  docker exec "clab-${LAB}-${n}" ip -br link show fab1 2>/dev/null | awk '{print " fab1="$2}' | tr -d '\n'
  echo
done
