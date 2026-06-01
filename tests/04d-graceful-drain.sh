#!/usr/bin/env bash
# Test 4D — DSR mode: PURE re-homing under graceful drain (no backend loss).
#
# This isolates the Maglev re-homing effect from the "backend died" confound that
# muddies 04c. The trick: before starting flows we cordon DRAIN_NODE and evict all
# echo pods OFF it, so every backend lives on a *surviving* node. DRAIN_NODE stays
# in the fabric as a pure ingress/LB node. Then mid-flow we drop its fabric links.
#
#   - Flows that ingressed via DRAIN_NODE must re-home to a surviving node.
#   - No backend ever lived on DRAIN_NODE, so re-homed flows always find their
#     backend alive. The ONLY variable is whether the new ingress picks the same
#     backend → exactly the Maglev property, with zero unreachable-backend noise.
#
#   Maglev off: re-homed flow → random backend → RST
#   Maglev on:  re-homed flow → same backend (alive) → survives → ~0%
#
# Drain any worker node (node2/node3), NEVER node1 (k3s control plane).
#
# Env knobs: N (300) DUR (50) RUNS (5) REPLICAS (6) DRAIN_NODE (node3)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

DRAIN_NODE="${DRAIN_NODE:-node3}"
DRAIN_CTR="${PFX}-${DRAIN_NODE}"

TEST_NAME="Test 4D — DSR + pure re-homing (graceful drain, backends safe)"
HELM_NODE="${PFX}-node1"
VALS_OFF="cilium-values-dsr-nomaglev.yaml"
VALS_ON="cilium-values-dsr-maglev.yaml"
TAG_OFF="graceful-drain_maglev-off"
TAG_ON="graceful-drain_maglev-on"
DSR=1
PRED_OFF="~33-50% (re-homed flows pick random backend; all backends alive)"
PRED_ON="~0% (Maglev picks same backend; no backend ever on the drained node)"

. lib/failover-lib.sh

# Cordon the drain node and evict every echo pod off it, so no backend lives there.
clear_backends_off_drain_node() {
  step "cordoning ${DRAIN_NODE} and evicting echo pods off it (keep it in the fabric)"
  kc cordon "$DRAIN_NODE" >/dev/null 2>&1 || true
  local on_node
  on_node=$(kc -n default get pods -l app=echo -o wide --no-headers 2>/dev/null \
            | awk -v n="$DRAIN_NODE" '$7==n {print $1}')
  for p in $on_node; do
    kc -n default delete pod "$p" --wait=false >/dev/null 2>&1 || true
  done
  # wait until 0 echo pods remain on DRAIN_NODE and the deployment is fully Ready
  for _ in $(seq 1 60); do
    local remaining
    remaining=$(kc -n default get pods -l app=echo -o wide --no-headers 2>/dev/null \
                | awk -v n="$DRAIN_NODE" '$7==n' | grep -c . || true)
    if [ "${remaining:-0}" -eq 0 ]; then
      kc -n default rollout status deploy/echo --timeout=60s >/dev/null 2>&1 || true
      step "no echo pods on ${DRAIN_NODE}; backends are all on surviving nodes"
      return 0
    fi
    sleep 2
  done
  yellow "  WARNING: echo pods still present on ${DRAIN_NODE} — re-homing may hit a dead backend"
}

inject_failure() {
  info "dropping ${DRAIN_NODE} fabric links → flows re-home (backends untouched)"
  docker exec "$DRAIN_CTR" ip link set fab0 down
  docker exec "$DRAIN_CTR" ip link set fab1 down
}

restore_failure() {
  step "restoring ${DRAIN_NODE} (fabric up; left cordoned until cleanup)"
  docker exec "$DRAIN_CTR" ip link set fab0 up 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab1 up 2>/dev/null || true
}

ensure_healthy() {
  step "ensuring ${DRAIN_NODE} fabric links are up"
  restore_failure
  docker exec "${PFX}-leaf1" ip link set eth4 up 2>/dev/null || true
  docker exec "${PFX}-leaf2" ip link set eth4 up 2>/dev/null || true
  clear_backends_off_drain_node
  step "pod placement:"
  kc get pods -l app=echo -o wide --no-headers 2>/dev/null | awk '{printf "  %-40s %s\n", $1, $7}' || true
  step "waiting for VIP ECMP to reconverge (≥2 nexthops at leaf1)"
  wait_vip_ecmp 60 || yellow "  INFO: VIP ECMP not fully reconverged — proceeding anyway"
}

# uncordon on cleanup (failover_cleanup calls restore_failure + reverts helm)
graceful_cleanup() {
  failover_cleanup
  kc uncordon "$DRAIN_NODE" 2>/dev/null || true
}

trap graceful_cleanup EXIT
failover_main
