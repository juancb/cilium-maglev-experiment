#!/usr/bin/env bash
# Client bring-up: start FRR (advertises 203.0.113.1/32, learns the VIP from the ToR).
# Interface IPs (eth1 10.0.0.0/31, lo 203.0.113.1/32) are applied by FRR/zebra from
# fabric/frr/client.conf.
set -euo pipefail

# Single uplink to the ToR — no client-side ECMP (the ToR owns the 3-way spine ECMP), but set
# the policy anyway so any future multipath at the client is per-flow.
sysctl -w net.ipv4.fib_multipath_hash_policy=1 || true
sysctl -w net.ipv4.ip_forward=1 || true

echo "[client] starting FRR"
/usr/lib/frr/frrinit.sh start 2>/dev/null || service frr start 2>/dev/null || true

echo "[client] ready. flowgen lives at /opt/flowgen (see tests/lib/flowgen)."
