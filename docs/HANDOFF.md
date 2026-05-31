# Lab Handoff Document

## Ultimate Goal

Run a **2×2 experiment** measuring how two consistent-hashing layers interact during a spine
switch failure in a BGP-ECMP Kubernetes fabric:

| | switch CH **off** | switch CH **on** |
|---|---|---|
| **Maglev off** | ~44% TCP flows break | ~22% break |
| **Maglev on** | ~0% break | ~0% break |

**The thesis:** a spine failure causes some in-flight TCP flows to be re-hashed onto a
different ingress node. That node has no conntrack state and re-selects a backend pod.
- **Maglev** ensures every node maps the same 5-tuple to the same backend → TCP survives.
- **Switch consistent-hashing (resilient ECMP)** controls how many flows get disturbed (~1/3
  with CH on, ~2/3 with CH off).

The two levers compound: CH shrinks the disturbed set; Maglev makes the disturbed set
survivable. Missing both ≈ `(M-1)/M` of all flows reset on every spine failure.

**The experiment is not done until we can see this in a chart.** The final deliverable is
`results/summary.html` — an HTML report with a cumulative broken-flow timeline and a
backend-distribution plot generated from real test data by `scripts/visualise.py`. Right now
every result file in `results/` shows 0% broken because they were captured before the
`fib_multipath_hash_policy` bug was fixed (see Key Discoveries). Those files need to be
re-run and replaced with valid data before the visualisation is meaningful.

---

## Topology

```
client (203.0.113.1/loopback, eth1=10.0.0.0/31)
  │
leaf1 (eth4→node1, eth5→node2, eth6→node3)
  ├── spine1 ── leaf2
  ├── spine2 ── leaf2
  └── spine3 ── leaf2
       │
     leaf2 (fab1 uplinks to all nodes)
       │
  node1  node2  node3   (k3s + bird + Cilium)
  10.10.0.1  .2  .3     fab0→leaf1, fab1→leaf2
```

VIP `192.0.2.10` advertised by all three nodes via Cilium BGP → bird → leaf1/leaf2 → spines.
ECMP at each level: 3-way at leaf (3 nodes), 2-way at spine (2 leaves per spine).

**Note:** The original plan included a SONiC ToR. The actual deployed topology uses FRR for
all switching nodes (no SONiC). The consistent-hashing knob is therefore `fib_multipath_hash_policy`
on the Linux/FRR nodes rather than SONiC Fine-Grained ECMP. See "Known Deviations" below.

---

## Key Discoveries (hard-won; save future debugging time)

### 1. Root cause of 0% broken — L3-only ECMP hash (FIXED)

**Problem:** all test runs showed 0% broken flows, even when node2 was stopped.

**Root cause:** `fib_multipath_hash_policy=0` (L3-only) on leaf1. With source IP `10.0.0.0`
and destination `192.0.2.10` fixed, `hash(src_ip, dst_ip)` is deterministic — ALWAYS selects
the same ECMP nexthop (eth6 → node3). Stopping node2 has zero effect because 0 flows ever
traverse node2.

**Evidence:** leaf1 interface counters with policy=0 active:
```
eth4 (→node1):  4.9M packets
eth5 (→node2):   51K packets  ← only BGP keepalives, zero data
eth6 (→node3): 10.7M packets  ← 100% of all VIP traffic
```

**Fix applied:** `sysctl -w net.ipv4.fib_multipath_hash_policy=1` on all 5 forwarding nodes.
Script: `scripts/fix-ecmp-hash.sh`. **This fix is NOT persistent across container restarts.**

**To make it persistent:** add the sysctl to each node's startup script or FRR config.

### 2. Client source IP = 10.0.0.0, not 203.0.113.1

The client uses `10.0.0.0` (its eth1 IP on the client↔leaf1 /31 link) as TCP source, NOT
`203.0.113.1` (loopback). Confirmed via `ip route get 192.0.2.10 src 10.0.0.0` from inside
the client container.

