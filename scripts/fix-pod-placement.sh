#!/usr/bin/env bash
# Reapply demo-app.yaml to enforce nodeAffinity (no pods on node2) then wait for rollout.
set -uo pipefail
REPO="/mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment"
N1="clab-maglev-clos-node1"
KC() { docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" k3s kubectl "$@"; }

echo "=== applying demo-app.yaml (nodeAffinity: not node2) ==="
KC apply -f "${REPO}/k8s/demo-app.yaml"

echo "=== rollout restart to reschedule pods ==="
KC rollout restart deploy/echo
KC rollout status deploy/echo --timeout=120s

echo "=== pod distribution ==="
KC get pods -l app=echo -o wide --no-headers | awk '{printf "  %-45s  node=%-6s  status=%s\n", $1, $7, $3}'
