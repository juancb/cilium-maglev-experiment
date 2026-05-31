#!/usr/bin/env bash
# Full lab bring-up.  Run as root from WSL Ubuntu-24.04.
# Usage:
#   bash scripts/bring-up.sh           # full fresh start (normal path)
#   bash scripts/bring-up.sh --skip-k3s  # fabric + nodes only, no k3s/Cilium
#
# Sequence:
#   1. containerlab deploy  — creates fabric + node-facing veths in host ns, then hangs
#                             on ext-container lookup; killed once veths appear (~10 s)
#   2. start-nodes.sh       — create node containers (cgroupns=host)
#   3. fix-node-veths.sh    — move veths from host ns → node containers
#   4. run-node-startup.sh  — addressing, cgroups, bird on each node
#   5. cluster-up.sh        — k3s server+agents, Cilium, demo app
#
# Why this order:  containerlab's ext-container kind creates the node-facing veth pairs
# (leaf side in the container, node side in the HOST ns as a placeholder) and then
# retries for ~3 min trying to move the host-side end into the missing container.
# By killing the deploy once the veth pairs exist we avoid the 3-minute wait.
# fix-node-veths.sh then moves them into the real node containers.
#
# The deploy MUST run BEFORE start-nodes.sh because removing node containers (which
# start-nodes.sh does on recreation) destroys any veths already inside them.
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
LAB="maglev-clos"
TOPO="${REPO}/topo/clos.clab.yml"

SKIP_K3S=false
for arg in "$@"; do
  case "$arg" in
    --skip-k3s) SKIP_K3S=true ;;
  esac
done

red()    { echo -e "\033[31m$*\033[0m"; }
green()  { echo -e "\033[32m$*\033[0m"; }
yellow() { echo -e "\033[33m$*\033[0m"; }
info()   { echo -e "\033[36m==> $*\033[0m"; }
die()    { red "ERROR: $*"; exit 1; }

# ── 0. Prerequisites ──────────────────────────────────────────────────────────
[[ $(id -u) -eq 0 ]] || die "must run as root (wsl -u root)"
command -v containerlab >/dev/null || die "containerlab not found"
command -v docker       >/dev/null || die "docker not found"
docker info >/dev/null 2>&1        || die "docker daemon not running"

# ── 1. Ensure management network exists ──────────────────────────────────────
info "ensuring maglev-mgmt network"
docker network create maglev-mgmt --subnet 172.30.0.0/24 2>/dev/null || true

# ── 2. containerlab deploy (background, killed once veth pairs appear) ────────
# Destroy any leftover state first (idempotent; ignore errors)
info "destroying any existing lab state"
containerlab destroy --topo "$TOPO" 2>/dev/null || true
# Also remove node containers (not managed by containerlab; destroy doesn't touch them)
docker rm -f clab-maglev-clos-node1 clab-maglev-clos-node2 clab-maglev-clos-node3 2>/dev/null || true

mkdir -p "${REPO}/logs"
info "starting containerlab deploy in background"
containerlab deploy --topo "$TOPO" >"${REPO}/logs/clab-deploy.log" 2>&1 &
CLAB_PID=$!

# Wait for leaf1:eth4/5/6 to appear.  Containerlab creates the node-facing veth pairs
# (leaf end in container, node end in host ns) then enters the ext-container retry loop.
# We only need the pairs to exist; we don't need containerlab to move them.
info "waiting for leaf1 eth4/5/6 (node-facing veth pairs)..."
deadline=$(( $(date +%s) + 90 ))
while true; do
  if docker exec clab-maglev-clos-leaf1 ip link show eth4 >/dev/null 2>&1 && \
     docker exec clab-maglev-clos-leaf1 ip link show eth5 >/dev/null 2>&1 && \
     docker exec clab-maglev-clos-leaf1 ip link show eth6 >/dev/null 2>&1; then
    green "veth pairs present on leaf1"
    break
  fi
  if [[ $(date +%s) -ge $deadline ]]; then
    kill -9 "$CLAB_PID" 2>/dev/null || true
    die "timed out waiting for leaf1 eth4/5/6 — check ${REPO}/logs/clab-deploy.log"
  fi
  sleep 2
done

# SIGKILL containerlab — SIGTERM triggers its cleanup handler which removes the
# containers it just created.  SIGKILL bypasses the handler; containers persist.
kill -9 "$CLAB_PID" 2>/dev/null || true
wait "$CLAB_PID" 2>/dev/null || true
green "containerlab deploy killed (fabric links created)"

# ── 3. Create node containers ─────────────────────────────────────────────────
info "creating k8s node containers"
bash "${REPO}/scripts/start-nodes.sh"

# ── 4. Wire fabric veths into node containers ─────────────────────────────────
info "moving fabric veths into node containers"
bash "${REPO}/scripts/fix-node-veths.sh"

# ── 5. Start bird + networking on each node ───────────────────────────────────
info "starting node networking (addressing, cgroups, bird)"
bash "${REPO}/scripts/run-node-startup.sh"

# ── 6. k3s + Cilium + demo app ────────────────────────────────────────────────
if $SKIP_K3S; then
  yellow "skipping k3s/Cilium (--skip-k3s)"
  green "fabric is up. run 'bash scripts/cluster-up.sh' when ready."
else
  info "starting k3s cluster, installing Cilium, deploying demo app"
  bash "${REPO}/scripts/cluster-up.sh"
fi

green "lab is up."
