#!/usr/bin/env bash
# Test 4B — DSR mode: Maglev observable via leaf switch failure (ToR ECMP re-hash).
#
# Failure injection: take down all peering links on FAIL_LEAF → ToR loses 1 of 3
# ECMP paths → ~1/3 of flows re-home to a different ingress node. All backend pods
# remain alive throughout. This is the clean signal for Maglev consistency.
#
#   Maglev off: new ingress picks random backend → different pod → no TCP state → RST (~28%)
#   Maglev on:  new ingress picks SAME backend (same 5-tuple hash) → pod has state → survives (~0%)
#
# NOTE: we never fail node interfaces or kill nodes in this test. See 04c-dsr.sh for
# the node-drain variant.
#
# Env knobs: N=<flows> (default 300)   DUR=<sec> (default 50)
#            FAIL_LEAF=<container>     (default clab-maglev-clos-leaf1)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

N="${N:-300}"; DUR="${DUR:-50}"
N1="${PFX}-node1"
FAIL_LEAF="${FAIL_LEAF:-${PFX}-leaf1}"
HELM_VALUES_DIR="/opt/k8s"
declare -A RESULT

set_cilium_values() {
  local vals="$1"
  info "applying ${vals} (helm upgrade + rollout restart)"
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/${vals}" --reset-values \
      --set loadBalancer.dsrDispatch=opt >/dev/null
  step "triggering rolling restart of cilium DaemonSet"
  docker exec "$N1" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null
  step "waiting for rollout to complete"
  docker exec "$N1" k3s kubectl -n kube-system rollout status ds/cilium --timeout=300s 2>&1 | sed 's/^/  /'
  sleep 5
}

cleanup() {
  info "Restoring leaf and Cilium values..."
  docker exec "$FAIL_LEAF" bash -c \
    "for i in \$(ip link show | awk -F': ' '/^[0-9]/{print \$2}' | grep -vE '^(lo|eth0)$'); do
       ip link set \$i up 2>/dev/null || true; done" 2>/dev/null || true
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/cilium-values-maglev.yaml" --reset-values >/dev/null 2>&1 || true
  docker exec "$N1" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null 2>&1 || true
  docker exec "$N1" k3s kubectl -n kube-system rollout status ds/cilium --timeout=300s 2>&1 | sed 's/^/  /' || true
}
trap cleanup EXIT

probe_srcip() {
  info "Probing source IP seen by backend pod (DSR sanity check)..."
  PROBE_PY="
import socket, sys
s = socket.socket()
s.settimeout(10)
try:
    s.connect(('${VIP}', ${VIP_PORT}))
    data = b''
    while data.count(b'\\n') < 2:
        chunk = s.recv(256)
        if not chunk: break
        data += chunk
    sys.stdout.write(data.decode('utf-8', 'replace'))
except Exception as e:
    sys.stderr.write('probe failed: %s\\n' % e)
finally:
    s.close()
"
  RESP=$(echo "$PROBE_PY" | docker exec -i "${CLIENT}" python3 2>/dev/null || true)
  SRCIP_LINE=$(echo "$RESP" | grep '^SRCIP=' | head -1 | tr -d '\r')
  if [ -n "$SRCIP_LINE" ]; then
    SRCIP=$(echo "$SRCIP_LINE" | cut -d= -f2)
    if echo "$SRCIP" | grep -qE '^203\.0\.113\.'; then
      green "  DSR confirmed: pod sees ${SRCIP} (original client IP)"
    else
      yellow "  WARNING: pod sees ${SRCIP} — DSR may not be active (SNAT masking source)"
    fi
  else
    yellow "  (SRCIP not in response)"
  fi
}

fail_leaf() {
  info "failing ${FAIL_LEAF} (all peering interfaces down)"
  docker exec "$FAIL_LEAF" bash -c \
    "for i in \$(ip link show | awk -F': ' '/^[0-9]/{print \$2}' | grep -vE '^(lo)$' | cut -d@ -f1); do
       ip link set \$i down 2>/dev/null || true; done"
}

