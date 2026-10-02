# End-of-RIB ordering, soft resets, and many Services (captured batches)

All runs: maglev + SNAT, eTP/iTP = Cluster, 200 flows per population, `CAPTURE_BGP=1`
(bird↔Cilium session on tcp/179 per node, bird log with the cilium protocol traced, and the
restarted agent's log). Results dirs: `results/eor-1.19.1`, `results/eor-1.19.8`,
`results/eor-upgrade`, `results/svc20-*`. Summarised by `docs/report/extract-eor-data.py`
over `scripts/analyze-bgp-capture.py`.

| Cilium | GR | advertised prefixes | runs | agent restarts captured | soft resets / start | End-of-RIB before VIP | VIP withdrawn to leaves (max) | broken % Cilium-only VIP, per run | broken % in-cluster, per run | in-cluster resets, per run |
|---|---|---|---|---|---|---|---|---|---|---|
| 1.19.1 | on | 3 (VIPs) | rollout x4, delete x3 | 15 | 4 | 1 | 1 (0.65 s) | 0 / 0 / 39.5 / 0 / 0 / 0 / 0 | 0 x7 | 0 x7 |
| 1.19.8 | on | 3 (VIPs) | rollout x4, delete x4 | 16 | 2 | 0 | 0 | 0 x8 | 0 x8 | 0 x8 |
| 1.19.1 → 1.19.8 | on | 3 (VIPs) | upgrade x3 | 9 | 2 | 0 | 0 | 0 x3 | 0 x3 | 0 x3 |
| 1.19.1 | off | 3 (VIPs) + 20 ClusterIP not advertised | rollout x3, delete x3 | 12 | 4 | 0 | n/a (no GR: every restart withdraws) | 30.5 / 46 / 48 / 100 / 100 / 100 | 2.5 / 81.5 / 84 / 84 / 82 / 83.5 | 5 / 3 / 1 / 2 / 3 / 1 |
| 1.19.1 | on | 3 (VIPs) + 20 ClusterIP not advertised | rollout x3, delete x3 | 12 | 4 | 1 | 1 (5.84 s) | 0 / 0 / 0 / 49.5 / 0 / 0 | 1 / 2 / 1.5 / 3 / 2.5 / 6 | 2 / 4 / 3 / 6 / 5 / 12 |
| 1.19.1 | on | 23 (VIPs + ClusterIPs) | delete x4 | 4 | 24 | 0 | 0 | 0 x4 | 3.5 / 1.5 / 4.5 / 2 | 7 / 3 / 9 / 4 |
| 1.19.8 | on | 23 (VIPs + ClusterIPs) | delete x4 | 4 | 2 | 0 | 0 | 0 x4 | 1.5 / 2 / 1 / 2 | 3 / 4 / 2 / 4 |

Rows are listed in the order the runs appear in each results dir (deletes before rollouts
where both exist). The 1.19.1 GR-off row's in-cluster breakage is timeouts (node2's
pod-CIDR gap: 25 s, 28 s, 53 s for the three deletes); its 1–5 resets per run are the
same small reset population the GR-on rows show.

## The two captured End-of-RIB-first sessions

Agent → bird on the node's own session, and bird → leaf for `192.0.2.20` only. Seconds
from the disruption command.

### 1.19.1, GR on, 3 advertised prefixes: single-node delete, run 3, node2

```
+28.26s  agent -> bird  OPEN
+28.26s  agent -> bird  UPDATE announce 10.244.0.0/24
+28.26s  agent -> bird  UPDATE End-of-RIB
+28.36s  bird -> leaf   UPDATE WITHDRAW 192.0.2.20/32        (both leaves)
+28.98s  agent -> bird  UPDATE announce 10.244.0.0/24        x3, each followed by End-of-RIB (one per soft reset)
+28.98s  agent -> bird  UPDATE announce 192.0.2.21/32
+28.98s  agent -> bird  UPDATE announce 192.0.2.20/32
+28.98s  agent -> bird  UPDATE announce 192.0.2.10/32
+29.02s  bird -> leaf   UPDATE announce 192.0.2.20/32        (both leaves; withdrawn for 0.65 s)
```

bird log (node2): `Neighbor graceful restart detected` at the old session's close;
`Sending END-OF-RIB`, `Got END-OF-RIB`, `Neighbor graceful restart done` at +28.26 s;
three more `Got END-OF-RIB` at +28.98 s. Agent log: `Neighbor soft reset out` at +27.23 s
and three at +28.98 s. 79 of 200 external flows re-hashed off node2 and all broke (SNAT).

### 1.19.1, GR on, 20 extra Services (not advertised): rollout, run 1, node3

```
+46.88s  agent -> bird  OPEN
+46.88s  agent -> bird  UPDATE announce 10.244.2.0/24
+46.88s  agent -> bird  UPDATE End-of-RIB
+46.88s  bird -> leaf   UPDATE WITHDRAW 192.0.2.20/32        (both leaves)
+52.72s  agent -> bird  UPDATE announce 10.244.2.0/24        x3, each followed by End-of-RIB
+52.72s  agent -> bird  UPDATE announce 192.0.2.20/32, 192.0.2.10/32, 192.0.2.21/32
+52.72s  bird -> leaf   UPDATE announce 192.0.2.20/32        (withdrawn for 5.84 s)
```

leaf1 showed 2 nexthops for `192.0.2.20` from +48.9 s to +52.2 s of samples. 99 of 200
external flows re-hashed and broke. node1 and node2 in the same rollout put all four
prefixes in their first UPDATE.

## 1.19.8 for comparison (every captured restart)

```
+41.52s  agent -> bird  OPEN
+41.53s  agent -> bird  UPDATE announce 192.0.2.20/32, 192.0.2.10/32, 10.244.1.0/24, 192.0.2.21/32
+41.53s  agent -> bird  UPDATE End-of-RIB
```

Agent log: 2 `Neighbor soft reset out` per start, 1.3–1.8 s before the OPEN; none after.
With the 20 ClusterIPs advertised the first UPDATE carries all 24 prefixes and the count is
still 2 (1.19.1: 24).

Cilium release notes: v1.19.3 #45049 (service advertisement race), v1.19.4 #45286 (only
Services with active backends), v1.19.5 #45927 "Reduce amount of soft peer resets by
service reconciliation". No BGP data-path changes in 1.19.6–1.19.8.
