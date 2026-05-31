#!/usr/bin/env bash
# Test 3 — the headline 2×2.
# Open N long-lived TCP flows, inject a failure, count RSTs.
#
# Default mode: SPINE FAILURE (fail spine1).
#   The ToR's 3-way ECMP shrinks to 2. Flows that were on spine1 rehash at the ToR.
#   In this FRR-only fabric the rehash maps through the same leaf→node ECMP groups,
#   so the ingress node doesn't change and Maglev has nothing to prove. Expect ~0%
#   for both Maglev on/off. This is a baseline connectivity/stability check.
#   Output files: spine-failure_ch-off_maglev-{on,off}.json
#
# Optional mode: SINGLE-NODE FAILURE (--node-failure, fail node2).
#   node2 is removed from the VIP ECMP group at the leaf. Flows that were on node2
#   are re-homed to node1 or node3. The new ingress agent must pick the SAME backend
#   (Maglev property). Expect ~28% broken with Maglev off, ~0% with Maglev on.
#   Output files: single-node_ch-off_maglev-{on,off}.json
#
# Env knobs:  N=<flows> (default 150)   B=<backends> (default 6)   DUR=<sec> (default 25)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

N="${N:-150}"; DUR="${DUR:-25}"; B="${B:-6}"
HELM_VALUES_DIR="/opt/k8s"
N1="${PFX}-node1"
declare -A RESULT

# ── mode selection ─────────────────────────────────────────────────────────────
TEST_MODE="spine-failure"
for arg in "$@"; do
  case "$arg" in
    --node-failure) TEST_MODE="single-node" ;;
  esac
done

if [ "$TEST_MODE" = "single-node" ]; then
  FAIL_TARGET="${PFX}-node2"
  info "Mode: SINGLE-NODE FAILURE (fail ${FAIL_TARGET})"
  info "Expected: ~28% broken (Maglev off), ~0% (Maglev on)"
else
  FAIL_TARGET="${PFX}-spine1"
  info "Mode: SPINE FAILURE (fail ${FAIL_TARGET})"
  info "Expected: ~0% broken in both cells (spine failure doesn't re-home flows)"
fi

# ── helpers ────────────────────────────────────────────────────────────────────
set_backends() {
  step "scaling echo deployment to ${B} replicas"
  kc -n default scale deploy/echo --replicas="$B" >/dev/null
  kc -n default rollout status deploy/echo --timeout=120s 2>&1 | sed 's/^/  /'
}

set_maglev() {
  local mode="$1"  # on|off
  local vals="cilium-values-maglev.yaml"; [ "$mode" = off ] && vals="cilium-values-nomaglev.yaml"
  wait_cilium_ready 30 || true
  info "switching Maglev ${mode} (helm upgrade ${vals})"
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/${vals}" --reuse-values >/dev/null
  step "helm applied; waiting for rolling restart"
  sleep 5
  local iter=0
  for _ in $(seq 1 60); do
    sleep 2
    iter=$(( iter + 1 ))
    for stuck in $(docker exec "$N1" k3s kubectl -n kube-system get pods \
        -l app.kubernetes.io/name=cilium-agent --no-headers 2>/dev/null \
        | awk '/Terminating/{print $1}'); do
      docker exec "$N1" k3s kubectl -n kube-system delete pod "$stuck" --force --grace-period=0 2>/dev/null || true
      yellow "  force-deleted stuck pod: $stuck"
    done
    cilium_not_ready=$(docker exec "$N1" k3s kubectl -n kube-system get pods \
      -l app.kubernetes.io/name=cilium-agent --no-headers 2>/dev/null \
      | grep -cv '1/1.*Running' || true)
    [ "${cilium_not_ready:-1}" -eq 0 ] && break
    [ $(( iter % 5 )) -eq 0 ] && step "Cilium restart in progress: ${cilium_not_ready} pod(s) not 1/1 (iter ${iter}/60)"
  done
  wait_cilium_ready 60 || yellow "  WARNING: Cilium not fully ready; results may be skewed"
}

set_ch() {
  local mode="$1"
  info "switching ToR consistent hashing ${mode}"
  docker exec "$TOR" bash "/etc/sonic/ch-${mode}.sh" >/dev/null 2>&1 \
    || yellow "  INFO: ToR CH toggle failed (sonic-vs fidelity?) — set EMULATE_CH=1 to script it"
}

restore_spine() {
  step "starting ${FAIL_TARGET}"
  docker start "$FAIL_TARGET" >/dev/null 2>&1 || true
  wait_vip_ecmp 60 || yellow "  WARNING: VIP ECMP not fully reconverged after spine restore"
}

