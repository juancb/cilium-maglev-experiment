#!/usr/bin/env bash
set -euo pipefail
N1="clab-maglev-clos-node1"
N2="clab-maglev-clos-node2"

TOKEN=$(docker exec "$N1" cat /var/lib/rancher/k3s/server/node-token)
docker exec "$N2" bash -c "rm -rf /run/k3s /var/run/k3s 2>/dev/null; true"
docker exec -d "$N2" bash -lc \
  "k3s agent --server https://10.10.0.1:6443 --token ${TOKEN} --node-ip 10.10.0.2 \
   --snapshotter=native >/var/log/k3s.log 2>&1"
echo "k3s agent started on node2, waiting for Ready..."
for i in $(seq 1 30); do
  s=$(docker exec "$N1" bash -c \
    "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get node node2 --no-headers 2>/dev/null" \
    | awk '{print $2}')
  echo "  [$i] node2: ${s:-unknown}"
  [ "${s:-}" = "Ready" ] && echo "node2 Ready" && exit 0
  sleep 5
done
echo "node2 did not become Ready"
exit 1
