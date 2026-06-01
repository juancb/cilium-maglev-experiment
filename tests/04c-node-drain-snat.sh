#!/usr/bin/env bash
# Test 4C-SNAT — SNAT mode (no DSR): Maglev observable via graceful node drain.
#
# Identical failure injection to 04c-node-drain.sh but Cilium runs in standard
# SNAT mode. Backend pods see the ingress-node IP, not the original client IP.
#
# Failure injection: kubectl drain <node> then immediately take down its fabric
# links. Pods have a GRACE-second termination window; flows re-home to remaining
# ingress nodes via ECMP re-hash.
#
#   Maglev off: new ingress picks random backend → RST (~44-56%)
#   Maglev on:  new ingress picks SAME backend   → survives (~0%)
#
# NOTE: drain any worker node (node2 or node3), never node1 (k3s control plane).
#
# Env knobs: N=<flows> (default 300)   DUR=<sec> (default 50)
#            DRAIN_NODE=<k8s-node-name>  (default node3)
#            GRACE=<seconds>             (default 60)
#            REPLICAS=<n>                (default 6)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

N="${N:-300}"; DUR="${DUR:-50}"; REPLICAS="${REPLICAS:-6}"
DRAIN_NODE="${DRAIN_NODE:-node3}"
DRAIN_CTR="${PFX}-${DRAIN_NODE}"
MASTER="${PFX}-node1"
GRACE="${GRACE:-60}"
HELM_VALUES_DIR="/opt/k8s"
declare -A RESULT

set_cilium_values() {
  local vals="$1"
  info "applying ${vals} (helm upgrade + rollout restart)"
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$MASTER" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/${vals}" --reset-values >/dev/null
  step "triggering rolling restart of cilium DaemonSet"
  docker exec "$MASTER" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null
  step "waiting for rollout to complete"
  docker exec "$MASTER" k3s kubectl -n kube-system rollout status ds/cilium --timeout=180s 2>&1 | sed 's/^/  /'
  sleep 5
}

cleanup() {
  info "Restoring drain node and Cilium values..."
  docker exec "$DRAIN_CTR" ip link set fab0 up 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab1 up 2>/dev/null || true
  kc uncordon "$DRAIN_NODE" 2>/dev/null || true
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$MASTER" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/cilium-values-maglev.yaml" --reset-values >/dev/null 2>&1 || true
  docker exec "$MASTER" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null 2>&1 || true
  docker exec "$MASTER" k3s kubectl -n kube-system rollout status ds/cilium --timeout=120s 2>&1 | sed 's/^/  /' || true
}
trap cleanup EXIT

ensure_node_up() {
  step "ensuring ${DRAIN_NODE} is uncordoned and fabric links are up"
  kc uncordon "$DRAIN_NODE" 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab0 up 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab1 up 2>/dev/null || true
  docker exec "${PFX}-leaf1" ip link set eth4 up 2>/dev/null || true
  docker exec "${PFX}-leaf2" ip link set eth4 up 2>/dev/null || true
  step "waiting for VIP ECMP to reconverge (≥2 nexthops at leaf1)"
  wait_vip_ecmp 60 || yellow "  INFO: VIP ECMP not fully reconverged — proceeding anyway"
}

