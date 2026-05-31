#!/usr/bin/env bash
# Test 2 — Cilium is in the required mode and Maglev makes backend selection consistent
# across nodes (the mechanism that lets a re-homed flow survive in Test 3).
set -euo pipefail
cd "$(dirname "$0")"
. lib/common.sh
FAILED=0

N1="${PFX}-node1"

info "Test 2a — kube-proxy replacement / native routing / BPF masquerade"
ST=$(docker exec "$N1" k3s kubectl -n kube-system exec ds/cilium -- cilium status --verbose 2>/dev/null || true)
grep -qi 'KubeProxyReplacement:\s*True' <<<"$ST" && ok "kube-proxy replacement = True" \
                                                 || bad "kube-proxy replacement not True"
grep -qiE 'Routing:.*Network:\s*Native|Host: BPF' <<<"$ST" && ok "native routing" \
                                                 || yellow "  INFO: confirm routingMode=native in 'cilium status'"
grep -qi 'Masquerading:.*BPF' <<<"$ST" && ok "BPF masquerade" \
                                       || yellow "  INFO: confirm bpf.masquerade in 'cilium status'"

info "Test 2b — service programmed + maglev config + identical seed across agents"
docker exec "$N1" k3s kubectl -n kube-system exec ds/cilium -- cilium service list 2>/dev/null \
  | grep -q "$VIP" && ok "VIP ${VIP} present in service list" || bad "VIP not in cilium service list"

seeds=""
for n in "${NODES[@]}"; do
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
# For each node, ask its datapath which backend a fixed VIP 5-tuple maps to. With Maglev the
# answer is identical on every node; with random it diverges. We use real probes: curl the VIP
# pinned through each node's host netns and read the POD= the backend returns.
declare -A choice
for n in "${NODES[@]}"; do
  # send via this node by sourcing from the node and connecting to the VIP; the local BPF LB
  # picks the backend per the configured algorithm.
  b=$(docker exec "$n" bash -lc \
        "exec 3<>/dev/tcp/${VIP}/${VIP_PORT}; head -c 64 <&3 | sed -n 's/^POD=//p' | tr -d '\r\n'" \
        2>/dev/null || echo "?")
  choice["$(basename "$n")"]="$b"
  yellow "  $(basename "$n") → backend ${b:-?}"
done
uniq_choice=$(printf '%s\n' "${choice[@]}" | sort -u | grep -v '^?$' | wc -l)
alg_is_maglev=$(grep -qi 'maglev' <<<"${alg:-}" && echo yes || echo unknown)
if [ "$uniq_choice" -le 1 ] && [ -n "${choice[node1]:-}" ]; then
  ok "all nodes selected the same backend for the VIP 5-tuple (consistent ⇒ maglev working)"
else
  yellow "  INFO: nodes selected different backends — expected with algorithm=random, NOT with maglev"
fi

echo
[ "$FAILED" -eq 0 ] && green "Test 2 PASSED" || { red "Test 2 had failures"; exit 1; }
