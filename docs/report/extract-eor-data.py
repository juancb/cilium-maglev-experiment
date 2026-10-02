#!/usr/bin/env python3
"""Build the End-of-RIB / many-Services tables for the report from the captured result dirs."""
import glob, json, os, re, statistics, subprocess, sys
R = "G:/Documents/Development/cilium-maglev-experiment"
sys.path.insert(0, R + "/scripts")
import importlib.util
spec = importlib.util.spec_from_file_location("abc_", R + "/scripts/analyze-bgp-capture.py"); abc = importlib.util.module_from_spec(spec); spec.loader.exec_module(abc)

BATCHES = [
    ("eor-1.19.1",            "1.19.1", "on",  "3 (VIPs)",   "rollout x4, delete x3"),
    ("eor-1.19.8",            "1.19.8", "on",  "3 (VIPs)",   "rollout x4, delete x4"),
    ("eor-upgrade",           "1.19.1 -> 1.19.8", "on", "3 (VIPs)", "upgrade x3"),
    ("svc20-1.19.1-groff",    "1.19.1", "off", "3 (VIPs) + 20 ClusterIP not advertised", "rollout x3, delete x3"),
    ("svc20-1.19.1-gron",     "1.19.1", "on",  "3 (VIPs) + 20 ClusterIP not advertised", "rollout x3, delete x3"),
    ("svc20-1.19.1-gron-adv", "1.19.1", "on",  "23 (VIPs + ClusterIPs)", "delete x4"),
    ("svc20-1.19.8-gron-adv", "1.19.8", "on",  "23 (VIPs + ClusterIPs)", "delete x4"),
]

def sessions(d, tag, meta):
    """per restarted node: dict(open, eor, vip, soft, soft_after_open, withdraw_s)"""
    ft = meta["failtime"]; out = []
    for cap in sorted(glob.glob(os.path.join(d, f"{tag}.bgp.node?.txt"))):
        node = cap[-9:-4]; recs = abc.parse_capture(cap)
        tx = [r for r in recs if r[4] == 179 and r[0] >= ft - 1]
        opens = [r for r in tx if r[5]["type"] == "Open"]
        up = [r for r in recs if r[2] == 179 and r[1].startswith("10.3.") and r[0] >= ft - 1]
        soft = []
        al = os.path.join(d, f"{tag}.agent.{node}.log")
        if os.path.exists(al):
            import datetime
            for l in open(al, errors="replace"):
                if re.search(r"soft.?reset", l, re.I):
                    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?Z", l)
                    if m:
                        frac = (m.group(2) or "0")[:6].ljust(6, "0")
                        soft.append(datetime.datetime.fromisoformat(f"{m.group(1)}.{frac}").replace(tzinfo=datetime.timezone.utc).timestamp())
        for oi, op in enumerate(opens):
            end = opens[oi + 1][0] if oi + 1 < len(opens) else float("inf")
            sess = [r for r in tx if op[0] <= r[0] < end and r[5]["type"] == "Update"]
            eor = next((r[0] for r in sess if r[5]["eor"]), None)
            vip = next((r[0] for r in sess if "192.0.2.20/32" in r[5]["announce"]), None)
            wds = [r for r in up if "192.0.2.20/32" in r[5]["withdraw"] and op[0] - 1 <= r[0] < end]
            wd_s = None
            if wds:
                w = wds[0]
                re_ann = [r for r in up if r[3] == w[3] and r[0] > w[0] and "192.0.2.20/32" in r[5]["announce"]]
                wd_s = round(re_ann[0][0] - w[0], 2) if re_ann else None
            s_run = [t for t in soft if abs(t - op[0]) < 15]
            out.append({"node": node, "open": round(op[0] - ft, 2), "eor": round(eor - ft, 2) if eor else None,
                        "vip": round(vip - ft, 2) if vip else None, "soft": len(s_run),
                        "soft_after_open": sum(1 for t in s_run if t > op[0] + 0.05),
                        "eor_first": bool(eor and vip and vip > eor), "withdraw_s": wd_s})
    return out

