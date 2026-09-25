#!/usr/bin/env bash
# Test 5 — how much does Cilium ITSELF disrupt the data plane? (fabric BGP stays up)
#
# Every cell holds long-lived flows open, applies ONE Cilium-side disruption, and records
# which established flows break and whether new connections fail:
#
#   agent-restart  kubectl rollout restart ds/cilium: the rolling agent restart of a
#                  Cilium upgrade/config change (SIGTERM, all nodes, chart maxUnavailable)
#   agent-upgrade  a real version change: helm upgrade CILIUM_VERSION (1.19.1, pinned in
#                  lib/common.sh) -> UPGRADE_TO (default: newest 1.19.x patch in the helm
#                  repo), rolled back after the run (unmeasured).
#   agent-kill     SIGKILL cilium-agent on TARGET_NODE, i.e. what the kernel OOM killer
#                  does. kubelet restarts it in place.
#   agent-delete   delete the cilium pod on TARGET_NODE; the DaemonSet replaces it. One
#                  node's worth of a rollout (init containers and all), for repeating a
#                  single-node pod replacement many times (RUNS=10).
#   backend-kill   SIGKILL KILL_COUNT echo backend(s) on TARGET_NODE (app OOM). Flows on
#                  the killed backend die by definition; what matters is COLLATERAL
#                  breakage of flows on the other backends.
#
# Why SIGKILL rather than a real OOM: the lab clears the cgroup-v2 subtree_control (see
# nodes/startup/node.sh), so memory limits aren't enforced. The data-plane effect is the
# same: the kernel SIGKILLs the process, its sockets close, kubelet restarts the container.
#
# Measured concurrently, same disruption, same instant:
#   ext-cil     external client -> 192.0.2.20 (VIP originated only by Cilium BGP)
#   ext-static  external client -> 192.0.2.21 (VIP also static in bird: "BGP unharmed")
#   int         in-cluster pod on IC_NODE -> ClusterIP (the only traffic iTP affects)
#   + a new-connection prober (connprobe.py) on each, and a 1s BGP route timeline at leaf1.
#
# Cell axes: {maglev,random} x MODES x traffic policies x disruptions. eTP only affects
# external traffic and iTP only in-cluster traffic, so by default they're toggled together
# ("Cluster:Cluster Local:Local") rather than crossed. Pass POLICIES to cross them.
#
# BGP: expects 90s hold and no explicit GR (see nodes/bird, fabric/frr/leaf*.conf,
# k8s/cilium-bgp.yaml). Verified before the matrix; STRICT_BGP=1 aborts on mismatch.
#
# Env knobs:
#   ALGOS ("maglev random")  MODES ("snat")  POLICIES ("Cluster:Cluster Local:Local")
#   DISRUPTIONS ("agent-restart agent-kill backend-kill", plus agent-upgrade when UPGRADE_TO
#     is set; also agent-delete)
#   TARGET_NODE (node2)  IC_NODE (=TARGET_NODE)  KILL_COUNT (1 | all)
#   CILIUM_VERSION (1.19.1)  UPGRADE_TO (unset; "latest" = newest patch of that minor)
#   MAX_UNAVAILABLE (unset = chart default, 2): DaemonSet rollingUpdate.maxUnavailable
#   CAPTURE_PCAP (1): per-node capture of client->VIP and node->backend packets, reduced
#     to 1s buckets on the node; scripts/analyze-rehoming.py then labels every external
#     flow re-homed/stayed and same/changed backend (results/<run>.ext-*.rehoming.json)
#   RUN_LABEL (unset): write results under results/<RUN_LABEL>/ instead of results/
#   N (200 flows per population)  RUNS (2)  REPLICAS (6)  PROBE_HZ (10)
#   DUR_ROLLOUT (200)  DUR_KILL (75)  DUR_DELETE (150)  SETTLE (15)  STRICT_BGP (0)
#   FLOW_TIMEOUT (30): seconds a flow may stall before it counts as broken. A real TCP
#     client keeps retransmitting through a short outage, so a stall is reported
#     separately (max_stall) rather than as a break.
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
SECONDS=0

