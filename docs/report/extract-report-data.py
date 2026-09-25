"""Extract plot data + evidence excerpts for the report into report-data.json."""
import json, glob, os, collections, statistics as st, re, sys
os.chdir(r"G:\Documents\Development\cilium-maglev-experiment")
S = os.path.dirname(os.path.abspath(__file__))  # pods.txt: pod->node map of the rehome batch (see docs/data/cilium-disruption-rehoming.md)
out = {}

def load(p):
    return json.load(open(p))

# ---- A. main matrix: broken% per cell (ext-cil/static/int), ordered
summ = load("results/prod-mirror-noGR/disruption-summary.json")
cells = []
for r in summ:
    cells.append({"cell": r["cell"], "disruption": r["disruption"], "algo": r["algo"], "mode": r["mode"],
                  "etp": r["etp"], "itp": r["itp"],
                  "cil": r["ext-cil"]["collateral_pct"][0], "static": r["ext-static"]["collateral_pct"][0],
                  "int": r["int"]["collateral_pct"][0],
                  "newconn": [r[p]["newconn_fail_pct"][0] for p in ("ext-cil", "ext-static", "int")],
                  "stalled": [r[p]["stalled_pct"][0] for p in ("ext-cil", "ext-static", "int")],
                  "podgap": r["podcidr_gap_s"], "vipdeg": r["vip_cil_degraded_s"]})
out["matrix"] = cells

# ---- B. per-node route gap per disruption type (prod mirror)
gaps = collections.defaultdict(list)
for mp in glob.glob("results/prod-mirror-noGR/dz_*.run*.meta.json"):
    m = load(mp); r = mp[:-len(".meta.json")]
    rows = [json.loads(l) for l in open(r + ".bgp.jsonl")]
    for n in ("node1", "node2", "node3"):
        start = None
        for a, b in zip(rows, rows[1:]):
            down = a["podcidr"][n] == 0
            if down and start is None: start = a["t"]
            if not down and start is not None: gaps[m["disruption"]].append(round(b["t"] - start, 1)); start = None
out["gaps"] = {k: sorted(v) for k, v in gaps.items()}
# add the two extreme agent-kill runs from rehome/ and the maxunavail1 runs
for d, lab in (("results/rehome", "agent-kill (rehome batch)"), ("results/maxunavail1", "agent-restart maxUnavailable=1")):
    g = []
    for mp in glob.glob(d + "/dz_*.run*.meta.json"):
        r = mp[:-len(".meta.json")]; rows = [json.loads(l) for l in open(r + ".bgp.jsonl")]
        for n in ("node1", "node2", "node3"):
            start = None
            for a, b in zip(rows, rows[1:]):
                down = a["podcidr"][n] == 0
                if down and start is None: start = a["t"]
                if not down and start is not None: g.append(round(b["t"] - start, 1)); start = None
    out["gaps"][lab] = sorted(g)

# ---- C. route timeline of one two-at-a-time rollout run and one maxUnavailable=1 run
def timeline(r):
    m = load(r + ".meta.json"); ft = m["failtime"]
    rows = [json.loads(l) for l in open(r + ".bgp.jsonl")]
    return {"end": round(m["endtime"] - ft, 1),
            "t": [round(x["t"] - ft, 2) for x in rows],
            "vip_cil": [x["vip_cil"] for x in rows], "vip_static": [x["vip_static"] for x in rows],
            "pod": {n: [x["podcidr"][n] for x in rows] for n in ("node1", "node2", "node3")}}
out["timeline_rollout"] = timeline("results/prod-mirror-noGR/dz_agent-restart_maglev-snat_etpCluster_itpCluster.run1")
out["timeline_mu1"] = timeline("results/maxunavail1/dz_agent-restart_maglev-snat_etpCluster_itpCluster.run1")
out["timeline_gr"] = timeline("results/gr-enabled/dz_agent-restart_maglev-snat_etpCluster_itpCluster.run2")
out["timeline_kill"] = timeline("results/rehome/dz_agent-kill_maglev-dsr_etpCluster_itpCluster.run1")

