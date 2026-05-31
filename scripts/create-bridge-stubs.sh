#!/usr/bin/env bash
# Create stub bridge interfaces in WSL2's default netns for each Docker bridge network.
# Docker Desktop runs its daemon in a separate WSL distro (docker-desktop), so its bridges
# are not visible here via netlink. We create matching stubs so containerlab's ip-link
# lookup succeeds; actual container networking is still handled by Docker Desktop.
set -uo pipefail

# Remove any broken stubs from previous runs
for br in $(ip -br link show type bridge | awk '{print $1}' | grep -v "^docker0$"); do
  [ -n "$br" ] || continue
  # only remove stubs that have no Docker backing (Docker Desktop owns docker0 etc)
  if [[ "$br" == br-* ]]; then
    echo "  cleaning old stub $br"
    ip link del "$br" 2>/dev/null || true
  fi
done

# Create a stub bridge for every Docker bridge network
while read -r line; do
  NID=$(echo "$line" | cut -d' ' -f1)
  DRV=$(echo "$line" | cut -d' ' -f2)
  [ "$DRV" = "bridge" ] || continue
  [ -n "$NID" ] || continue
  BR="br-${NID:0:12}"
  if ip link show "$BR" &>/dev/null; then
    echo "  $BR already present"
  else
    ip link add "$BR" type bridge
    ip link set "$BR" up
    echo "  created $BR (for network $NID)"
  fi
done < <(docker network ls --format "{{.ID}} {{.Driver}}" 2>/dev/null)

echo "=== bridges visible in WSL2 ==="
ip -br link show type bridge
