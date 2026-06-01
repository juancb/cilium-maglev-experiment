#!/usr/bin/env bash
# Show TC BPF programs on each node
for NODE in clab-maglev-clos-node1 clab-maglev-clos-node2 clab-maglev-clos-node3; do
  echo "=== $NODE ==="
  docker exec "$NODE" bash -c '
    for dev in $(ip -o link show | awk -F"[ :]" "{print \$3}"); do
      out=$(tc filter show dev "$dev" ingress 2>/dev/null)
      [ -n "$out" ] && echo "  $dev: $out" | head -3
    done
  '
  echo ""
done
