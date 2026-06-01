#!/usr/bin/env bash
set -euo pipefail
N1="clab-maglev-clos-node1"

CPOD=$(docker exec "$N1" bash -c 'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system get pod -l k8s-app=cilium -o name 2>/dev/null' | head -1 | sed 's|pod/||')
echo "cilium pod: $CPOD"

echo ""
echo "=== cgroup BPF programs (looking for connect4/sock4_connect) ==="
docker exec "$N1" bash -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system exec $CPOD -- bpftool cgroup list /run/cilium/cgroupv2 2>/dev/null" \
  | grep -iE "connect|sock.*lb" || echo "(none — socket-LB detached)"

echo ""
echo "=== test: single VIP connection from client (check destination IP) ==="
docker exec clab-maglev-clos-client rm -f /tmp/chk.pcap
docker exec -d clab-maglev-clos-client bash -c \
  "tcpdump -i eth1 -nn -c 10 'tcp and port 8080' -w /tmp/chk.pcap 2>/dev/null"
sleep 1

docker exec clab-maglev-clos-client python3 -c "
import socket
s = socket.socket()
s.bind(('203.0.113.1', 55555))
s.settimeout(3)
try:
    s.connect(('192.0.2.10', 8080))
    d = s.recv(64)
    print('got:', d[:50].decode())
    s.close()
except Exception as e:
    print('error:', e)
" 2>/dev/null

sleep 2
docker exec clab-maglev-clos-client pkill tcpdump 2>/dev/null || true
sleep 1

echo ""
echo "=== client eth1 capture (SYN should go to 192.0.2.10 now, not pod IP) ==="
docker exec clab-maglev-clos-client bash -c "tcpdump -r /tmp/chk.pcap -nn 2>/dev/null | head -10" || echo "no capture"
