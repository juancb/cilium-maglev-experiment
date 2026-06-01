#!/usr/bin/env bash
# Test 4C — DSR mode: Maglev observable via graceful node drain (maintenance reboot model).
#
# Failure injection: kubectl drain <node> then immediately take down its fabric links.
# Pods have a 30s termination grace period (>> flowgen's 5s socket timeout), so they
# are still alive and reachable on other nodes during the ECMP re-hash window.
#
# Why this is a valid Maglev test:
#   - Drain marks the node unschedulable and starts graceful pod eviction
#   - Fabric failure causes ECMP re-hash: flows re-home to remaining ingress nodes
#   - Maglev on remaining nodes selects the SAME backend (same 5-tuple hash)
#   - That backend is still alive (within the 30s grace window, or was never on the drained node)
#   - Maglev off: random backend → likely different pod → no TCP state → RST
#
# NOTE: Only pods NOT on the drained node are guaranteed reachable after fabric failure.
# Pods ON the drained node become unreachable (fabric is down). The test is cleanest
# when few/no pods are scheduled on the drain node — run 'kubectl get pods -o wide'
# before this test to check placement.
#
# Env knobs: N=<flows> (default 300)   DUR=<sec> (default 50)
#            DRAIN_NODE=<k8s-node-name>  (default node3 — change if node3 has many pods)
#            GRACE=<seconds>             (default 60 — pod termination grace period)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

N="${N:-300}"; DUR="${DUR:-50}"
DRAIN_NODE="${DRAIN_NODE:-node3}"          # k8s node name (not container name)
DRAIN_CTR="${PFX}-$DRAIN_NODE"             
MASTER="${PFX}-node1"                      # master node
GRACE="${GRACE:-60}"                       # termination grace period (must be >> flowgen timeout)
HELM_VALUES_DIR="/opt/k8s"
declare -A RESULT

set_cilium_values() {
  local vals="$1"
  info "applying ${vals} (helm upgrade + rollout restart)"
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$MASTER" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/${vals}" --reset-values \
      --set loadBalancer.dsrDispatch=opt >/dev/null
  step "triggering rolling restart of cilium DaemonSet"
  docker exec "$MASTER" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null
  step "waiting for rollout to complete"
  docker exec "$MASTER" k3s kubectl -n kube-system rollout status ds/cilium --timeout=180s 2>&1 | sed 's/^/  /'
  sleep 5
}

cleanup() {
  info "Restoring drain node and Cilium values..."
  docker exec "$DRAIN_CTR" ip link set fab0 up 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab1 up 2>/dev/null || true
  kc uncordon "$DRAIN_NODE" 2>/dev/null || true
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$MASTER" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/cilium-values-maglev.yaml" --reset-values >/dev/null 2>&1 || true
  docker exec "$MASTER" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null 2>&1 || true
  docker exec "$MASTER" k3s kubectl -n kube-system rollout status ds/cilium --timeout=120s 2>&1 | sed 's/^/  /' || true
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

ensure_node_up() {
  step "ensuring ${DRAIN_NODE} is uncordoned and fabric links are up"
  kc uncordon "$DRAIN_NODE" 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab0 up 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab1 up 2>/dev/null || true
  # Also bring up the leaf-side interfaces in case a prior run left them down
  docker exec "${PFX}-leaf1" ip link set eth4 up 2>/dev/null || true
  docker exec "${PFX}-leaf2" ip link set eth4 up 2>/dev/null || true
  step "waiting for VIP ECMP to reconverge (≥2 nexthops at leaf1)"
  wait_vip_ecmp 60 || yellow "  INFO: VIP ECMP not fully reconverged — proceeding anyway"
}

run_cell() {
  local tag="$1"
  info "=== cell: ${tag} ==="

  ensure_node_up

  # Show pod placement so the user can sanity-check
  step "pod placement before drain:"
  kc get pods -o wide --no-headers 2>/dev/null | awk '{printf "  %-40s %s\n", $1, $7}' || true

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
  step "flows established; sleeping 3s before drain + fabric failure"
  sleep 3

  local failtime; failtime=$(date +%s)

  # Drain first (starts graceful pod eviction, GRACE-second window)
  info "draining ${DRAIN_NODE} (grace-period=${GRACE}s) and failing its fabric links"
  kc drain "$DRAIN_NODE" \
    --ignore-daemonsets \
    --delete-emptydir-data \
    --grace-period="${GRACE}" \
    --timeout=10s \
    2>&1 | sed 's/^/  /' || true   # best-effort; don't abort if drain times out

  # Immediately fail fabric (forces ECMP re-hash to remaining nodes)
  docker exec "$DRAIN_CTR" ip link set fab0 down
  docker exec "$DRAIN_CTR" ip link set fab1 down

  local wait_secs=$(( DUR > 20 ? DUR-15 : 10 ))
  for i in $(seq 1 "$wait_secs"); do
    sleep 1
    [ $(( i % 5 )) -eq 0 ] && step "post-failure wait: ${i}/${wait_secs}s"
  done

  step "restoring ${DRAIN_NODE} (uncordon + fabric up)"
  kc uncordon "$DRAIN_NODE" 2>/dev/null || true
  docker exec "$DRAIN_CTR" ip link set fab0 up
  docker exec "$DRAIN_CTR" ip link set fab1 up

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

info "Test 4C setup: N=${N} flows, DUR=${DUR}s, drain=${DRAIN_NODE} (grace=${GRACE}s), 6 replicas"
yellow "  NOTE: flows to pods ON ${DRAIN_NODE} will break (fabric goes down)."
yellow "  For cleanest results use a drain node with no/few pods: kubectl get pods -o wide"
step "scaling echo to 6 replicas"
kc -n default scale deploy/echo --replicas=6 >/dev/null 2>&1 || true
kc -n default rollout status deploy/echo --timeout=120s 2>&1 | sed 's/^/  /'

info "--- DSR + Maglev OFF ---"
set_cilium_values "cilium-values-dsr-nomaglev.yaml"
probe_srcip
run_cell "dsr-drain-node_maglev-off"

info "--- DSR + Maglev ON ---"
set_cilium_values "cilium-values-dsr-maglev.yaml"
probe_srcip
run_cell "dsr-drain-node_maglev-on"

echo
green "================ Test 4C: DSR + Node Drain results ====================="
printf '%-40s %s\n' "DSR + Maglev off:" "${RESULT[dsr-drain-node_maglev-off]:-?}"
printf '%-40s %s\n' "DSR + Maglev on: " "${RESULT[dsr-drain-node_maglev-on]:-?}"
echo
echo "Drain node: ${DRAIN_NODE}  Grace period: ${GRACE}s  Flowgen timeout: 5s"
echo "Predicted (flows NOT to pods on ${DRAIN_NODE}):"
echo "  DSR + Maglev off: ~28%  (re-homed flows pick random backend)"
echo "  DSR + Maglev on:  ~0%   (Maglev picks same backend; pod still alive within grace window)"
echo
echo "Raw JSON: ${RESULTS_DIR}/"
green "Runtime: $(fmt_duration)"