restore_leaf() {
  step "restoring ${FAIL_LEAF} (peering interfaces up)"
  docker exec "$FAIL_LEAF" bash -c \
    "for i in \$(ip link show | awk -F': ' '/^[0-9]/{print \$2}' | grep -vE '^(lo)$' | cut -d@ -f1); do
       ip link set \$i up 2>/dev/null || true; done"
}

ensure_leaf_up() {
  restore_leaf
  step "waiting for VIP ECMP to reconverge (≥2 nexthops at leaf1)"
  wait_vip_ecmp 60 || yellow "  INFO: VIP ECMP not fully reconverged — proceeding anyway"
}

run_cell() {
  local tag="$1"
  info "=== cell: ${tag} ==="

  ensure_leaf_up

  step "starting ${N} flows (duration ${DUR}s)"
  docker exec "$CLIENT" rm -f /tmp/${tag}.json /tmp/${tag}.ready 2>/dev/null || true
  docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
      --vip "$VIP" --port "$VIP_PORT" --count "$N" --duration "$DUR" \
      --src 203.0.113.1 \
      --out "/tmp/${tag}.json" --ready-file "/tmp/${tag}.ready"

  local elapsed=0
  for _ in $(seq 1 30); do
    docker exec "$CLIENT" test -f /tmp/${tag}.ready && break
    sleep 1; elapsed=$(( elapsed + 1 ))
    [ $(( elapsed % 5 )) -eq 0 ] && step "waiting for flows to establish... (${elapsed}s)"
  done
  step "flows established; sleeping 3s before failure injection"
  sleep 3

  local failtime; failtime=$(date +%s)
  fail_leaf

  local wait_secs=$(( DUR > 20 ? DUR-15 : 10 ))
  for i in $(seq 1 "$wait_secs"); do
    sleep 1
    [ $(( i % 5 )) -eq 0 ] && step "post-failure wait: ${i}/${wait_secs}s (collecting RSTs)"
  done

  restore_leaf

  step "collecting results from flowgen"
  for _ in $(seq 1 30); do
    docker exec "$CLIENT" test -s /tmp/${tag}.json && break; sleep 1
  done
  docker cp "${CLIENT}:/tmp/${tag}.json" "${RESULTS_DIR}/${tag}.json" >/dev/null 2>&1 || true
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

info "Test 4B setup: N=${N} flows, DUR=${DUR}s, leaf failure=${FAIL_LEAF}, 6 replicas"
step "scaling echo to 6 replicas"
kc -n default scale deploy/echo --replicas=6 >/dev/null 2>&1 || true
kc -n default rollout status deploy/echo --timeout=120s 2>&1 | sed 's/^/  /'

info "--- DSR + Maglev OFF ---"
set_cilium_values "cilium-values-dsr-nomaglev.yaml"
probe_srcip
run_cell "tor-failure-dsr_maglev-off"

info "--- DSR + Maglev ON ---"
set_cilium_values "cilium-values-dsr-maglev.yaml"
probe_srcip
run_cell "tor-failure-dsr_maglev-on"

echo
green "================ Test 4B: DSR + leaf Failure results =================="
printf '%-40s %s\n' "DSR + Maglev off:" "${RESULT[tor-failure-dsr_maglev-off]:-?}"
printf '%-40s %s\n' "DSR + Maglev on: " "${RESULT[tor-failure-dsr_maglev-on]:-?}"
echo
echo "Predicted (M=3 nodes, B=3 backends, 1 leaf of 3 fails → ~1/3 re-home):"
echo "  DSR + Maglev off: ~22%  (1/3 re-home × 2/3 wrong backend)"
echo "  DSR + Maglev on:  ~0%   (Maglev selects same backend; pod has state)"
echo
echo "Raw JSON: ${RESULTS_DIR}/"
green "Runtime: $(fmt_duration)"