words() { echo "${1//,/ }"; }
ALGOS=$(words "${ALGOS:-maglev random}")
MODES=$(words "${MODES:-snat}")
POLICIES=$(words "${POLICIES:-Cluster:Cluster Local:Local}")
UPGRADE_TO="${UPGRADE_TO:-}"
_dd="agent-restart agent-kill backend-kill"; [ -n "$UPGRADE_TO" ] && _dd+=" agent-upgrade"
DISRUPTIONS=$(words "${DISRUPTIONS:-$_dd}")
TARGET_NODE="${TARGET_NODE:-node2}"; TARGET_CTR="${PFX}-${TARGET_NODE}"
IC_NODE="${IC_NODE:-$TARGET_NODE}"
KILL_COUNT="${KILL_COUNT:-1}"
N="${N:-200}"; RUNS="${RUNS:-2}"; REPLICAS="${REPLICAS:-6}"; PROBE_HZ="${PROBE_HZ:-10}"
DUR_ROLLOUT="${DUR_ROLLOUT:-200}"; DUR_KILL="${DUR_KILL:-75}"; DUR_DELETE="${DUR_DELETE:-150}"; SETTLE="${SETTLE:-15}"
FLOW_TIMEOUT="${FLOW_TIMEOUT:-30}"
MAX_UNAVAILABLE="${MAX_UNAVAILABLE:-}"
CAPTURE_PCAP="${CAPTURE_PCAP:-1}"
RUN_LABEL="${RUN_LABEL:-}"
[ -n "$RUN_LABEL" ] && { RESULTS_DIR="${RESULTS_DIR}/${RUN_LABEL}"; mkdir -p "$RESULTS_DIR"; }
STRICT_BGP="${STRICT_BGP:-0}"
BASE_VALUES="cilium-values-maglev.yaml"
VIP_CIL="192.0.2.20"; VIP_STATIC="192.0.2.21"
SRC="203.0.113.1"
# sourced AFTER our defaults: failover-lib assigns its own N/RUNS defaults
. lib/failover-lib.sh      # wait_stable
. lib/bgp-verify.sh
KCFG=/etc/rancher/k3s/k3s.yaml
helm1() { docker exec -e KUBECONFIG="$KCFG" "${PFX}-node1" helm "$@"; }
kci()   { docker exec -i "${PFX}-node1" k3s kubectl "$@"; }

CUR_ALGO=""; CUR_MODE=""; CLUSTER_IP=""
BGPW_PID=""; KILLED=()

# ── Cilium config ────────────────────────────────────────────────────────────
# newest chart in CILIUM_VERSION's minor (1.19.1 -> newest 1.19.x)
latest_patch() {
  helm1 repo update cilium >/dev/null 2>&1 || true
  helm1 search repo cilium/cilium --versions -o json 2>/dev/null | python3 -c '
import json, sys
minor = sys.argv[1].rsplit(".", 1)[0] + "."
vs = [r["version"] for r in json.load(sys.stdin)
      if r["name"] == "cilium/cilium" and r["version"].startswith(minor) and "-" not in r["version"]]
print(max(vs, key=lambda v: int(v.rsplit(".", 1)[1])) if vs else "")' "$CILIUM_VERSION"
}

installed_cilium_version() {
  helm1 list -n kube-system -o json 2>/dev/null | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if r["name"] == "cilium":
        print(r["chart"].split("cilium-", 1)[1])'
}

# helm upgrade to (algo, mode) at a PINNED chart version. An unpinned upgrade would
# silently move the cluster to whatever the repo's latest chart is.
helm_cilium() {  # algo mode version
  helm1 upgrade cilium cilium/cilium -n kube-system --version "$3" \
    -f "/opt/k8s/${BASE_VALUES}" --reset-values \
    --set loadBalancer.algorithm="$1" --set loadBalancer.mode="$2" \
    ${MAX_UNAVAILABLE:+--set updateStrategy.rollingUpdate.maxUnavailable="$MAX_UNAVAILABLE"} >/dev/null
}

apply_cilium() {  # algo mode
  info "Cilium ${CILIUM_VERSION}: loadBalancer.algorithm=$1 mode=$2 (helm upgrade + rollout restart)"
  helm_cilium "$1" "$2" "$CILIUM_VERSION"
  kc -n kube-system rollout restart ds/cilium >/dev/null
  kc -n kube-system rollout status ds/cilium --timeout=600s 2>&1 | sed 's/^/  /'
  CUR_ALGO="$1"; CUR_MODE="$2"
  wait_stable
}

set_policies() {  # etp itp
  step "services: externalTrafficPolicy=$1 internalTrafficPolicy=$2"
  local s
  for s in echo-dz-cil echo-dz-static; do
    kc -n default patch svc "$s" --type merge \
      -p "{\"spec\":{\"externalTrafficPolicy\":\"$1\",\"internalTrafficPolicy\":\"$2\"}}" >/dev/null
  done
  sleep 5
}

# ── Health gates ─────────────────────────────────────────────────────────────
cilium_pod_on() {
  kc -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=$1" \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true
}

# bird spawns dynbgp1, dynbgp2, ... from "neighbor range"; count the Established ones
cilium_sessions() { docker exec "$1" birdc show protocols 2>/dev/null | awk '$1 ~ /^(dynbgp|cilium)[0-9]+$/ && /Established/' | grep -c . || true; }

