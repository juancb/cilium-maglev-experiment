#!/usr/bin/env bash
# Shared helpers for the test scripts. Source this: . "$(dirname "$0")/lib/common.sh"
set -euo pipefail

# The lab runs on the native Docker CE daemon (scripts/install-native-docker.sh), which
# listens on docker-native.sock because Docker Desktop's WSL proxy owns docker.sock.
[ -S /var/run/docker-native.sock ] && export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker-native.sock}"

LAB="maglev-clos"
PFX="clab-${LAB}"

# container names
TOR="${PFX}-tor"
SPINES=("${PFX}-spine1" "${PFX}-spine2" "${PFX}-spine3")
LEAVES=("${PFX}-leaf1" "${PFX}-leaf2")
NODES=("${PFX}-node1" "${PFX}-node2" "${PFX}-node3")
CLIENT="${PFX}-client"

# Cilium chart version for EVERY helm install/upgrade in the lab. An unpinned
# `helm upgrade` silently moves the cluster to the repo's newest chart.
CILIUM_VERSION="${CILIUM_VERSION:-1.19.1}"

VIP="192.0.2.10"
VIP_PORT="8080"
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RESULTS_DIR="${REPO_ROOT}/results"
mkdir -p "${RESULTS_DIR}"

# kubectl against node1's k3s
kc() { docker exec "${PFX}-node1" k3s kubectl "$@"; }

# run a vtysh command on an FRR container
frr() { local c="$1"; shift; docker exec "$c" vtysh -c "$*"; }

# colourised output
green() { printf '\033[32m%s\033[0m\n' "$*"; }
red()   { printf '\033[31m%s\033[0m\n' "$*"; }
yellow(){ printf '\033[33m%s\033[0m\n' "$*"; }
ok()    { green "  PASS: $*"; }
bad()   { red   "  FAIL: $*"; FAILED=1; }
info()  { yellow "[*] $*"; }

# timestamped progress line (uses the caller's $SECONDS if set, else wall clock offset)
step() { printf '\033[36m  [%3ds] %s\033[0m\n' "${SECONDS:-0}" "$*"; }

fmt_duration() {
  local s="${1:-${SECONDS:-0}}"
  local m=$(( s / 60 )) r=$(( s % 60 ))
  [ "$m" -gt 0 ] && printf '%dm %02ds' "$m" "$r" || printf '%ds' "$r"
}

# wait until all bird uplink BGP sessions on a node are Established
wait_node_bgp() {
  local node="$1" tries="${2:-60}"
  local elapsed=0
  for _ in $(seq 1 "$tries"); do
    if docker exec "$node" birdc show protocols 2>/dev/null | grep -qE 'uplink0.*Established' \
       && docker exec "$node" birdc show protocols 2>/dev/null | grep -qE 'uplink1.*Established'; then
      return 0
    fi
    elapsed=$(( elapsed + 2 ))
    [ $(( elapsed % 10 )) -eq 0 ] && step "waiting for bird uplinks on $(basename "$node")... (${elapsed}s)"
    sleep 2
  done
  return 1
}

# wait until the VIP is a multipath route at the leaf (≥2 nexthops)
wait_vip_ecmp() {
  local max_secs="${1:-120}"
  local elapsed=0
  for _ in $(seq 1 "$max_secs"); do
    local n
    n=$(frr "${LEAVES[0]}" "show ip route ${VIP}/32" 2>/dev/null | grep -cE '^\s+\* 10\.' || true)
    [ "${n:-0}" -ge 2 ] && return 0
    elapsed=$(( elapsed + 1 ))
    [ $(( elapsed % 5 )) -eq 0 ] && step "VIP ECMP: ${n:-0} nexthops at leaf1, need ≥2 (${elapsed}s)"
    sleep 1
  done
  return 1
}

# wait until all k8s nodes are Ready and all cilium-agent pods are 1/1 Running
wait_cilium_ready() {
  local tries="${1:-90}"
  local max_secs=$(( tries * 3 ))
  local N1="${PFX}-node1"
  info "waiting for all nodes Ready + Cilium 1/1..."
  local elapsed=0
  for _ in $(seq 1 "$max_secs"); do
    local nodes_not_ready cilium_not_ready
    nodes_not_ready=$(docker exec "$N1" k3s kubectl get nodes --no-headers 2>/dev/null \
      | grep -cv ' Ready ' || true)
    cilium_not_ready=$(docker exec "$N1" k3s kubectl -n kube-system get pods \
      -l app.kubernetes.io/name=cilium-agent --no-headers 2>/dev/null \
      | grep -cv '1/1.*Running' || true)
    [ "${nodes_not_ready:-1}" -eq 0 ] && [ "${cilium_not_ready:-1}" -eq 0 ] && return 0
    elapsed=$(( elapsed + 1 ))
    if [ $(( elapsed % 10 )) -eq 0 ]; then
      step "still waiting: ${nodes_not_ready} node(s) not Ready, ${cilium_not_ready} cilium pod(s) not 1/1 (${elapsed}s)"
    fi
    sleep 1
  done
  yellow "  WARNING: cluster not fully ready after ${max_secs}s"
  return 1
}
