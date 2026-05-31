#!/usr/bin/env bash
# Watch cgroup.subtree_control in node1 for 30 seconds after clearing it.
# Shows whether Docker re-sets it and how quickly.
docker exec clab-maglev-clos-node1 bash -c '
echo "clearing subtree_control now"
echo "-cpuset -cpu -io -memory -hugetlb -pids -rdma" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
echo "cleared to: $(cat /sys/fs/cgroup/cgroup.subtree_control)"
PREV=""
for i in $(seq 1 60); do
  STC=$(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null)
  if [ "$STC" != "$PREV" ]; then
    echo "[${i}x0.5s] subtree_control changed: \"${PREV}\" -> \"${STC}\""
    PREV="$STC"
  fi
  sleep 0.5
done
echo "final: $(cat /sys/fs/cgroup/cgroup.subtree_control)"
'