wait_cilium_session() {  # node-ctr secs
  local i
  for i in $(seq 1 "${2:-120}"); do
    [ "$(cilium_sessions "$1")" -ge 1 ] && return 0
    sleep 1
  done
  return 1
}

leaf_nexthops() {  # prefix
  docker exec "${LEAVES[0]}" vtysh -c "show ip route $1" 2>/dev/null | grep -cE '^\s+\* 10\.' || true
}

wait_vip_n() {  # vip secs
  local i
  for i in $(seq 1 "${2:-60}"); do
    [ "$(leaf_nexthops "$1/32")" -ge 2 ] && return 0
    sleep 1
  done
  return 1
}

echo_nodes_ok() {  # every node runs >=1 Ready echo pod
  local n
  for n in node1 node2 node3; do
    kc -n default get pods -l app=echo --field-selector "spec.nodeName=$n" \
      -o jsonpath='{range .items[*]}{.status.containerStatuses[0].ready}{"\n"}{end}' 2>/dev/null \
      | grep -q true || return 1
  done
}

ensure_healthy() {
  step "health gate: nodes uncordoned, agents 1/1, BGP up, backends spread, VIPs in fabric"
  local n
  for n in node1 node2 node3; do kc uncordon "$n" >/dev/null 2>&1 || true; done
  wait_cilium_ready 60 >/dev/null || yellow "  INFO: agents not all 1/1"
  for n in "${NODES[@]}"; do
    wait_node_bgp "$n" 60 || yellow "  INFO: bird uplinks not Established on ${n#${PFX}-}"
    wait_cilium_session "$n" 90 || yellow "  INFO: bird<->Cilium session not Established on ${n#${PFX}-}"
  done
  kc -n default rollout status deploy/echo --timeout=120s >/dev/null 2>&1 || true
  if ! echo_nodes_ok; then
    step "echo backends not on every node; rebalancing"
    kc -n default rollout restart deploy/echo >/dev/null
    kc -n default rollout status deploy/echo --timeout=180s >/dev/null 2>&1 || true
    echo_nodes_ok || yellow "  WARNING: some node has no Ready echo backend (eTP/iTP=Local results skewed)"
  fi
  kc -n default wait --for=condition=Ready pod/flowgen-ic --timeout=120s >/dev/null 2>&1 \
    || yellow "  WARNING: flowgen-ic not Ready"
  wait_vip_n "$VIP_CIL" 60    || yellow "  INFO: ${VIP_CIL} <2 nexthops at leaf1"
  wait_vip_n "$VIP_STATIC" 60 || yellow "  INFO: ${VIP_STATIC} <2 nexthops at leaf1"
  sleep 3
}

# ── In-cluster client ────────────────────────────────────────────────────────
deploy_ic_client() {
  step "in-cluster client: flowgen-ic pinned to ${IC_NODE}"
  docker cp "${REPO_ROOT}/tests/lib/flowgen/flowgen.py"   "${PFX}-node1:/tmp/flowgen.py" >/dev/null
  docker cp "${REPO_ROOT}/tests/lib/flowgen/connprobe.py" "${PFX}-node1:/tmp/connprobe.py" >/dev/null
  kc -n default create configmap flowgen --from-file=/tmp/flowgen.py --from-file=/tmp/connprobe.py \
     --dry-run=client -o yaml | kci apply -f - >/dev/null
  kc -n default delete pod flowgen-ic --ignore-not-found --wait=true >/dev/null 2>&1 || true
  kci apply -f - >/dev/null <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: flowgen-ic
  namespace: default
  labels: { app: flowgen-ic }
spec:
  nodeName: ${IC_NODE}
  terminationGracePeriodSeconds: 0
  containers:
    - name: fg
      image: python:3.12-slim
      command: ["sleep", "infinity"]
      volumeMounts: [{ name: fg, mountPath: /opt/flowgen }]
  volumes: [{ name: fg, configMap: { name: flowgen } }]
EOF
  kc -n default wait --for=condition=Ready pod/flowgen-ic --timeout=180s >/dev/null
  CLUSTER_IP=$(kc -n default get svc echo-dz-cil -o jsonpath='{.spec.clusterIP}')
  step "  in-cluster target: echo-dz-cil ClusterIP ${CLUSTER_IP}"
}

