#!/usr/bin/env bash
# Test 4B-SNAT — SNAT mode (no DSR): Maglev observable via leaf switch failure.
#
# Same failure injection as 04b-leaf-failure.sh but Cilium runs in standard SNAT
# mode (the production configuration). Backend pods see the ingress-node IP.
#
# Env knobs: N (300)  DUR (50)  RUNS (5)  REPLICAS (6)  FAIL_LEAF (…-leaf1)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

FAIL_LEAF="${FAIL_LEAF:-${PFX}-leaf1}"

TEST_NAME="Test 4B-SNAT — SNAT + leaf failure"
HELM_NODE="${PFX}-node1"
VALS_OFF="cilium-values-nomaglev.yaml"
VALS_ON="cilium-values-maglev.yaml"
TAG_OFF="snat-leaf-failure_maglev-off"
TAG_ON="snat-leaf-failure_maglev-on"
DSR=0
PRED_OFF="~22% (1/3 re-home × wrong backend)"
PRED_ON="~0%  (Maglev selects same backend)"

. lib/failover-lib.sh

inject_failure() {
  info "failing ${FAIL_LEAF} (all peering interfaces down)"
  docker exec "$FAIL_LEAF" bash -c \
    "for i in \$(ip link show | awk -F': ' '/^[0-9]/{print \$2}' | grep -vE '^(lo)$' | cut -d@ -f1); do
       ip link set \$i down 2>/dev/null || true; done"
}

restore_failure() {
  step "restoring ${FAIL_LEAF} (peering interfaces up)"
  docker exec "$FAIL_LEAF" bash -c \
    "for i in \$(ip link show | awk -F': ' '/^[0-9]/{print \$2}' | grep -vE '^(lo)$' | cut -d@ -f1); do
       ip link set \$i up 2>/dev/null || true; done"
}

ensure_healthy() {
  restore_failure
  step "waiting for VIP ECMP to reconverge (≥2 nexthops at leaf1)"
  wait_vip_ecmp 60 || yellow "  INFO: VIP ECMP not fully reconverged — proceeding anyway"
}

trap failover_cleanup EXIT
failover_main
