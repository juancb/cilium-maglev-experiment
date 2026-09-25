# Findings: how much does Cilium itself disrupt the data plane?

Status as of the 2026-09-24 run (Cilium 1.19.1, upgrade target 1.19.8). Full per-cell tables:
`docs/data/cilium-disruption-prod-mirror-noGR.md`, `docs/data/cilium-disruption-gr-enabled.md`. Raw results (local, gitignored):
`results/prod-mirror-noGR/` (64 runs) and `results/gr-enabled/` (graceful-restart
comparison). Test: `tests/05-cilium-disruption.sh`; summariser:
`scripts/disruption-summary.py`.

## TL;DR

1. **Killing a backend pod (app OOM) costs nothing beyond that pod's own flows.** Zero
   collateral breakage in all 8 combinations (maglev/random × SNAT/DSR × eTP/iTP).
2. **Almost all of Cilium's disruption comes from BGP, not the BPF datapath.** With no
   graceful restart, any agent restart closes the bird↔Cilium session, and bird withdraws
   the node's **pod CIDR** and any VIP **only Cilium originates**. The datapath keeps
   forwarding; the fabric just stops sending it traffic (or stops routing replies to it).
3. **A rollout or upgrade costs much more than an OOM kill.** A SIGKILL restarts the agent
   container in place (median 8.4s route gap). A rollout replaces the pod, init containers
   and all (median 43–46s route gap per node, up to 85s), and the chart's default
   `maxUnavailable: 2` takes two nodes out at once.
4. **During a rollout with eTP/iTP = Cluster, ~70% of external flows and ~65% of in-cluster
   flows break** (stall > 30s), whatever the LB algorithm or forwarding mode, and 28–50%
   of new connections fail. **With eTP/iTP = Local and a stable VIP route, that drops to
   ~1% and 0%.**
5. **A VIP advertised only by Cilium breaks 100% of its flows in every rollout.** The VIP is
   withdrawn from each restarting node, so its flows re-home to another node that has no
   state for them. eTP=Local doesn't help here, and makes a re-home certain to break.
6. **A re-homed flow survives only with DSR + Maglev** (per-flow pcap attribution, 140/140
   re-homed flows survived, 0 changed backend). Under SNAT every re-homed flow with a live
   backend broke, Maglev or not (145/145). Under DSR + random the new node picks a
   different backend 5 times in 6; when that backend is local to the new node the pod
   RSTs the flow; when it's remote the pod's RST leaves with the pod's IP instead of the
   VIP, the client ignores it, and the flow stalls. This settles the open SNAT question in
   `findings-maglev-rehoming.md`: under SNAT, Maglev can't save a re-homed flow.
7. **Turning on graceful restart in Cilium alone (bird/FRR are already helpers) removes
   nearly all of it.** Rollout, upgrade and OOM all went to 0% broken and 0% new-connection
   failures, with no pod-CIDR gap, and 10 of 10 single-node pod replacements moved nothing.
   One ~1.5s VIP blip was seen once in 16 node restarts, only during a two-nodes-at-a-time
   rollout.
8. **`maxUnavailable: 1` halves the peak but not the total.** Rolling one node at a time
   cut the worst new-connection failure rate from ~50% to ~27% and never had two nodes'
   routes missing at once, but every cross-node flow still stalled for one full agent
   restart; whether that counts as "broken" depends only on the restart time vs the
   client's timeout (41% and 69% static-VIP breakage in two identical runs).
9. **Agent restart time is the whole game, and it varies a lot.** Two identical OOM kills
   gave a 5.7s and a 28.7s route gap; the first broke 0% of static-VIP flows, the second
   23.5% (timeouts at the 30s threshold). A stall also outlasts the route gap by up to one
   TCP retransmit backoff (16.8s stalls on a 10s gap).

**Least disruptive:** backend OOM (any config), anything with Cilium GR enabled, and agent
OOM against a statically routed VIP with eTP/iTP=Local (0% broken, ~0% stalled). **Most
disruptive (the prod config):** an agent rollout or upgrade against a Cilium-originated
VIP (100%), or against any VIP with eTP/iTP=Cluster (~70% stalled past 30s).

## Setup

- 3 nodes (k3s + Cilium 1.19.1, kube-proxy replacement, native routing), host bird per
  node, 2 FRR leaves, 3 FRR spines, SONiC ToR. 6 echo backends (2 per node).
