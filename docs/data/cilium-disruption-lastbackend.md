# Cilium disruption summary (least → most disruptive by pooled collateral broken%)

coll% = established flows broken by the disruption, excluding flows on a backend the test killed on purpose. Values are mean±stddev over runs.

| cell | coll% ext-cil | coll% ext-static | coll% int | newconn fail% cil/static/int | max outage s cil/static/int | stalled% cil/static/int | stall p50/p95 s cil · static · int | re-homed% cil/static | of re-homed: broken% cil/static | backend changed% cil/static | podCIDR gap s | .20 degraded s | .21 degraded s | Cilium BGP down s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| dz_backend-kill_maglev-snat_etpLocal_itpLocal | 10.9±15.4 | 0.0 | - | 0.7±0.3 / 3.9±5.5 / 20.7±23.7 | 0.1 / 0.1±0.2 / 6.0±8.2 | 0.0 / 0.0 / 0.0 | - · - · - | 8.8±12.4 / 0.0 | 100.0 / - | - / - | 0.0 | 5.3 | 0.0 | 0.0 |
