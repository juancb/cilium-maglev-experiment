# Cilium disruption summary (least → most disruptive by pooled collateral broken%)

coll% = established flows broken by the disruption, excluding flows on a backend the test killed on purpose. Values are mean±stddev over runs.

| cell | coll% ext-cil | coll% ext-static | coll% int | newconn fail% cil/static/int | max outage s cil/static/int | stalled% cil/static/int | stall p50/p95 s cil · static · int | re-homed% cil/static | of re-homed: broken% cil/static | backend changed% cil/static | podCIDR gap s | .20 degraded s | .21 degraded s | Cilium BGP down s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| dz_agent-restart_maglev-snat_etpCluster_itpCluster | 100.0 | 55.5±19.8 | 69.0±2.8 | 26.6±1.4 / 18.2±1.7 / 32.9±1.4 | 0.9±0.4 / 0.5 / 1.4±0.1 | 0.0 / 14.2±20.2 / 0.0 | 30.0/30.0+ · 30.0/30.0+ · 30.0/30.0+ | 100.0 / 0.0 | 100.0 / - | 0.0 / - | 38.5 | 102.7 | 0.0 | 38.5 |