- **BGP mirrors prod:** hold 90s / keepalive 30s on node↔leaf and bird↔Cilium; no BFD;
  no graceful restart configured. Defaults are bird GR "aware" (helper), FRR helper,
  and Cilium GR off. Verified live with `make verify-bgp` before every matrix.
- Three client populations run at the same time through every disruption, each with 200
  long-lived flows (100ms echo keepalive) and a 10 Hz new-connection prober:
  - **ext-cil**: external client → `192.0.2.20`, a VIP advertised **only by Cilium BGP**.
  - **ext-static**: external client → `192.0.2.21`, the same service also statically
    originated by bird. This is the "BGP unharmed" control.
  - **int**: a pod on node2 → the ClusterIP. iTP only affects this population; eTP only
    affects the two external ones.
- **Disruptions** (target node2 for kills):
  - `agent-restart`: `kubectl rollout restart ds/cilium`.
  - `agent-upgrade`: `helm upgrade` 1.19.1 → 1.19.8, images pre-pulled.
  - `agent-kill`: SIGKILL of cilium-agent, i.e. what the OOM killer does. A real OOM
    isn't possible in this lab because cgroup memory limits aren't enforced.
  - `backend-kill`: SIGKILL of one echo pod on node2.
- A flow counts as **broken** on an RST or a stall longer than 30s. A stall of 1–30s that
  recovers is reported separately as **stalled**: a real TCP client rides through it with
  a hiccup.
- A leaf1 route timeline sampled every 0.25s records pod-CIDR and VIP nexthops and the
  bird↔Cilium session state.

## Results

Broken % (collateral: excludes flows on a backend the test killed on purpose). Mean of
2 runs. ext-cil / ext-static / int.

### Backend OOM (SIGKILL one echo pod)

Every combination: **0 / 0 / 0**. New-connection failures < 3%, max outage < 0.3s. The
killed pod's own flows die (by definition); nothing else notices.

### Agent OOM (SIGKILL cilium-agent on node2)

| LB | eTP/iTP | ext-cil | ext-static | int | stalled (cil/static/int) |
|---|---|---|---|---|---|
| maglev+DSR | Cluster | **0.0** | 0.0 | 0.0 | 33 / 28 / 66% |
| random+DSR | Cluster | 7.5 | 0.0 | 0.0 | 44 / 29 / 68% |
| random+SNAT | Cluster | 23.8 | 0.0 | 0.0 | 34 / 32 / 68% |
| maglev+SNAT | Cluster | 24.8 | 0.0 | 0.0 | 31 / 25 / 68% |
| random+DSR | Local | 30.8 | 0.0 | 0.0 | ~1–3% |
| maglev+DSR | Local | 33.8 | 0.0 | 0.0 | ~1% |
| maglev+SNAT | Local | 34.2 | 0.0 | 0.0 | ~1% |
| random+SNAT | Local | 37.8 | 0.0 | 0.0 | ~1% |

Node2's pod CIDR and `.20` left the fabric for a median 8.4s (2–24s).
- **Cluster:** every flow that crosses to or from node2's pods stalls (25–68% of flows,
  worst ~17–30s), but survives.
- **Local:** nothing crosses nodes, so nothing stalls.
- **ext-cil breaks** are flows that had ingressed node2 and were forced onto another node
  when `.20` was withdrawn.
  - Under SNAT the new ingress re-SNATs, so the backend RSTs whatever backend is chosen.
  - Under DSR the backend sees the real client IP, and Maglev picks the same backend again.
  - Under Local the new ingress always picks a different, *local* backend.
