#!/usr/bin/env bash
# diag-smoke.sh — smoke test with real-time diagnostics during the node2 stop window.
#
# Answers the two remaining questions about why 0% flows broke:
#   Q1: Does leaf1 actually remove node2 from ECMP after docker stop?
#   Q2: Do node1/node3 gain Cilium CT entries for re-homed flows?
#
# Run after flowgen-selftest.sh confirms flowgen itself works.

set -euo pipefail
cd /mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment/tests
. lib/common.sh

N=20; DUR=40
N1="${PFX}-node1"; N3="${PFX}-node3"
TAG="diag_smoke"

KC() { docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" k3s kubectl "$@"; }

restore_fail_node() {
  docker start "$FAIL_SPINE" >/dev/null 2>&1 || true
  sleep 0.5
  if ! docker exec "$FAIL_SPINE" ip link show fab0 >/dev/null 2>&1; then
    local node="${FAIL_SPINE#${PFX}-}"
    bash "${REPO_ROOT}/scripts/rewire-node-veths.sh" "$node" 2>/dev/null || true
    docker exec -d "$FAIL_SPINE" bash /opt/startup.sh 2>/dev/null || true
  fi
}

# snapshot the leaf1 VIP ECMP route
show_ecmp() {
  local label="$1"
  printf '\n[ECMP @ %s (%s)]\n' "$label" "$(date +%T)"
  docker exec "${LEAVES[0]}" vtysh -c "show ip route ${VIP}/32" 2>/dev/null \
    | grep -E '^\s+\*|^Routing' | head -6 || echo "  (no route)"
}

# count Cilium CT entries on a node that match the client src IP
show_ct() {
  local node="$1" label="$2"
  printf '[CT on %-6s @ %s] ' "$label" "$(date +%T)"
  # cilium bpf ct list is large; grep for the client prefix
  docker exec "$node" cilium bpf ct list global 2>/dev/null \
    | grep -c "203.0.113" 2>/dev/null || echo "0"
}

info "=== diag smoke: N=${N} DUR=${DUR}s ==="
restore_fail_node
wait_vip_ecmp 30 || { yellow "VIP ECMP not ready"; exit 1; }

show_ecmp "before-start"

# start flows
docker exec "$CLIENT" rm -f /tmp/${TAG}.json /tmp/${TAG}.ready 2>/dev/null || true
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
    --vip "$VIP" --port "$VIP_PORT" --count "$N" --duration "$DUR" \
    --out "/tmp/${TAG}.json" --ready-file "/tmp/${TAG}.ready"

for _ in $(seq 1 30); do
  docker exec "$CLIENT" test -f /tmp/${TAG}.ready 2>/dev/null && break; sleep 1
done
info "flows established"

show_ecmp "after-establish"
show_ct "$N1" "node1"
show_ct "$N3" "node3"

sleep 3

# fail node2
info "=== stopping node2 ==="
docker stop "$FAIL_SPINE" >/dev/null
FAILTIME=$(date +%s)

# observe immediately after stop
show_ecmp "1s-after-stop"
show_ct "$N1" "node1"
show_ct "$N3" "node3"

sleep 5
show_ecmp "6s-after-stop"
show_ct "$N1" "node1"
show_ct "$N3" "node3"

sleep 10

# restore
info "=== restoring node2 ==="
restore_fail_node

# wait for flowgen to finish
for _ in $(seq 1 "${DUR}"); do
  docker exec "$CLIENT" test -s /tmp/${TAG}.json 2>/dev/null && break; sleep 1
done
docker cp "${CLIENT}:/tmp/${TAG}.json" "${RESULTS_DIR}/${TAG}.json" 2>/dev/null || true

show_ecmp "after-restore"

# report
if command -v jq >/dev/null 2>&1 && [ -s "${RESULTS_DIR}/${TAG}.json" ]; then
  BROKEN=$(jq --argjson t "$FAILTIME" \
    '[.flows[] | select(.status=="broken" and .established_at!=null and (.broke_at//0) >= $t)] | length' \
    "${RESULTS_DIR}/${TAG}.json")
  EST=$(jq '.summary.established' "${RESULTS_DIR}/${TAG}.json")
  PCT=$(awk "BEGIN{printf \"%.0f\", 100*${BROKEN}/${EST:-1}}")
  green "DIAG RESULT: ${BROKEN} broken of ${EST} (${PCT}%)"
  green "  (expected ~33% if flowing normally, 0% if ECMP never changes or flows were cached)"
  jq '.summary' "${RESULTS_DIR}/${TAG}.json"
fi
