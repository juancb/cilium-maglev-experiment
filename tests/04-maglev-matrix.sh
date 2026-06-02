#!/usr/bin/env bash
# Test 4 — Maglev 2x2 matrix (no Cilium restart).
#
# Four LoadBalancer VIPs over the SAME echo backends (k8s/echo-matrix.yaml),
# differing only in per-Service Cilium annotations:
#   192.0.2.11  mag-dsr   maglev + dsr
#   192.0.2.12  rnd-dsr   random + dsr
#   192.0.2.13  mag-snat  maglev + snat
#   192.0.2.14  rnd-snat  random + snat
# All four run concurrently under ONE shared failure (cordon a worker, evict its
# echo pods first so backends are all on survivors, then drop its fabric → flows
# that ingressed it must re-home). Identical fabric/ECMP/failure for every arm.
#
# Hypothesis under test: Maglev only preserves a re-homed flow when the backend
# still recognises it — i.e. with DSR (client IP preserved). In SNAT the new
# ingress node re-SNATs with its own IP, so even the same Maglev backend RSTs.
#   Expect:  mag-dsr ~0%   rnd-dsr high   mag-snat ≈ rnd-snat high
#
# Env knobs: N (300) DUR (50) RUNS (5) REPLICAS (6) DRAIN_NODE (node3)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

N="${N:-300}"; DUR="${DUR:-50}"; RUNS="${RUNS:-5}"; REPLICAS="${REPLICAS:-6}"
DRAIN_NODE="${DRAIN_NODE:-node3}"
DRAIN_CTR="${PFX}-${DRAIN_NODE}"
declare -A RESULT

# arm tag -> VIP
declare -A VIP_OF=(
  [mag-dsr]=192.0.2.11
  [rnd-dsr]=192.0.2.12
  [mag-snat]=192.0.2.13
  [rnd-snat]=192.0.2.14
)
ARMS=(mag-dsr rnd-dsr mag-snat rnd-snat)

cleanup() {
  info "cleanup: uncordon ${DRAIN_NODE}, fabric up"
  kc uncordon "$DRAIN_NODE" >/dev/null 2>&1 || true
  docker exec "$DRAIN_CTR" ip link set fab0 up 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab1 up 2>/dev/null || true
}
trap cleanup EXIT

wait_vip() {  # vip, secs
  local vip="$1" secs="${2:-60}"
  for _ in $(seq 1 "$secs"); do
    [ "$(docker exec "${LEAVES[0]}" vtysh -c "show ip route ${vip}/32" 2>/dev/null | grep -cE '^\s+\* 10\.')" -ge 2 ] && return 0
    sleep 1
  done
  return 1
}

clear_backends_off_drain_node() {
  step "cordon ${DRAIN_NODE}, evict echo pods off it (backends land on survivors)"
  kc cordon "$DRAIN_NODE" >/dev/null 2>&1 || true
  for p in $(kc -n default get pods -l app=echo -o wide --no-headers 2>/dev/null \
             | awk -v n="$DRAIN_NODE" '$7==n {print $1}'); do
    kc -n default delete pod "$p" --wait=false >/dev/null 2>&1 || true
  done
  for _ in $(seq 1 60); do
    [ "$(kc -n default get pods -l app=echo -o wide --no-headers 2>/dev/null | awk -v n="$DRAIN_NODE" '$7==n' | grep -c .)" -eq 0 ] \
      && { kc -n default rollout status deploy/echo --timeout=60s >/dev/null 2>&1 || true; return 0; }
    sleep 2
  done
  yellow "  WARNING: echo pods still on ${DRAIN_NODE}"
}

ensure_healthy() {
  step "uncordon ${DRAIN_NODE}, fabric up, wait all VIPs ECMP"
  kc uncordon "$DRAIN_NODE" >/dev/null 2>&1 || true
  docker exec "$DRAIN_CTR" ip link set fab0 up 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab1 up 2>/dev/null || true
  for a in "${ARMS[@]}"; do wait_vip "${VIP_OF[$a]}" 60 || yellow "  INFO: ${VIP_OF[$a]} not fully ECMP"; done
  clear_backends_off_drain_node
}

