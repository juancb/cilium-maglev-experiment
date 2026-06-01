#!/usr/bin/env bash
# Verify DSR is working: start 5 flows and check Hubble to see what src IP pods see.
set -euo pipefail
CLIENT="clab-maglev-clos-client"
N1="clab-maglev-clos-node1"
RELAY="10.244.2.14:4245"

echo "=== current bpf-lb config ==="
docker exec "$N1" bash -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml cilium config view 2>/dev/null" \
  | grep -E "bpf-lb-mode|bpf-lb-dsr|bpf-lb-algorithm|bpf-lb-sock"

echo ""
echo "=== starting 5 flows from 203.0.113.1 ==="
docker exec "$CLIENT" rm -f /tmp/vdsr.json /tmp/vdsr.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 5 --duration 25 \
  --src 203.0.113.1 --out /tmp/vdsr.json --ready-file /tmp/vdsr.ready

echo "waiting for flows..."
for i in $(seq 1 15); do
  docker exec "$CLIENT" test -f /tmp/vdsr.ready 2>/dev/null && break
  sleep 1
done
echo "flows established"
sleep 2

echo ""
echo "=== Hubble: last 30 events to echo pods ==="
docker exec "$N1" bash -c "HUBBLE_SERVER=${RELAY} hubble observe --pod echo --last 30 --output compact 2>&1" | head -40

echo ""
echo "=== Hubble: specifically from 203.0.113.1 ==="
docker exec "$N1" bash -c "HUBBLE_SERVER=${RELAY} hubble observe --from-ip 203.0.113.1 --last 20 --output compact 2>&1" | head -20

sleep 22

echo ""
echo "=== flowgen result ==="
docker cp "$CLIENT:/tmp/vdsr.json" /tmp/vdsr_result.json
python3 -c "
import json
d = json.load(open('/tmp/vdsr_result.json'))
s = d['summary']
print(f'  established={s[\"established\"]} broken={s[\"broken_after_establish\"]} survived={s[\"survived\"]}')
for f in d['flows'][:5]:
    print(f'  flow srcport={f[\"srcport\"]} backend={f[\"backend\"]} status={f[\"status\"]}')
"
