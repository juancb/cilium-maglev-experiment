#!/usr/bin/env bash
set -uo pipefail
N1="clab-maglev-clos-node1"
KC() { docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" k3s kubectl "$@"; }

MANIFEST="/mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment/k8s/demo-app.yaml"
docker cp "$MANIFEST" "${N1}:/tmp/demo-app.yaml"

echo "=== applying demo-app.yaml ==="
KC apply -f /tmp/demo-app.yaml

echo "=== rollout restart ==="
KC rollout restart deploy/echo
KC rollout status deploy/echo --timeout=120s

echo "=== pod distribution ==="
KC get pods -l app=echo -o wide --no-headers | awk '{printf "  %-45s  node=%-6s  status=%s\n", $1, $7, $3}'
