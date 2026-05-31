<!-- >>> ACTIVE HANDOFF >>> -->
> **START HERE:** There is an in-progress live bring-up of this lab. **Read `HANDOFF.md` in the
> repo root before doing anything**, then continue from its "NEXT STEPS".
> Once you've absorbed the context and the deploy is underway, **delete `HANDOFF.md` and remove
> this pointer block** (everything between the `>>> ACTIVE HANDOFF >>>` markers).
<!-- <<< ACTIVE HANDOFF <<< -->

# cilium-maglev-experiment

Virtual leaf-spine lab measuring the impact of Cilium **Maglev** consistent hashing and switch
**consistent-hashing ECMP** on established TCP flows during a spine-switch failure. See
`README.md` for the overview, `docs/ADDRESSING.md` for the IP/ASN plan, and the approved plan at
`~/.claude/plans/ok-let-s-create-a-validated-babbage.md` for full rationale.

## Running things (this host)
- Linux runs in **WSL `Ubuntu-24.04`**; the agent shell is **Git Bash (MSYS2)**.
- Run as root: `wsl -d Ubuntu-24.04 -u root -- bash -c '<cmd>'`. User `juan` has no passwordless
  sudo, so containerlab must run as root.
- **Prefix every Bash-tool command with `MSYS_NO_PATHCONV=1`** or `/mnt/c/...` paths get
  mangled. Don't inline multi-line scripts through the wsl bridge — run script *files*.
- Repo at `/mnt/c/Users/Juan/Documents/Development/cilium-maglev-experiment`. Container names:
  `clab-maglev-clos-<node>`. Validate artifacts anytime with `bash scripts/preflight.sh`.
