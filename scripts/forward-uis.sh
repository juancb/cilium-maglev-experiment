#!/usr/bin/env bash
# Forward WSL host ports to the kubectl port-forwards running inside node1.
# Run once after bring-up; re-run after wsl --shutdown (node1 IP is stable).
set -euo pipefail

NODE1_IP=172.30.0.9

pkill -f 'socat.*18080' 2>/dev/null || true
pkill -f 'socat.*18081' 2>/dev/null || true
sleep 1

nohup socat TCP-LISTEN:18080,bind=0.0.0.0,fork,reuseaddr TCP:${NODE1_IP}:18080 >/tmp/socat-hubble.log 2>&1 &
nohup socat TCP-LISTEN:18081,bind=0.0.0.0,fork,reuseaddr TCP:${NODE1_IP}:18081 >/tmp/socat-grafana.log 2>&1 &

sleep 2
echo "socat listeners:"
ss -nltp | grep socat || echo "(none yet — may need a moment)"

echo "testing:"
curl -sf -o /dev/null -w '%{http_code}' http://localhost:18080/ && echo " hubble OK" || echo " hubble FAIL"
curl -sf -o /dev/null -w '%{http_code}' http://localhost:18081/ && echo " grafana OK" || echo " grafana FAIL"
echo ""
echo "Windows: http://localhost:18080  (Hubble)"
echo "Windows: http://localhost:18081  (Grafana admin/admin)"
