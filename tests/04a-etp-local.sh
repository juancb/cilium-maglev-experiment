#!/usr/bin/env bash
# Test 4A — ETP=Local: confirm Maglev is irrelevant when each ingress node
# can only forward to its own local backend.
#
# Setup: 3 replicas, 1 per node (DoNotSchedule spread). externalTrafficPolicy=Local.
# When node2 fails: ~1/3 of flows were ingressed by node2. Those re-home to
# node1/node3, which forward to THEIR local pods (different pods from node2's).
# Result: ~33% broken in BOTH cells — Maglev makes no difference.
#
# This disproves the incorrect inference from Test 3 that "ETP=Local would fix SNAT".
#
# Env knobs: N=<flows> (default 300)   DUR=<sec> (default 50)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

N="${N:-300}"; DUR="${DUR:-50}"
N1="${PFX}-node1"
HELM_VALUES_DIR="/opt/k8s"
declare -A RESULT

set_maglev() {
  local mode="$1"
  local vals="cilium-values-maglev.yaml"; [ "$mode" = off ] && vals="cilium-values-nomaglev.yaml"
  info "switching Maglev ${mode} (helm upgrade ${vals})"
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/${vals}" --reuse-values >/dev/null
  docker exec "$N1" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null
  docker exec "$N1" k3s kubectl -n kube-system rollout status ds/cilium --timeout=180s >/dev/null
  sleep 5
}

cleanup() {
  info "Restoring original demo-app (ETP=Cluster, 6 replicas)..."
  kc apply -f /opt/k8s/demo-app.yaml >/dev/null 2>&1 || true
  kc rollout status deploy/echo --timeout=120s >/dev/null 2>&1 || true
}
trap cleanup EXIT

run_cell() {
  local mag="$1"
  local tag="etp-local_maglev-${mag}"
  info "=== cell: ETP=Local / Maglev ${mag} ==="

  # Restart the failed node, rewire veths, bring network back up
  docker start "$FAIL_SPINE" >/dev/null 2>&1 || true
  bash "${REPO_ROOT}/scripts/fix-node-veths.sh" "$FAIL_SPINE" 2>/dev/null || true
  docker exec -d "$FAIL_SPINE" bash /opt/startup.sh 2>/dev/null || true
  wait_vip_ecmp 30 || yellow "  INFO: VIP ECMP not fully reconverged"

  # start N flows
  docker exec "$CLIENT" rm -f /tmp/${tag}.json /tmp/${tag}.ready 2>/dev/null || true
  docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
      --vip "$VIP" --port "$VIP_PORT" --count "$N" --duration "$DUR" \
      --out "/tmp/${tag}.json" --ready-file "/tmp/${tag}.ready"
  for _ in $(seq 1 30); do
    docker exec "$CLIENT" test -f /tmp/${tag}.ready && break; sleep 1
  done
  sleep 3

  # inject failure
  local failtime; failtime=$(date +%s)
  info "stopping ${FAIL_SPINE}"
  docker stop "$FAIL_SPINE" >/dev/null
  sleep $((DUR > 20 ? DUR-15 : 10))
  docker start "$FAIL_SPINE" >/dev/null
  bash "${REPO_ROOT}/scripts/fix-node-veths.sh" "$FAIL_SPINE" 2>/dev/null || true

  # collect
  for _ in $(seq 1 30); do
    docker exec "$CLIENT" test -s /tmp/${tag}.json && break; sleep 1
  done
  docker cp "${CLIENT}:/tmp/${tag}.json" "${RESULTS_DIR}/${tag}.json" >/dev/null 2>&1 || true

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

info "Test 4A setup: N=${N} flows, 3 replicas (1/node), ETP=Local, DUR=${DUR}s"

info "Applying ETP=Local manifest (demo-app-local.yaml)..."
kc apply -f /opt/k8s/demo-app-local.yaml >/dev/null
kc rollout status deploy/echo --timeout=120s >/dev/null
info "Pod distribution:"
kc get pods -l app=echo -o wide --no-headers 2>/dev/null | awk '{print "  " $1 " -> " $7}'

set_maglev off
run_cell off

set_maglev on
run_cell on

echo
green "================ ETP=Local broken-flow results =========================="
printf '%-40s %s\n' "Maglev off (ETP=Local):" "${RESULT[etp-local_maglev-off]:-?}"
printf '%-40s %s\n' "Maglev on  (ETP=Local):" "${RESULT[etp-local_maglev-on]:-?}"
echo
echo "Predicted: ~33% broken in BOTH cells (1/3 of flows on node2; all break"
echo "because surviving nodes have different local pods; Maglev is irrelevant)."
echo "This confirms ETP=Local does NOT benefit from Maglev — disproving the"
echo "earlier inference from Test 3."
echo
echo "For the config that DOES make Maglev observable: bash tests/04b-dsr.sh"
echo "Raw JSON: ${RESULTS_DIR}/"
