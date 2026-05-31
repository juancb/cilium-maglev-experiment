#!/usr/bin/env bash
# Debug script: watch who writes to subtree_control while k3s starts, then show kubepods state.
# Run BEFORE cluster-up on a clean container. Output shows the root cause.
set -uo pipefail
TOR="clab-maglev-clos-node1"

echo "=== current state ==="
docker exec "$TOR" bash -c 'echo "subtree_control: $(cat /sys/fs/cgroup/cgroup.subtree_control)"; echo "procs: $(wc -l < /sys/fs/cgroup/cgroup.procs)"'

echo "=== clearing subtree_control now ==="
docker exec "$TOR" bash -c 'echo "-cpuset -cpu -io -memory -hugetlb -pids -rdma" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null; echo "subtree_control now: $(cat /sys/fs/cgroup/cgroup.subtree_control)"'

echo "=== starting inotifywait watcher in background ==="
docker exec -d "$TOR" bash -c 'inotifywait -m -e modify /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null | while read e; do echo "[$(date +%T)] MODIFIED: $(cat /sys/fs/cgroup/cgroup.subtree_control) | pids=$(wc -l < /sys/fs/cgroup/cgroup.procs)"; done >> /tmp/cgroup_trace.log'

echo "=== starting k3s server (will fail, that is expected) ==="
docker exec -d "$TOR" bash -lc 'k3s server --flannel-backend=none --disable-kube-proxy --disable=traefik --disable=servicelb --disable=local-storage --cluster-cidr 10.244.0.0/16 --service-cidr 10.96.0.0/16 --node-ip 10.10.0.1 --advertise-address 10.10.0.1 --tls-san 10.10.0.1 --snapshotter=native >/var/log/k3s-debug.log 2>&1'

echo "=== waiting 15s for k3s to touch cgroup ==="
sleep 15

echo "=== cgroup trace ==="
docker exec "$TOR" cat /tmp/cgroup_trace.log 2>/dev/null || echo "(no trace)"

echo "=== k3s log tail ==="
docker exec "$TOR" tail -5 /var/log/k3s-debug.log 2>/dev/null