# ── BGP timeline ─────────────────────────────────────────────────────────────
# One JSON line per ~second: nexthops at leaf1 for both VIPs and every node's pod CIDR,
# plus Established bird<->Cilium sessions per node. Shows whether (and for how long) a
# Cilium disruption pulled routes out of the fabric.
bgp_watch() {  # out stopfile
  set +e   # best-effort sampler: one failed docker exec must not kill it
  local out="$1" stopf="$2" pcs=() n
  for n in node1 node2 node3; do
    pcs+=("$(kc get ciliumnode "$n" -o jsonpath='{.spec.ipam.podCIDRs[0]}' 2>/dev/null)")
  done
  : > "$out"
  local tmp; tmp=$(mktemp -d)
  while [ ! -f "$stopf" ]; do
    local ts routes s1 s2 s3
    ts=$(date +%s.%N)
    # the four probes run in parallel, so a sample costs one docker exec of latency, not four
    docker exec "${LEAVES[0]}" vtysh \
        -c "show ip route ${VIP_CIL}/32" -c "show ip route ${VIP_STATIC}/32" \
        -c "show ip route ${pcs[0]}" -c "show ip route ${pcs[1]}" -c "show ip route ${pcs[2]}" \
        > "$tmp/routes" 2>/dev/null &
    cilium_sessions "${NODES[0]}" > "$tmp/s1" &
    cilium_sessions "${NODES[1]}" > "$tmp/s2" &
    cilium_sessions "${NODES[2]}" > "$tmp/s3" &
    wait
    routes=$(awk -v a="${VIP_CIL}/32" -v b="${VIP_STATIC}/32" -v p1="${pcs[0]}" -v p2="${pcs[1]}" -v p3="${pcs[2]}" '
                 /^Routing entry for/ {p=$4}
                 /^[[:space:]]+\* 10\./ {c[p]++}
                 END {printf "%d,%d,%d,%d,%d", c[a], c[b], c[p1], c[p2], c[p3]}' "$tmp/routes")
    s1=$(cat "$tmp/s1"); s2=$(cat "$tmp/s2"); s3=$(cat "$tmp/s3")
    IFS=, read -r r1 r2 r3 r4 r5 <<<"$routes"
    printf '{"t":%s,"vip_cil":%s,"vip_static":%s,"podcidr":{"node1":%s,"node2":%s,"node3":%s},"cilium_sess":{"node1":%s,"node2":%s,"node3":%s}}\n' \
      "$ts" "${r1:-0}" "${r2:-0}" "${r3:-0}" "${r4:-0}" "${r5:-0}" "${s1:-0}" "${s2:-0}" "${s3:-0}" >> "$out"
    sleep 0.25
  done
  rm -rf "$tmp"
}

# ── Disruptions (each blocks until Cilium/the backend has recovered) ────────
restart_count() {  # ns pod container
  kc -n "$1" get pod "$2" -o jsonpath="{.status.containerStatuses[?(@.name==\"$3\")].restartCount}" 2>/dev/null || true
}
container_ready() {
  kc -n "$1" get pod "$2" -o jsonpath="{.status.containerStatuses[?(@.name==\"$3\")].ready}" 2>/dev/null || true
}
wait_restarted() {  # ns pod container rc0 secs
  local i
  for i in $(seq 1 "${5:-180}"); do
    local rc; rc=$(restart_count "$1" "$2" "$3")
    [ "${rc:-0}" -gt "$4" ] && [ "$(container_ready "$1" "$2" "$3")" = "true" ] && return 0
    sleep 1
  done
  return 1
}

wait_all_cilium_sessions() {
  local n
  for n in "${NODES[@]}"; do wait_cilium_session "$n" 120 || yellow "  INFO: Cilium BGP not back on ${n#${PFX}-}"; done
}

disrupt() {  # disruption
  KILLED=()
  case "$1" in
    agent-restart)
      info "DISRUPT: rolling restart of ds/cilium"
      kc -n kube-system rollout restart ds/cilium >/dev/null
      kc -n kube-system rollout status ds/cilium --timeout=600s 2>&1 | sed 's/^/  /'
      wait_all_cilium_sessions
      ;;
    agent-upgrade)
      info "DISRUPT: helm upgrade Cilium ${CILIUM_VERSION} -> ${UPGRADE_TO}"
      helm_cilium "$CUR_ALGO" "$CUR_MODE" "$UPGRADE_TO"
      kc -n kube-system rollout status ds/cilium --timeout=900s 2>&1 | sed 's/^/  /'
      wait_all_cilium_sessions
      ;;
    agent-kill)
      local pod rc0
      pod=$(cilium_pod_on "$TARGET_NODE"); rc0=$(restart_count kube-system "$pod" cilium-agent)
      info "DISRUPT: SIGKILL cilium-agent on ${TARGET_NODE} (${pod})"
      docker exec "$TARGET_CTR" pkill -9 -x cilium-agent || red "  pkill found no cilium-agent"
      wait_restarted kube-system "$pod" cilium-agent "${rc0:-0}" 240 || yellow "  WARNING: agent not back Ready"
      wait_cilium_session "$TARGET_CTR" 120 || yellow "  INFO: Cilium BGP not back on ${TARGET_NODE}"
      ;;
    agent-delete)
      local old new i
      old=$(cilium_pod_on "$TARGET_NODE")
      info "DISRUPT: delete cilium pod ${old} on ${TARGET_NODE} (DaemonSet replaces it)"
      kc -n kube-system delete pod "$old" --wait=false >/dev/null
      new=""
      for i in $(seq 1 400); do
        # while the old pod is Terminating both exist on the node; pick the other one
        new=$(kc -n kube-system get pods -l k8s-app=cilium --field-selector "spec.nodeName=${TARGET_NODE}" \
                -o jsonpath='{.items[*].metadata.name}' 2>/dev/null | tr " " "\n" | grep -vx "$old" | head -1 || true)
        [ -n "$new" ] && [ "$(container_ready kube-system "$new" cilium-agent)" = "true" ] && break
        sleep 1
      done
      [ -n "$new" ] && [ "$(container_ready kube-system "$new" cilium-agent)" = "true" ] \
        || yellow "  WARNING: replacement cilium pod on ${TARGET_NODE} not Ready"
      wait_cilium_session "$TARGET_CTR" 120 || yellow "  INFO: Cilium BGP not back on ${TARGET_NODE}"
      ;;
    backend-kill)
      local pods=() p
      read -r -a pods <<<"$(kc -n default get pods -l app=echo --field-selector "spec.nodeName=${TARGET_NODE}" \
                              -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)"
      [ "$KILL_COUNT" = "all" ] || pods=("${pods[@]:0:$KILL_COUNT}")
      declare -A rc0=()
      for p in "${pods[@]}"; do
        rc0[$p]=$(restart_count default "$p" echo)
        local cid pid
        cid=$(docker exec "$TARGET_CTR" k3s crictl ps -q --name '^echo$' --label "io.kubernetes.pod.name=${p}" 2>/dev/null | head -1 || true)
        pid=$(docker exec "$TARGET_CTR" k3s crictl inspect -o go-template --template '{{.info.pid}}' "$cid" 2>/dev/null || true)
        if [ -z "$pid" ]; then red "  no PID for ${p}; skipping"; continue; fi
        info "DISRUPT: SIGKILL echo backend ${p} on ${TARGET_NODE} (pid ${pid})"
        docker exec "$TARGET_CTR" kill -9 "$pid"
        KILLED+=("$p")
      done
      for p in "${KILLED[@]}"; do
        wait_restarted default "$p" echo "${rc0[$p]:-0}" 180 || yellow "  WARNING: ${p} not back Ready"
      done
      ;;
    *) red "unknown disruption: $1"; exit 2 ;;
  esac
}

