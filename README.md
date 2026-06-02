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
make test-fabric   # Test 1: BGP up, ECMP present, per-flow (not per-packet) hash
make test-cilium   # Test 2: kpr/native/masq on; cross-node backend matrix consistent under maglev
make test-maglev   # Maglev paired test: two VIPs (maglev vs random), node drain, per-flow re-homing
make down
```

## Test reference

| Script | Failure injection | What it proves |
|--------|------------------|----------------|
| `tests/01-fabric.sh` | Withdraw spine1's ToR uplink | Fabric is wired correctly; ECMP is per-flow (not per-packet) |
| `tests/02-cilium.sh` | None (read-only probe) | Cilium is in kube-proxy-replacement + native-routing + BPF-masquerade mode |
| `tests/04-maglev-paired.sh` | `kubectl drain` a worker node (removes it from the VIP ECMP set) | Two VIPs over the **same** backends — one annotated `lb-algorithm=maglev`, one `random` — measured under **one** failure. Re-homed flows survive on the maglev VIP and break on the random VIP, proving Maglev keeps the backend across an ingress-node change. |

**Why the paired design:** switching Maglev on/off per-Service via `service.cilium.io/lb-algorithm`
(enabled by `bpf.lbAlgorithmAnnotation`) needs **no Cilium restart**, so both VIPs run
simultaneously over an identical fabric/ECMP state — a true paired comparison with no
rollout-convergence artifact and no run-to-run variance.

**Earlier single-knob tests (leaf-failure, node-drain DSR/SNAT variants) were removed** once we
found that (a) hard leaf failure resets flows in place rather than re-homing them, and (b)
switching the algorithm via `helm upgrade + rollout restart` injected a convergence artifact that
dominated the results. See git history for those scripts.

## Caveats

- **sonic-vs dataplane fidelity** is the top risk: the virtual ASIC may *accept* the
  fine-grained/consistent-hashing config without honoring it in forwarding. `make test-fabric`
  gates this. If it fails, set `EMULATE_CH=1` to reproduce the
  CH-on vs CH-off disturbed sets via scripted next-hop withdrawals so the Maglev comparison
  still runs; Appendix A asserts the real-hardware behavior.
- **Cilium→bird at 127.0.0.1** uses `ebgpMultihop: 2`. If the session won't establish, the
  fallback (Cilium peers the leaves directly) is documented in `k8s/cilium-bgp.yaml`.
- Spines/leaves are FRR (they only do plain ECMP forwarding and never lose a group member, so
  resilient hashing isn't needed there). Swap to `sonic-vs` in `topo/clos.clab.yml` for an
  all-SONiC fabric if you have the RAM.
