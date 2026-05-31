# EXECUTION HANDOFF — read this first (state as of 2026-05-30)

> **You are picking up a half-finished live bring-up.** The repo is fully written and
> syntax-validated; host tools are installed; most images are built. You are ~1 image build
> away from `containerlab deploy`. Start at **NEXT STEPS**.
>
> **When you have absorbed this and the lab is deploying/running, delete this file and remove
> the pointer block from `CLAUDE.md`** (see "Self-removal" at the bottom).

Full design rationale, scaling math, and the 2×2 experiment live in the approved plan:
`~/.claude/plans/ok-let-s-create-a-validated-babbage.md` (this is a condensed operational copy).

---

## What this project is (one paragraph)
A virtual leaf-spine lab that measures a **2×2**: `{ToR consistent-hashing on/off} ×
{Cilium Maglev on/off}`. Open N long-lived TCP flows client→VIP (`192.0.2.10`), `docker stop`
spine1, count flows that RST. Expected ≈ **44%** (CH off/Maglev off), ≈ **22%** (CH on/Maglev
off), ≈ **0%** (Maglev on, either CH). Topology: client → **SONiC ToR** (3-way ECMP across
spines = the CH knob) → **3 FRR spines** → **2 FRR leaves** → **3 k3s nodes** (host `bird` +
Cilium native routing / kube-proxy replacement / BPF masquerade; Cilium BGP peers local bird at
`127.0.0.1`). Addresses/ASNs: `docs/ADDRESSING.md`. Container names: `clab-maglev-clos-<node>`.

## How to run commands (CRITICAL — learned the hard way)
- Agent shell is **Git Bash (MSYS2)** on Windows; the Linux host is **WSL `Ubuntu-24.04`**.
- Run Linux work as **root** (containerlab needs it; user `juan` has NO passwordless sudo):
  `wsl -d Ubuntu-24.04 -u root -- bash -c '<cmd>'`
- **Always prefix the Bash-tool command with `MSYS_NO_PATHCONV=1`** or MSYS rewrites
  `/mnt/c/...` → `C:/Program Files/Git/mnt/...` and everything 404s.
- **Do NOT inline multi-line scripts** via `wsl ... bash -lc '...'` — the bridge mangles
  newlines/`$vars`. Instead **write a script file** into the repo and run
  `bash /mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment/scripts/foo.sh`.
- **Don't trust `/tmp` across separate `wsl` invocations** (a written file read back empty
  later). Do fetch+use in ONE process — see `scripts/fetch-sonic.sh`.
- Azure artifact URLs need `curl -g` (globoff); they contain `[`/`]`.
- Repo path: `C:\Users\Juan\Documents\Development\cilium-maglev-experiment` =
  `/mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment`.
- Host: 16 CPU, 30 GB RAM, 947 GB free. Docker Desktop 29.4.1, WSL integration on.

## DONE so far
- **WSL tools:** containerlab 0.75.0, helm v3.16.3, jq, kubectl, docker — all present
  (via `scripts/wsl-install-tools.sh`).
- **Images:**
  - `docker-sonic-vs:latest` (824 MB) — the **202505** build with fine-grained/consistent-hash
    ECMP. Tarball at `/root/docker-sonic-vs.gz`. (via `scripts/fetch-sonic.sh`.)
  - `quay.io/frrouting/frr:9.1.0` — pulled.
  - `maglev/client:latest` — built.
- **Repo:** all files written; `bash scripts/preflight.sh` passes (shell/JSON/YAML/python green).

## NEXT STEPS (in order)
1. **Build the node image** (interrupted here — immediate next action):
   ```
   MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- bash -c \
     'cd /mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment && docker build -t maglev/k3s-bird:latest nodes/'
   ```
   (downloads k3s v1.31.4+k3s1, helm, cilium CLI, ubuntu:24.04 base; a few minutes.)
2. **Deploy topology** (as root, from repo root so relative binds resolve):
   ```
   MSYS_NO_PATHCONV=1 wsl -d Ubuntu-24.04 -u root -- bash -c \
     'cd /mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment && containerlab deploy -t topo/clos.clab.yml --reconfigure'
   ```
   - If bind-mounted scripts on `/mnt/c` misbehave (exec/perf), copy the repo to `/root/lab`
     and deploy there.
   - Call `containerlab` **directly** as root — do NOT use the `Makefile` `up`/`down` targets
     (they call `sudo containerlab`; `make` may not be installed).
3. **Bootstrap cluster:** `bash scripts/cluster-up.sh` (k3s server node1, agents node2/3,
   Cilium maglev install, applies `k8s/cilium-bgp.yaml` + `k8s/demo-app.yaml`).
4. **Run tests directly with bash:** `bash tests/01-fabric.sh` → `bash tests/02-cilium.sh`
   → `bash tests/03-failover.sh`.

## Likely breakage to expect & fix (don't be surprised)
- **SONiC `config_db.json`** may need tweaks for THIS sonic-vs build's hwsku/port lanes
  (`Force10-S6000`, Ethernet0/4/8/12). If ToR BGP won't come up, check `docker logs
  clab-maglev-clos-tor` and `docker exec clab-maglev-clos-tor show ip bgp summary`.
- **`FG_NHG` consistent hashing may not be honored by the software dataplane** (THE top risk);
  `tests/01-fabric.sh` gates it. If unsupported, the Maglev lever still runs — use the
  `EMULATE_CH` path (scripted next-hop withdrawals) and lean on `docs/APPENDIX-A` for the CH
  claim.
- **Cilium BGPv2 CRD fields** (`k8s/cilium-bgp.yaml`) can drift by Cilium version — if `apply`
  errors, reconcile names with the installed chart. Fallback (peer leaves directly) is in that
  file's header.
- **Cilium→bird at 127.0.0.1**: viable (Cilium BGP doesn't listen by default; dials out; bird is
  `passive`). If sessions don't form, check `docker exec clab-maglev-clos-node1 birdc show
  protocols`.
- **k3s join** needs the fabric converged first (node IPs `10.10.0.x` routed via BGP);
  `cluster-up.sh` already waits on bird uplinks before starting k3s.

## Helper scripts added during bring-up (not in the original plan's file list)
`scripts/preflight.sh` (validate all artifacts + tool/image inventory),
`scripts/wsl-install-tools.sh` (containerlab/helm/jq), `scripts/fetch-sonic.sh` (download+load
sonic-vs).

## Self-removal (do this once context is absorbed and deploy is underway)
1. Delete this file: `HANDOFF.md`.
2. Remove the `>>> ACTIVE HANDOFF` pointer block at the top of `CLAUDE.md`.
