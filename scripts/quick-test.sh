#!/usr/bin/env bash
# Quick failover smoke test with Hubble observation.
set -euo pipefail

CLIENT="clab-maglev-clos-client"
NODE2="clab-maglev-clos-node2"
N1="clab-maglev-clos-node1"
KC="KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl"

N1POD=$(docker exec "$N1" bash -c "$KC -n kube-system get pods -l k8s-app=cilium --no-headers" \
  | head -1 | awk '{print $1}')
echo "cilium pod: $N1POD"

hubble_snap() {
  local label="$1" last="${2:-20}"
  echo ""
  echo "=== Hubble [$label] ==="
  docker exec "$N1" bash -c \
    "$KC -n kube-system exec $N1POD -c cilium-agent -- \
     hubble observe --from-ip 203.0.113.1 --last $last --output compact 2>&1" \
    | grep -v '^$' || true
}

# ── start flows ──────────────────────────────────────────────────────────────
echo "=== starting 15 flows from 203.0.113.1 ==="
docker exec "$CLIENT" rm -f /tmp/qt.json /tmp/qt.ready 2>/dev/null || true
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 15 --duration 40 \
  --src 203.0.113.1 --out /tmp/qt.json --ready-file /tmp/qt.ready

for i in $(seq 1 20); do
  docker exec "$CLIENT" test -f /tmp/qt.ready 2>/dev/null && break
  sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/qt.ready 2>/dev/null || echo 0)
echo "$EST flows established"

hubble_snap "pre-failure" 20

# ── fail node2 ───────────────────────────────────────────────────────────────
echo ""
echo "=== FAILING node2 (fabric links down) ==="
docker exec "$NODE2" ip link set fab0 down
docker exec "$NODE2" ip link set fab1 down
FAILTIME=$(date +%s)

# stream for 8s post-failure
echo "=== Hubble stream post-failure (8s) ==="
docker exec "$N1" bash -c \
  "$KC -n kube-system exec $N1POD -c cilium-agent -- \
   hubble observe --from-ip 203.0.113.1 --follow --output compact 2>&1" &
HPID=$!
sleep 8
kill "$HPID" 2>/dev/null || true

hubble_snap "post-failure" 30

# ── restore ──────────────────────────────────────────────────────────────────
echo ""
echo "=== restoring node2 (fabric links up) ==="
docker exec "$NODE2" ip link set fab0 up
docker exec "$NODE2" ip link set fab1 up

echo "waiting for flowgen to finish..."
sleep 18

# ── results ──────────────────────────────────────────────────────────────────
echo ""
echo "=== RESULTS ==="
docker cp "$CLIENT:/tmp/qt.json" /tmp/qt_result.json 2>/dev/null
python3 - <<'EOF'
import json
d = json.load(open("/tmp/qt_result.json"))
s = d["summary"]
broken = [f for f in d["flows"] if f["status"] == "broken" and f["established_at"]]
pct = 100 * s["broken_after_establish"] / s["established"] if s["established"] else 0
print(f"  Established:          {s['established']}")
print(f"  Broken after establish: {s['broken_after_establish']}  ({pct:.0f}%)")
print(f"  Survived:             {s['survived']}")
print("  Backend distribution:")
for pod, n in sorted(s["backend_distribution"].items()):
    print(f"    {pod}: {n}")
EOF
