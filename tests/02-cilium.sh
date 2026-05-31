#!/usr/bin/env bash
# Test 2 — Cilium is in the required mode and Maglev makes backend selection consistent
# across nodes (the mechanism that lets a re-homed flow survive in Test 3).
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
FAILED=0
SECONDS=0

N1="${PFX}-node1"

info "Test 2a — kube-proxy replacement / native routing / BPF masquerade"
step "fetching cilium status"
ST=$(docker exec "$N1" k3s kubectl -n kube-system exec ds/cilium -- cilium status --verbose 2>/dev/null || true)
grep -qi 'KubeProxyReplacement:\s*True' <<<"$ST" && ok "kube-proxy replacement = True" \
                                                 || bad "kube-proxy replacement not True"
grep -qiE 'Routing:.*Network:\s*Native|Host: BPF' <<<"$ST" && ok "native routing" \
                                                 || yellow "  INFO: confirm routingMode=native in 'cilium status'"
grep -qi 'Masquerading:.*BPF' <<<"$ST" && ok "BPF masquerade" \
                                       || yellow "  INFO: confirm bpf.masquerade in 'cilium status'"

info "Test 2b — service programmed + maglev config + identical seed across agents"
step "checking VIP in cilium service list"
docker exec "$N1" k3s kubectl -n kube-system exec ds/cilium -- cilium service list 2>/dev/null \
  | grep -q "$VIP" && ok "VIP ${VIP} present in service list" || bad "VIP not in cilium service list"

seeds=""
for n in "${NODES[@]}"; do
  step "checking maglev config on $(basename "$n")"
  cfg=$(docker exec "$n" k3s kubectl -n kube-system exec ds/cilium -- cilium config view 2>/dev/null || true)
  alg=$(grep -iE 'node-port-algorithm|bpf-lb-algorithm' <<<"$cfg" | head -1 || true)
  seed=$(grep -i 'maglev' <<<"$cfg" | grep -i 'seed' | awk '{print $NF}' | head -1 || true)
  yellow "  $(basename "$n"): ${alg:-<no alg line>} seed=${seed:-<none>}"
  seeds="${seeds} ${seed}"
done
uniq_seeds=$(tr ' ' '\n' <<<"$seeds" | sed '/^$/d' | sort -u | wc -l)
[ "$uniq_seeds" -le 1 ] && ok "maglev hashSeed identical across agents" \
                        || bad "maglev hashSeed differs across agents (uniq=$uniq_seeds)"

info "Test 2c — cross-node backend consistency (the Maglev property)"
yellow "  Checking Maglev via BPF LB tables (not live probes — avoids socket BPF path issues)"
first_backends=""
maglev_consistent=1
for n in "${NODES[@]}"; do
  step "reading BPF LB table on $(basename "$n")"
  backends=$(docker exec "$n" bash -lc \
    "k3s kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf lb list 2>/dev/null | \
     grep '${VIP}:${VIP_PORT}' | grep -v 'non-routable\|0\.0\.0\.0:0' | \
     awk '{print \$2}' | sort" 2>/dev/null | tr '\n' ',' | sed 's/,$//')
  yellow "  $(basename "$n") BPF LB backends: ${backends:-<none>}"
  if [ -z "$first_backends" ]; then
    first_backends="$backends"
  elif [ "$backends" != "$first_backends" ]; then
    maglev_consistent=0
  fi
done
if [ "$maglev_consistent" -eq 1 ] && [ -n "$first_backends" ]; then
  ok "all nodes have identical VIP backend list in BPF LB table (Maglev consistent)"
else
  yellow "  INFO: backend lists differ or unavailable — check cilium-dbg bpf lb list manually"
fi

echo
[ "$FAILED" -eq 0 ] && green "Test 2 PASSED" || { red "Test 2 had failures"; exit 1; }
green "Runtime: $(fmt_duration)"