**Impact:** When grepping CT entries for the client, search for `10.0.0.0`, not `203.0.113`.

### 3. SNAT is NOT applying (beneficial for the demo)

`bpf-lb-mode: snat` is configured, but Cilium is not SNATing service ingress traffic in our
setup. CT entries on backend pods show source `10.0.0.0` (original client IP), not a node IP.
NAT tables on all nodes are empty.

**Why this happens:** Cilium's native routing mode with `bpf.masquerade` does not SNAT traffic
on the ingress path when the backend is reachable directly (no tunnel needed).

**Impact on the experiment:** This is BENEFICIAL. Without SNAT:
- Backend pod sees the original client IP throughout the connection lifetime
- Maglev selects the same backend for the same 5-tuple on any node
- If a re-homed flow hits a node that selects the same backend (Maglev), the pod has TCP state
  → flow survives. If it hits a different backend (random), no state → RST.
- DSR (`loadBalancer.mode=dsr`) is NOT needed — the experiment works in the current config.

### 4. flowgen detection is confirmed correct

Self-test (`scripts/flowgen-selftest.sh`): started echo server on client:9999, ran flowgen
against it, killed the server mid-test. Result: 10/10 flows correctly reported as broken.
flowgen is NOT the measurement problem.

### 5. node2 Cilium was silently broken after docker stop/start cycles

After repeated `docker stop / docker start` cycles on node2, the Cilium pod showed `1/1
Running` in k3s but had NO `cilium-agent` process inside. The kubelet returned 502 for exec
requests. Root cause: container restart without re-running the startup script causes
interfaces (`cilium_host`, `fab0`, `fab1`) to be missing.

**Recovery:** Delete the Cilium pod (DaemonSet recreates it) AND ensure startup.sh runs
inside node2 after any container restart.

---

## Current State (as of last session)

### What is working
- Lab topology is up: all containers running, BGP sessions established
- k3s cluster healthy: node1, node3 fully operational with Cilium Running
- `fib_multipath_hash_policy=1` applied on all 5 switching nodes
- Demo app deployed; pods spread across nodes
- flowgen, all diagnostic scripts present and tested

### What is broken / pending

**1. node2 Cilium pod stuck `0/1 Pending`**

After deleting the broken cilium-dqc2b pod, the replacement `cilium-lv5rs` is stuck Pending:
```
cilium-g82vg   1/1   Running   0   node1
cilium-h9zz7   1/1   Running   0   node3
cilium-lv5rs   0/1   Pending   0   node2   ← BROKEN
```
Pod never started; likely the k3s agent on node2 is in NotReady state after repeated
docker stop/start cycles. node2 has no `cilium_host` interface.

**Diagnosis commands:**
```bash
# Check pod events
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- bash -c '
docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml clab-maglev-clos-node1 \
  k3s kubectl -n kube-system describe pod cilium-lv5rs | tail -30'

# Check k3s node readiness
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- bash -c '
docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml clab-maglev-clos-node1 \
  k3s kubectl get nodes'

# Check k3s agent process on node2
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- bash -c '
docker exec clab-maglev-clos-node2 ps aux | grep k3s | grep -v grep'

# If node2 is NotReady, re-run startup and check k3s agent logs
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- bash -c '
docker exec clab-maglev-clos-node2 bash /opt/startup.sh
docker exec clab-maglev-clos-node2 journalctl -u k3s-agent -n 50 --no-pager'
```

**Expected fix:** node2's k3s agent needs to reconnect. If it's stuck, restart it:
```bash
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- bash -c '
docker exec clab-maglev-clos-node2 systemctl restart k3s-agent 2>/dev/null ||
docker exec clab-maglev-clos-node2 bash /opt/startup.sh'
```

**2. Hash policy not persistent across restarts**