restore_node() {
  step "starting ${FAIL_TARGET}"
  docker start "$FAIL_TARGET" >/dev/null 2>&1 || true
  sleep 0.5
  if ! docker exec "$FAIL_TARGET" ip link show fab0 >/dev/null 2>&1; then
    local node="${FAIL_TARGET#${PFX}-}"
    step "rewiring fabric veths for ${node}"
    bash "${REPO_ROOT}/scripts/rewire-node-veths.sh" "$node" 2>/dev/null || true
    docker exec -d "$FAIL_TARGET" bash /opt/startup.sh 2>/dev/null || true
  fi
  if ! docker exec "$FAIL_TARGET" bash -c 'pgrep -f "k3s agent" >/dev/null 2>&1'; then
    local token; token=$(docker exec "${PFX}-node1" cat /var/lib/rancher/k3s/server/node-token)
    local node_num="${FAIL_TARGET##*node}"
    docker exec "$FAIL_TARGET" bash -c 'rm -rf /run/k3s /var/run/k3s 2>/dev/null; true'
    docker exec -d "$FAIL_TARGET" bash -lc \
      "k3s agent --server https://10.10.0.1:6443 --token ${token} --node-ip 10.10.0.${node_num} \
       --snapshotter=native >/var/log/k3s.log 2>&1"
    yellow "  restarted k3s agent on ${FAIL_TARGET}"
    local elapsed=0
    for _ in $(seq 1 90); do
      kc get node "node${node_num}" --no-headers 2>/dev/null | grep -q ' Ready' && break
      elapsed=$(( elapsed + 3 ))
      [ $(( elapsed % 15 )) -eq 0 ] && step "waiting for node${node_num} Ready... (${elapsed}s)"
      sleep 3
    done
  fi
}

restore_fail_target() {
  if [ "$TEST_MODE" = "spine-failure" ]; then restore_spine; else restore_node; fi
}

run_cell() {
  local ch="$1" mag="$2"
  local tag="${TEST_MODE}_ch-${ch}_maglev-${mag}"
  info "=== cell: CH ${ch} / Maglev ${mag} ==="

  restore_fail_target
  wait_cilium_ready 60 || yellow "  INFO: Cilium not fully ready before run"
  wait_vip_ecmp 60 || yellow "  INFO: VIP ECMP not fully reconverged before run"
  set_ch "$ch"

  step "starting ${N} flows (duration ${DUR}s)"
  docker exec "$CLIENT" rm -f /tmp/${tag}.json /tmp/${tag}.ready 2>/dev/null || true
  docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
      --vip "$VIP" --port "$VIP_PORT" --count "$N" --duration "$DUR" \
      --out "/tmp/${tag}.json" --ready-file "/tmp/${tag}.ready"

  local elapsed=0
  for _ in $(seq 1 30); do
    docker exec "$CLIENT" test -f /tmp/${tag}.ready && break
    sleep 1; elapsed=$(( elapsed + 1 ))
    [ $(( elapsed % 5 )) -eq 0 ] && step "waiting for ${N} flows to establish... (${elapsed}s)"
  done
  step "flows established; sleeping 3s before failure injection"
  sleep 3

  local failtime; failtime=$(date +%s)
  local fail_secs="${SECONDS}"
  info "stopping ${FAIL_TARGET} at t=${fail_secs}s"
  docker stop "$FAIL_TARGET" >/dev/null

  local wait_secs=$(( DUR > 20 ? DUR-15 : 10 ))
  for i in $(seq 1 "$wait_secs"); do
    sleep 1
    [ $(( i % 5 )) -eq 0 ] && step "post-failure wait: ${i}/${wait_secs}s (collecting RSTs)"
  done

  restore_fail_target

  step "collecting results from flowgen"
  for _ in $(seq 1 30); do
    docker exec "$CLIENT" test -s /tmp/${tag}.json && break; sleep 1
  done
  docker cp "${CLIENT}:/tmp/${tag}.json" "${RESULTS_DIR}/${tag}.json" >/dev/null 2>&1 || true
  # inject failtime so visualise.py can draw the failure marker
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

# ── main ───────────────────────────────────────────────────────────────────────
info "Test 3 setup: N=${N} flows, B=${B} backends, duration ${DUR}s, mode=${TEST_MODE}"
info "Note: ToR CH toggle non-functional (FRR ToR, not SONiC) — running CH-off cells only"
set_backends

set_maglev off
run_cell off off
set_maglev on
run_cell off on

echo
if [ "$TEST_MODE" = "spine-failure" ]; then
  green "======== broken-flow results: SPINE FAILURE (CH lever non-functional) ========"
  printf 'Maglev off:  %s\n' "${RESULT[spine-failure_ch-off_maglev-off]:-?}"
  printf 'Maglev on:   %s\n' "${RESULT[spine-failure_ch-off_maglev-on]:-?}"
  echo  "Predicted: ~0% both cells (spine failure doesn't re-home flows to new ingress node)"
else
  green "======== broken-flow results: SINGLE-NODE FAILURE (CH lever non-functional) ========"
  printf 'Maglev off:  %s\n' "${RESULT[single-node_ch-off_maglev-off]:-?}"
  printf 'Maglev on:   %s\n' "${RESULT[single-node_ch-off_maglev-on]:-?}"
  echo  "Predicted: ~28% broken (Maglev off); ~0% (Maglev on)"
fi
echo  "Raw per-flow JSON in ${RESULTS_DIR}/"
green "Runtime: $(fmt_duration)"
