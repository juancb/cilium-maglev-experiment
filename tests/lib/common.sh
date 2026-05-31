#!/usr/bin/env bash
# Shared helpers for the test scripts. Source this: . "$(dirname "$0")/lib/common.sh"
set -euo pipefail

LAB="maglev-clos"
PFX="clab-${LAB}"

# container names
TOR="${PFX}-tor"
SPINES=("${PFX}-spine1" "${PFX}-spine2" "${PFX}-spine3")
LEAVES=("${PFX}-leaf1" "${PFX}-leaf2")
NODES=("${PFX}-node1" "${PFX}-node2" "${PFX}-node3")
CLIENT="${PFX}-client"

VIP="192.0.2.10"
VIP_PORT="8080"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS_DIR="${REPO_ROOT}/results"
mkdir -p "${RESULTS_DIR}"

# kubectl against node1's k3s
kc() { docker exec "${PFX}-node1" k3s kubectl "$@"; }

# run a vtysh command on an FRR container
frr() { local c="$1"; shift; docker exec "$c" vtysh -c "$*"; }

# colourised pass/fail
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
ok()   { green "  PASS: $*"; }
bad()  { red   "  FAIL: $*"; FAILED=1; }
info() { yellow "[*] $*"; }

# wait until all bird uplink + leaf BGP sessions to a node are Established
wait_node_bgp() {
  local node="$1" tries="${2:-60}"
  for _ in $(seq 1 "$tries"); do
    if docker exec "$node" birdc show protocols 2>/dev/null | grep -qE 'uplink0.*Established' \
       && docker exec "$node" birdc show protocols 2>/dev/null | grep -qE 'uplink1.*Established'; then
      return 0
    fi
    sleep 2
  done
  return 1
}

# wait until the VIP is a multipath route at the leaf (leaf has per-node ECMP; drops when a
# node fails, restores when it recovers — more reliable signal than spine-level ECMP)
wait_vip_ecmp() {
  local tries="${1:-60}"
  for _ in $(seq 1 "$tries"); do
    local n
    # FRR 9.1 format: "* 10.3.1.1, via eth4, weight 1" (nexthop before "via")
    n=$(frr "${LEAVES[0]}" "show ip route ${VIP}/32" 2>/dev/null | grep -cE '^\s+\* 10\.' || true)
    [ "${n:-0}" -ge 2 ] && return 0
    sleep 2
  done
  return 1
}

# We fail a NODE (not a spine) because spine failures don't change the ingress node in
# a CLOS fabric — per-flow ECMP is deterministic at each tier so same 5-tuple → same leaf
# → same node regardless of spine. A node failure forces flow re-homing to a different
# ingress node, which is what exercises Maglev backend consistency.
# node2 has no echo pods (all pods are on node3), so it can be stopped safely.
FAIL_SPINE="${PFX}-node2"