`fib_multipath_hash_policy=1` was set live but will revert if any switch container restarts.
Add to each node's startup or FRR config. For FRR nodes, the cleanest place is in
`/opt/startup.sh` on each container, or a post-BGP-up route-map action.

**3. The actual 2×2 test has never successfully run**

`tests/03-failover.sh` depends on flows distributing across all 3 nodes. With the hash fix,
this should now work once node2 Cilium is healthy.

---

## Remaining Work (in order)

1. **Fix node2 Cilium** — diagnose Pending pod; get k3s agent healthy; confirm `cilium_host`
   interface appears and `cilium status` shows OK.

2. **Verify flow distribution** — with policy=1 applied, run a short diagnostic to confirm
   flows now spread across node1/node2/node3 (should be ~1/3 each):
   ```bash
   bash scripts/trace-flow.sh   # or scripts/diag-smoke.sh
   # Check leaf1 eth4/eth5/eth6 counters: should be roughly equal
   ```

3. **Run tests/03-failover.sh** — the main 2×2 experiment. Failing a node (not a spine —
   see Known Deviations) tests the Maglev effect. Expected:
   - Maglev on, node2 stopped: ~0% broken (same backend selected on remaining nodes)
   - Maglev off (random), node2 stopped: ~28% broken (2/3 * 1/3 disturbed × 2/3 wrong pod)

4. **Make hash policy persistent** — add `sysctl -w net.ipv4.fib_multipath_hash_policy=1`
   to startup scripts so it survives any container restart.

5. **Produce the visualisation** — once test data is valid, run:
   ```bash
   MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- bash -c \
     'cd /mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment && \
      python3 scripts/visualise.py results/'
   # Opens results/summary.html — the final report
   ```
   The script produces:
   - **Timeline plot** — cumulative broken flows vs. seconds relative to the failure event,
     one line per cell (ch-off/maglev-off, ch-on/maglev-off, maglev-on). The Maglev-on
     lines should be flat at zero; the Maglev-off lines should step up within the BGP
     holdtime window (0–9s).
   - **Backend distribution plot** — bar chart showing which backend pods handled each cell,
     confirming Maglev's stickiness (same pod across cells) vs. random's scatter.
   - **Summary table** — actual broken% vs. predicted per cell, colour-coded green/orange/red.

   **IMPORTANT:** The existing JSON files in `results/` (`ch-off_maglev-off.json`, etc.) are
   all **invalid** — they show 0 broken flows because they were captured when
   `fib_multipath_hash_policy=0` was forcing all traffic to node3. Do NOT use them as final
   results. They will be overwritten when `tests/03-failover.sh` runs successfully.

   Install matplotlib in WSL if missing: `apt install -y python3-matplotlib`

6. **Commit untracked scripts** — the following exist in `scripts/` but are not yet committed:
   `check-maglev.sh`, `apply-demo-app.sh`, `show-pods.sh`, `smoke-test3.sh`,
   `fix-pod-placement.sh`, `flowgen-selftest.sh`, `diag-smoke.sh`, `check-ct.sh`,
   `check-ct2.sh`, `dump-ct.sh`, `trace-flow.sh`, `fix-ecmp-hash.sh`, `fix-node2-cilium.sh`

---

## Known Deviations from the Original Plan

| Plan | Actual | Impact |
|------|--------|--------|
| SONiC ToR with Fine-Grained ECMP | FRR on all switches | No hardware-CH knob; use `fib_multipath_hash_policy` instead |
| Fail a spine to test Maglev | Fail a node (node2) | Still demonstrates Maglev; slightly different failure mode |
| DSR required for Maglev demo | SNAT not applying; native routing preserves client IP | DSR not needed; current setup already works for the core thesis |
| CH on/off via `ch-on.sh`/`ch-off.sh` | No SONiC; CH knob = sysctl on FRR nodes | Same observable effect at Linux level |

---

## Troubleshooting Conventions (CRITICAL)

All of these were learned through failures — violating them causes silent breakage.

