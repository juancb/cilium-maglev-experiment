#!/usr/bin/env bash
# Full Cilium uninstall + reinstall to properly detach cgroup BPF programs.
# The helm uninstall triggers Cilium's shutdown handler which cleans up cgroup attachments.
set -euo pipefail

N1="clab-maglev-clos-node1"
VALUES="/mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment/k8s/cilium-values-maglev.yaml"

kctl() {
  docker exec "$N1" bash -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $*"
}
helm() {
  docker exec "$N1" bash -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm $*"
}

echo "=== 1. Uninstalling Cilium ==="
helm "uninstall cilium -n kube-system" 2>/dev/null || true

echo "=== 2. Waiting for Cilium pods to terminate ==="
for i in $(seq 1 60); do
  COUNT=$(kctl "-n kube-system get pods -l k8s-app=cilium --no-headers 2>/dev/null | wc -l" 2>/dev/null || echo 1)
  echo "  cilium pods remaining: $COUNT"
  [ "$COUNT" -eq 0 ] && break
  sleep 3
done

echo "=== 3. Verifying cgroup BPF programs are gone ==="
docker exec "$N1" bash -c \
  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system run bpftool-check --rm -i --restart=Never \
   --image=quay.io/cilium/cilium:v1.19.4 \
   --overrides='{\"spec\":{\"hostPID\":true,\"hostNetwork\":true}}' \
   -- bpftool cgroup list /run/cilium/cgroupv2" 2>/dev/null || true

echo ""
echo "=== 4. Reinstalling Cilium with socketLB.enabled=false ==="
docker exec "$N1" bash -c \
  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml helm upgrade --install cilium cilium/cilium \
   -n kube-system -f $VALUES" 2>/dev/null

echo "=== 5. Waiting for Cilium pods to be ready ==="
docker exec "$N1" bash -c \
  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system rollout status ds/cilium --timeout=120s"

echo ""
echo "=== Done. Checking socketLB status ==="
docker exec "$N1" bash -c \
  "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system exec ds/cilium -- \
   cilium-dbg status 2>/dev/null | grep -i sock" || true
