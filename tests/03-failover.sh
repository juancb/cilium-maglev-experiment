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

N="${N:-150}"; DUR="${DUR:-25}"; B="${B:-6}"
HELM_VALUES_DIR="/opt/k8s"            # bound into node containers at /opt/k8s
N1="${PFX}-node1"
declare -A RESULT

set_backends() {
  kc -n default scale deploy/echo --replicas="$B" >/dev/null
  kc -n default rollout status deploy/echo --timeout=120s >/dev/null 2>&1 || true
}

wait_cilium_ready() {
  local tries="${1:-90}"
  info "waiting for all nodes Ready + Cilium 1/1..."
  for _ in $(seq 1 "$tries"); do
    local nodes_not_ready cilium_not_ready
    nodes_not_ready=$(docker exec "$N1" k3s kubectl get nodes --no-headers 2>/dev/null \
      | grep -cv ' Ready ' || true)
    cilium_not_ready=$(docker exec "$N1" k3s kubectl -n kube-system get pods \
      -l app.kubernetes.io/name=cilium-agent --no-headers 2>/dev/null \
      | grep -cv '1/1.*Running' || true)
    [ "${nodes_not_ready:-1}" -eq 0 ] && [ "${cilium_not_ready:-1}" -eq 0 ] && return 0
    sleep 3
  done
  yellow "  WARNING: cluster not fully ready after wait"
  return 1
}

set_maglev() {
  local mode="$1"  # on|off
  local vals="cilium-values-maglev.yaml"; [ "$mode" = off ] && vals="cilium-values-nomaglev.yaml"
  # Wait for Cilium to be stable before upgrading (node2 may still be recovering)
  wait_cilium_ready 90 || true
  info "switching Maglev ${mode} (helm upgrade ${vals})"
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/${vals}" --reuse-values >/dev/null
  # helm upgrade triggers a rolling update; no need for explicit rollout restart.
  # Just wait for the rollout to complete, force-deleting any stuck Terminating pods.
  for _ in $(seq 1 6); do
    sleep 10
    for stuck in $(docker exec "$N1" k3s kubectl -n kube-system get pods \
        -l app.kubernetes.io/name=cilium-agent --no-headers 2>/dev/null \
        | awk '/Terminating/{print $1}'); do
      docker exec "$N1" k3s kubectl -n kube-system delete pod "$stuck" --force --grace-period=0 2>/dev/null || true
      yellow "  force-deleted stuck pod: $stuck"
    done
  done
  # Wait for ALL nodes including node2 — node2 must be forwarding before flows start.
  wait_cilium_ready 120 || yellow "  WARNING: Cilium not fully ready; results may be skewed"
  sleep 3
}

set_ch() {
  local mode="$1"  # on|off
  info "switching ToR consistent hashing ${mode}"
  docker exec "$TOR" bash "/etc/sonic/ch-${mode}.sh" >/dev/null 2>&1 \
    || yellow "  INFO: ToR CH toggle failed (sonic-vs fidelity?) — set EMULATE_CH=1 to script it"
}

restore_fail_node() {
  # docker start is a no-op if already running; actual start clears the netns
  # destroying both fab0/fab1 in the node AND the peer eth in the leaf.
  # We detect this by checking if fab0 is absent after the start.
  docker start "$FAIL_SPINE" >/dev/null 2>&1 || true
  sleep 0.5  # let the container process initialise
  if ! docker exec "$FAIL_SPINE" ip link show fab0 >/dev/null 2>&1; then
    # Fresh netns: recreate veth pairs from scratch, then reconfigure network
    local node="${FAIL_SPINE#${PFX}-}"
    bash "${REPO_ROOT}/scripts/rewire-node-veths.sh" "$node" 2>/dev/null || true
    docker exec -d "$FAIL_SPINE" bash /opt/startup.sh 2>/dev/null || true
  fi
  # Restart k3s agent if not running (docker stop kills all processes in the container)
  if ! docker exec "$FAIL_SPINE" bash -c 'pgrep -f "k3s agent" >/dev/null 2>&1'; then
    local token; token=$(docker exec "${PFX}-node1" cat /var/lib/rancher/k3s/server/node-token)
    local node_num="${FAIL_SPINE##*node}"
    # Clean stale runtime sockets so k3s-agent starts cleanly
    docker exec "$FAIL_SPINE" bash -c 'rm -rf /run/k3s /var/run/k3s 2>/dev/null; true'
    docker exec -d "$FAIL_SPINE" bash -lc \
      "k3s agent --server https://10.10.0.1:6443 --token ${token} --node-ip 10.10.0.${node_num} \
       --snapshotter=native >/var/log/k3s.log 2>&1"
    yellow "  restarted k3s agent on ${FAIL_SPINE}"
    # wait for node Ready (cgroup cleanup can take ~60-90s before kubelet posts status)
    for _ in $(seq 1 90); do
      kc get node "node${node_num}" --no-headers 2>/dev/null | grep -q ' Ready' && break
      sleep 3
    done
  fi
}

run_cell() {
  local ch="$1" mag="$2"
  local tag="ch-${ch}_maglev-${mag}"
  info "=== cell: CH ${ch} / Maglev ${mag} ==="
  # Restore the failed node (idempotent: if already up and wired, this is a no-op).
  restore_fail_node
  wait_cilium_ready 60 || yellow "  INFO: Cilium not fully ready before run"
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
  restore_fail_node

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
info "Note: ToR CH toggle non-functional (FRR ToR, not SONiC) — running CH-off cells only"
set_backends

set_maglev off
run_cell off off
set_maglev on
run_cell off on

echo
green "======== broken-flow results (CH lever non-functional, omitted) ========"
printf 'Maglev off:  %s\n' "${RESULT[ch-off_maglev-off]:-?}"
printf 'Maglev on:   %s\n' "${RESULT[ch-off_maglev-on]:-?}"
echo  "Predicted (P=3,M=3,large B): ~44% broken (Maglev off);  ~0% (Maglev on)"
echo  "Raw per-flow JSON in ${RESULTS_DIR}/"
