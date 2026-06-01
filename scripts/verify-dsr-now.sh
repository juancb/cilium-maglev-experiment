#!/usr/bin/env bash
# Apply DSR-nomaglev config and verify DSR with Hubble (pod should see 203.0.113.1).
set -euo pipefail
N1="clab-maglev-clos-node1"
CLIENT="clab-maglev-clos-client"
KC="KUBECONFIG=/etc/rancher/k3s/k3s.yaml"

echo "=== applying DSR nomaglev config ==="
docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
  helm upgrade cilium cilium/cilium -n kube-system \
  -f /opt/k8s/cilium-values-dsr-nomaglev.yaml --reset-values \
  --set loadBalancer.dsrDispatch=opt
docker exec "$N1" k3s kubectl -n kube-system rollout restart ds/cilium
docker exec "$N1" k3s kubectl -n kube-system rollout status ds/cilium --timeout=120s

echo ""
echo "=== current bpf-lb config ==="
docker exec "$N1" bash -c "$KC cilium config view 2>/dev/null" | grep -E "bpf-lb-mode|bpf-lb-dsr|bpf-lb-algorithm|bpf-lb-sock"

echo ""
echo "=== start 5 flows, observe Hubble for 10s ==="
RELAY_IP=$(docker exec "$N1" bash -c \
  "$KC kubectl -n kube-system get pod -l k8s-app=hubble-relay \
   -o jsonpath='{.items[0].status.podIP}' 2>/dev/null")
echo "relay: ${RELAY_IP}:4244"

docker exec "$CLIENT" rm -f /tmp/vdsr.json /tmp/vdsr.ready
docker exec -d "$CLIENT" python3 /opt/flowgen/flowgen.py \
  --vip 192.0.2.10 --port 8080 --count 5 --duration 20 \
  --src 203.0.113.1 --out /tmp/vdsr.json --ready-file /tmp/vdsr.ready

sleep 4

echo "=== Hubble flows to echo pods (last 30) ==="
docker exec "$N1" bash -c \
  "HUBBLE_SERVER=${RELAY_IP}:4244 hubble observe --pod echo --last 30 --output compact 2>&1" | head -30

sleep 18

echo ""
echo "=== flowgen result ==="
docker cp "$CLIENT:/tmp/vdsr.json" /tmp/vdsr_result.json
python3 -c "
import json; d = json.load(open('/tmp/vdsr_result.json'))
s = d['summary']
print(f'  established={s[\"established\"]} broken={s[\"broken_after_establish\"]} survived={s[\"survived\"]}')
for f in d['flows'][:5]:
    print(f'  flow srcport={f[\"srcport\"]} backend={f[\"backend\"]} status={f[\"status\"]}')
"

echo ""
echo "=== restoring baseline ==="
docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml "$N1" \
  helm upgrade cilium cilium/cilium -n kube-system \
  -f /opt/k8s/cilium-values-maglev.yaml --reset-values
docker exec "$N1" k3s kubectl -n kube-system rollout restart ds/cilium
docker exec "$N1" k3s kubectl -n kube-system rollout status ds/cilium --timeout=120s
