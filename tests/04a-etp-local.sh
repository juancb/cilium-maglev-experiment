#!/usr/bin/env bash
# Test 4A — ETP=Local: confirm Maglev is irrelevant when each ingress node
# can only forward to its own local backend.
#
# Setup: 3 replicas, 1 per node (DoNotSchedule spread). externalTrafficPolicy=Local.
# When node2 fails: ~1/3 of flows were ingressed by node2. Those re-home to
# node1/node3, which forward to THEIR local pods (different pods from node2's).
# Result: ~33% broken in BOTH cells — Maglev makes no difference.
#
# Env knobs: N=<flows> (default 150)   DUR=<sec> (default 25)
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

N="${N:-150}"; DUR="${DUR:-25}"
N1="${PFX}-node1"
FAIL_NODE="${PFX}-node2"
HELM_VALUES_DIR="/opt/k8s"
declare -A RESULT

set_maglev() {
  local mode="$1"
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
    [ $(( iter % 5 )) -eq 0 ] && step "Cilium restart: ${cilium_not_ready} pod(s) not 1/1 (iter ${iter}/60)"
  done
  wait_cilium_ready 60 || yellow "  WARNING: Cilium not fully ready; results may be skewed"
}

cleanup() {
  info "Restoring original demo-app (ETP=Cluster, 6 replicas)..."
  kc apply -f /opt/k8s/demo-app.yaml >/dev/null 2>&1 || true
  kc rollout status deploy/echo --timeout=120s 2>&1 | sed 's/^/  /' || true
}
trap cleanup EXIT

run_cell() {
  local mag="$1"
  local tag="etp-local_maglev-${mag}"
  info "=== cell: ETP=Local / Maglev ${mag} ==="

  step "restoring ${FAIL_NODE}"
  docker start "$FAIL_NODE" >/dev/null 2>&1 || true
  bash "${REPO_ROOT}/scripts/fix-node-veths.sh" "$FAIL_NODE" 2>/dev/null || true
  docker exec -d "$FAIL_NODE" bash /opt/startup.sh 2>/dev/null || true
  if ! docker exec "$FAIL_NODE" bash -c 'pgrep -f "k3s agent" >/dev/null 2>&1'; then
    local token; token=$(docker exec "$N1" cat /var/lib/rancher/k3s/server/node-token)
    local node_num="${FAIL_NODE##*node}"
    docker exec "$FAIL_NODE" bash -c 'rm -rf /run/k3s /var/run/k3s 2>/dev/null; true'
    docker exec -d "$FAIL_NODE" bash -lc \
      "k3s agent --server https://10.10.0.1:6443 --token ${token} --node-ip 10.10.0.${node_num} \
       --snapshotter=native >/var/log/k3s.log 2>&1"
    yellow "  restarted k3s agent on ${FAIL_NODE}"
  fi

  for stuck in $(kc get pods -l app=echo --no-headers 2>/dev/null | awk '/Terminating/{print $1}'); do
    kc delete pod "$stuck" --force --grace-period=0 2>/dev/null || true
    yellow "  force-deleted stale echo pod: $stuck"
  done
  wait_vip_ecmp 30 || yellow "  INFO: VIP ECMP not fully reconverged"

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
    [ $(( elapsed % 5 )) -eq 0 ] && step "waiting for ${N} flows to establish... (${elapsed}s)"
  done
  step "flows established; sleeping 3s before failure injection"
  sleep 3

  local failtime; failtime=$(date +%s)
  info "failing ${FAIL_NODE} (fabric links down)"
  docker exec "$FAIL_NODE" ip link set fab0 down
  docker exec "$FAIL_NODE" ip link set fab1 down

  local wait_secs=$(( DUR > 20 ? DUR-15 : 10 ))
  for i in $(seq 1 "$wait_secs"); do
    sleep 1
    [ $(( i % 5 )) -eq 0 ] && step "post-failure wait: ${i}/${wait_secs}s"
  done

  step "restoring ${FAIL_NODE} (fabric links up)"
  docker exec "$FAIL_NODE" ip link set fab0 up
  docker exec "$FAIL_NODE" ip link set fab1 up

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

info "Test 4A setup: N=${N} flows, 3 replicas (1/node), ETP=Local, DUR=${DUR}s"

wait_cilium_ready 30 || true

step "purging any stale Terminating echo pods"
for stuck in $(kc get pods -l app=echo --no-headers 2>/dev/null | awk '/Terminating/{print $1}'); do
  kc delete pod "$stuck" --force --grace-period=0 2>/dev/null || true
  yellow "  force-deleted stale pod: $stuck"
done

if ! docker exec "${PFX}-node2" bash -c 'pgrep -f "k3s agent" >/dev/null 2>&1'; then
  step "restarting k3s agent on node2"
  token=$(docker exec "$N1" cat /var/lib/rancher/k3s/server/node-token)
  docker exec "${PFX}-node2" bash -c 'rm -rf /run/k3s /var/run/k3s 2>/dev/null; true'
  docker exec -d "${PFX}-node2" bash -lc \
    "k3s agent --server https://10.10.0.1:6443 --token ${token} --node-ip 10.10.0.2 \
     --snapshotter=native >/var/log/k3s.log 2>&1"
  yellow "  restarted k3s agent on node2 — waiting for Ready"
  local elapsed=0
  for _ in $(seq 1 90); do
    kc get node node2 --no-headers 2>/dev/null | grep -q ' Ready' && break
    elapsed=$(( elapsed + 3 ))
    [ $(( elapsed % 15 )) -eq 0 ] && step "waiting for node2 Ready... (${elapsed}s)"
    sleep 3
  done
fi

info "Applying ETP=Local manifest (demo-app-local.yaml)..."
kc apply -f /opt/k8s/demo-app-local.yaml >/dev/null
local iter=0
for _ in $(seq 1 60); do
  sleep 2; iter=$(( iter + 1 ))
  for stuck in $(kc -n default get pods -l app=echo --no-headers 2>/dev/null \
      | awk '/Terminating/{print $1}'); do
    kc delete pod "$stuck" --force --grace-period=0 2>/dev/null || true
    yellow "  force-deleted stuck echo pod: $stuck"
  done
  [ $(( iter % 5 )) -eq 0 ] && step "waiting for echo rollout... (iter ${iter}/60)"
  kc rollout status deploy/echo --timeout=5s >/dev/null 2>&1 && break || true
done

info "Pod distribution:"
kc get pods -l app=echo -o wide --no-headers 2>/dev/null | awk '{print "  " $1 " -> " $7}'

pod_nodes=$(kc get pods -l app=echo -o wide --no-headers 2>/dev/null | awk '{print $7}' | sort | uniq -c)
if echo "$pod_nodes" | grep -vq '^ *1 '; then
  yellow "  WARNING: pod distribution is not 1-per-node — results may be skewed"
  yellow "  Distribution: $pod_nodes"
fi

set_maglev off
run_cell off

set_maglev on
run_cell on

echo
green "================ ETP=Local broken-flow results =========================="
printf '%-40s %s\n' "Maglev off (ETP=Local):" "${RESULT[etp-local_maglev-off]:-?}"
printf '%-40s %s\n' "Maglev on  (ETP=Local):" "${RESULT[etp-local_maglev-on]:-?}"
echo
echo "Predicted: ~33% broken in BOTH cells (1/3 of flows on node2; all break"
echo "because surviving nodes have different local pods; Maglev is irrelevant)."
echo "For the config that DOES make Maglev observable: bash tests/04b-leaf-failure.sh"
echo "Raw JSON: ${RESULTS_DIR}/"
green "Runtime: $(fmt_duration)"
