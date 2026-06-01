#!/usr/bin/env bash
set -euo pipefail
for i in $(seq 1 40); do
  status=$(KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl get node node2 --no-headers 2>/dev/null | awk '{print $2}')
  echo "  [${i}] node2: ${status:-unknown}"
  [ "${status:-}" = "Ready" ] && echo "node2 Ready" && exit 0
  sleep 3
done
echo "node2 did not become Ready in time"
exit 1