after_run() {  # disruption: undo anything persistent (unmeasured)
  if [ "$1" = "agent-upgrade" ]; then
    info "rolling Cilium back to ${CILIUM_VERSION} (not measured)"
    apply_cilium "$CUR_ALGO" "$CUR_MODE"
  fi
}

# ── Per-node packet capture (CAPTURE_PCAP=1) ─────────────────────────────────
# Capture only the packets the re-homing analysis needs: client->VIP (which node
# ingressed the flow) and the ingress node's forward to the backend pod (client-src for
# DSR, node-IP-src for SNAT; the source port is preserved either way). The pcap stays in
# the node's /tmp; only a 1s-bucketed, per-(src,dst) count file crosses the 9p mount.
DZ_PCAP_FILTER="dst port ${VIP_PORT} and (src host ${SRC} or src net 10.10.0.0/24)"
dz_pcap_start() {  # rtag
  [ "$CAPTURE_PCAP" = "1" ] || return 0
  local n
  for n in "${NODES[@]}"; do
    docker exec "$n" pkill -x tcpdump 2>/dev/null || true
    docker exec "$n" rm -f "/tmp/dz.pcap" 2>/dev/null || true
    docker exec -d "$n" tcpdump -i any -nn -s 96 -w /tmp/dz.pcap "$DZ_PCAP_FILTER" 2>/dev/null \
      || yellow "  WARN: tcpdump failed to start on ${n#${PFX}-}"
  done
  sleep 1
}
dz_pcap_stop() {  # rtag
  [ "$CAPTURE_PCAP" = "1" ] || return 0
  local n node pop vip
  for n in "${NODES[@]}"; do docker exec "$n" pkill -x tcpdump 2>/dev/null || true; done
  sleep 2
  for n in "${NODES[@]}"; do
    node="${n#${PFX}-}"
    for pop in ext-cil ext-static; do
      vip="$VIP_CIL"; [ "$pop" = ext-static ] && vip="$VIP_STATIC"
      # "<sec>.0 <src>.<sport> > <dst>.<dport> <count>", one line per (second, src, dst)
      docker exec "$n" sh /tmp/pcap-reduce.sh /tmp/dz.pcap "$SRC" "$vip" \
        > "${RESULTS_DIR}/${1}.${pop}.${node}.txt" 2>/dev/null || true
    done
  done
}
dz_rehoming() {  # rtag failtime -> prints, writes <rtag>.<pop>.rehoming.json
  [ "$CAPTURE_PCAP" = "1" ] || return 0
  local pop vip f tmp
  for pop in ext-cil ext-static int; do
    f="${RESULTS_DIR}/${1}.${pop}.json"
    [ -s "$f" ] || continue
    tmp=$(mktemp); jq --argjson ft "$2" '.summary.failtime = $ft' "$f" > "$tmp" && mv "$tmp" "$f" || rm -f "$tmp"
  done
  for pop in ext-cil ext-static; do
    vip="$VIP_CIL"; [ "$pop" = ext-static ] && vip="$VIP_STATIC"
    [ -s "${RESULTS_DIR}/${1}.${pop}.json" ] || continue
    python3 "${REPO_ROOT}/scripts/analyze-rehoming.py" "$RESULTS_DIR" "${1}.${pop}" --vip "$vip" 2>&1 | sed 's/^/  /' || true
  done
}