- The per-flow attribution below explains the DSR+random number (see "What happens to a
  re-homed flow").

### Agent rollout and upgrade (pod replacement, 2 nodes at a time)

| eTP/iTP | ext-cil | ext-static | int | new-conn fail (cil/static/int) |
|---|---|---|---|---|
| Cluster (all 8 LB/version combos) | 100 | 69–73 | 63–68 | 40–50 / 27–32 / 35–52% |
| Local (all 8 combos) | 100 | 0.2–1.8 | 0.0 | 1–2 / ~0 / 0% |

- Per-node pod-CIDR gap: median 43s (restart) and 46s (upgrade); range 28–85s. `.20` was
  degraded for 75–108s per run.
- Maglev vs random and SNAT vs DSR make no difference here. The gap outlasts the 30s
  break threshold, and a real client would stall for about a minute.
- The upgrade (1.19.1 → 1.19.8) behaved like a plain rolling restart. The version change
  itself added nothing measurable.

## What happens to a re-homed flow (pcap attribution, `results/rehome/`)

`CAPTURE_PCAP=1` records which node ingressed every flow before and after the kill and
which backend the new node forwarded it to. 8 agent-kill runs, eTP/iTP=Cluster, 200
Cilium-VIP flows each. About a third of the flows re-home when `.20` leaves node2 (the
leaf's hash-threshold ECMP moves ~1/3 of flows when one of three nexthops disappears).

| re-homed flows whose backend was NOT on node2 | n | broke | of those: same backend | changed backend |
|---|---|---|---|---|
| **DSR + Maglev** | 95 | **0%** | 38 (0% broke) | 1 |
| DSR + random | 83 | 21.7% | 9 | 44 |
| SNAT + Maglev | 86 | **100%** | 37 (100% broke) | 0 |
| SNAT + random | 91 | 65.9% | 2 | 45 |

("same/changed" is only visible when the backend is remote from the ingress node; local
delivery uses `bpf_redirect_peer`, which the capture can't see.)

- **Maglev is consistent across nodes** (0 changed backends in 76 visible re-homes);
  **random is not** (89 changed of 100 visible).
- **SNAT + Maglev broke every re-homed flow with a live backend**, same backend or not:
  the new ingress node SNATs with its own IP, so the backend sees a new 4-tuple and
  resets it. SNAT + random "only" 66% because some of its picks landed on node2 (below).
- **DSR + Maglev survived every re-home**: the backend node still holds the DSR
  conntrack entry from the original SYN, so the packet is delivered and the pod continues.
- **DSR + random**: when the new backend is *local* to the new ingress node the pod gets
  the mid-stream segment and RSTs it (~2/6 of picks; 17 and 18 resets in the two runs,
  27% of re-homed both times). When it is *remote*, the DSR packet arrives at a backend
  node with no DSR state for that flow. The pod replies with an RST, but the node sends it
  out with the *pod's* IP as source instead of the VIP (captured: `10.244.2.177 >
  203.0.113.1`), so the client, connected to the VIP, ignores it. The flow stalls and,
  in this lab, survives only because node2's route came back ~10s later and ECMP moved it
  home, where its original state still lived.
- **Any flow whose backend was on node2** (the disrupted node) was blackholed by the
  withdrawn pod CIDR rather than reset, and likewise survived only by returning home.

So in this lab a re-homed flow can "survive" three ways, and only the first is real:
DSR+Maglev (delivered), DSR+wrong remote backend (dropped, waited it out), backend on
the dead node (blackholed, waited it out). **In production a re-home is usually
permanent** (the node is gone), so the last two become "stall until the client gives
up": a permanently re-homed flow survives only under DSR + Maglev.

## What drives the disruption

| Mechanism | Triggered by | Hurts | Fixed by |
|---|---|---|---|
| Pod CIDR withdrawn while the node's agent is down (no GR) | every agent restart | anything crossing nodes to or from that node's pods: eTP/iTP=Cluster traffic, SNAT/DSR hops to remote backends, pod→remote-backend replies | graceful restart (see below), statically originated pod CIDRs, or eTP/iTP=Local |
| Cilium-only VIP withdrawn from the node | every agent restart | flows ingressing that node re-home. SNAT breaks always; Local breaks always; DSR+Maglev survives if the backend path works | GR, or originate the VIP independently of the agent (bird static, like `.21`) |
| Pod replacement time | rollout/upgrade | makes both of the above last 30–85s instead of ~8s | GR; faster agent start; `maxUnavailable: 1` |
| Backend process death | app OOM | only its own flows | nothing needed |

## Graceful-restart comparison

This is **not** the prod config: it answers what enabling GR on Cilium would buy. The
only change was `gracefulRestart: {enabled: true, restartTimeSeconds: 120}` on the
`CiliumBGPPeerConfig`. bird (GR "aware") and FRR (helper) were left at their defaults,
and they honored it. maglev+SNAT, eTP/iTP=Cluster, 2 runs each. Afterwards the lab was
restored to no-GR and re-verified.

| Disruption | GR off: broken cil / static / int | **GR on** | Pod-CIDR gap off → on | New-conn fail off → on |
|---|---|---|---|---|
| agent-kill (OOM) | 24.8 / 0 / 0, plus 25–68% stalled | **0 / 0 / 0, 0% stalled** | 10.8s → **0** | 9–21% → **0** |
| agent-upgrade | 100 / 69 / 67.5 | **0 / 0 / 0** | 75s → **0** | 28–52% → **0** |
| agent-restart | 100 / 71 / 68 | 15.8 / 0 / 0 (see below) | 61s → **0** | 33–50% → **0** |

- The bird↔Cilium session still drops for the whole restart (8s kill, ~50s rollout). bird
  keeps the node's routes as stale until the new agent re-peers, so the fabric never
  notices.
- A graceful SIGTERM shutdown did not cancel GR.
- **Residual race.** In 1 of 6 node restarts during the two-at-a-time rollout, `.20` lost
  that node for ~1.5s exactly when the new agent re-peered, and the 63 SNAT flows
  ingressing that node re-homed and reset. The pod CIDR never blipped. A follow-up of
  **10 single-node pod replacements with GR on** (`results/gr-repeer/`, `agent-delete`)
  showed **0 flows moved and 0 broken in all 10**. So it is 1 in 16 node restarts overall
  and only seen while another node was restarting at the same time. It looks like the new
  agent signalling End-of-RIB before its Service advertisements were in place. Not
  confirmed against Cilium's reconciler; worth a Cilium issue if it can be reproduced.

## Follow-up batches

All GR off (prod mirror) unless stated. Tables in `docs/data/cilium-disruption-<batch>.md`.

- **`maxUnavailable: 1`** (`maxunavail1/`, rolling restart, maglev/SNAT, Cluster, 2 runs):
  nodes restarted strictly one at a time (route gaps 25s / 44s / 45s and 38s / 44s / 47s).
  Peak new-connection failures fell to 27% / 18% / 33% (cil / static / int) from
  50% / 33% / 46%. Static-VIP flows broken: 41% and 69% (vs 71%): in the first run one
  node's gap was under the 30s threshold, in the second none was. In-cluster: 69% (vs
  68%). Every cross-node flow still stalls for one full agent restart.
- **Node loses its last local backend, eTP/iTP=Local** (`lastbackend/`, `KILL_COUNT=all`,
  3 pods on node2 killed): external collateral 0% and 22% in the two runs. In the first the
  containers were back in ~3s and Cilium never withdrew the VIP; in the second they took
  ~20s, Cilium withdrew `.20` from node2 for 5s, and all 35 flows that had ingressed node2
  re-homed and reset. In-cluster (iTP=Local, client on node2): every flow was on a killed
  pod by definition, and 4% / 37% of new connections failed while node2 had no ready
  local backend: **iTP=Local refuses rather than forwards** when the node has nothing
  local.
- **In-cluster client on a healthy node** (`ic-remote/`, client on node1, node2's agent
  killed, 2 runs): flows to node2's backends all stalled (99/99 and similar, up to 17s),
  none broke; flows to node1/node3 backends untouched. Same mechanism seen from the other
  side.
- **GR on, 10 single-node pod replacements** (`gr-repeer/`): 0 / 0 / 0 broken, 0 stalled,
  0 re-homed, no route gap, in all 10.

## Recommendations for the prod environment

(Ordered by impact on these results. All assume BGP to the fabric stays up.)

1. **Enable graceful restart on Cilium's BGP peer** (`restartTimeSeconds` longer than your
   slowest agent pod start; 120s covered 85s here). bird's default already acts as helper,
   so this is a Cilium-side change only, and doesn't need GR or BFD on the fabric. In this
   lab it took every agent disruption from up to 100% broken to 0%.
   - For VIPs, also originate them from bird statically (like `.21`) or otherwise
     independently of the agent. That covers the re-peer race, and the case where the
     agent is down longer than the restart timer.
2. **Use eTP=Local (and iTP=Local) for latency-sensitive services, but only if the VIP
   route is stable.** It removes the cross-node dependency, which eliminated ~70% breakage
   during rollouts. If the VIP can be withdrawn from a node, Local guarantees those flows
   break.
3. **Roll the agent DaemonSet with `maxUnavailable: 1`** and pre-pull images. It halves
   the peak failure rate and keeps only one node's routes missing at a time, but without
   GR every cross-node flow still stalls for one agent restart; treat it as damage
   limitation, not a fix.
4. **If flows can re-home at all, DSR + Maglev** is the only combination in which a
   re-homed flow survived (140/140, pcap-verified). Under SNAT every re-homed flow with a
   live backend broke, with or without Maglev.
5. Backend OOMs need no mitigation from Cilium's side, with one eTP=Local exception: if a
   node loses its *last* ready backend for longer than Cilium's reconciliation (~20s
   here), the VIP is withdrawn from that node and its flows re-home and break. Keep at
   least two backends per node under eTP=Local, or use pod anti-affinity that guarantees
   it.

## Caveats

- **ext-cil percentages in the main matrix are not comparable across cells** (the
  re-home fraction varies per run: 25–37% of flows). The pcap-attributed follow-up
  (`results/rehome/`) is the comparable view: read "of re-homed flows, % broken" there.
- **The main matrix ran without per-flow capture.** Its agent-kill cells were re-run with
  capture (`rehome/`) and agree with it; the rollout cells were not, and their "100%
  ext-cil" is by construction (every node restarts, so every flow re-homes).
- **"Broken" during rollouts means stalled > 30s**, the threshold this test uses. The
  pod-CIDR gap was 28–85s, so the ~70% is really "stalled for 30–85s". A stall-duration
  distribution would be the better headline for the GR-off rollout case.
- **`podCIDR gap s` is the longest single node's gap**, not the union; two nodes were
  missing at once during rollouts.
- **Transient vs permanent re-home.** Every re-home in this lab was transient (node2's
  route returned after ~10s and most flows moved back). Survival figures for anything
  other than DSR+Maglev depend on that; see "What happens to a re-homed flow".
- **Absolute gap durations are lab-inflated.** Agent pod start-up on WSL/9p is slow. Prod
  will be shorter, but the mechanism (routes absent for the agent's whole restart) is the
  same.
- **3 nodes with `maxUnavailable: 2` means two thirds of the cluster** had routes withdrawn
  at once during rollouts. In a large cluster, the *fraction* of flows hit per step is
  smaller, but each affected flow sees the same gap.
- "Broken" means an RST, or a stall longer than 30s. Real TCP retransmits for minutes, so
  some long stalls might survive at the transport layer. Most application timeouts would
  not.
- One target node (node2) for kills, 2 runs per cell. The spread between runs is small
  (see ± in `disruption-summary.md`).

## Lab fixes made while validating (these changed results)

1. **ECMP hashing followed the socket hash, not the headers.** Every hop shares one kernel
   over veth, and `fib_multipath_hash_policy=1` reuses `skb->hash`. Linux re-randomizes the
   client's hash on every TCP retransmission timeout, so a flow that merely *stalled* got
   re-hashed to another node: a fake re-home, and an RST under SNAT. Now policy 3
   (5-tuple). **Earlier results in `findings-maglev-rehoming.md` ran under policy 1**, so
   any flow that retransmitted during those tests could have re-homed spuriously.
2. **Cilium-only VIPs were originated by one node.** bird couldn't resolve Cilium's next
   hop (the node's own IP), so it preferred the fabric-learned copy of the VIP and stopped
   originating it. Cilium VIP routes are now pinned to `dev k8s`, and nodes no longer
   re-export routes they learned from one leaf to the other.
3. **Withdrawn pod-CIDR traffic leaked out the docker management interface.** Nodes now
   blackhole `10.244.0.0/16` at low priority.
4. **flowgen counted any 5s stall as broken.** It now has `--timeout` (30s in Test 5) and
   records each flow's longest stall.
5. **Re-homing attribution needed two fixes** before the pcap numbers were right: a flow
   that re-homes and breaks within a second, or re-homes and moves back, looked "stayed"
   to a dominant-node-after test (now: any other node seen after the kill); and a forward
   packet is captured both by the node that sends it and by the node that hosts the pod,
   which had made the "new backend" follow the returned flow (now: sender's view only).

## Reproduce

```bash
make verify-bgp
MODES="snat dsr" RUNS=2 DUR_ROLLOUT=240 make test-disruption      # ~5h
python3 scripts/disruption-summary.py results
```
