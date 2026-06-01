#!/usr/bin/env bash
# Recreate veth pairs for node2 after docker stop destroyed them.
# leaf1:eth5 <-> node2:fab0
# leaf2:eth5 <-> node2:fab1
set -euo pipefail
LAB="maglev-clos"

LEAF1="clab-${LAB}-leaf1"
LEAF2="clab-${LAB}-leaf2"
NODE2="clab-${LAB}-node2"

LEAF1_PID=$(docker inspect "$LEAF1" --format '{{.State.Pid}}')
LEAF2_PID=$(docker inspect "$LEAF2" --format '{{.State.Pid}}')
NODE2_PID=$(docker inspect "$NODE2" --format '{{.State.Pid}}')

echo "leaf1 pid=$LEAF1_PID  leaf2 pid=$LEAF2_PID  node2 pid=$NODE2_PID"

# Remove stale interfaces if they exist
docker exec "$NODE2" ip link del fab0 2>/dev/null || true
docker exec "$NODE2" ip link del fab1 2>/dev/null || true
docker exec "$LEAF1" ip link del eth5 2>/dev/null || true
docker exec "$LEAF2" ip link del eth5 2>/dev/null || true

echo "=== creating leaf1:eth5 <-> node2:fab0 ==="
ip link add l1n2a type veth peer name l1n2b
ip link set l1n2a netns "$LEAF1_PID" name eth5
ip link set l1n2b netns "$NODE2_PID" name fab0
docker exec "$LEAF1" ip link set eth5 up mtu 9500
docker exec "$NODE2" ip link set fab0 up mtu 9500

echo "=== creating leaf2:eth5 <-> node2:fab1 ==="
ip link add l2n2a type veth peer name l2n2b
ip link set l2n2a netns "$LEAF2_PID" name eth5
ip link set l2n2b netns "$NODE2_PID" name fab1
docker exec "$LEAF2" ip link set eth5 up mtu 9500
docker exec "$NODE2" ip link set fab1 up mtu 9500

echo "=== verifying ==="
echo -n "  node2 fab0: "; docker exec "$NODE2" ip -br link show fab0
echo -n "  node2 fab1: "; docker exec "$NODE2" ip -br link show fab1
echo -n "  leaf1 eth5: "; docker exec "$LEAF1" ip -br link show eth5
echo -n "  leaf2 eth5: "; docker exec "$LEAF2" ip -br link show eth5

echo "=== running node2 startup ==="
docker exec -d "$NODE2" bash /opt/startup.sh
echo "done — wait ~15s for bird BGP to re-establish"