# ── One run ──────────────────────────────────────────────────────────────────
start_clients() {  # rtag dur
  local r="$1" d="$2"
  docker exec "$CLIENT" sh -c "rm -f /tmp/${r}.*" 2>/dev/null || true
  kc -n default exec flowgen-ic -- sh -c "rm -f /tmp/${r}.*" 2>/dev/null || true
  docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py --vip "$VIP_CIL" --port "$VIP_PORT" \
    --count "$N" --duration "$d" --timeout "$FLOW_TIMEOUT" --src "$SRC" --out "/tmp/${r}.ext-cil.json" --ready-file "/tmp/${r}.ext-cil.ready"
  docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py --vip "$VIP_STATIC" --port "$VIP_PORT" \
    --count "$N" --duration "$d" --timeout "$FLOW_TIMEOUT" --src "$SRC" --out "/tmp/${r}.ext-static.json" --ready-file "/tmp/${r}.ext-static.ready"
  docker exec -d "$CLIENT" python3 /opt/flowgen/connprobe.py --vip "$VIP_CIL" --port "$VIP_PORT" \
    --hz "$PROBE_HZ" --duration "$d" --src "$SRC" --out "/tmp/${r}.probe-ext-cil.json"
  docker exec -d "$CLIENT" python3 /opt/flowgen/connprobe.py --vip "$VIP_STATIC" --port "$VIP_PORT" \
    --hz "$PROBE_HZ" --duration "$d" --src "$SRC" --out "/tmp/${r}.probe-ext-static.json"
  kc -n default exec flowgen-ic -- sh -c "nohup python3 /opt/flowgen/flowgen.py --vip ${CLUSTER_IP} --port ${VIP_PORT} \
    --count ${N} --duration ${d} --timeout ${FLOW_TIMEOUT} --out /tmp/${r}.int.json --ready-file /tmp/${r}.int.ready >/tmp/${r}.int.log 2>&1 &"
  kc -n default exec flowgen-ic -- sh -c "nohup python3 /opt/flowgen/connprobe.py --vip ${CLUSTER_IP} --port ${VIP_PORT} \
    --hz ${PROBE_HZ} --duration ${d} --out /tmp/${r}.probe-int.json >/tmp/${r}.probe-int.log 2>&1 &"
}

clients_ready() {  # rtag
  docker exec "$CLIENT" test -f "/tmp/$1.ext-cil.ready" && docker exec "$CLIENT" test -f "/tmp/$1.ext-static.ready" \
    && kc -n default exec flowgen-ic -- test -f "/tmp/$1.int.ready" 2>/dev/null
}

collect_clients() {  # rtag timeout
  local r="$1" f i
  for i in $(seq 1 "$2"); do
    docker exec "$CLIENT" test -s "/tmp/${r}.ext-cil.json" && docker exec "$CLIENT" test -s "/tmp/${r}.ext-static.json" \
      && docker exec "$CLIENT" test -s "/tmp/${r}.probe-ext-static.json" \
      && kc -n default exec flowgen-ic -- test -s "/tmp/${r}.int.json" 2>/dev/null \
      && kc -n default exec flowgen-ic -- test -s "/tmp/${r}.probe-int.json" 2>/dev/null && break
    sleep 1
  done
  for f in ext-cil ext-static probe-ext-cil probe-ext-static; do
    docker cp "${CLIENT}:/tmp/${r}.${f}.json" "${RESULTS_DIR}/${r}.${f}.json" >/dev/null 2>&1 \
      || yellow "  missing ${r}.${f}.json"
  done
  for f in int probe-int; do
    kc -n default exec flowgen-ic -- cat "/tmp/${r}.${f}.json" > "${RESULTS_DIR}/${r}.${f}.json" 2>/dev/null \
      || { rm -f "${RESULTS_DIR}/${r}.${f}.json"; yellow "  missing ${r}.${f}.json"; }
  done
}

