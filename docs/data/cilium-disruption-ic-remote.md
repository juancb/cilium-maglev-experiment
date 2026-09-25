# Cilium disruption summary (least → most disruptive by pooled collateral broken%)

coll% = established flows broken by the disruption, excluding flows on a backend the test killed on purpose. Values are mean±stddev over runs.

| cell | coll% ext-cil | coll% ext-static | coll% int | newconn fail% cil/static/int | max outage s cil/static/int | stalled% cil/static/int | stall p50/p95 s cil · static · int | re-homed% cil/static | of re-homed: broken% cil/static | backend changed% cil/static | podCIDR gap s | .20 degraded s | .21 degraded s | Cilium BGP down s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| dz_agent-kill_maglev-snat_etpCluster_itpCluster | 14.8±1.1 | 0.0 | 0.0 | 17.0±12.8 / 12.3±9.7 / 15.6±10.9 | 0.7±0.2 / 0.3±0.2 / 0.6±0.3 | 51.2±1.1 / 41.5±4.2 / 49.2±0.4 | 16.8/16.9 · 16.7/16.9 · 16.8/16.9 | 30.5±7.1 / 0.0 | 49.3±7.9 / - | 0.0 / - | 10.0 | 10.9 | 0.0 | 10.0 |
