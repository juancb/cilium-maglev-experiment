#!/usr/bin/env bash
# Verify DSR is working: send 1 flow from 203.0.113.1, confirm Hubble shows it at the pod.
set -euo pipefail
CLIENT="clab-maglev-clos-client"
N1="clab-maglev-clos-node1"
KC="KUBECONFIG=/etc/rancher/k3s/k3s.yaml"

RELAY_IP=$(docker exec "$N1" bash -c \
  "$KC kubectl -n kube-system get pod -l k8s-app=hubble-relay \
   -o jsonpath='{.items[0].status.podIP}' 2>/dev/null")
echo "hubble relay: ${RELAY_IP}:4245"
docker exec "$N1" bash -c "HUBBLE_SERVER=${RELAY_IP}:4245 hubble status 2>&1"

echo ""
echo "=== single flow from 203.0.113.1 (DSR: backend should see 203.0.113.1) ==="
docker exec "$CLIENT" rm -f /tmp/dv.json /tmp/dv.ready 2>/dev/null || true
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 1 --duration 10 \
  --src 203.0.113.1 --out /tmp/dv.json --ready-file /tmp/dv.ready

sleep 4

echo "=== Hubble flows to echo pods ==="
docker exec "$N1" bash -c \
  "HUBBLE_SERVER=${RELAY_IP}:4245 hubble observe --pod echo --last 30 --output compact 2>&1" \
  | grep -v "^$" | tail -20

sleep 8

echo ""
echo "=== flowgen result ==="
docker cp "$CLIENT:/tmp/dv.json" /tmp/dv_result.json 2>/dev/null
python3 -c "
import json
d = json.load(open('/tmp/dv_result.json'))
print(json.dumps(d['summary'], indent=2))
for f in d['flows']:
    print(f'  flow srcport={f[\"srcport\"]} backend={f[\"backend\"]} status={f[\"status\"]}')
"
