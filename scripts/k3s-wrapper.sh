#!/usr/bin/env bash
# Wrapper: keep cgroup subtree_control cleared while k3s starts, then let it manage itself.
# The race: k3s's embedded containerd re-sets subtree_control before kubelet runs, causing
# the "domain invalid" error on kubepods creation.
# We run a background loop to keep clearing it until k3s's ContainerManager has passed init.
set -uo pipefail
ROLE="${1:-server}"  # server or agent
shift

# Start subtree_control clearing loop
( while true; do
    echo "" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
    sleep 0.05
  done ) &
LOOP_PID=$!

echo "[k3s-wrapper] cleared subtree_control loop running (pid ${LOOP_PID})"
echo "[k3s-wrapper] starting k3s ${ROLE} $*"

# Run k3s; it will succeed once kubepods passes init
if [ "$ROLE" = "server" ]; then
  k3s server "$@" &
else
  k3s agent "$@" &
fi
K3S_PID=$!

# Wait until k3s kubelet ContainerManager is past init (kubepods exists or k3s has been up 30s)
echo "[k3s-wrapper] waiting for k3s to initialize cgroup hierarchy..."
for _ in $(seq 1 60); do
  if [ -d /sys/fs/cgroup/kubepods ] || \
     k3s kubectl get nodes --no-headers 2>/dev/null | grep -q Ready; then
    echo "[k3s-wrapper] k3s initialized — stopping subtree_control clear loop"
    break
  fi
  sleep 1
done

kill "$LOOP_PID" 2>/dev/null || true
echo "[k3s-wrapper] loop stopped"

# Wait for k3s to exit (it should not — this is a daemon)
wait "$K3S_PID"
