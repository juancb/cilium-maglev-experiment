# Cilium disruption summary (least → most disruptive by pooled collateral broken%)

coll% = established flows broken by the disruption, excluding flows on a backend the test killed on purpose. Values are mean±stddev over runs.

| cell | coll% ext-cil | coll% ext-static | coll% int | newconn fail% cil/static/int | max outage s cil/static/int | stalled% cil/static/int | stall p50/p95 s cil · static · int | re-homed% cil/static | of re-homed: broken% cil/static | backend changed% cil/static | podCIDR gap s | .20 degraded s | .21 degraded s | Cilium BGP down s |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| dz_agent-kill_maglev-dsr_etpCluster_itpCluster | 0.0 | 0.0 | 0.0 | 9.4±6.2 / 9.4±7.3 / 20.6±14.3 | 0.3±0.1 / 0.3±0.3 / 0.9±0.1 | 34.8±6.0 / 27.0±4.2 / 70.2±3.2 | 16.7/16.7 · 16.7/16.7 · 16.7/16.7 | 35.0±0.7 / 0.0 | 0.0 / - | 1.6±2.3 / - | 11.5 | 11.5 | 0.0 | 11.5 |
| dz_agent-kill_random-dsr_etpCluster_itpCluster | 8.8±0.4 | 0.0 | 0.0 | 11.1±5.6 / 8.1±4.8 / 20.9±16.4 | 0.3±0.1 / 0.3±0.1 / 0.8±0.5 | 39.2±3.2 / 27.2±2.5 / 69.5 | 16.7/16.7 · 16.7/16.7 · 16.7/16.7 | 32.2±1.8 / 0.0 | 27.1±0.4 / - | 83.0±5.1 / - | 12.2 | 12.2 | 0.0 | 11.9 |
| dz_agent-kill_random-snat_etpCluster_itpCluster | 22.2±3.2 | 0.0 | 0.0 | 10.4±3.9 / 8.4±2.2 / 17.2±5.7 | 0.5±0.1 / 0.3±0.1 / 0.6±0.2 | 34.5±2.1 / 24.0±0.7 / 67.2±1.8 | 16.7/16.8 · 16.7/16.8 · 16.7/16.8 | 35.0±2.1 / 0.0 | 63.4±5.2 / - | 88.9±2.5 / - | 9.3 | 9.3 | 0.0 | 9.3 |
| dz_agent-kill_maglev-snat_etpCluster_itpCluster | 39.5±24.0 | 11.8±16.6 | 34.2±48.4 | 12.5±11.4 / 10.2±5.8 / 24.2±17.9 | 0.4±0.1 / 0.3±0.1 / 0.8±0.3 | 15.2±21.6 / 11.0±15.6 / 32.0±45.3 | 18.4/18.4+ · 18.4/18.4+ · 18.4/18.4+ | 32.2±1.8 / 0.0 | 83.6±23.2 / - | 0.0 / - | 17.2 | 17.2 | 0.0 | 17.8 |
