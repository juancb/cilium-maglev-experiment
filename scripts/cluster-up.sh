#!/usr/bin/env bash
# Bring up the k3s cluster (node1 server, node2/3 agents) and install Cilium + BGP + demo app,
# AFTER containerlab + bird have converged so node k8s IPs are routable across the fabric.
set -euo pipefail
. "$(dirname "$0")/../tests/lib/common.sh"

KCFG="/etc/rancher/k3s/k3s.yaml"
helm1() { docker exec -e KUBECONFIG="$KCFG" "${PFX}-node1" helm "$@"; }

K3S_SERVER_FLAGS="--flannel-backend=none --disable-network-policy --disable-kube-proxy \
  --disable=traefik --disable=servicelb --disable=local-storage \
  --cluster-cidr 10.244.0.0/16 --service-cidr 10.96.0.0/16 \
  --node-ip 10.10.0.1 --advertise-address 10.10.0.1 --tls-san 10.10.0.1 \
  --snapshotter=native"
# --snapshotter=native: overlay-on-overlay fails inside Docker containers (the containerd
# data dir sits on Docker's overlayfs layer). "native" uses bind mounts instead.

info "waiting for bird uplinks on all nodes (fabric must route k8s IPs before join)"
for n in "${NODES[@]}"; do
  wait_node_bgp "$n" 60 || { red "$(basename "$n") bird uplinks not Established"; exit 1; }
done
green "fabric converged"

info "starting k3s server on node1"
docker exec -d "${PFX}-node1" bash -lc "k3s server ${K3S_SERVER_FLAGS} >/var/log/k3s.log 2>&1"
for _ in $(seq 1 60); do
  TOKEN=$(docker exec "${PFX}-node1" cat /var/lib/rancher/k3s/server/node-token 2>/dev/null || true)
  [ -n "${TOKEN:-}" ] && break; sleep 2
done
[ -n "${TOKEN:-}" ] || { red "k3s server did not produce a join token"; exit 1; }

for id in 2 3; do
  info "starting k3s agent on node${id}"
  docker exec -d "${PFX}-node${id}" bash -lc \
    "k3s agent --server https://10.10.0.1:6443 --token ${TOKEN} --node-ip 10.10.0.${id} \
     --snapshotter=native >/var/log/k3s.log 2>&1"
done

info "waiting for 3 nodes to register"
for _ in $(seq 1 90); do
  c=$(kc get nodes --no-headers 2>/dev/null | grep -c . || true)
  [ "${c:-0}" -ge 3 ] 2>/dev/null && break; sleep 3
done
kc get nodes -o wide || true

info "installing Cilium ${CILIUM_VERSION} (maglev variant)"
helm1 repo add cilium https://helm.cilium.io >/dev/null 2>&1 || true
helm1 repo update >/dev/null
helm1 install cilium cilium/cilium -n kube-system --create-namespace \
    --version "${CILIUM_VERSION}" -f /opt/k8s/cilium-values-maglev.yaml
docker exec -e KUBECONFIG="$KCFG" "${PFX}-node1" cilium status --wait --wait-duration 3m || true

info "applying BGP config + demo app"
kc apply -f /opt/k8s/cilium-bgp.yaml
kc apply -f /opt/k8s/demo-app.yaml
kc -n default rollout status deploy/echo --timeout=180s || true

info "applying Hubble UI NodePort (internal reference only — UI served via port-forward)"
kc apply -f /opt/k8s/hubble-nodeport.yaml

info "waiting for VIP to appear in the fabric"
wait_vip_ecmp 60 && green "VIP ${VIP} is ECMP in the fabric" \
                 || yellow "VIP not yet ECMP — check 'cilium bgp routes' and bird sessions"

# ── Observability stack ──────────────────────────────────────────────────────
info "adding Helm repos for observability stack"
helm1 repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null 2>&1 || true
helm1 repo add grafana https://grafana.github.io/helm-charts >/dev/null 2>&1 || true
helm1 repo update >/dev/null

info "installing kube-prometheus-stack (Prometheus + Grafana) — Windows: http://localhost:32002 admin/admin"
helm1 upgrade --install kube-prometheus prometheus-community/kube-prometheus-stack \
    -n monitoring --create-namespace \
    -f /opt/k8s/prometheus-values.yaml \
    --timeout 8m || yellow "kube-prometheus-stack install had warnings (check: kubectl -n monitoring get pods)"

info "installing Loki + Promtail (log aggregation, 7d retention)"
helm1 upgrade --install loki grafana/loki \
    -n monitoring \
    -f /opt/k8s/loki-values.yaml \
    --timeout 5m || yellow "Loki install had warnings"

info "installing Tempo (distributed tracing, 7d retention)"
helm1 upgrade --install tempo grafana/tempo \
    -n monitoring \
    -f /opt/k8s/tempo-values.yaml \
    --timeout 5m || yellow "Tempo install had warnings"

info "starting kubectl port-forwards (Hubble UI :18080, Grafana :18081)"
docker exec -d "${PFX}-node1" bash -c \
  'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl port-forward -n kube-system svc/hubble-ui 18080:80 --address 0.0.0.0 &>/var/log/pf-hubble.log'
docker exec -d "${PFX}-node1" bash -c \
  'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl port-forward -n monitoring svc/kube-prometheus-grafana 18081:80 --address 0.0.0.0 &>/var/log/pf-grafana.log'
sleep 3

green "cluster up."
green "  Hubble UI  → http://localhost:18080"
green "  Grafana    → http://localhost:18081  (admin / admin)"
