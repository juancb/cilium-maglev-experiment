#!/usr/bin/env bash
# Per-node network bring-up (runs in the privileged containerlab node, host netns).
# Derives all addresses from NODE_ID (see docs/ADDRESSING.md). k3s + Cilium are started
# afterward by `make up` once the fabric has converged (so node IPs are routable for join).
set -euo pipefail
ID="${NODE_ID:?NODE_ID not set}"

FAB0="10.3.1.$((2*(ID-1)+1))"     # /31 to leaf1
FAB1="10.3.2.$((2*(ID-1)+1))"     # /31 to leaf2
PUBLIC="198.51.100.${ID}"          # "public" interface /32
K8S="10.10.0.${ID}"                # "k8s" InternalIP /32

echo "[node${ID}] waiting for fabric uplinks fab0/fab1"
for i in fab0 fab1; do
  for _ in $(seq 1 30); do ip link show "$i" &>/dev/null && break; sleep 1; done
done

echo "[node${ID}] addressing: fab0=${FAB0}/31 fab1=${FAB1}/31 public=${PUBLIC}/32 k8s=${K8S}/32"
ip addr replace "${FAB0}/31" dev fab0
ip addr replace "${FAB1}/31" dev fab1
ip link set fab0 up
ip link set fab1 up

# dummy interfaces named exactly per requirement
ip link add public type dummy 2>/dev/null || true
ip link add k8s    type dummy 2>/dev/null || true
ip addr replace "${PUBLIC}/32" dev public
ip addr replace "${K8S}/32"    dev k8s
ip link set public up
ip link set k8s up

echo "[node${ID}] sysctls: per-flow L4 ECMP + forwarding + rp_filter off"
sysctl -w net.ipv4.fib_multipath_hash_policy=1
sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.all.rp_filter=0
sysctl -w net.ipv4.conf.default.rp_filter=0

echo "[node${ID}] cgroupv2: clear subtree_control so k3s can create kubepods hierarchy"
# cgroupv2 propagates domain controllers to child cgroups via subtree_control. If the root
# has domain controllers set, any child cgroup (including kubepods) inherits them. When kubelet
# then tries to have processes AND children under kubepods, it hits the "domain invalid" state.
# Fix: clear subtree_control NOW — before any child cgroup is created — so kubepods inherits
# no domain controllers. This must happen before bird starts (which would create a child cgroup).
# Resource accounting is not needed for this experiment.
if [ -f /sys/fs/cgroup/cgroup.subtree_control ]; then
  CTLS=$(cat /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true)
  if [ -n "${CTLS:-}" ]; then
    MINUS=$(echo "$CTLS" | sed 's/[^ ]*/\-&/g')
    echo "${MINUS}" > /sys/fs/cgroup/cgroup.subtree_control 2>/dev/null || true
    echo "[node${ID}] cgroupv2 subtree_control cleared (was: ${CTLS}; now: $(cat /sys/fs/cgroup/cgroup.subtree_control))"
  fi
  # Pre-create kubepods hierarchy NOW while subtree_control is empty.
  # kubepods inherits controllers from root's subtree_control at creation time.
  # If we create it while stc=empty, kubepods gets stc=empty → k3s can enter it later
  # even after containerd re-sets root's stc.
  # Pre-create ONLY kubepods (no children). If we also create burstable/besteffort,
  # kubepods will have children + inherited domain controllers from parent = domain invalid.
  mkdir -p /sys/fs/cgroup/kubepods 2>/dev/null || true
  echo "[node${ID}] kubepods cgroup pre-created (type: $(cat /sys/fs/cgroup/kubepods/cgroup.type 2>/dev/null), stc: '$(cat /sys/fs/cgroup/kubepods/cgroup.subtree_control 2>/dev/null)')"
fi

echo "[node${ID}] bpf + cgroup2 mounts for Cilium"
mount bpffs -t bpf /sys/fs/bpf 2>/dev/null || true
mkdir -p /run/cilium/cgroupv2
mount -t cgroup2 none /run/cilium/cgroupv2 2>/dev/null || true

echo "[node${ID}] starting host bird"
mkdir -p /run/bird
pkill -x bird 2>/dev/null || true
bird -c /etc/bird/bird.conf

echo "[node${ID}] network ready. (k3s + Cilium started by 'make up'.)"