run_cell() {
  local tag="$1"
  info "=== cell: ${tag} ==="

  ensure_node_up

  step "pod placement before drain:"
  kc get pods -o wide --no-headers 2>/dev/null | awk '{printf "  %-40s %s\n", $1, $7}' || true

  step "starting ${N} flows (duration ${DUR}s)"
  docker exec "$CLIENT" rm -f /tmp/${tag}.json /tmp/${tag}.ready 2>/dev/null || true
  docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
      --vip "$VIP" --port "$VIP_PORT" --count "$N" --duration "$DUR" \
      --src 203.0.113.1 \
      --out "/tmp/${tag}.json" --ready-file "/tmp/${tag}.ready"

  local elapsed=0
  for _ in $(seq 1 30); do
    docker exec "$CLIENT" test -f /tmp/${tag}.ready && break
    sleep 1; elapsed=$(( elapsed + 1 ))
    [ $(( elapsed % 5 )) -eq 0 ] && step "waiting for flows to establish... (${elapsed}s)"
  done
  step "flows established; sleeping 3s before drain + fabric failure"
  sleep 3

  local failtime; failtime=$(date +%s)

  info "draining ${DRAIN_NODE} (grace-period=${GRACE}s) and failing its fabric links"
  kc drain "$DRAIN_NODE" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --grace-period="${GRACE}" \
    --timeout=10s \
    2>&1 | sed 's/^/  /' || true

  docker exec "$DRAIN_CTR" ip link set fab0 down
  docker exec "$DRAIN_CTR" ip link set fab1 down

  local wait_secs=$(( DUR > 20 ? DUR-15 : 10 ))
  for i in $(seq 1 "$wait_secs"); do
    sleep 1
    [ $(( i % 5 )) -eq 0 ] && step "post-failure wait: ${i}/${wait_secs}s"
  done

  step "restoring ${DRAIN_NODE} (uncordon + fabric up)"
  kc uncordon "$DRAIN_NODE" 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab0 up
  docker exec "$DRAIN_CTR" ip link set fab1 up

  step "collecting results from flowgen"
  for _ in $(seq 1 30); do
    docker exec "$CLIENT" test -s /tmp/${tag}.json && break; sleep 1
  done
  docker cp "${CLIENT}:/tmp/${tag}.json" "${RESULTS_DIR}/${tag}.json" >/dev/null 2>&1 || true
  if command -v jq >/dev/null 2>&1 && [ -s "${RESULTS_DIR}/${tag}.json" ]; then
    local tmp; tmp=$(mktemp)
    jq --argjson ft "$failtime" '.summary.failtime = $ft' "${RESULTS_DIR}/${tag}.json" > "$tmp" \
      && mv "$tmp" "${RESULTS_DIR}/${tag}.json" || rm -f "$tmp"
  fi

  local broken est pct
  if command -v jq >/dev/null 2>&1 && [ -s "${RESULTS_DIR}/${tag}.json" ]; then
    broken=$(jq --argjson t "$failtime" \
      '[.flows[] | select(.status=="broken" and .established_at!=null and (.broke_at//0) >= $t)] | length' \
      "${RESULTS_DIR}/${tag}.json")
    est=$(jq '.summary.established' "${RESULTS_DIR}/${tag}.json")
  else
    broken="?"; est="$N"
  fi
  if [ "$broken" != "?" ] && [ "${est:-0}" -gt 0 ]; then
    pct=$(awk "BEGIN{printf \"%.0f\", 100*$broken/$est}")
  else pct="?"; fi
  RESULT["$tag"]="${broken}/${est} (${pct}%)"
  green "  cell result: ${broken} broken of ${est} established (${pct}%)"
}

info "Test 4C-SNAT setup: N=${N} flows, DUR=${DUR}s, drain=${DRAIN_NODE} (grace=${GRACE}s), ${REPLICAS} replicas"
yellow "  NOTE: flows to pods ON ${DRAIN_NODE} will break (fabric goes down)."
yellow "  For cleanest results use a drain node with no/few pods: kubectl get pods -o wide"
step "scaling echo to ${REPLICAS} replicas"
kc -n default scale deploy/echo --replicas="${REPLICAS}" >/dev/null 2>&1 || true
kc -n default rollout status deploy/echo --timeout=120s 2>&1 | sed 's/^/  /'

info "--- SNAT + Maglev OFF ---"
set_cilium_values "cilium-values-nomaglev.yaml"
run_cell "snat-node-drain_maglev-off"

info "--- SNAT + Maglev ON ---"
set_cilium_values "cilium-values-maglev.yaml"
run_cell "snat-node-drain_maglev-on"

echo
green "================ Test 4C-SNAT: Node Drain results ======================"
printf '%-40s %s\n' "SNAT + Maglev off:" "${RESULT[snat-node-drain_maglev-off]:-?}"
printf '%-40s %s\n' "SNAT + Maglev on: " "${RESULT[snat-node-drain_maglev-on]:-?}"
echo
echo "Drain node: ${DRAIN_NODE}  Grace period: ${GRACE}s  Replicas: ${REPLICAS}"
echo "Predicted (no CH on leaves, ECMP 3→2 full rehash):"
echo "  SNAT + Maglev off: ~44-56%  (2/3 re-homed × wrong backend)"
echo "  SNAT + Maglev on:  ~0%      (Maglev selects same backend)"
echo
echo "Raw JSON: ${RESULTS_DIR}/"
green "Runtime: $(fmt_duration)"
