# Cilium Maglev × Switch Consistent-Hashing Failure-Impact Lab

A virtual leaf-spine fabric that measures, empirically, what **consistent hashing** buys you
at two independent layers when a **spine switch fails**:

1. **Switch layer — consistent hashing ≡ resilient ECMP.** When a spine leaves an ECMP group,
   does only the failed member's share of flows move (CH on), or does the whole group rehash
   (CH off)? Toggled on the SONiC ToR.
2. **Cilium service-LB layer — Maglev.** When a flow lands on a *different ingress node*
   mid-connection, does that node recompute the **same** backend (Maglev on → TCP survives) or
   a different one (Maglev off → RST)?

These two levers compound, so the headline experiment is a **2×2** over
`{ToR CH on/off} × {Maglev on/off}`:

| | switch CH **off** | switch CH **on** |
|---|---|---|
| **Maglev off** | ≈ **44%** flows reset | ≈ **22%** flows reset |
| **Maglev on**  | ≈ **0%** | ≈ **0%** (best) |

Full rationale, scaling math, and the spine-vs-leaf-failure justification live in the approved
plan file (`~/.claude/plans/ok-let-s-create-a-validated-babbage.md`).

## Topology

```
client ── tor(SONiC, CH knob) ──3x── spine1/2/3(FRR) ──mesh── leaf1/2(FRR) ──── node1/2/3
                                                                         (k3s + host bird + Cilium)
```

- **1 ToR / 3 spine / 2 leaf / 3 node.** The ToR owns the 3-way ECMP across spines — that's
  the group a spine failure shrinks 3→2, so the CH knob has a survivor set to preserve. (A pure
  2-spine fabric can't show the CH lever: every group is size 2 and collapses to 1 on failure.)
- Each node has **two NICs** (`fab0`→leaf1, `fab1`→leaf2), each an eBGP session. Plus a
  `public` /32 and a `k8s` InternalIP interface.
- **bird runs on the host** (not a container) and owns the two uplink BGP sessions; **Cilium's
  BGP control plane peers the local bird** at `127.0.0.1` and originates the Service VIP /
  pod CIDR into it.
- Cilium: kube-proxy replacement, native routing, BPF masquerade, BGP control plane.

Addressing and ASNs: [docs/ADDRESSING.md](docs/ADDRESSING.md).
SONiC↔Arista↔SAI consistent-hashing mapping: [docs/APPENDIX-A-arista-mapping.md](docs/APPENDIX-A-arista-mapping.md).

## Prerequisites (WSL2 / Linux)

- Docker, [containerlab](https://containerlab.dev), `kubectl`, `helm`, `cilium` CLI, `jq`.
- **SONiC** `docker-sonic-vs` image (`docker load -i docker-sonic-vs.gz`).
- `.wslconfig` sized to ~12–14 GB (1 sonic-vs + 5 FRR + 3 k3s nodes + client).
- Build the node + client images once:
  ```bash
  make images        # builds maglev/k3s-bird:latest and maglev/client:latest
  ```

## Run

> **Important:** always use `make up` / `make down` (or `bash scripts/bring-up.sh` / `bash scripts/tear-down.sh`
> directly as root in WSL). Never run `containerlab deploy` by hand — the ext-container node
> containers must be created by `start-nodes.sh` first, and the deploy must be killed once veth
> pairs appear. `bring-up.sh` handles all of this automatically.

```bash
make up              # deploy topology, bring up k3s+Cilium(maglev) on each node, apply demo app
make test-fabric     # Test 1: BGP up, ECMP present, per-flow (not per-packet) hash, ToR CH on vs off
make test-cilium     # Test 2: kpr/native/masq on; cross-node backend matrix consistent under maglev
make test-failover   # Test 3: the 2×2 — N flows, stop spine1, count resets per cell
make sweep           # vary B (and M) → results/sweep.csv + plot vs. predicted curve
make down
```

## Test reference

| Script | Failure injection | What it proves |
|--------|------------------|----------------|
| `tests/01-fabric.sh` | Withdraw spine1's ToR uplink | Fabric is wired correctly; ToR consistent-hashing (CH) moves only ~1/3 of flows (CH on) vs ~2/3 (CH off) when a spine is removed |
| `tests/02-cilium.sh` | None (read-only probe) | Cilium is in kube-proxy-replacement + native-routing + BPF-masquerade mode; with Maglev, every node selects the **same** backend for a given 5-tuple |
| `tests/03-failover.sh` | Stop spine1 (ToR ECMP 3→2) | Headline 2×2: `{ToR CH on/off} × {Maglev on/off}` — measures reset % vs prediction `D·((M-1)/M)·((B-1)/B)` |
| `tests/04b-dsr.sh` | Stop spine1 (same as Test 3) | DSR variant: Maglev on vs off with Direct Server Return active so the backend sees the original client IP — confirms Maglev selects the same live backend after re-homing |
| `tests/04c-dsr.sh` | `kubectl drain` with long grace period | Node-drain variant: graceful pod eviction gives Maglev time to re-home flows to surviving backends; drain timeout >> flowgen socket timeout so no RSTs expected with Maglev on |

**What is never done in 04b:** node interface failure, node isolation, or anything that takes a k8s node off the network. Spine failure only.

## What each test proves

- **Test 1 (`tests/01-fabric.sh`)** — fabric is wired correctly *and* consistent hashing works:
  shutting spine1's ToR link moves only ~1/3 of flows with CH on, ~2/3 with CH off. The
  measured disturbed-set `D` feeds Test 3's prediction.
- **Test 2 (`tests/02-cilium.sh`)** — Cilium is in the required mode and, with Maglev, every
  node selects the **same** backend for a given 5-tuple (the mechanism that lets a re-homed
  flow survive).
- **Test 3 (`tests/03-failover.sh`)** — the headline: open `N` long-lived TCP flows, stop
  spine1, count resets in each of the four `{CH}×{Maglev}` cells, compare to
  `D·((M-1)/M)·((B-1)/B)`.

## Caveats

- **sonic-vs dataplane fidelity** is the top risk: the virtual ASIC may *accept* the
  fine-grained/consistent-hashing config without honoring it in forwarding. `make test-fabric`
  gates this. If it fails, set `EMULATE_CH=1` (see `tests/03-failover.sh`) to reproduce the
  CH-on vs CH-off disturbed sets via scripted next-hop withdrawals so the Maglev comparison
  still runs; Appendix A asserts the real-hardware behavior.
- **Cilium→bird at 127.0.0.1** uses `ebgpMultihop: 2`. If the session won't establish, the
  fallback (Cilium peers the leaves directly) is documented in `k8s/cilium-bgp.yaml`.
- Spines/leaves are FRR (they only do plain ECMP forwarding and never lose a group member, so
  resilient hashing isn't needed there). Swap to `sonic-vs` in `topo/clos.clab.yml` for an
  all-SONiC fabric if you have the RAM.