# ---- D. re-homing attribution table (rehome batch), from rehoming.json + pods.txt
pods = {}
for l in open(os.path.join(S, "pods.txt")):
    n, ip, node = l.split(); pods[n] = node
att = collections.OrderedDict()
for p in sorted(glob.glob("results/rehome/dz_agent-kill_*.run*.ext-cil.rehoming.json")):
    cell = os.path.basename(p).split(".run")[0].replace("dz_agent-kill_", "").replace("_etpCluster_itpCluster", "")
    m = load(p.replace(".ext-cil.rehoming.json", ".meta.json")); target = m["target_node"]
    a = att.setdefault(cell, collections.Counter())
    for f in load(p)["flows"]:
        a["flows"] += 1
        if not f["rehomed"]: continue
        a["rehomed"] += 1
        on = pods.get(f["backend"]) == target
        g = "on_target" if on else "elsewhere"
        a[g] += 1; a[g + ("_broken" if f["broke_after_fail"] else "_ok")] += 1
        if not on and f["backend_changed"] is not None:
            a["vis_" + ("changed" if f["backend_changed"] else "same")] += 1
out["attribution"] = {k: dict(v) for k, v in att.items()}

# ---- E. GR on vs off (same cells)
def cellrow(d, cell):
    for r in load(d + "/disruption-summary.json"):
        if r["cell"] == cell: return r
gr = []
for disr in ("agent-kill", "agent-restart", "agent-upgrade"):
    c = f"dz_{disr}_maglev-snat_etpCluster_itpCluster"
    a, b = cellrow("results/prod-mirror-noGR", c), cellrow("results/gr-enabled", c)
    gr.append({"disruption": disr,
               "off": [a[p]["collateral_pct"][0] for p in ("ext-cil", "ext-static", "int")],
               "on": [b[p]["collateral_pct"][0] for p in ("ext-cil", "ext-static", "int")],
               "off_newconn": [a[p]["newconn_fail_pct"][0] for p in ("ext-cil", "ext-static", "int")],
               "on_newconn": [b[p]["newconn_fail_pct"][0] for p in ("ext-cil", "ext-static", "int")],
               "off_gap": a["podcidr_gap_s"], "on_gap": b["podcidr_gap_s"]})
out["gr"] = gr
mu = cellrow("results/maxunavail1", "dz_agent-restart_maglev-snat_etpCluster_itpCluster")
out["mu1"] = {"broken": [mu[p]["collateral_pct"][0] for p in ("ext-cil", "ext-static", "int")],
              "newconn": [mu[p]["newconn_fail_pct"][0] for p in ("ext-cil", "ext-static", "int")]}

