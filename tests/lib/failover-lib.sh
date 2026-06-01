#!/usr/bin/env bash
# failover-lib.sh — shared engine for the failover tests (04b/04c and variants).
#
# Source AFTER lib/common.sh. A wrapper script sets the config vars below and
# defines three hooks, then calls failover_main.
#
# Config vars (set in the wrapper before calling failover_main):
#   TEST_NAME       human label for the run banner / final table
#   HELM_NODE       container to run helm/kubectl from (e.g. ${PFX}-node1)
#   VALS_OFF        Cilium values file for the Maglev-OFF cell
#   VALS_ON         Cilium values file for the Maglev-ON cell
#   TAG_OFF         result tag for the Maglev-OFF cell
#   TAG_ON          result tag for the Maglev-ON cell
#   DSR             1 → pass --set loadBalancer.dsrDispatch=opt; 0 → SNAT
#   PRED_OFF        predicted broken% string for the OFF cell (display only)
#   PRED_ON         predicted broken% string for the ON cell  (display only)
#
# Env knobs (with defaults): N, DUR, RUNS, REPLICAS
#
# Hooks the wrapper MUST define:
#   inject_failure    cause the failure (leaf down / drain / etc.)
#   restore_failure   undo the failure
#   ensure_healthy    restore + wait for the VIP to be ECMP again (pre-cell)

N="${N:-300}"; DUR="${DUR:-50}"; RUNS="${RUNS:-5}"; REPLICAS="${REPLICAS:-6}"
DSR="${DSR:-0}"
HELM_VALUES_DIR="${HELM_VALUES_DIR:-/opt/k8s}"
declare -A RESULT

# ── Cilium values switching ──────────────────────────────────────────────────
set_cilium_values() {
  local vals="$1"
  local dsr_args=()
  [ "$DSR" = "1" ] && dsr_args=(--set loadBalancer.dsrDispatch=opt)
  info "applying ${vals} (helm upgrade + rollout restart)"
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$HELM_NODE" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/${vals}" --reset-values "${dsr_args[@]}" >/dev/null
  step "triggering rolling restart of cilium DaemonSet"
  docker exec "$HELM_NODE" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null
  step "waiting for rollout to complete"
  docker exec "$HELM_NODE" k3s kubectl -n kube-system rollout status ds/cilium --timeout=300s 2>&1 | sed 's/^/  /'
  sleep 5
}

# ── Disturbed-set (D) capture ────────────────────────────────────────────────
# Per-node count of distinct client source ports ingressing the VIP, read from
# each agent's Hubble ring buffer — the empirical spread of flows across ingress
# nodes (the bigger a node's share, the more flows re-home when its leaf drops).
#
# This replaces a full `cilium bpf ct list global` dump (multi-second, thousands
# of entries) with `hubble observe --last N` (~0.4s, reads the in-memory ring).
# It is also launched in the BACKGROUND from run_cell so it can never delay
# failure injection. Never fails the test (writes {} on error).
#
# The k8s node name (node1) differs from the container name (clab-…-node1); we
# strip the ${PFX}- prefix to match the kubectl -o wide NODE column.
capture_ingress_dist() {
  local out="$1"
  {
    printf '{'
    local sep=''
    for n in "${NODES[@]}"; do
      local node pod cnt
      node="${n#${PFX}-}"
      pod=$(kc -n kube-system get pods -l k8s-app=cilium -o wide --no-headers 2>/dev/null \
            | awk -v nn="$node" '$7==nn {print $1; exit}')
      cnt=0
      if [ -n "$pod" ]; then
        # each agent's Hubble sees only its own node's flows → per-node ingress load
        cnt=$(kc -n kube-system exec "$pod" -c cilium-agent -- \
              hubble observe --last 2000 --to-port "${VIP_PORT}" --verdict FORWARDED -o jsonpb 2>/dev/null \
              | python3 "${REPO_ROOT}/scripts/hubble-count-ports.py" 2>/dev/null || echo 0)
      fi
      printf '%s"%s":%s' "$sep" "$node" "${cnt:-0}"
      sep=','
    done
    printf '}\n'
  } > "$out" 2>/dev/null || echo '{}' > "$out"
}

