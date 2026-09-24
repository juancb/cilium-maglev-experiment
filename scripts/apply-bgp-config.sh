#!/usr/bin/env bash
# Push the BGP timer/GR config (90s hold, no explicit GR) and the bird-static disruption VIP
# into a RUNNING lab without a redeploy, then verify. A fresh `make up` picks all of this up
# from the repo files anyway.
#
#   bird  : birdc configure (re-reads the bind-mounted /etc/bird/bird.conf)
#   FRR   : per-neighbor "timers 30 90" on the leaves' node-facing sessions + hard clear
#   Cilium: re-apply k8s/cilium-bgp.yaml (PeerConfig timers, GR block removed)
#
# Resets every node BGP session once. Don't run it in the middle of a test.
set -euo pipefail
. "$(dirname "$0")/../tests/lib/common.sh"
. "${REPO_ROOT}/tests/lib/bgp-verify.sh"

info "bird: reconfigure from bind-mounted config"
for id in 1 2 3; do
  n="${PFX}-node${id}"
  # a single-file bind mount goes stale if the host file was replaced (new inode); catch that
  want=$(md5sum "${REPO_ROOT}/nodes/bird/node${id}.conf" | cut -d' ' -f1)
  have=$(docker exec "$n" md5sum /etc/bird/bird.conf | cut -d' ' -f1)
  if [ "$want" != "$have" ]; then
    red "  node${id}: container sees a stale bird.conf (bind mount lost the file) — run 'make redeploy'"
    exit 1
  fi
  docker exec "$n" birdc configure | sed "s/^/  node${id}: /"
done

info "FRR leaves: node-facing neighbors → timers 30 90"
for l in 1 2; do
  leaf="${PFX}-leaf${l}"
  args=(-c "configure terminal" -c "router bgp 6501${l}")
  for nb in 1 3 5; do args+=(-c "neighbor 10.3.${l}.${nb} timers 30 90"); done
  docker exec "$leaf" vtysh "${args[@]}"
  # timers are only renegotiated on a new OPEN
  for nb in 1 3 5; do docker exec "$leaf" vtysh -c "clear bgp 10.3.${l}.${nb}"; done
done

info "Cilium: apply BGP peer config"
kc apply -f /opt/k8s/cilium-bgp.yaml

info "waiting for sessions to re-establish"
for n in "${NODES[@]}"; do wait_node_bgp "$n" 60 || true; done
sleep 10
verify_bgp