run_once() {  # cell run disruption etp itp
  local cell="$1" run="$2" d="$3" etp="$4" itp="$5" r="${1}.run${2}"
  step "--- ${cell} run ${run}/${RUNS} ---"
  ensure_healthy

  local dur="$DUR_KILL"
  case "$d" in agent-restart|agent-upgrade) dur="$DUR_ROLLOUT" ;; agent-delete) dur="$DUR_DELETE" ;; esac
  dz_pcap_start "$r"
  local t0; t0=$(date +%s.%N)
  step "starting ${N} flows x3 populations + new-connection probes (${dur}s)"
  start_clients "$r" "$dur"
  local i
  for i in $(seq 1 30); do clients_ready "$r" && break; sleep 1; done
  clients_ready "$r" || yellow "  WARNING: not all populations signalled ready"

  local stopf; stopf=$(mktemp -u)
  bgp_watch "${RESULTS_DIR}/${r}.bgp.jsonl" "$stopf" &
  BGPW_PID=$!
  sleep 5

  local failtime endtime
  failtime=$(date +%s.%N)
  disrupt "$d"
  endtime=$(date +%s.%N)
  step "disruption over after $(python3 -c "print(round(${endtime}-${failtime},1))")s; settling ${SETTLE}s"
  sleep "$SETTLE"

  local truncated
  truncated=$(python3 -c "print('true' if ${endtime}+${SETTLE} > ${t0}+${dur} else 'false')")
  [ "$truncated" = "true" ] && yellow "  WARNING: flows ended before disruption+settle finished; raise DUR_ROLLOUT/DUR_KILL"

  step "waiting for clients to finish and collecting"
  local left; left=$(python3 -c "import time; print(max(10, int(${t0}+${dur}-time.time())+30))")
  collect_clients "$r" "$left"
  touch "$stopf"; wait "$BGPW_PID" 2>/dev/null || true; BGPW_PID=""; rm -f "$stopf"
  dz_pcap_stop "$r"
  dz_rehoming "$r" "$failtime"

  local killed_json
  killed_json=$(printf '%s\n' "${KILLED[@]:-}" | python3 -c 'import json,sys; print(json.dumps([l.strip() for l in sys.stdin if l.strip()]))')
  cat > "${RESULTS_DIR}/${r}.meta.json" <<EOF
{"cell":"${cell}","run":${run},"disruption":"${d}","algo":"${CUR_ALGO}","mode":"${CUR_MODE}",
 "etp":"${etp}","itp":"${itp}","target_node":"${TARGET_NODE}","ic_node":"${IC_NODE}",
 "kill_count":"${KILL_COUNT}","cilium_version":"${CILIUM_VERSION}","upgrade_to":"${UPGRADE_TO}",
 "max_unavailable":"${MAX_UNAVAILABLE}","run_label":"${RUN_LABEL}",
 "t0":${t0},"failtime":${failtime},"endtime":${endtime},"settle":${SETTLE},"dur":${dur},"flow_timeout":${FLOW_TIMEOUT},
 "truncated":${truncated},"killed":${killed_json}}
EOF
  after_run "$d"
}

# ── Cleanup ──────────────────────────────────────────────────────────────────
dz_cleanup() {
  info "cleanup: stop watchers, restore policies + Cilium (maglev/snat @ ${CILIUM_VERSION})"
  [ -n "$BGPW_PID" ] && kill "$BGPW_PID" 2>/dev/null || true
  for n in node1 node2 node3; do kc uncordon "$n" >/dev/null 2>&1 || true; done
  set_policies Cluster Cluster 2>/dev/null || true
  kc -n default delete pod flowgen-ic --ignore-not-found --wait=false >/dev/null 2>&1 || true
  if [ -n "$CUR_ALGO" ] && { [ "$CUR_ALGO" != "maglev" ] || [ "$CUR_MODE" != "snat" ] || [ -n "$UPGRADE_TO" ]; }; then
    helm_cilium maglev snat "$CILIUM_VERSION" 2>/dev/null || true
    kc -n kube-system rollout restart ds/cilium >/dev/null 2>&1 || true
    kc -n kube-system rollout status ds/cilium --timeout=600s 2>&1 | sed 's/^/  /' || true
  fi
}
trap dz_cleanup EXIT

