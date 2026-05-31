#!/usr/bin/env bash
# Disable consistent hashing on the ToR — VIP falls back to plain (non-resilient) ECMP,
# so a spine loss rehashes the whole group. Run on the host:
#   docker exec clab-maglev-clos-tor /etc/sonic/ch-off.sh
set -euo pipefail

VIP_PREFIX="192.0.2.10/32"

echo "[ch-off] removing consistent-hashing binding for ${VIP_PREFIX} (plain ECMP)"

# Deleting only the PREFIX binding is enough to revert the VIP to normal ECMP;
# the FG_NHG/members are left defined so ch-on.sh can re-bind instantly.
sonic-db-cli CONFIG_DB del "FG_NHG_PREFIX|${VIP_PREFIX}"

echo "[ch-off] done. VIP now uses standard ECMP (rehashes on member change)."
