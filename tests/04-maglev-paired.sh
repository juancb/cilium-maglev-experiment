#!/usr/bin/env bash
# Test 4 — Maglev paired comparison (no Cilium restart).
#
# Two LoadBalancer VIPs over the SAME echo backends (k8s/echo-paired.yaml):
#   192.0.2.11  echo-mag  — service.cilium.io/lb-algorithm=maglev
#   192.0.2.12  echo-rnd  — service.cilium.io/lb-algorithm=random
# Switching the algorithm is a per-Service annotation (bpf.lbAlgorithmAnnotation),
# so BOTH run simultaneously over the identical fabric/ECMP state — no rollout
# restart, no convergence artifact, no run-to-run variance between the two arms.
#
# Failure (the validated clean re-homing trigger from earlier work): cordon a
# worker node and evict echo pods OFF it FIRST so every backend lives on a
# surviving node, then drop that node's fabric links. Flows that ingressed the
# drained node must re-home to another node — with backends guaranteed alive, the
# ONLY variable is whether the new ingress picks the same backend (Maglev) or not.
#
# Expectation: echo-mag ~0% broken, echo-rnd materially higher.
#
# Env knobs: N (300) DUR (50) RUNS (5) REPLICAS (6) DRAIN_NODE (node3)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

N="${N:-300}"; DUR="${DUR:-50}"; RUNS="${RUNS:-5}"; REPLICAS="${REPLICAS:-6}"
DRAIN_NODE="${DRAIN_NODE:-node3}"
DRAIN_CTR="${PFX}-${DRAIN_NODE}"
MAG_VIP="192.0.2.11"; RND_VIP="192.0.2.12"
declare -A RESULT

cleanup() {
  info "cleanup: uncordon ${DRAIN_NODE}, fabric up"
  kc uncordon "$DRAIN_NODE" >/dev/null 2>&1 || true
  docker exec "$DRAIN_CTR" ip link set fab0 up 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab1 up 2>/dev/null || true
}
trap cleanup EXIT

# wait until $1 (a VIP /32) has >=2 ECMP nexthops at leaf1
wait_vip() {
  local vip="$1" secs="${2:-60}"
  for _ in $(seq 1 "$secs"); do
    local n
    n=$(frr "${LEAVES[0]}" "show ip route ${vip}/32" 2>/dev/null | grep -cE '^\s+\* 10\.' || true)
    [ "${n:-0}" -ge 2 ] && return 0
    sleep 1
  done
  return 1
}

clear_backends_off_drain_node() {
  step "cordon ${DRAIN_NODE} and evict echo pods off it (backends land on survivors)"
  kc cordon "$DRAIN_NODE" >/dev/null 2>&1 || true
  for p in $(kc -n default get pods -l app=echo -o wide --no-headers 2>/dev/null \
             | awk -v n="$DRAIN_NODE" '$7==n {print $1}'); do
    kc -n default delete pod "$p" --wait=false >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 60); do
    local left
    left=$(kc -n default get pods -l app=echo -o wide --no-headers 2>/dev/null \
           | awk -v n="$DRAIN_NODE" '$7==n' | grep -c . || true)
    [ "${left:-0}" -eq 0 ] && { kc -n default rollout status deploy/echo --timeout=60s >/dev/null 2>&1 || true; return 0; }
    sleep 2
  done
  yellow "  WARNING: echo pods still on ${DRAIN_NODE}"
}

ensure_healthy() {
  step "uncordon ${DRAIN_NODE}, bring fabric up, wait both VIPs ECMP"
  kc uncordon "$DRAIN_NODE" >/dev/null 2>&1 || true
  docker exec "$DRAIN_CTR" ip link set fab0 up 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab1 up 2>/dev/null || true
  wait_vip "$MAG_VIP" 60 || yellow "  INFO: ${MAG_VIP} not fully ECMP"
  wait_vip "$RND_VIP" 60 || yellow "  INFO: ${RND_VIP} not fully ECMP"
  clear_backends_off_drain_node
}

