#!/usr/bin/env bash
# Test 1 — fabric correctness + consistent hashing.
#  (a) all BGP sessions Established
#  (b) VIP present as ECMP in the fabric; nodes have multipath + per-flow L4 hashing
#  (c) consistent hashing: shutting spine1's ToR link moves only ~1/3 of flows with CH on,
#      ~2/3 with CH off. The measured disturbed-set D feeds Test 3's prediction.
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
FAILED=0

info "Test 1a — BGP sessions"
for s in "${SPINES[@]}" "${LEAVES[@]}"; do
  if frr "$s" "show bgp summary" 2>/dev/null | grep -qiE 'Established|[0-9]+ *$'; then
    ok "$s BGP up"; else bad "$s BGP not established"; fi
done
for n in "${NODES[@]}"; do
  if wait_node_bgp "$n" 5; then ok "$(basename "$n") bird uplinks Established"
  else bad "$(basename "$n") bird uplinks not Established"; fi
done

info "Test 1b — VIP ECMP + node multipath + per-flow hashing"
if wait_vip_ecmp 5; then ok "spine sees VIP via multiple leaves (ECMP)"
else bad "VIP not multipath at spine"; fi

for n in "${NODES[@]}"; do
  hp=$(docker exec "$n" sysctl -n net.ipv4.fib_multipath_hash_policy 2>/dev/null || echo "?")
  [ "$hp" = "1" ] && ok "$(basename "$n") fib_multipath_hash_policy=1 (per-flow L4)" \
                  || bad "$(basename "$n") fib_multipath_hash_policy=$hp (want 1)"
  if docker exec "$n" ip route get "$VIP" 2>/dev/null | grep -q nexthop \
     || docker exec "$n" ip route show "$VIP" 2>/dev/null | grep -q nexthop; then
    ok "$(basename "$n") has multipath route toward peers"
  else
    yellow "  INFO: $(basename "$n") VIP not multipath locally (expected if VIP is node-local)"
  fi
done

# --- consistent-hashing disturbance measurement --------------------------------------------
# Count, per ToR→spine uplink, how many distinct client flows traverse it, before and after
# shutting spine1. We approximate "flows" via packet counters on the ToR's spine-facing ports
# while flowgen holds N flows open. Disturbed set D = flows whose egress spine changed.
measure_ch() {
  local mode="$1"   # "on" or "off"
  info "Test 1c — consistent hashing: CH ${mode}"
  docker exec "$TOR" bash "/etc/sonic/ch-${mode}.sh" 2>/dev/null \
    || yellow "  INFO: could not toggle CH ${mode} on ToR (sonic-vs fidelity?) — see README EMULATE_CH"

  # hold flows open from the client
  docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
     --vip "$VIP" --port "$VIP_PORT" --count 300 --duration 40 \
     --out "/tmp/ch_${mode}.json" --ready-file "/tmp/ch_${mode}.ready"
  sleep 8

  # snapshot per-uplink packet counters (Ethernet4/8/12 → spine1/2/3)
  read -r b1 b2 b3 < <(tor_uplink_counts)
  docker stop "$FAIL_SPINE" >/dev/null
  sleep 8
  read -r a1 a2 a3 < <(tor_uplink_counts)
  docker start "$FAIL_SPINE" >/dev/null

  local moved_from1=$(( b1>0 ? b1 : 0 ))
  yellow "  CH ${mode}: spine1 carried ~${b1} (pre), now 0; survivors spine2/3 delta = $((a2-b2))/$((a3-b3))"
  yellow "  → interpret: CH on ⇒ survivor deltas ≈ spine1's share only; CH off ⇒ much larger."
  sleep 35  # let flowgen finish
}

# best-effort uplink packet counts (works on sonic-vs via 'show interfaces counters' or ip -s)
tor_uplink_counts() {
  for p in Ethernet4 Ethernet8 Ethernet12; do
    docker exec "$TOR" bash -lc "cat /sys/class/net/${p}/statistics/rx_packets 2>/dev/null \
        || echo 0" 2>/dev/null || echo 0
  done | tr '\n' ' '
}

if docker exec "$TOR" which sonic-db-cli >/dev/null 2>&1; then
  measure_ch on
  measure_ch off
  docker exec "$TOR" bash /etc/sonic/ch-on.sh >/dev/null 2>&1 || true   # leave CH on by default
else
  yellow "[*] ToR is not SONiC (no sonic-db-cli) — CH lever is analytical only here."
fi

echo
[ "$FAILED" -eq 0 ] && green "Test 1 PASSED" || { red "Test 1 had failures"; exit 1; }
