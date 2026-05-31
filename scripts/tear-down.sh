#!/usr/bin/env bash
# Full lab tear-down. Mirrors the cleanup at the top of bring-up.sh.
# Run as root from WSL Ubuntu-24.04:  bash scripts/tear-down.sh  (or: make down)
set -euo pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
TOPO="${REPO}/topo/clos.clab.yml"

red()   { echo -e "\033[31m$*\033[0m"; }
green() { echo -e "\033[32m$*\033[0m"; }
info()  { echo -e "\033[36m==> $*\033[0m"; }

[[ $(id -u) -eq 0 ]] || { red "ERROR: must run as root (wsl -u root)"; exit 1; }

info "stopping node containers (not managed by containerlab)..."
docker rm -f clab-maglev-clos-node1 clab-maglev-clos-node2 clab-maglev-clos-node3 2>/dev/null || true

info "destroying containerlab topology..."
CLAB_VERSION_CHECK=disable containerlab destroy --topo "$TOPO" 2>/dev/null || true

info "removing management network..."
docker network rm maglev-mgmt 2>/dev/null || true

green "lab torn down."