rows = []; evidence = {}
for label, ver, gr, nsvc, runs in BATCHES:
    d = os.path.join(R, "results", label)
    if not os.path.isdir(d): continue
    metas = sorted(glob.glob(os.path.join(d, "dz_*.run*.meta.json")))
    restarts = 0; eor_first = 0; wd = []; soft = []; ext_broken = []; int_broken = []; int_reset = []; ext_rehomed = []
    for mp in metas:
        meta = json.load(open(mp)); tag = mp[:-10]
        ss = sessions(d, os.path.basename(tag), meta)
        restarts += len(ss); eor_first += sum(1 for s in ss if s["eor_first"]); wd += [s["withdraw_s"] for s in ss if s["withdraw_s"]]
        soft += [s["soft"] for s in ss]
        for pop, lst in (("ext-cil", ext_broken), ("int", int_broken)):
            f = tag + f".{pop}.json"
            if os.path.exists(f):
                j = json.load(open(f)); fl = [x for x in j["flows"] if x["established_at"]]
                br = [x for x in fl if x["status"] == "broken"]
                lst.append(100.0 * len(br) / len(fl) if fl else 0)
                if pop == "int": int_reset.append(sum(1 for x in br if x["error_type"] == "reset"))
        rh = tag + ".ext-cil.rehoming.json"
        if os.path.exists(rh):
            ext_rehomed.append(json.load(open(rh))["summary"]["rehomed_total"])
    rows.append({"batch": label, "version": ver, "gr": gr, "advertised": nsvc, "runs": runs, "n_runs": len(metas),
                 "restarts": restarts, "soft_per_start": f"{min(soft)}-{max(soft)}" if soft and min(soft) != max(soft) else (str(soft[0]) if soft else "-"),
                 "eor_first": eor_first, "withdrawals": len(wd), "withdraw_max_s": max(wd) if wd else 0,
                 "ext_broken_pct": [round(x, 1) for x in ext_broken], "ext_rehomed": ext_rehomed,
                 "int_broken_pct": [round(x, 1) for x in int_broken], "int_resets": int_reset})

# evidence: message sequences for the two flagged sessions
def seq(label, tag, node):
    d = os.path.join(R, "results", label); meta = json.load(open(os.path.join(d, tag + ".meta.json"))); ft = meta["failtime"]
    recs = abc.parse_capture(os.path.join(d, f"{tag}.bgp.{node}.txt")); lines = []
    for r in recs:
        if r[0] < ft - 1: continue
        m = r[5]; who = "agent -> bird" if r[4] == 179 and r[3].startswith("198.51.") else ("bird -> leaf" if r[2] == 179 and r[1].startswith("10.3.") else None)
        if not who: continue
        if m["type"] == "Open": lines.append(f"+{r[0]-ft:6.2f}s  {who:14s} OPEN")
        elif m["type"] == "Update":
            if m["eor"]: lines.append(f"+{r[0]-ft:6.2f}s  {who:14s} UPDATE End-of-RIB")
            else:
                a = ", ".join(m["announce"]); w = ", ".join(m["withdraw"])
                if len(a) > 60: a = a[:57] + "..."
                lines.append(f"+{r[0]-ft:6.2f}s  {who:14s} UPDATE" + (f" announce {a}" if a else "") + (f" WITHDRAW {w}" if w else ""))
    # keep bird->leaf lines only for the VIP
    lines = [l for l in lines if "agent -> bird" in l or "192.0.2.20" in l]
    # dedupe consecutive identical (two leaves)
    out = []
    for l in lines:
        if out and out[-1][8:] == l[8:] and "bird -> leaf" in l: continue
        out.append(l)
    return "\n".join(out[:30])

evidence["seq_1svc"] = seq("eor-1.19.1", "dz_agent-delete_maglev-snat_etpCluster_itpCluster.run3", "node2")
evidence["seq_20svc"] = seq("svc20-1.19.1-gron", "dz_agent-restart_maglev-snat_etpCluster_itpCluster.run1", "node3")
bl = os.path.join(R, "results/eor-1.19.1/dz_agent-delete_maglev-snat_etpCluster_itpCluster.run3.bird.node2.log")
evidence["bird_log"] = "\n".join(l.strip() for l in open(bl, errors="replace") if re.search(r"graceful|END-OF-RIB", l))
al = os.path.join(R, "results/eor-1.19.1/dz_agent-delete_maglev-snat_etpCluster_itpCluster.run3.agent.node2.log")
evidence["agent_log"] = "\n".join(l.strip()[:150] for l in open(al, errors="replace") if re.search(r"soft reset|Established|bgp.*OPEN|session", l, re.I))[:3000]
json.dump({"rows": rows, "evidence": evidence}, open(os.path.dirname(os.path.abspath(__file__)) + "/eor-data.json", "w"), indent=1)
for r in rows: print(r)
print(evidence["seq_1svc"]); print("---"); print(evidence["seq_20svc"]); print("---"); print(evidence["bird_log"])
