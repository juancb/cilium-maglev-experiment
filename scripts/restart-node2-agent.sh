#!/usr/bin/env bash
set -euo pipefail
N1="clab-maglev-clos-node1"
N2="clab-maglev-clos-node2"

echo "[*] Killing k3s agent on node2..."
docker exec "$N2" bash -c 'pkill -f "k3s agent" 2>/dev/null; sleep 2; pkill -9 -f "k3s agent" 2>/dev/null; true'
sleep 2

echo "[*] Cleaning stale k3s runtime state..."
docker exec "$N2" bash -c 'rm -rf /run/k3s /var/run/k3s 2>/dev/null; true'

echo "[*] Starting k3s agent..."
token=$(docker exec "$N1" cat /var/lib/rancher/k3s/server/node-token)
docker exec -d "$N2" bash -lc \
  "k3s agent --server https://10.10.0.1:6443 --token ${token} --node-ip 10.10.0.2 \
   --snapshotter=native >/var/log/k3s.log 2>&1"

echo "[*] Waiting for node2 Ready..."
for i in $(seq 1 90); do
  out=$(docker exec "$N1" k3s kubectl get node node2 --no-headers 2>/dev/null || true)
  echo "  [$i] $out"
  echo "$out" | grep -q ' Ready' && echo "[+] node2 Ready" && exit 0
  sleep 3
done
echo "[-] node2 did not become Ready after 270s"
exit 1
