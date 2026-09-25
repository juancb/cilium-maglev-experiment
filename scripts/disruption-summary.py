#!/usr/bin/env python3
"""
disruption-summary.py — summarise tests/05-cilium-disruption.sh results.

For every cell (results/dz_<disruption>_<algo>-<mode>_etp<X>_itp<Y>.run<k>.*) and each
traffic population (ext-cil, ext-static, int) it reports, as mean ± stddev over runs:

  broken%      established flows that broke at/after the disruption started
  collateral%  the same, EXCLUDING flows pinned to a backend the test killed on purpose
               (backend-kill). For agent disruptions nothing is killed: collateral == broken.
  newconn%     new-connection attempts that failed between disruption start and the end of
               the settle window (connprobe)
  outage s     longest run of consecutive failed new connections
  stalled%     flows that SURVIVED but stalled >= 1s after the disruption started (a real
               client would see a hiccup, not an error); stall s = the longest such stall
plus, from the leaf1 route timeline: the LONGEST single node's pod-CIDR absence (not the
union across nodes; during a rollout two nodes can be missing at once), seconds the
Cilium-only VIP had fewer nexthops than before, and the longest single node's
bird<->Cilium session outage.

Writes results/disruption-summary.json and results/disruption-summary.md and prints the
table ranked from least to most disruptive (by pooled collateral broken%).

Usage: python3 scripts/disruption-summary.py [results-dir]
"""
import glob
import json
import math
import os
import re
import sys

POPS = ["ext-cil", "ext-static", "int"]


def load(path):
    try:
        with open(path) as f:
            return json.load(f)
    except Exception:
        return None


def mean(xs):
    return sum(xs) / len(xs) if xs else None


def sd(xs):
    if len(xs) < 2:
        return 0.0 if xs else None
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def flow_stats(data, failtime, killed):
    flows = [f for f in data.get("flows", []) if f.get("established_at")]
    # flows that broke BEFORE the disruption are pre-existing noise: drop from the denominator
    live = [f for f in flows if not (f["status"] == "broken" and (f.get("broke_at") or 0) < failtime)]
    broken = [f for f in live if f["status"] == "broken"]
    direct = [f for f in live if f.get("backend") in killed]
    coll_den = len(live) - len(direct)
    coll = [f for f in broken if f.get("backend") not in killed]
    errs = {}
    for f in broken:
        errs[f.get("error_type") or "other"] = errs.get(f.get("error_type") or "other", 0) + 1
    # survivors whose longest keepalive round trip began after the disruption started
    stalls = [f.get("max_stall") or 0.0 for f in live
              if f["status"] != "broken" and (f.get("stall_at") or 0) >= failtime - 1.0]
    stalled = [x for x in stalls if x >= 1.0]
    return {
        "established": len(live),
        "pre_broken": len(flows) - len(live),
        "broken": len(broken),
        "broken_pct": 100.0 * len(broken) / len(live) if live else None,
        "on_killed_backend": len(direct),
        "collateral": len(coll),
        "collateral_pct": 100.0 * len(coll) / coll_den if coll_den > 0 else None,
        "errors": errs,
        "stalled_1s": len(stalled),
        "stalled_1s_pct": 100.0 * len(stalled) / len(live) if live else None,
        "max_stall_s": round(max(stalls), 2) if stalls else 0.0,
    }


def probe_stats(data, failtime, window_end):
    atts = sorted(data.get("attempts", []), key=lambda a: a["t"])
    hz = data.get("summary", {}).get("hz") or 10.0
    win = [a for a in atts if failtime <= a["t"] <= window_end]
    pre = [a for a in atts if a["t"] < failtime]
    fails = [a for a in win if a.get("ok") is not True]
    # longest streak of consecutive failures anywhere in the run, in seconds
    longest, start = 0.0, None
    for a in atts:
        if a.get("ok") is not True:
            start = a["t"] if start is None else start
            longest = max(longest, a["t"] - start + 1.0 / hz)
        else:
            start = None
    errs = {}
    for a in fails:
        errs[a.get("err") or "unfinished"] = errs.get(a.get("err") or "unfinished", 0) + 1
    return {
        "attempts": len(win),
        "failed": len(fails),
        "fail_pct": 100.0 * len(fails) / len(win) if win else None,
        "pre_fail_pct": 100.0 * sum(1 for a in pre if a.get("ok") is not True) / len(pre) if pre else None,
        "max_outage_s": round(longest, 2),
        "errors": errs,
    }


def bgp_stats(path):
    rows = []
    try:
        with open(path) as f:
            rows = [json.loads(l) for l in f if l.strip()]
    except Exception:
        return None
    if len(rows) < 2:
        return None
    base = rows[0]

    def secs(pred):
        total = 0.0
        for a, b in zip(rows, rows[1:]):
            if pred(a):
                total += b["t"] - a["t"]
        return round(total, 1)

    nodes = sorted(base["podcidr"].keys())
    return {
        "vip_cil_baseline_nh": base["vip_cil"],
        "vip_cil_degraded_s": secs(lambda r: r["vip_cil"] < base["vip_cil"]),
        "vip_cil_absent_s": secs(lambda r: r["vip_cil"] == 0),
        "vip_static_degraded_s": secs(lambda r: r["vip_static"] < base["vip_static"]),
        "podcidr_absent_s": {n: secs(lambda r, n=n: r["podcidr"][n] == 0) for n in nodes},
        "cilium_sess_down_s": {n: secs(lambda r, n=n: r["cilium_sess"][n] == 0) for n in nodes},
    }


def fmt(m, s, digits=1):
    if m is None:
        return "-"
    return f"{m:.{digits}f}±{s:.{digits}f}" if s else f"{m:.{digits}f}"


