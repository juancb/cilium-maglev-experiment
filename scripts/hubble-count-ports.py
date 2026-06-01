#!/usr/bin/env python3
"""Read Hubble jsonpb flow events from stdin, print the count of distinct TCP
source ports. Used by tests/lib/failover-lib.sh to measure per-node ingress load
(the disturbed-set D) cheaply — far lighter than dumping the BPF CT map."""
import sys, json

ports = set()
for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        ev = json.loads(line)
    except Exception:
        continue
    fl = ev.get("flow", ev)
    sp = fl.get("l4", {}).get("TCP", {}).get("source_port")
    if sp:
        ports.add(sp)
print(len(ports))