# ── Main ─────────────────────────────────────────────────────────────────────
case "$TARGET_NODE" in node1|node2|node3) ;; *) red "TARGET_NODE must be node1..3"; exit 2 ;; esac
for d in $DISRUPTIONS; do
  case "$d" in
    agent-restart|agent-kill|agent-delete|backend-kill) ;;
    agent-upgrade) [ -n "$UPGRADE_TO" ] || { red "agent-upgrade needs UPGRADE_TO=<version|latest>"; exit 2; } ;;
    *) red "unknown disruption '$d' (agent-restart agent-upgrade agent-kill agent-delete backend-kill)"; exit 2 ;;
  esac
done
installed=$(installed_cilium_version || true)
[ "$installed" = "$CILIUM_VERSION" ] \
  || yellow "  installed Cilium chart is ${installed:-unknown}, not ${CILIUM_VERSION}; the first helm upgrade moves it"
if [ "$UPGRADE_TO" = "latest" ]; then
  UPGRADE_TO=$(latest_patch)
  [ -n "$UPGRADE_TO" ] || { red "could not resolve the newest ${CILIUM_VERSION%.*}.x chart"; exit 1; }
fi
case " $DISRUPTIONS " in *" agent-upgrade "*)
  [ "$UPGRADE_TO" != "$CILIUM_VERSION" ] || { red "UPGRADE_TO equals CILIUM_VERSION (${CILIUM_VERSION}); nothing to upgrade"; exit 2; } ;;
esac

set -- $ALGOS;       n_a=$#
set -- $MODES;       n_m=$#
set -- $POLICIES;    n_p=$#
set -- $DISRUPTIONS; n_d=$#
n_cells=$(( n_a * n_m * n_p * n_d ))
info "Test 5 (Cilium disruption): ${n_cells} cells x ${RUNS} runs | Cilium ${CILIUM_VERSION}${UPGRADE_TO:+ -> ${UPGRADE_TO}}"
info "  algos=[${ALGOS}] modes=[${MODES}] policies(eTP:iTP)=[${POLICIES}] disruptions=[${DISRUPTIONS}]"
info "  target=${TARGET_NODE} ic_node=${IC_NODE} kill_count=${KILL_COUNT} N=${N}/population replicas=${REPLICAS}"
info "  max_unavailable=${MAX_UNAVAILABLE:-chart default} capture_pcap=${CAPTURE_PCAP} results=${RESULTS_DIR}"

if ! verify_bgp; then
  [ "$STRICT_BGP" = "1" ] && { red "STRICT_BGP=1: fix BGP first (bash scripts/apply-bgp-config.sh)"; exit 1; }
  yellow "  continuing anyway (STRICT_BGP=0); results won't reflect the 90s-hold prod setup"
fi
docker exec "${NODES[0]}" birdc show route "${VIP_STATIC}/32" protocol vip 2>/dev/null | grep -q "${VIP_STATIC}" \
  || yellow "  WARNING: bird isn't statically originating ${VIP_STATIC} (old bird.conf?) — ext-static isn't the BGP-unharmed control"

step "applying disruption services (.20 Cilium-originated, .21 bird-static) and spreading backends"
kc apply -f /opt/k8s/echo-disruption.yaml >/dev/null
for n in node1 node2 node3; do kc uncordon "$n" >/dev/null 2>&1 || true; done
kc -n default scale deploy/echo --replicas="$REPLICAS" >/dev/null
kc -n default rollout restart deploy/echo >/dev/null
kc -n default rollout status deploy/echo --timeout=180s 2>&1 | sed 's/^/  /'
docker cp "${REPO_ROOT}/tests/lib/flowgen/flowgen.py"   "${CLIENT}:/opt/flowgen/flowgen.py" >/dev/null
docker cp "${REPO_ROOT}/tests/lib/flowgen/connprobe.py" "${CLIENT}:/opt/flowgen/connprobe.py" >/dev/null
for n in "${NODES[@]}"; do docker cp "${REPO_ROOT}/tests/lib/pcap-reduce.sh" "${n}:/tmp/pcap-reduce.sh" >/dev/null; done
deploy_ic_client

for mode in $MODES; do
  for algo in $ALGOS; do
    apply_cilium "$algo" "$mode"
    for pol in $POLICIES; do
      etp="${pol%%:*}"; itp="${pol##*:}"
      set_policies "$etp" "$itp"
      for d in $DISRUPTIONS; do
        cell="dz_${d}_${algo}-${mode}_etp${etp}_itp${itp}"
        info "=== cell ${cell} ==="
        rm -f "${RESULTS_DIR}/${cell}.run"* 2>/dev/null || true
        for run in $(seq 1 "$RUNS"); do run_once "$cell" "$run" "$d" "$etp" "$itp"; done
      done
    done
  done
done

echo
green "================ Test 5: Cilium disruption summary ================"
python3 "${REPO_ROOT}/scripts/disruption-summary.py" "${RESULTS_DIR}" || yellow "summary failed"
green "Runtime: $(fmt_duration)"
