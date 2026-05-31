#!/usr/bin/env bash
# Pre-create stub bridges in WSL2's default netns for each Docker management network so
# containerlab's netlink bridge lookup succeeds. Docker Desktop's actual container networking
# doesn't use these stubs — it routes containers itself. We just satisfy the lookup.
#
# Usage: bash scripts/wsl-bridge-stub.sh [network-name...]
# Default: stubs for every Docker bridge network that lacks a visible interface.
set -uo pipefail

NETS=("${@:-}")
if [ "${#NETS[@]}" -eq 0 ]; then
  mapfile -t NETS < <(docker network ls --filter driver=bridge -q 2>/dev/null)
fi

for NID in "${NETS[@]}"; do
  if [ ${#NID} -lt 12 ]; then
    NID=$(docker network inspect "$NID" --format '{{.Id}}' 2>/dev/null || true)
  fi
  BRNAME="br-${NID:0:12}"
  if ip link show "$BRNAME" &>/dev/null; then
    echo "  $BRNAME already present — skipping"
  else
    echo "  creating stub bridge $BRNAME"
    ip link add "$BRNAME" type bridge
    ip link set "$BRNAME" up
  fi
done
echo "done ($(ip -br link show type bridge | wc -l) bridge(s) now visible)"
