#!/usr/bin/env bash
# bgp-verify.sh — show the NEGOTIATED hold/keepalive timers and graceful-restart state of
# every node BGP session (bird uplinks to the leaves, bird<->Cilium), from both ends.
#
# Prod mirror we expect: hold 90 everywhere, no BFD, GR not explicitly configured
# (bird: default "aware"/helper; FRR: default helper; Cilium: default disabled).
#
# Run directly (exit 1 if any session isn't Established at hold=$WANT_HOLD) or source it
# and call verify_bgp.
#   bash tests/lib/bgp-verify.sh
#   WANT_HOLD=90 bash tests/lib/bgp-verify.sh

verify_bgp() {
  local want="${WANT_HOLD:-90}" bad=0 n node p out hold ka
  info "BGP sessions (want negotiated hold=${want}s)"
  printf '  %-7s %-10s %-12s %-6s %-6s %s\n' node session state hold ka "neighbor GR capability"
  for n in "${NODES[@]}"; do
    node="${n#${PFX}-}"
    # bird names each dynamic session spawned by "neighbor range" dynbgp1, dynbgp2, ...
    local protos
    protos="uplink0 uplink1 $(docker exec "$n" birdc show protocols 2>/dev/null \
                              | awk '$1 ~ /^(dynbgp|cilium)[0-9]+$/ {print $1}' | tr '\n' ' ')"
    for p in $protos; do
      out=$(docker exec "$n" birdc show protocols all "$p" 2>/dev/null || true)
      local state; state=$(printf '%s\n' "$out" | awk '/BGP state:/ {print $3; exit}')
      hold=$(printf '%s\n' "$out" | grep -oE 'Hold timer: +[0-9.]+/[0-9]+' | sed 's#.*/##')
      ka=$(printf '%s\n' "$out" | grep -oE 'Keepalive timer: +[0-9.]+/[0-9]+' | sed 's#.*/##')
      # bird prints capability blocks as "Local capabilities" / "Neighbor capabilities";
      # "Graceful restart" appears in the neighbor block when the peer advertises GR.
      local ngr
      ngr=$(printf '%s\n' "$out" | awk '/Neighbor capabilities/ {f=1; next} f && /capabilities|Session:/ {f=0} f' \
            | grep -qi 'graceful restart' && echo "advertised" || echo "none")
      printf '  %-7s %-10s %-12s %-6s %-6s %s\n' "$node" "$p" "${state:-?}" "${hold:--}" "${ka:--}" "$ngr"
      if [ "${state:-}" != "Established" ] || [ "${hold:-}" != "$want" ]; then bad=1; fi
    done
    case "$protos" in *dynbgp*|*cilium[0-9]*) ;; *) printf '  %-7s %-10s %s\n' "$node" "cilium*" "NO SESSION"; bad=1 ;; esac
  done

  info "leaf side (FRR) of the node sessions"
  local leaf nb
  for leaf in "${LEAVES[@]}"; do
    local l="${leaf#${PFX}-leaf}"
    for nb in 1 3 5; do
      out=$(docker exec "$leaf" vtysh -c "show bgp neighbors 10.3.${l}.${nb}" 2>/dev/null || true)
      printf '  %-6s 10.3.%s.%-3s %s | %s\n' "leaf${l}" "$l" "$nb" \
        "$(printf '%s\n' "$out" | grep -m1 -oE 'Hold time is [0-9]+' || echo 'Hold time ?')" \
        "$(printf '%s\n' "$out" | grep -E 'GR Mode' | sed 's/^ *//' | tr '\n' ' ')"
    done
  done

  [ "$bad" -eq 0 ] && green "  all node BGP sessions Established at hold=${want}s" \
                   || red   "  some node BGP sessions are down or not at hold=${want}s (see table)"
  return "$bad"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -uo pipefail
  . "$(dirname "$0")/common.sh"
  set +e
  verify_bgp
  exit $?
fi
