#!/usr/bin/env bash
# Test 4B — DSR mode: the configuration that makes Maglev observable.
#
# loadBalancer.mode=dsr preserves the original client IP end-to-end.
# When a flow re-homes to a different ingress node after a failure:
#   Maglev off: new ingress picks random backend → different pod → no TCP state → RST (~28%)
#   Maglev on:  new ingress picks SAME backend (same 5-tuple, same hash) → pod has state → survives (~0%)
#
# Run scripts/probe-source-ip.sh first to confirm DSR is working (pod sees 203.0.113.1).
# If the no-Maglev cell shows 0% broken, DSR is likely not working — try dsrDispatch=geneve.
#
# Env knobs: N=<flows> (default 300)   DUR=<sec> (default 50)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

N="${N:-300}"; DUR="${DUR:-50}"
N1="${PFX}-node1"
FAIL_NODE="${PFX}-node2"
HELM_VALUES_DIR="/opt/k8s"
declare -A RESULT

set_cilium_values() {
  local vals="$1"
  info "applying ${vals} (helm upgrade + rollout restart)"
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/${vals}" --reuse-values >/dev/null
  step "triggering rolling restart of cilium DaemonSet"
  docker exec "$N1" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null
  step "waiting for rollout to complete"
  docker exec "$N1" k3s kubectl -n kube-system rollout status ds/cilium --timeout=180s 2>&1 | sed 's/^/  /'
  sleep 5
}

cleanup() {
  info "Restoring original Cilium values (maglev + snat)..."
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/cilium-values-maglev.yaml" --reuse-values >/dev/null 2>&1 || true
  docker exec "$N1" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null 2>&1 || true
  docker exec "$N1" k3s kubectl -n kube-system rollout status ds/cilium --timeout=120s 2>&1 | sed 's/^/  /' || true
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
    while data.count(b'\\n') < 1:
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
  FIRST=$(echo "$RESP" | head -1 | tr -d '\r')
  if echo "$FIRST" | grep -qE '^SRCIP='; then
    SRCIP=$(echo "$FIRST" | cut -d= -f2)
    if echo "$SRCIP" | grep -qE '^172\.30\.'; then
      yellow "  WARNING: pod sees ${SRCIP} — DSR may not be active yet"
      yellow "  If no-Maglev cell shows 0%, switch to dsrDispatch: geneve in values files"
    elif echo "$SRCIP" | grep -qE '^203\.0\.113\.'; then
      green "  DSR confirmed: pod sees ${SRCIP} (original client IP)"
    fi
  else
    yellow "  (SRCIP not in response — run scripts/probe-source-ip.sh for a full check)"
  fi
}

run_cell() {
  local tag="$1"
  info "=== cell: ${tag} ==="

  step "restoring ${FAIL_NODE}"
  docker start "$FAIL_NODE" >/dev/null 2>&1 || true
  bash "${REPO_ROOT}/scripts/fix-node-veths.sh" "$FAIL_NODE" 2>/dev/null || true
  docker exec -d "$FAIL_NODE" bash /opt/startup.sh 2>/dev/null || true
  wait_vip_ecmp 60 || yellow "  INFO: VIP ECMP not fully reconverged"

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
  info "stopping ${FAIL_NODE}"
  docker stop "$FAIL_NODE" >/dev/null

  local wait_secs=$(( DUR > 20 ? DUR-15 : 10 ))
  for i in $(seq 1 "$wait_secs"); do
    sleep 1
    [ $(( i % 5 )) -eq 0 ] && step "post-failure wait: ${i}/${wait_secs}s (collecting RSTs)"
  done

  step "restoring ${FAIL_NODE} after failure"
  docker start "$FAIL_NODE" >/dev/null
  bash "${REPO_ROOT}/scripts/fix-node-veths.sh" "$FAIL_NODE" 2>/dev/null || true

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

info "Test 4B setup: N=${N} flows, DUR=${DUR}s, ETP=Cluster, 6 replicas"
step "scaling echo to 6 replicas"
kc -n default scale deploy/echo --replicas=6 >/dev/null 2>&1 || true
kc -n default rollout status deploy/echo --timeout=120s 2>&1 | sed 's/^/  /'

info "--- DSR + Maglev OFF ---"
set_cilium_values "cilium-values-dsr-nomaglev.yaml"
probe_srcip
run_cell "dsr_maglev-off"

info "--- DSR + Maglev ON ---"
set_cilium_values "cilium-values-dsr-maglev.yaml"
probe_srcip
run_cell "dsr_maglev-on"

echo
green "================ DSR broken-flow results ================================"
printf '%-40s %s\n' "DSR + Maglev off:" "${RESULT[dsr_maglev-off]:-?}"
printf '%-40s %s\n' "DSR + Maglev on: " "${RESULT[dsr_maglev-on]:-?}"
echo
echo "Predicted (M=3 nodes, B=6 backends):"
echo "  DSR + Maglev off: ~28%  (1/3 re-home × 5/6 wrong backend)"
echo "  DSR + Maglev on:  ~0%   (Maglev selects same backend; pod has state)"
echo
if [ "${RESULT[dsr_maglev-off]:-?}" != "?" ] && \
   echo "${RESULT[dsr_maglev-off]}" | grep -qE '^\?|0/'; then
  yellow "WARNING: Maglev-off cell shows 0% — DSR may not be working."
  yellow "Try uncommenting dsrDispatch: geneve in k8s/cilium-values-dsr-*.yaml"
fi
echo "Raw JSON: ${RESULTS_DIR}/"
green "Runtime: $(fmt_duration)"
