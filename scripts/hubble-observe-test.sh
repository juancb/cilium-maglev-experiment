#!/usr/bin/env bash
# Short non-disruptive flowgen run observed via hubble CLI on node1 (relay-connected).
set -euo pipefail

CLIENT="clab-maglev-clos-client"
N1="clab-maglev-clos-node1"
KC="KUBECONFIG=/etc/rancher/k3s/k3s.yaml"

# Get the relay pod IP (may change after restarts)
RELAY_IP=$(docker exec "$N1" bash -c \
  "$KC kubectl -n kube-system get pod -l k8s-app=hubble-relay \
   -o jsonpath='{.items[0].status.podIP}' 2>/dev/null")
echo "=== hubble relay: ${RELAY_IP}:4245 ==="
docker exec "$N1" bash -c "HUBBLE_SERVER=${RELAY_IP}:4245 hubble status 2>&1"

echo ""
echo "=== starting 20 flows from 203.0.113.1 (30s, no failure) ==="
docker exec "$CLIENT" rm -f /tmp/obs.json /tmp/obs.ready 2>/dev/null || true
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 20 --duration 30 \
  --src 203.0.113.1 --out /tmp/obs.json --ready-file /tmp/obs.ready

echo "waiting for flows to establish..."
for i in $(seq 1 20); do
  docker exec "$CLIENT" test -f /tmp/obs.ready 2>/dev/null && break
  sleep 1
done
EST=$(docker exec "$CLIENT" cat /tmp/obs.ready 2>/dev/null || echo 0)
echo "$EST/20 flows established"

echo ""
echo "=== hubble observe: all 3 nodes via relay, 20s, from 203.0.113.1 ==="
docker exec "$N1" bash -c \
  "HUBBLE_SERVER=${RELAY_IP}:4245 timeout 20 hubble observe \
   --from-ip 203.0.113.1 \
   --follow \
   --output json 2>&1" \
| python3 - <<'PYEOF'
import sys, json
flows = []
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        f = json.loads(line)
    except Exception:
        print(line)
        continue
    flows.append(f)

# Print compact summary
from collections import defaultdict
by_node = defaultdict(lambda: defaultdict(int))
by_dst  = defaultdict(int)
flags_seen = set()

for f in flows:
    node = f.get("node_name", "?")
    ep   = (f.get("destination") or {}).get("pod_name", "?")
    fl   = f.get("l4", {}).get("TCP", {}).get("flags", {})
    flag_str = "+".join(k for k, v in fl.items() if v)
    by_node[node][flag_str] += 1
    by_dst[ep] += 1
    flags_seen.add(flag_str)

print(f"Total flow events captured: {len(flows)}")
print()
print("Events per ingress node:")
for node, flags in sorted(by_node.items()):
    total = sum(flags.values())
    flag_summary = ", ".join(f"{f}:{n}" for f, n in sorted(flags.items()) if n > 0)
    print(f"  {node:12s}  {total:4d} events  [{flag_summary}]")

print()
print("Events per backend pod:")
for pod, n in sorted(by_dst.items(), key=lambda x: -x[1]):
    print(f"  {pod:45s} {n:4d}")
PYEOF

echo ""
echo "=== waiting for flowgen to finish ==="
sleep 15

echo ""
echo "=== flowgen summary ==="
docker cp "$CLIENT:/tmp/obs.json" /tmp/obs_result.json 2>/dev/null
python3 - <<'EOF'
import json
d = json.load(open("/tmp/obs_result.json"))
s = d["summary"]
pct = 100 * s["broken_after_establish"] / s["established"] if s["established"] else 0
print(f"  Flows:     {s['count']} started, {s['established']} established, {s['never_established']} never connected")
print(f"  Broken:    {s['broken_after_establish']} ({pct:.0f}%)")
print(f"  Survived:  {s['survived']}")
print()
print("  Backend distribution:")
for pod, n in sorted(s["backend_distribution"].items(), key=lambda x: -x[1]):
    bar = "█" * n
    print(f"    {pod:45s} {n:3d}  {bar}")
EOF
