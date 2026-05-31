#!/usr/bin/env bash
# Enable consistent hashing (resilient ECMP) on the ToR for the Service VIP.
# Run on the host:  docker exec clab-maglev-clos-tor /etc/sonic/ch-on.sh
# (the Makefile binds this file in; or `docker cp` it.)
set -euo pipefail

VIP_PREFIX="192.0.2.10/32"
FG_NHG="vip_chash"

echo "[ch-on] installing FG_NHG '$FG_NHG' and binding $VIP_PREFIX → consistent hashing"

sonic-db-cli CONFIG_DB hset "FG_NHG|${FG_NHG}" bucket_size 120 match_mode nexthop-based
# each spine next-hop in its own bank → losing one spine only redistributes that bank
sonic-db-cli CONFIG_DB hset "FG_NHG_MEMBER|10.1.1.1" FG_NHG "${FG_NHG}" bank 0   # spine1
sonic-db-cli CONFIG_DB hset "FG_NHG_MEMBER|10.1.1.3" FG_NHG "${FG_NHG}" bank 1   # spine2
sonic-db-cli CONFIG_DB hset "FG_NHG_MEMBER|10.1.1.5" FG_NHG "${FG_NHG}" bank 2   # spine3
sonic-db-cli CONFIG_DB hset "FG_NHG_PREFIX|${VIP_PREFIX}" FG_NHG "${FG_NHG}"

echo "[ch-on] done. Verify:  show fgnhg active-hops ${FG_NHG}"
