# Appendix A — Consistent hashing ≡ Resilient ECMP ≡ SONiC Fine-Grained ECMP

The lab toggles consistent hashing on a virtual SONiC ToR. This appendix records the
three-way equivalence so the result translates to a real Arista fabric, and so reviewers can
see that "resilient ECMP" and "consistent hashing" are the same property under different
vendor names.

## The property

When a next-hop leaves (or joins) an ECMP group, **only the flows on the changed member are
re-bucketed; every other flow keeps its next-hop.** Plain ECMP recomputes `hash mod N` for the
whole group, so changing `N` moves most flows. Consistent/resilient hashing fixes the bucket
table so survivors are undisturbed.

In this lab that is exactly what bounds the disturbed set `D` on a spine failure:
`D ≈ N/P` (resilient) vs `D ≈ (P-1)/P · N` (plain).

## Three-way mapping

| Concept                         | SONiC (this lab)                                  | Arista EOS                                             | SAI (ASIC layer)                                  |
|---------------------------------|---------------------------------------------------|-------------------------------------------------------|---------------------------------------------------|
| Feature name                    | Fine-Grained ECMP / consistent hashing            | Resilient ECMP (resilient hashing)                    | Fine-grain ECMP next-hop group                    |
| Where configured                | `FG_NHG`, `FG_NHG_PREFIX`, `FG_NHG_MEMBER` (config_db) | `router general` / next-hop-group `resilient`     | `SAI_NEXT_HOP_GROUP_TYPE_FINE_GRAIN_ECMP`         |
| Bucket table size               | `FG_NHG.bucket_size` (120 here)                    | `resilient ... capacity <buckets>`                    | `SAI_NEXT_HOP_GROUP_ATTR_CONFIGURED_SIZE`         |
| Member→bank assignment          | `FG_NHG_MEMBER.bank`                               | implicit / per-group                                  | real-time vs configured member set                |
| Bind to a prefix                | `FG_NHG_PREFIX` (192.0.2.10/32)                    | applied to the route/next-hop-group                   | next-hop-group on the route entry                 |
| Per-flow (not per-packet)       | yes — 5-tuple hash into the bucket table          | yes — flow-based                                      | yes — hash seed + fields select a fixed bucket    |

## Arista EOS equivalent of `fabric/tor/config_db.json` + `ch-on.sh`

```
! Resilient ECMP for the Service VIP toward the three spines.
router general
   hardware next-hop-group resilient
!
ip route 192.0.2.10/32 10.1.1.1   name to-spine1
ip route 192.0.2.10/32 10.1.1.3   name to-spine2
ip route 192.0.2.10/32 10.1.1.5   name to-spine3
!
! (On real 7050X/7060X-class hardware, resilient hashing keeps survivor flows pinned when one
!  spine next-hop is withdrawn — the same behavior ch-on.sh asks sonic-vs to emulate.)
```

`ch-off.sh` ≡ removing the resilient binding so the VIP uses standard ECMP, which rehashes the
whole group on a member change.

## Why this matters for the experiment

`sonic-vs` has a *software* dataplane and may accept the FG_NHG config without honoring it in
forwarding (the lab's top risk, gated by `make test-fabric`). On real Arista silicon the
resilient-hashing behavior is a hardware guarantee. This appendix is the bridge: the lab
*measures* Maglev's effect empirically and *asserts* the switch-CH effect via this mapping when
the virtual ASIC can't reproduce it. If `sonic-vs` does honor FG_NHG, the 2×2 shows both
levers empirically and this appendix is just the production translation.
