#!/usr/bin/env bash
# Create the three k8s node containers manually with --cgroupns=host so k3s can
# create its kubepods cgroup hierarchy. containerlab uses ext-container kind to
# wire the fabric veth links to these containers after they exist.
set -uo pipefail
LAB="maglev-clos"
NET="maglev-mgmt"
REPO="/mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment"

# Ensure management network exists
docker network create "$NET" --subnet 172.30.0.0/24 2>/dev/null || true

for ID in 1 2 3; do
  NAME="clab-${LAB}-node${ID}"
  echo "=== creating ${NAME} ==="

  # Remove if exists
  docker rm -f "$NAME" 2>/dev/null || true

  # node1 publishes ports so Windows can reach UIs at localhost:PORT.
  # Use high non-NodePort ports so Cilium BPF doesn't pre-reserve them;
  # kubectl port-forward inside node1 bridges these to the actual pods.
  #   18080 → Hubble UI    (http://localhost:18080)
  #   18081 → Grafana      (http://localhost:18081)
  EXTRA_PORTS=""
  [ "$ID" -eq 1 ] && EXTRA_PORTS="-p 18080:18080 -p 18081:18081"

  docker run -d \
    --name "$NAME" \
    --hostname "node${ID}" \
    --cgroupns=host \
    --privileged \
    --network "$NET" \
    -e "NODE_ID=${ID}" \
    -v "${REPO}/nodes/bird/node${ID}.conf:/etc/bird/bird.conf:ro" \
    -v "${REPO}/nodes/startup/node.sh:/opt/startup.sh:ro" \
    -v "${REPO}/k8s:/opt/k8s:ro" \
    $EXTRA_PORTS \
    maglev/k3s-bird:latest \
    sleep infinity

  echo "  started ${NAME} (cgroupns=host)"
done

echo "=== node containers running ==="
docker ps --filter "name=clab-${LAB}-node" --format "{{.Names}}\t{{.Status}}"