# ── One cell = RUNS repetitions, then aggregate ──────────────────────────────
run_cell() {
  local tag="$1"
  info "=== cell: ${tag} (${RUNS} run(s)) ==="

  local run
  for run in $(seq 1 "$RUNS"); do
    local rtag="${tag}.run${run}"
    step "--- ${tag}: run ${run}/${RUNS} ---"

    ensure_healthy

    step "starting ${N} flows (duration ${DUR}s)"
    docker exec "$CLIENT" rm -f /tmp/${rtag}.json /tmp/${rtag}.ready 2>/dev/null || true
    docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
        --vip "$VIP" --port "$VIP_PORT" --count "$N" --duration "$DUR" \
        --src 203.0.113.1 \
        --out "/tmp/${rtag}.json" --ready-file "/tmp/${rtag}.ready"

    local elapsed=0
    for _ in $(seq 1 30); do
      docker exec "$CLIENT" test -f /tmp/${rtag}.ready && break
      sleep 1; elapsed=$(( elapsed + 1 ))
      [ $(( elapsed % 5 )) -eq 0 ] && step "waiting for flows to establish... (${elapsed}s)"
    done
    step "flows established; capturing ingress distribution via Hubble (background)"
    capture_ingress_dist "${RESULTS_DIR}/${rtag}.dist.json" &
    local dist_pid=$!
    step "sleeping 3s before failure injection"
    sleep 3

    local failtime; failtime=$(date +%s)
    inject_failure

    local wait_secs=$(( DUR > 20 ? DUR-15 : 10 ))
    for i in $(seq 1 "$wait_secs"); do
      sleep 1
      [ $(( i % 5 )) -eq 0 ] && step "post-failure wait: ${i}/${wait_secs}s (collecting RSTs)"
    done

    restore_failure
    wait "$dist_pid" 2>/dev/null || true   # ensure dist file is written before aggregation

    step "collecting run ${run} results"
    for _ in $(seq 1 30); do
      docker exec "$CLIENT" test -s /tmp/${rtag}.json && break; sleep 1
    done
    docker cp "${CLIENT}:/tmp/${rtag}.json" "${RESULTS_DIR}/${rtag}.json" >/dev/null 2>&1 || true
    if command -v jq >/dev/null 2>&1 && [ -s "${RESULTS_DIR}/${rtag}.json" ]; then
      local tmp; tmp=$(mktemp)
      jq --argjson ft "$failtime" \
         --slurpfile dist "${RESULTS_DIR}/${rtag}.dist.json" \
         '.summary.failtime = $ft | .summary.ingress_dist = $dist[0]' \
         "${RESULTS_DIR}/${rtag}.json" > "$tmp" \
        && mv "$tmp" "${RESULTS_DIR}/${rtag}.json" || rm -f "$tmp"
    fi
  done

  # Aggregate all runs for this tag → results/<tag>.json
  step "aggregating ${RUNS} run(s) for ${tag}"
  local agg
  agg=$(python3 "${REPO_ROOT}/scripts/aggregate-runs.py" "${RESULTS_DIR}" "${tag}" 2>&1) || true
  echo "  ${agg}"
  RESULT["$tag"]="${agg##*: }"
}

# ── Cleanup trap (wrapper sets the trap to call this) ────────────────────────
failover_cleanup() {
  info "Restoring failure state and Cilium values..."
  restore_failure 2>/dev/null || true
  docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$HELM_NODE" \
      helm upgrade cilium cilium/cilium -n kube-system \
      -f "${HELM_VALUES_DIR}/cilium-values-maglev.yaml" --reset-values >/dev/null 2>&1 || true
  docker exec "$HELM_NODE" k3s kubectl -n kube-system rollout restart ds/cilium >/dev/null 2>&1 || true
  docker exec "$HELM_NODE" k3s kubectl -n kube-system rollout status ds/cilium --timeout=300s 2>&1 | sed 's/^/  /' || true
}

# ── Orchestration ────────────────────────────────────────────────────────────
failover_main() {
  info "${TEST_NAME}: N=${N} flows, DUR=${DUR}s, RUNS=${RUNS}, ${REPLICAS} replicas"
  step "scaling echo to ${REPLICAS} replicas"
  kc -n default scale deploy/echo --replicas="${REPLICAS}" >/dev/null 2>&1 || true
  kc -n default rollout status deploy/echo --timeout=120s 2>&1 | sed 's/^/  /'

  info "--- Maglev OFF ---"
  set_cilium_values "$VALS_OFF"
  run_cell "$TAG_OFF"

  info "--- Maglev ON ---"
  set_cilium_values "$VALS_ON"
  run_cell "$TAG_ON"

  echo
  green "================ ${TEST_NAME}: results (mean ± stddev over ${RUNS} runs) ========"
  printf '%-22s %s\n' "Maglev off:" "${RESULT[$TAG_OFF]:-?}"
  printf '%-22s %s\n' "Maglev on: " "${RESULT[$TAG_ON]:-?}"
  echo
  echo "Predicted:"
  echo "  Maglev off: ${PRED_OFF}"
  echo "  Maglev on:  ${PRED_ON}"
  echo
  echo "Per-run + disturbed-set (D) JSON: ${RESULTS_DIR}/${TAG_OFF}.run*.json (+ .dist.json)"
  green "Runtime: $(fmt_duration)"
}
