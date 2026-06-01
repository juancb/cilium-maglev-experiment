#!/usr/bin/env bash
# Smoke test: single cell (Maglev off, CH off) with N=50 flows, DUR=25s
# Used to validate the failover test loop before running the full 2x2.
set -euo pipefail
cd /mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment/tests
. lib/common.sh

N=50; DUR=25; B=6
HELM_VALUES_DIR="/opt/k8s"
N1="${PFX}-node1"

KC() { docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" k3s kubectl "$@"; }

restore_fail_node() {
  docker start "$FAIL_SPINE" >/dev/null 2>&1 || true
  sleep 0.5
  if ! docker exec "$FAIL_SPINE" ip link show fab0 >/dev/null 2>&1; then
    local node="${FAIL_SPINE#${PFX}-}"
    bash "${REPO_ROOT}/scripts/rewire-node-veths.sh" "$node" 2>/dev/null || true
    docker exec -d "$FAIL_SPINE" bash /opt/startup.sh 2>/dev/null || true
  fi
}

set_maglev_off() {
  info "switching Maglev OFF (helm upgrade)"
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
    helm upgrade cilium cilium/cilium -n kube-system \
    -f "${HELM_VALUES_DIR}/cilium-values-nomaglev.yaml" --reuse-values >/dev/null
  KC -n kube-system rollout restart ds/cilium >/dev/null
  KC -n kube-system rollout status ds/cilium --timeout=180s >/dev/null
  sleep 5
}

info "=== smoke test: CH off / Maglev off  N=${N} DUR=${DUR}s ==="
restore_fail_node
wait_vip_ecmp 30 || { yellow "VIP ECMP not ready"; exit 1; }
info "VIP ECMP OK"

set_maglev_off

TAG="smoke_ch-off_maglev-off"
docker exec "$CLIENT" rm -f /tmp/${TAG}.json /tmp/${TAG}.ready 2>/dev/null || true
info "starting ${N} flows via flowgen..."
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
    --vip "$VIP" --port "$VIP_PORT" --count "$N" --duration "$DUR" \
    --src 203.0.113.1 \
    --out "/tmp/${TAG}.json" --ready-file "/tmp/${TAG}.ready"

for _ in $(seq 1 30); do
  docker exec "$CLIENT" test -f /tmp/${TAG}.ready && break; sleep 1
done
info "flows established — waiting 3s"
sleep 3

FAILTIME=$(date +%s)
info "stopping ${FAIL_SPINE} at $(date)"
docker stop "$FAIL_SPINE" >/dev/null

sleep $((DUR > 20 ? DUR-15 : 10))

info "restoring ${FAIL_SPINE}"
restore_fail_node

for _ in $(seq 1 30); do
  docker exec "$CLIENT" test -s /tmp/${TAG}.json && break; sleep 1
done
docker cp "${CLIENT}:/tmp/${TAG}.json" "${RESULTS_DIR}/${TAG}.json" >/dev/null 2>&1 || true

if command -v jq >/dev/null 2>&1 && [ -s "${RESULTS_DIR}/${TAG}.json" ]; then
  BROKEN=$(jq --argjson t "$FAILTIME" \
    '[.flows[] | select(.status=="broken" and .established_at!=null and (.broke_at//0) >= $t)] | length' \
    "${RESULTS_DIR}/${TAG}.json")
  EST=$(jq '.summary.established' "${RESULTS_DIR}/${TAG}.json")
  PCT=$(awk "BEGIN{printf \"%.0f\", 100*${BROKEN}/${EST:-1}}")
  green "SMOKE RESULT: ${BROKEN} broken of ${EST} established (${PCT}%)"
  green "  Expected with SNAT: ~28% broken (or 0% if SNAT masks ingress node change)"
else
  yellow "No JSON result — check flowgen output"
fi

info "done — node2 state after smoke:"
docker exec "$FAIL_SPINE" ip -br link show fab0 2>/dev/null | head -1 || echo "  fab0 absent"
docker exec "$FAIL_SPINE" birdc show protocols 2>/dev/null | grep -E "uplink|BIRD" | head -5 || true
