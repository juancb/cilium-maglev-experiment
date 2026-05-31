#!/usr/bin/env bash
# Test 3 — the headline 2×2.
# Open N long-lived TCP flows, fail node2 (no pods; all pods on node3), count RSTs.
#
# Why node2, not spine1: in a CLOS fabric with per-flow ECMP at each tier, the same
# 5-tuple always maps to the same leaf→node regardless of which spine carries it.
# A spine failure only changes the spine, not the ingress node, so Maglev vs random
# makes no difference. A NODE failure forces flow re-homing to a different ingress
# Cilium agent, which is exactly what the Maglev vs random comparison tests.
#
# Expected (M=3 nodes, B=6 backends, ~1/3 of flows on node2):
#   Maglev off: re-homed flows pick random backend → ~(1/3)×((B-1)/B)≈~28% break
#   Maglev on:  re-homed flows pick SAME backend   → ~0% break
#
# Env knobs:  N=<flows> (default 300)   B=<backends> (default 6)   DUR=<sec> (default 50)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh

N="${N:-300}"; DUR="${DUR:-50}"; B="${B:-6}"
HELM_VALUES_DIR="/opt/k8s"            # bound into node containers at /opt/k8s
N1="${PFX}-node1"
declare -A RESULT

set_backends() {
  kc -n default scale deploy/echo --replicas="$B" >/dev/null
  kc -n default rollout status deploy/echo --timeout=120s >/dev/null
}

set_maglev() {
  local mode="$1"  # on|off
  local vals="cilium-values-maglev.yaml"; [ "$mode" = off ] && vals="cilium-values-nomaglev.yaml"
  info "switching Maglev ${mode} (helm upgrade ${vals})"
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/${vals}" --reuse-values >/dev/null
  docker exec "$N1" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null
  docker exec "$N1" k3s kubectl -n kube-system rollout status ds/cilium --timeout=180s >/dev/null
  sleep 5
}

set_ch() {
  local mode="$1"  # on|off
  info "switching ToR consistent hashing ${mode}"
  docker exec "$TOR" bash "/etc/sonic/ch-${mode}.sh" >/dev/null 2>&1 \
    || yellow "  INFO: ToR CH toggle failed (sonic-vs fidelity?) — set EMULATE_CH=1 to script it"
}

run_cell() {
  local ch="$1" mag="$2"
  local tag="ch-${ch}_maglev-${mag}"
  info "=== cell: CH ${ch} / Maglev ${mag} ==="
  # Restart the failed node and bring its network/bird back up.
  # docker start recreates the container netns, losing manually-placed veths;
  # fix-node-veths.sh moves them back before startup.sh re-addresses them.
  docker start "$FAIL_SPINE" >/dev/null 2>&1 || true
  bash "${REPO_ROOT}/scripts/fix-node-veths.sh" "$FAIL_SPINE" 2>/dev/null || true
  docker exec -d "$FAIL_SPINE" bash /opt/startup.sh 2>/dev/null || true
  wait_vip_ecmp 30 || yellow "  INFO: VIP ECMP not fully reconverged before run"
  set_ch "$ch"

  # start N flows; wait until established
  docker exec "$CLIENT" rm -f /tmp/${tag}.json /tmp/${tag}.ready 2>/dev/null || true
  docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
      --vip "$VIP" --port "$VIP_PORT" --count "$N" --duration "$DUR" \
      --out "/tmp/${tag}.json" --ready-file "/tmp/${tag}.ready"
  for _ in $(seq 1 30); do
    docker exec "$CLIENT" test -f /tmp/${tag}.ready && break; sleep 1
  done
  sleep 3

  # inject the failure and timestamp it
  local failtime; failtime=$(date +%s)
  info "stopping ${FAIL_SPINE}"
  docker stop "$FAIL_SPINE" >/dev/null
  sleep $((DUR > 20 ? DUR-15 : 10))     # let resets surface, leave margin before flowgen ends
  docker start "$FAIL_SPINE" >/dev/null
  bash "${REPO_ROOT}/scripts/fix-node-veths.sh" "$FAIL_SPINE" 2>/dev/null || true

  # collect
  for _ in $(seq 1 30); do
    docker exec "$CLIENT" test -s /tmp/${tag}.json && break; sleep 1
  done
  docker cp "${CLIENT}:/tmp/${tag}.json" "${RESULTS_DIR}/${tag}.json" >/dev/null 2>&1 || true

  # broken = established then reset at/after the failure
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

info "Test 3 setup: N=${N} flows, B=${B} backends, duration ${DUR}s"
set_backends

set_maglev off
run_cell off off
run_cell on  off
set_maglev on
run_cell off on
run_cell on  on

# leave the lab in the maglev + CH-on state
set_ch on

echo
green "================ 2×2 broken-flow matrix (broken/established) ================"
printf '                 %-22s %-22s\n' "switch CH off" "switch CH on"
printf 'Maglev off       %-22s %-22s\n' "${RESULT[ch-off_maglev-off]:-?}" "${RESULT[ch-on_maglev-off]:-?}"
printf 'Maglev on        %-22s %-22s\n' "${RESULT[ch-off_maglev-on]:-?}"  "${RESULT[ch-on_maglev-on]:-?}"
echo  "Predicted (P=3,M=3,large B): ~44% | ~22% (Maglev off);  ~0% | ~0% (Maglev on)"
echo  "Raw per-flow JSON in ${RESULTS_DIR}/"
