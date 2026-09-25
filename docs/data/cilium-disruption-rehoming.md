# Re-homing attribution (scripts/rehoming-report.py), ext-cil population

```
population: ext-cil   (n = flows, broken% of those)
cell                                                 runs flows re-homed returned | backend elsewhere | same backend | changed backend | backend on disrupted node
dz_agent-kill_maglev-dsr_etpCluster_itpCluster          2   400      140      140 |   95   0.0% |   38   0.0% |    1   0.0% |   45   0.0%
dz_agent-kill_maglev-snat_etpCluster_itpCluster         2   400      129      107 |   86 100.0% |   37 100.0% |    0     - |   43  48.8%
dz_agent-kill_random-dsr_etpCluster_itpCluster          2   400      129      110 |   83  21.7% |    9   0.0% |   44   2.3% |   46  37.0%
dz_agent-kill_random-snat_etpCluster_itpCluster         2   400      140       70 |   91  65.9% |    2 100.0% |   45  42.2% |   49  59.2%

dz_agent-kill_maglev-snat_etpCluster_itpCluster         2   400      122       82 |   59 100.0% |   20 100.0% |    0     - |   63   0.0%
dz_agent-restart_maglev-snat_etpCluster_itpCluster      2   400      400      184 |  261 100.0% |   95 100.0% |    0     - |  139 100.0%
dz_agent-delete_maglev-snat_etpCluster_itpCluster      10  2000        0        0 |    0     - |    0     - |    0     - |    0     -
```
