#!/usr/bin/env bash
# Prepare cgroupv2 on a node container so k3s can create its kubepods hierarchy.
# In Docker containers (cgroupns=private), the container's root cgroup already has
# processes (PID 1 etc.), which blocks k3s from creating domain child cgroups (cgroupv2
# "no internal processes" rule). Fix: move all processes to system.slice first.
#
# Usage:  bash prepare-node-cgroup.sh <container-name>
set -uo pipefail
CONTAINER="${1:?container name required}"

docker exec "$CONTAINER" bash -s <<'INNER'
set -uo pipefail
CROOT="/sys/fs/cgroup"
DEST="${CROOT}/system.slice"

# bail if not cgroupv2
[ -f "${CROOT}/cgroup.controllers" ] || { echo "no cgroupv2, nothing to do"; exit 0; }

echo "[cgroup] creating ${DEST}"
mkdir -p "$DEST"

# snapshot PIDs before we start moving (avoid TOCTOU as file shrinks)
mapfile -t PIDS < "${CROOT}/cgroup.procs"
echo "[cgroup] moving ${#PIDS[@]} PIDs from root to system.slice"
moved=0; failed=0
for pid in "${PIDS[@]}"; do
  [ -n "$pid" ] || continue
  if echo "$pid" > "${DEST}/cgroup.procs" 2>/dev/null; then
    ((moved++)) || true
  else
    ((failed++)) || true
  fi
done
echo "[cgroup] moved=${moved} failed=${failed}"

remaining=$(wc -l < "${CROOT}/cgroup.procs" || echo "?")
echo "[cgroup] root cgroup procs remaining: ${remaining}"

# Now enable controllers at root (works only if root is empty)
if [ "${remaining:-1}" -eq 0 ]; then
  CTLS=$(cat "${CROOT}/cgroup.controllers" 2>/dev/null || true)
  PLUS=$(echo "$CTLS" | sed 's/[a-z_]*/+&/g' | tr '\n' ' ')
  echo "${PLUS}" > "${CROOT}/cgroup.subtree_control" 2>/dev/null \
    && echo "[cgroup] subtree_control enabled: ${CTLS}" \
    || echo "[cgroup] WARN: could not enable subtree_control (non-fatal)"
  # verify k3s can create kubepods
  mkdir -p "${CROOT}/kubepods" 2>/dev/null \
    && echo "[cgroup] kubepods cgroup created OK" \
    || echo "[cgroup] WARN: could not create kubepods"
else
  echo "[cgroup] WARN: root still has ${remaining} procs — k3s may hit cgroup errors"
  cat "${CROOT}/cgroup.procs" | while read p; do
    cat /proc/$p/comm 2>/dev/null | xargs echo "  still-in-root: pid=$p"
  done
fi
INNER

