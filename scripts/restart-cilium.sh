#!/usr/bin/env bash
set -uo pipefail
KC="docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml clab-maglev-clos-node1 k3s kubectl"
$KC -n kube-system delete pods -l k8s-app=cilium 2>/dev/null
echo "waiting 40s..."
sleep 40
$KC get pods -n kube-system 2>/dev/null | grep -v Completed
echo "---nodes---"
$KC get nodes 2>/dev/null