def main():
    rdir = sys.argv[1] if len(sys.argv) > 1 else "results"
    metas = sorted(glob.glob(os.path.join(rdir, "dz_*.run*.meta.json")))
    if not metas:
        sys.stderr.write(f"no dz_*.meta.json in {rdir}\n")
        sys.exit(1)

    cells = {}
    for mp in metas:
        meta = load(mp)
        if not meta:
            continue
        rtag = re.sub(r"\.meta\.json$", "", mp)
        killed = set(meta.get("killed") or [])
        window_end = meta["endtime"] + meta.get("settle", 0)
        run = {"meta": meta, "pops": {}, "probes": {}, "bgp": bgp_stats(rtag + ".bgp.jsonl")}
        for p in POPS:
            d = load(f"{rtag}.{p}.json")
            if d:
                run["pops"][p] = flow_stats(d, meta["failtime"], killed)
            pr = load(f"{rtag}.probe-{p}.json")
            if pr:
                run["probes"][p] = probe_stats(pr, meta["failtime"], window_end)
        cells.setdefault(meta["cell"], []).append(run)

    out = []
    for cell, runs in cells.items():
        m = runs[0]["meta"]
        row = {"cell": cell, "disruption": m["disruption"], "algo": m["algo"], "mode": m["mode"],
               "etp": m["etp"], "itp": m["itp"], "runs": len(runs),
               "truncated_runs": sum(1 for r in runs if r["meta"].get("truncated")),
               "duration_s": mean([r["meta"]["endtime"] - r["meta"]["failtime"] for r in runs])}
        pooled = []
        for p in POPS:
            b = [r["pops"][p]["broken_pct"] for r in runs if p in r["pops"] and r["pops"][p]["broken_pct"] is not None]
            c = [r["pops"][p]["collateral_pct"] for r in runs if p in r["pops"] and r["pops"][p]["collateral_pct"] is not None]
            n = [r["probes"][p]["fail_pct"] for r in runs if p in r["probes"] and r["probes"][p]["fail_pct"] is not None]
            o = [r["probes"][p]["max_outage_s"] for r in runs if p in r["probes"]]
            st = [r["pops"][p]["stalled_1s_pct"] for r in runs if p in r["pops"] and r["pops"][p]["stalled_1s_pct"] is not None]
            ms = [r["pops"][p]["max_stall_s"] for r in runs if p in r["pops"]]
            row[p] = {"broken_pct": (mean(b), sd(b)), "collateral_pct": (mean(c), sd(c)),
                      "newconn_fail_pct": (mean(n), sd(n)), "max_outage_s": (mean(o), sd(o)),
                      "stalled_pct": (mean(st), sd(st)), "max_stall_s": (mean(ms), sd(ms))}
            pooled += c
        bg = [r["bgp"] for r in runs if r["bgp"]]
        row["podcidr_gap_s"] = mean([max(b["podcidr_absent_s"].values()) for b in bg]) if bg else None
        row["vip_cil_degraded_s"] = mean([b["vip_cil_degraded_s"] for b in bg]) if bg else None
        row["vip_static_degraded_s"] = mean([b["vip_static_degraded_s"] for b in bg]) if bg else None
        row["cilium_sess_down_s"] = mean([max(b["cilium_sess_down_s"].values()) for b in bg]) if bg else None
        row["score_collateral_pct"] = mean(pooled)
        row["runs_detail"] = runs
        out.append(row)

    out.sort(key=lambda r: (r["score_collateral_pct"] is None, r["score_collateral_pct"] or 0))

    hdr = ("| cell | coll% ext-cil | coll% ext-static | coll% int | newconn fail% cil/static/int "
           "| max outage s cil/static/int | stalled% cil/static/int | max stall s cil/static/int | podCIDR gap s | .20 degraded s | .21 degraded s | Cilium BGP down s |")
    lines = ["# Cilium disruption summary (least → most disruptive by pooled collateral broken%)", "",
             "coll% = established flows broken by the disruption, excluding flows on a backend the test "
             "killed on purpose. Values are mean±stddev over runs.", "", hdr,
             "|" + "---|" * (hdr.count("|") - 1)]
    for r in out:
        f = lambda p, k, d=1: fmt(*r[p][k], digits=d)
        g = lambda v: "-" if v is None else f"{v:.1f}"
        trunc = " ⚠truncated" if r["truncated_runs"] else ""
        lines.append(
            f"| {r['cell']}{trunc} | {f('ext-cil','collateral_pct')} | {f('ext-static','collateral_pct')} "
            f"| {f('int','collateral_pct')} "
            f"| {f('ext-cil','newconn_fail_pct')} / {f('ext-static','newconn_fail_pct')} / {f('int','newconn_fail_pct')} "
            f"| {f('ext-cil','max_outage_s')} / {f('ext-static','max_outage_s')} / {f('int','max_outage_s')} "
            f"| {f('ext-cil','stalled_pct')} / {f('ext-static','stalled_pct')} / {f('int','stalled_pct')} "
            f"| {f('ext-cil','max_stall_s')} / {f('ext-static','max_stall_s')} / {f('int','max_stall_s')} "
            f"| {g(r['podcidr_gap_s'])} | {g(r['vip_cil_degraded_s'])} | {g(r['vip_static_degraded_s'])} "
            f"| {g(r['cilium_sess_down_s'])} |")
    md = "\n".join(lines) + "\n"
    with open(os.path.join(rdir, "disruption-summary.md"), "w", encoding="utf-8") as f:
        f.write(md)
    with open(os.path.join(rdir, "disruption-summary.json"), "w") as f:
        json.dump(out, f, indent=2)
    print(md)
    print(f"wrote {os.path.join(rdir, 'disruption-summary.md')} and .json")


if __name__ == "__main__":
    main()
