#!/usr/bin/env bash
N1="clab-maglev-clos-node1"
sleep "${1:-0}"
docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" k3s kubectl get pods -l app=echo -o wide --no-headers 2>/dev/null \
  | grep -v Terminating \
  | awk '{printf "  %-45s  node=%-6s  status=%s\n", $1, $7, $3}'