# ---- F. probe failure per 10s window: rollout default vs maxUnavailable=1 (static VIP)
def probe_windows(r, pop="ext-static", w=10):
    m = load(r + ".meta.json"); ft = m["failtime"]
    at = load(f"{r}.probe-{pop}.json")["attempts"]
    b = collections.defaultdict(lambda: [0, 0])
    for a in at:
        k = int((a["t"] - ft) // w) * w; b[k][1] += 1; b[k][0] += (a["ok"] is not True)
    return [[k, round(100 * v[0] / v[1], 1)] for k, v in sorted(b.items()) if -10 <= k <= 140]
out["probe_default"] = probe_windows("results/prod-mirror-noGR/dz_agent-restart_maglev-snat_etpCluster_itpCluster.run1")
out["probe_mu1"] = probe_windows("results/maxunavail1/dz_agent-restart_maglev-snat_etpCluster_itpCluster.run1")
out["probe_gr"] = probe_windows("results/gr-enabled/dz_agent-restart_maglev-snat_etpCluster_itpCluster.run2")

# ---- G. stall eCDF: agent-kill run pair (5.7s vs 28.7s gap), static VIP
def stalls(r, pop):
    m = load(r + ".meta.json"); ft = m["failtime"]; d = load(f"{r}.{pop}.json")
    xs = []
    for f in d["flows"]:
        if not f["established_at"]: continue
        if f["status"] == "broken": xs.append(30.0)
        elif (f.get("stall_at") or 0) >= ft - 1: xs.append(round(f.get("max_stall") or 0, 2))
        else: xs.append(0.0)
    return sorted(xs)
out["stall_kill_short"] = stalls("results/rehome/dz_agent-kill_maglev-snat_etpCluster_itpCluster.run1", "ext-static")
out["stall_kill_long"] = stalls("results/rehome/dz_agent-kill_maglev-snat_etpCluster_itpCluster.run2", "ext-static")
out["stall_rollout"] = stalls("results/prod-mirror-noGR/dz_agent-restart_maglev-snat_etpCluster_itpCluster.run1", "ext-static")
out["stall_gr"] = stalls("results/gr-enabled/dz_agent-restart_maglev-snat_etpCluster_itpCluster.run2", "ext-static")

# ---- H. evidence excerpts
ev = {}
ev["bgp_verify"] = "\n".join(l for l in open("logs/dz-driver2.log", encoding="utf-8", errors="replace").read().splitlines()[-24:]
                             if re.search(r"node\d +(uplink|dynbgp)|leaf\d +10\.|all node", l))
ev["flow35777"] = ""
m = load("results/rehome/dz_agent-kill_random-dsr_etpCluster_itpCluster.run1.meta.json"); ft = m["failtime"]
lines = []
for n in (1, 2, 3):
    for l in open(f"results/rehome/dz_agent-kill_random-dsr_etpCluster_itpCluster.run1.ext-cil.node{n}.txt"):
        if ".35777 >" in l:
            ts = float(l.split()[0])
            if -2 <= ts - ft <= 9: lines.append((ts - ft, n, " ".join(l.split()[1:])))
ev["flow35777"] = "\n".join(f"node{n}  t{t:+5.1f}s  {rest}" for t, n, rest in sorted(lines))
ev["rst_capture"] = open("logs/dsr-drop-check2.log", encoding="utf-8", errors="replace").read().split("== RSTs per node")[1].split("flows 150")[0]
ev["hubble"] = open("logs/dsr-drop-check2.log", encoding="utf-8", errors="replace").read().split("== Hubble DROPPED")[1].split("== RSTs per node")[0]
ev["gr_blip"] = json.dumps([(round(x["t"] - load("results/gr-enabled/dz_agent-restart_maglev-snat_etpCluster_itpCluster.run1.meta.json")["failtime"], 2), x["vip_cil"], x["cilium_sess"]["node2"]) for x in [json.loads(l) for l in open("results/gr-enabled/dz_agent-restart_maglev-snat_etpCluster_itpCluster.run1.bgp.jsonl")] if 44 <= x["t"] - load("results/gr-enabled/dz_agent-restart_maglev-snat_etpCluster_itpCluster.run1.meta.json")["failtime"] <= 49])
ev["lastbackend"] = "\n".join(l for l in open("logs/dz-r3-lastbackend.log", encoding="utf-8", errors="replace").read().splitlines() if "DISRUPT" in l or "disruption over" in l)[:1200]
ev["snat_pcap"] = """1790270469.19 fab0  In  IP 203.0.113.1.46375 > 192.0.2.21.8080: Flags [P.]      # client -> VIP, ingress node1
1790270469.19 fab0  Out IP 10.10.0.1.46375   > 10.244.0.200.8080: Flags [P.]     # node1 SNATs to its own IP, same port
1790270469.19 fab0  In  IP 10.244.0.200.8080 > 10.10.0.1.46375: Flags [P.]       # backend replies to node1
1790270469.19 fab1  Out IP 192.0.2.21.8080   > 203.0.113.1.46375: Flags [P.]     # node1 rev-SNATs back to the VIP
...
1790270471.47 fab0  In  IP 203.0.113.1.46375 > 192.0.2.21.8080: Flags [P.]      # +2.1s: same flow now ingresses node2
1790270471.47 lxc.. In  IP 10.244.0.200.8080 > 203.0.113.1.46375: Flags [R]      # backend sees an unknown 4-tuple: RST
1790270471.47 fab1  Out IP 192.0.2.21.8080   > 203.0.113.1.46375: Flags [R]      # node2 forwards the RST to the client"""
out["evidence"] = ev
json.dump(out, open(os.path.join(S, "report-data.json"), "w"), indent=1)
print({k: (len(v) if hasattr(v, "__len__") else v) for k, v in out.items()})
