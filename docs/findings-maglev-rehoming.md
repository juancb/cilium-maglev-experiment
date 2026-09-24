# Findings: Maglev and flow re-homing across ingress nodes

Status as of the clean-lab run (2026-06-02). This captures what is **empirically
proven** versus **theorised**. It deliberately does **not** modify
`maglev-production-case.md`, whose SNAT-mode claim remains unverified (see below).

> **Update 2026-09-24** (see `findings-cilium-disruption.md`):
> - These runs used `fib_multipath_hash_policy=1`, which in this single-kernel lab
>   re-hashes a flow to a different ECMP member on every TCP retransmission timeout.
>   Flows that retransmitted during a failure could have re-homed spuriously. The fabric
>   now uses policy 3. The DSR headline (Maglev keeps re-homed flows alive) was
>   re-confirmed under policy 3: DSR+Maglev 0% vs DSR+random 7.5% vs SNAT ~24%.
> - The **SNAT question below is now answered**: in Test 5, `.20` flows re-homed in every
>   mode, and SNAT broke them equally with Maglev (24.8%) and random (23.8%). Maglev
>   doesn't help under SNAT.

## Method (what makes these numbers trustworthy)

- **Failure injection — graceful node drain (`tests/04d-graceful-drain.sh`):** cordon
  a worker (node3) and evict all echo pods *off* it first, so every backend lives on a
  surviving node, then drop node3's fabric links. Flows that ingressed node3 must
  re-home to another node, with all backends guaranteed alive — isolating the pure
  re-homing effect from any "backend died" confound.
- **Per-flow re-homing verification (`CAPTURE_PCAP=1` + `scripts/analyze-rehoming.py`):**
  per-node tcpdump → for each flow, the ingress node *before* vs *after* the failure,
  joined with survive/break. A "0% broken" is only meaningful when re-homing actually
  occurred, which the pcap confirms.
- **Stabilization gate (`wait_stable` in `tests/lib/failover-lib.sh`):** after any Cilium
  rollout, a no-failure warm-up flowburst must survive cleanly before measuring — kills
  the post-restart convergence artifact that dominated earlier single-run results.
- Cluster mode/algorithm set cluster-wide via `helm upgrade` per cell on the unannotated
  `echo` VIP (192.0.2.10). (Per-service annotation switching was attempted but is
  unreliable in this Cilium 1.19.4 lab — see "Dead ends".)

## Proven result — Maglev preserves re-homed flows under DSR

Clean lab, 300 flows/cell, pcap-verified:

| cell | flows re-homed | of those survived | broken% |
|------|---------------:|------------------:|--------:|
| **DSR + Maglev** | **151** | **151 (100%)** | **0.0%** |
| DSR + random     | 30 | 26 | 34.0% |

Every one of the 151 flows that re-homed to a new ingress node kept its backend and
survived under Maglev; without it, broken rate is ~34%. This reproduces an earlier clean
run (110 re-homed, 0 broken). **This is the defensible headline: with DSR, Maglev makes a
flow survive an ingress-node change.** The mechanism: the re-homed flow's 5-tuple hashes
to the same backend on the new node (Maglev), and DSR preserves the original client IP so
that backend still recognises the connection.

Plots: `results/plots/rehoming.png` (per-flow outcome bars), `results/plots/timeline.png`
(broken-fraction eCDF).

## NOT proven — the SNAT interaction

| cell | flows re-homed | broken% |
|------|---------------:|--------:|
| SNAT + Maglev | **0** | 51% (in place) |
| SNAT + random | **0** | 43% (in place) |

In the same clean run, the SNAT cells showed **zero re-homing** (with ~50% of flows
breaking *in place*), so they **did not exercise the re-homing path** and cannot prove or
disprove anything about Maglev under SNAT.

- **Theory (unconfirmed):** in SNAT the new ingress node re-masquerades the re-homed flow
  with *its own* source IP, so even the same Maglev backend sees an unknown connection and
  resets it — i.e. Maglev's benefit would require DSR. This is consistent with the
  DSR-vs-SNAT asymmetry above but is **not** directly demonstrated.
- **Open anomaly:** why SNAT shows 0 re-homing while DSR shows 151 under the *identical*
  drain is unexplained. Until that's understood, the SNAT conclusion stays a hypothesis.

**Consequence:** `maglev-production-case.md` argues Maglev helps in a SNAT production
environment. That claim is **neither confirmed nor refuted** by this work — only the DSR
case is proven. Treat the production-case doc's SNAT conclusion as unverified.

## Dead ends (documented so they aren't re-attempted)

- **Hard leaf-switch failure** does not re-home flows in this topology (each node is
  dual-homed to both leaves; killing one leaf reroutes to the same node via the other).
  It resets ~64% of flows *in place* — a fabric-resilience signal, not a Maglev test.
- **Per-service annotations** (`service.cilium.io/lb-algorithm`,
  `forwarding-mode`) in Cilium 1.19.4 here: DSR-annotated services work, but
  SNAT-annotated services aren't programmed on the BPF datapath (SYN forwarded out the
  mgmt interface, never DNAT'd), and annotations only apply at service *creation*. Not a
  reliable basis for the experiment; cluster-wide `helm` config is the trustworthy method.
- **Spine-switch failure** is a no-op for node selection (full mesh; the surviving leaf
  keeps forwarding to the same node).