### Shell environment
```bash
# ALL Bash tool commands must be prefixed:
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- bash -c '<cmd>'
# Without MSYS_NO_PATHCONV=1: MSYS rewrites /mnt/c/... → C:/Program Files/Git/mnt/...
# Without -u root: containerlab/docker ops fail silently (no passwordless sudo for juan)
```

### Never inline multi-line scripts through the wsl bridge
```bash
# BAD — bash variables come back empty, loops don't work:
wsl -u root -- bash -c 'for i in 1 2 3; do echo "$i"; done'

# GOOD — write a script file and run it:
# Write the script to /mnt/c/.../scripts/foo.sh first, then:
MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- bash -c \
  'bash /mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment/scripts/foo.sh'
```

### kubectl / cilium commands
```bash
# kubectl alias (from outside k3s server):
KC="docker exec -e KUBECONFIG=/etc/rancher/k3s/k3s.yaml clab-maglev-clos-node1 k3s kubectl"

# cilium-dbg (NOT 'cilium') for BPF inspection — must exec into the Cilium DaemonSet pod:
$KC -n kube-system exec <cilium-pod-name> -- cilium-dbg bpf ct list global
$KC -n kube-system exec <cilium-pod-name> -- cilium-dbg bpf nat list

# Get current Cilium pod names:
$KC -n kube-system get pods -l k8s-app=cilium -o wide
```

### CT entry format
CT entries are keyed by INTERNAL addresses (client/pod IPs), not VIP:
```
TCP IN 10.0.0.0:33482 → 10.244.0.81:8080 [SeenNonSyn] expires=42427
         ^client IP        ^pod IP (not VIP)
```
When grepping, use `10.0.0.0` (client source), not `192.0.2.10` (VIP) or `203.0.113` (loopback).

### After any docker stop/start of a node container
The container's network namespace is re-created; manually-placed veths are lost. Always:
1. Re-run `bash /opt/startup.sh` inside the container
2. Run `bash scripts/fix-node-veths.sh` to re-wire lab veths
3. Wait for BGP to reconverge before testing

---

## Quick-Reference: Lab Addresses

| Entity | Address |
|--------|---------|
| VIP | `192.0.2.10` |
| Client eth1 (source IP for all TCP) | `10.0.0.0` |
| Client loopback | `203.0.113.1` |
| node1 k8s IP | `10.10.0.1` |
| node2 k8s IP | `10.10.0.2` |
| node3 k8s IP | `10.10.0.3` |
| leaf1 → node1 fab | `10.3.1.1` (node side) |
| leaf1 → node2 fab | `10.3.1.3` (node side) |
| leaf1 → node3 fab | `10.3.1.5` (node side) |
| Container prefix | `clab-maglev-clos-<node>` |

## Quick-Reference: Key Scripts

| Script | Purpose |
|--------|---------|
| `scripts/fix-ecmp-hash.sh` | Set `fib_multipath_hash_policy=1` on all switches |
| `scripts/fix-node-veths.sh` | Re-wire containerlab veths after node restart |
| `scripts/fix-node2-cilium.sh` | Restart stuck Cilium pod on node2 |
| `scripts/flowgen-selftest.sh` | Verify flowgen detection works (self-test) |
| `scripts/trace-flow.sh` | Start 1 flow; show CT/NAT + fab0 traffic on all nodes |
| `scripts/diag-smoke.sh` | Full diagnostic smoke test with ECMP + CT snapshots |
| `scripts/check-ct2.sh` | Start 20 flows, dump CT/NAT on all 3 Cilium pods |
| `tests/03-failover.sh` | The main 2×2 experiment |
| `scripts/visualise.py` | Generate `results/summary.html` + timeline/backend plots from JSON |
| `scripts/check-results.py` | Quick summary of broken% across all result JSON files |
| `scripts/preflight.sh` | Validate all repo artifacts (run anytime) |