start_flow() {  # vip, rtag
  docker exec "$CLIENT" rm -f /tmp/${2}.json /tmp/${2}.ready 2>/dev/null || true
  docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
    --vip "$1" --port "$VIP_PORT" --count "$N" --duration "$DUR" \
    --src 203.0.113.1 --out "/tmp/${2}.json" --ready-file "/tmp/${2}.ready"
}

collect() {  # rtag, failtime
  for _ in $(seq 1 30); do docker exec "$CLIENT" test -s /tmp/${1}.json && break; sleep 1; done
  docker cp "${CLIENT}:/tmp/${1}.json" "${RESULTS_DIR}/${1}.json" >/dev/null 2>&1 || true
  if command -v jq >/dev/null 2>&1 && [ -s "${RESULTS_DIR}/${1}.json" ]; then
    local tmp; tmp=$(mktemp)
    jq --argjson ft "$2" '.summary.failtime = $ft' "${RESULTS_DIR}/${1}.json" > "$tmp" \
      && mv "$tmp" "${RESULTS_DIR}/${1}.json" || rm -f "$tmp"
  fi
}

run_pair() {
  local run="$1" mtag="paired-maglev.run$1" rtag="paired-random.run$1"
  step "=== run ${run}/${RUNS} ==="
  ensure_healthy

  step "starting ${N} flows to each VIP (maglev ${MAG_VIP}, random ${RND_VIP})"
  start_flow "$MAG_VIP" "$mtag"
  start_flow "$RND_VIP" "$rtag"
  local elapsed=0
  for _ in $(seq 1 40); do
    if docker exec "$CLIENT" test -f /tmp/${mtag}.ready && docker exec "$CLIENT" test -f /tmp/${rtag}.ready; then break; fi
    sleep 1; elapsed=$((elapsed+1))
    [ $((elapsed % 5)) -eq 0 ] && step "waiting for both flow sets to establish... (${elapsed}s)"
  done
  step "established; 3s then drop ${DRAIN_NODE} fabric (single shared failure)"
  sleep 3

  local failtime; failtime=$(date +%s)
  docker exec "$DRAIN_CTR" ip link set fab0 down
  docker exec "$DRAIN_CTR" ip link set fab1 down

  local wait_secs=$(( DUR > 20 ? DUR-15 : 10 ))
  for i in $(seq 1 "$wait_secs"); do sleep 1; [ $((i%5)) -eq 0 ] && step "post-failure: ${i}/${wait_secs}s"; done

  step "restore ${DRAIN_NODE} fabric"
  docker exec "$DRAIN_CTR" ip link set fab0 up; docker exec "$DRAIN_CTR" ip link set fab1 up

  collect "$mtag" "$failtime"
  collect "$rtag" "$failtime"
}

info "Test 4 (paired): N=${N} DUR=${DUR}s RUNS=${RUNS} REPLICAS=${REPLICAS} drain=${DRAIN_NODE}"
step "applying paired services (echo-mag ${MAG_VIP} / echo-rnd ${RND_VIP})"
kc apply -f /opt/k8s/echo-paired.yaml >/dev/null 2>&1 || kc apply -f - < ../k8s/echo-paired.yaml >/dev/null 2>&1 || true
kc -n default scale deploy/echo --replicas="${REPLICAS}" >/dev/null 2>&1 || true
kc -n default rollout status deploy/echo --timeout=120s 2>&1 | sed 's/^/  /'

# clear stale per-run files so the aggregate reflects only this invocation
rm -f "${RESULTS_DIR}/paired-maglev.run"*.json "${RESULTS_DIR}/paired-random.run"*.json 2>/dev/null || true

for run in $(seq 1 "$RUNS"); do run_pair "$run"; done

echo
green "================ Test 4: Maglev paired (mean ± stddev over ${RUNS} runs) ================"
for tag in paired-maglev paired-random; do
  agg=$(python3 "${REPO_ROOT}/scripts/aggregate-runs.py" "${RESULTS_DIR}" "${tag}" 2>&1) || true
  RESULT["$tag"]="${agg##*: }"
  printf '  %-16s %s\n' "$tag:" "${RESULT[$tag]}"
done
echo
echo "Same backends, same failure, same instant — only the LB algorithm differs."
echo "Expect maglev ≈ 0% broken; random materially higher."
green "Runtime: $(fmt_duration)"
