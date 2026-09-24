# Cilium disruption summary (least → most disruptive by pooled collateral broken%)

coll% = established flows broken by the disruption, excluding flows on a backend the test killed on purpose. Values are mean±stddev over runs.

| cell | coll% ext-cil | coll% ext-static | coll% int | newconn fail% cil/static/int | max outage s cil/static/int | stalled% cil/static/int | max stall s cil/static/int | podCIDR gap s | .20 degraded s | .21 degraded s | Cilium BGP down s |
|---|---|---|---|---|---|---|---|---|---|---|---|
| dz_agent-kill_maglev-snat_etpCluster_itpCluster | 0.0 | 0.0 | 0.0 | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 | 0.0 / 0.0±0.0 / 0.0 | 0.0 | 0.0 | 0.0 | 8.2 |
| dz_agent-upgrade_maglev-snat_etpCluster_itpCluster | 0.0 | 0.0 | 0.0 | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 | 0.0 | 0.0 | 0.0 | 56.1 |
| dz_agent-restart_maglev-snat_etpCluster_itpCluster | 15.8±22.3 | 0.0 | 0.0 | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0 | 0.0 / 0.0 / 0.0±0.1 | 0.0 | 0.8 | 0.0 | 48.8 |
