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
- Repo at `/mnt/g/Documents/Development/cilium-maglev-experiment` (G:\Documents\Development\...). Container names:
  `clab-maglev-clos-<node>`. Validate artifacts anytime with `bash scripts/preflight.sh`.

## Docker setup
- **Native Docker CE 29.5.2** is installed in WSL Ubuntu-24.04 and listens on
  `/var/run/docker-native.sock`. Docker Desktop's WSL proxy owns the default
  `/var/run/docker.sock`, so a bare `docker`/`containerlab` goes to the WRONG daemon (symptom:
  containerlab reports every container "exited", never wires the leaf veths, bring-up times out).
  Every lab entry script exports `DOCKER_HOST=unix:///var/run/docker-native.sock`; do the same
  for ad-hoc commands. Bridges are visible via netlink on the native daemon (required for
  containerlab veth wiring).
- Images must be in the native daemon. If lost after WSL restart, run:
  `bash scripts/load-images-native.sh`  (loads sonic-vs from `/root/docker-sonic-vs.gz`,
  pulls frr, rebuilds node/client images).
- Bridge stubs are NOT needed with the native daemon (it creates real bridges).
- `scripts/create-bridge-stubs.sh` is a legacy workaround, no longer required.