collect() {  # rtag, failtime
  for _ in $(seq 1 30); do docker exec "$CLIENT" test -s /tmp/${1}.json && break; sleep 1; done
  docker cp "${CLIENT}:/tmp/${1}.json" "${RESULTS_DIR}/${1}.json" >/dev/null 2>&1 || true
  if command -v jq >/dev/null 2>&1 && [ -s "${RESULTS_DIR}/${1}.json" ]; then
    local tmp; tmp=$(mktemp)
    jq --argjson ft "$2" '.summary.failtime = $ft' "${RESULTS_DIR}/${1}.json" > "$tmp" && mv "$tmp" "${RESULTS_DIR}/${1}.json" || rm -f "$tmp"
  fi
}

run_matrix() {
  local run="$1"
  step "=== run ${run}/${RUNS} ==="
  ensure_healthy

  step "starting ${N} flows on each of the 4 arms"
  for a in "${ARMS[@]}"; do
    local rtag="paired-${a}.run${run}"
    docker exec "$CLIENT" rm -f /tmp/${rtag}.json /tmp/${rtag}.ready 2>/dev/null || true
    docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
      --vip "${VIP_OF[$a]}" --port "$VIP_PORT" --count "$N" --duration "$DUR" \
      --src 203.0.113.1 --out "/tmp/${rtag}.json" --ready-file "/tmp/${rtag}.ready"
  done

  local elapsed=0
  for _ in $(seq 1 40); do
    local ready=1
    for a in "${ARMS[@]}"; do docker exec "$CLIENT" test -f /tmp/paired-${a}.run${run}.ready || ready=0; done
    [ "$ready" -eq 1 ] && break
    sleep 1; elapsed=$((elapsed+1)); [ $((elapsed%5)) -eq 0 ] && step "waiting for all arms to establish... (${elapsed}s)"
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

  for a in "${ARMS[@]}"; do collect "paired-${a}.run${run}" "$failtime"; done
}

info "Test 4 (2x2 matrix): N=${N} DUR=${DUR}s RUNS=${RUNS} REPLICAS=${REPLICAS} drain=${DRAIN_NODE}"
step "applying matrix services (.11 mag-dsr / .12 rnd-dsr / .13 mag-snat / .14 rnd-snat)"
kc apply -f /opt/k8s/echo-matrix.yaml >/dev/null 2>&1 || true
kc -n default scale deploy/echo --replicas="${REPLICAS}" >/dev/null 2>&1 || true
kc -n default rollout status deploy/echo --timeout=120s 2>&1 | sed 's/^/  /'

for a in "${ARMS[@]}"; do rm -f "${RESULTS_DIR}/paired-${a}.run"*.json 2>/dev/null || true; done

for run in $(seq 1 "$RUNS"); do run_matrix "$run"; done

echo
green "================ Test 4: Maglev 2x2 (mean ± stddev broken%, over ${RUNS} runs) ================"
for a in "${ARMS[@]}"; do
  agg=$(python3 "${REPO_ROOT}/scripts/aggregate-runs.py" "${RESULTS_DIR}" "paired-${a}" 2>&1) || true
  RESULT["$a"]="${agg##*: }"
done
printf '  %-22s %-22s\n' "" "broken% (mean ± stddev)"
printf '  %-22s %s\n' "DSR  + maglev:" "${RESULT[mag-dsr]:-?}"
printf '  %-22s %s\n' "DSR  + random:" "${RESULT[rnd-dsr]:-?}"
printf '  %-22s %s\n' "SNAT + maglev:" "${RESULT[mag-snat]:-?}"
printf '  %-22s %s\n' "SNAT + random:" "${RESULT[rnd-snat]:-?}"
echo
echo "Same backends, same failure, same instant — only the per-Service annotation differs."
echo "If DSR+maglev ≈ 0 while SNAT+maglev ≈ SNAT+random (high), Maglev needs DSR to"
echo "preserve a re-homed flow (SNAT re-source breaks it regardless of backend choice)."
green "Runtime: $(fmt_duration)"
