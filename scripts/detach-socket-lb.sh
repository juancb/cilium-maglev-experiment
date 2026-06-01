#!/usr/bin/env bash
# Detach stale Cilium socket-LB cgroup BPF programs from the cgroupv2 root.
set -euo pipefail

CGROUP="/run/cilium/cgroupv2"
N1="clab-maglev-clos-node1"

kctl() {
  docker exec "$N1" bash -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl $*"
}

CILIUM_POD=$(kctl "-n kube-system get pod -l k8s-app=cilium -o name" 2>/dev/null | head -1 | sed 's|pod/||')
echo "Using cilium pod: $CILIUM_POD"

kexec() {
  docker exec "$N1" bash -c "KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system exec $CILIUM_POD -- $*"
}

echo ""
echo "=== Programs before detach ==="
kexec "bpftool cgroup list $CGROUP" 2>/dev/null

echo ""
echo "=== Detaching ==="
kexec "bpftool cgroup list $CGROUP -j" 2>/dev/null | python3 -c "
import json, sys, subprocess

type_map = {
    'cgroup_inet4_connect':    'connect4',
    'cgroup_inet6_connect':    'connect6',
    'cgroup_inet4_post_bind':  'post_bind4',
    'cgroup_inet6_post_bind':  'post_bind6',
    'cgroup_inet_sock_release':'sock_release',
    'cgroup_udp4_sendmsg':     'sendmsg4',
    'cgroup_udp6_sendmsg':     'sendmsg6',
    'cgroup_udp4_recvmsg':     'recvmsg4',
    'cgroup_udp6_recvmsg':     'recvmsg6',
    'cgroup_inet4_getpeername':'getpeername4',
    'cgroup_inet6_getpeername':'getpeername6',
    'cgroup_sock_ops':         'sock_ops',
}

n1     = 'clab-maglev-clos-node1'
pod    = '$CILIUM_POD'
cgroup = '$CGROUP'

data = json.load(sys.stdin)
for prog in data:
    pid   = prog.get('id')
    atype = prog.get('attach_type', '')
    name  = prog.get('name', '')
    bt    = type_map.get(atype, atype)
    cmd   = ['docker','exec',n1,'bash','-c',
             f'KUBECONFIG=/etc/rancher/k3s/k3s.yaml kubectl -n kube-system exec {pod} -- bpftool cgroup detach {cgroup} {bt} id {pid}']
    print(f'  detach id={pid} type={bt} name={name} ...', end=' ', flush=True)
    r = subprocess.run(cmd, capture_output=True, text=True)
    print('OK' if r.returncode == 0 else f'FAIL: {r.stderr.strip()}')
"

echo ""
echo "=== Programs after detach ==="
kexec "bpftool cgroup list $CGROUP" 2>/dev/null || echo "(none — clean)"
