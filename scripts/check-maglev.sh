#!/usr/bin/env bash
N1="clab-maglev-clos-node1"
KC() { docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" k3s kubectl "$@"; }

echo "=== cilium-config: LB/algorithm keys ==="
KC -n kube-system get cm cilium-config -o go-template='{{range $k,$v := .data}}{{printf "%s: %s\n" $k $v}}{{end}}' \
  | grep -iE "maglev|algorithm|lb-|loadbalancer" | sort

echo
echo "=== cilium status (LB section) ==="
docker exec "$N1" cilium-dbg status --verbose 2>/dev/null | grep -iE "maglev|algorithm|lb mode|kube.?proxy" | head -10

echo
echo "=== bpf lb list (first 15 lines) ==="
docker exec "$N1" cilium-dbg bpf lb list 2>/dev/null | head -15 || echo "  (no output)"

echo
echo "=== bpf lb maglev ==="
docker exec "$N1" cilium-dbg bpf lb maglev list 2>/dev/null | head -5 || echo "  (no maglev table)"
