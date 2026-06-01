#!/usr/bin/env bash
# Test 4C-SNAT — SNAT mode (no DSR): Maglev under graceful node drain + fabric failure.
#
# Same failure injection as 04c-node-drain.sh but Cilium runs in standard SNAT
# mode (the production configuration). Same fabric-cut caveat applies — see
# 04d-graceful-drain.sh for the fabric-intact variant.
#
# Drain any worker node (node2/node3), NEVER node1 (k3s control plane).
#
# Env knobs: N (300) DUR (50) RUNS (5) REPLICAS (6) DRAIN_NODE (node3) GRACE (60)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

DRAIN_NODE="${DRAIN_NODE:-node3}"
DRAIN_CTR="${PFX}-${DRAIN_NODE}"
GRACE="${GRACE:-60}"

TEST_NAME="Test 4C-SNAT — SNAT + node drain (fabric cut)"
HELM_NODE="${PFX}-node1"
VALS_OFF="cilium-values-nomaglev.yaml"
VALS_ON="cilium-values-maglev.yaml"
TAG_OFF="snat-node-drain_maglev-off"
TAG_ON="snat-node-drain_maglev-on"
DSR=0
PRED_OFF="~44-56% (full ECMP rehash, no CH on leaves)"
PRED_ON="~0% for backends off the drained node; drained-node backends unreachable"

. lib/failover-lib.sh

inject_failure() {
  info "draining ${DRAIN_NODE} (grace=${GRACE}s) then failing its fabric links"
  kc drain "$DRAIN_NODE" --ignore-daemonsets --delete-emptydir-data \
    --grace-period="${GRACE}" --timeout=10s 2>&1 | sed 's/^/  /' || true
  docker exec "$DRAIN_CTR" ip link set fab0 down
  docker exec "$DRAIN_CTR" ip link set fab1 down
}

restore_failure() {
  step "restoring ${DRAIN_NODE} (uncordon + fabric up)"
  kc uncordon "$DRAIN_NODE" 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab0 up 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab1 up 2>/dev/null || true
}

ensure_healthy() {
  step "ensuring ${DRAIN_NODE} is uncordoned and fabric links are up"
  restore_failure
  docker exec "${PFX}-leaf1" ip link set eth4 up 2>/dev/null || true
  docker exec "${PFX}-leaf2" ip link set eth4 up 2>/dev/null || true
  step "pod placement:"
  kc get pods -o wide --no-headers 2>/dev/null | awk '{printf "  %-40s %s\n", $1, $7}' || true
  step "waiting for VIP ECMP to reconverge (≥2 nexthops at leaf1)"
  wait_vip_ecmp 60 || yellow "  INFO: VIP ECMP not fully reconverged — proceeding anyway"
}

trap failover_cleanup EXIT
failover_main
