#!/usr/bin/env python3
"""
analyze-rehoming.py — per-flow re-homing verification from per-node pcaps.

For one run (tag like 'snat-leaf-failure_maglev-on.run1') it reads:
  results/<tag>.json            flowgen: failtime + per-flow {srcport, backend, status, broke_at}
  results/<tag>.<node>.txt      tcpdump -tt decode of that node's client->VIP packets

For each client source port it decides which node ingressed the flow BEFORE vs
AFTER failtime, hence whether the flow re-homed, and joins that with whether the
flow survived. This finally separates:
  - re-homed & survived  → Maglev preserved the backend (working as designed)
  - re-homed & broken    → backend changed on re-home (Maglev mismatch / RST)
  - not re-homed & broken → broke for another reason (e.g. reconvergence blackhole)
  - not re-homed & survived → not exercised

Writes results/<tag>.rehoming.json and prints a summary.

Usage: python3 scripts/analyze-rehoming.py <results-dir> <tag>
"""
import json, os, re, sys, glob

SRC_RE = re.compile(r"^(\d+\.\d+)\s+.*?\b203\.0\.113\.1\.(\d+)\s+>\s")


def parse_node_txt(path):
    """node txt -> {srcport: [timestamps]}"""
    flows = {}
    if not os.path.exists(path):
        return flows
    for line in open(path, errors="replace"):
        m = SRC_RE.match(line.strip())
        if not m:
            continue
        ts = float(m.group(1))
        sp = int(m.group(2))
        flows.setdefault(sp, []).append(ts)
    return flows


def dominant_node(per_node_ts, lo=None, hi=None):
    """Among nodes, which saw the most packets for this flow in [lo,hi)."""
    best, bestn = None, 0
    for node, tss in per_node_ts.items():
        n = sum(1 for t in tss if (lo is None or t >= lo) and (hi is None or t < hi))
        if n > bestn:
            bestn, best = n, node
    return best, bestn


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: analyze-rehoming.py <results-dir> <tag>\n"); sys.exit(2)
    d, tag = sys.argv[1], sys.argv[2]

    runjson = os.path.join(d, f"{tag}.json")
    if not os.path.exists(runjson):
        sys.stderr.write(f"no flowgen json {runjson}\n"); sys.exit(1)
    data = json.load(open(runjson))
    failtime = (data.get("summary") or {}).get("failtime")
    if not failtime:
        sys.stderr.write("no failtime in summary; cannot split before/after\n"); sys.exit(1)

    # per-node packet timestamps by source port
    node_txts = sorted(glob.glob(os.path.join(d, f"{tag}.*.txt")))
    nodes = {}
    for p in node_txts:
        node = os.path.basename(p)[len(tag) + 1:-4]  # strip "<tag>." and ".txt"
        nodes[node] = parse_node_txt(p)
    if not nodes:
        sys.stderr.write("no per-node .txt captures found; was CAPTURE_PCAP=1?\n"); sys.exit(1)

    # invert: srcport -> {node: [ts]}
    by_sp = {}
    for node, flows in nodes.items():
        for sp, tss in flows.items():
            by_sp.setdefault(sp, {})[node] = tss

    # flowgen per-flow facts
    fg = {}
    for fl in data.get("flows", []):
        sp = fl.get("srcport")
        if sp is not None:
            fg[int(sp)] = fl

    records = []
    cnt = {"rehomed_survived": 0, "rehomed_broken": 0,
           "stayed_survived": 0, "stayed_broken": 0,
           "unknown": 0}
    for sp, per_node in by_sp.items():
        nb, nbn = dominant_node(per_node, hi=failtime)
        na, nan = dominant_node(per_node, lo=failtime)
        fl = fg.get(sp, {})
        status = fl.get("status")
        broke_after = bool(fl.get("broke_at") and fl["broke_at"] >= failtime)
        broken = (status == "broken" and broke_after)
        if nb is None or na is None:
            cat = "unknown"
        else:
            rehomed = (nb != na)
            if rehomed and broken:   cat = "rehomed_broken"
            elif rehomed:            cat = "rehomed_survived"
            elif broken:             cat = "stayed_broken"
            else:                    cat = "stayed_survived"
        cnt[cat] += 1
        records.append({"srcport": sp, "node_before": nb, "node_after": na,
                        "rehomed": (nb is not None and na is not None and nb != na),
                        "backend": fl.get("backend"), "status": status,
                        "broke_after_fail": broken, "category": cat})

    rehomed_total = cnt["rehomed_survived"] + cnt["rehomed_broken"]
    summary = {
        "tag": tag, "failtime": failtime,
        "flows_seen_in_pcap": len(by_sp),
        "rehomed_total": rehomed_total,
        "rehomed_survived": cnt["rehomed_survived"],
        "rehomed_broken": cnt["rehomed_broken"],
        "stayed_survived": cnt["stayed_survived"],
        "stayed_broken": cnt["stayed_broken"],
        "unknown": cnt["unknown"],
    }
    out = {"summary": summary, "flows": sorted(records, key=lambda r: r["srcport"])}
    json.dump(out, open(os.path.join(d, f"{tag}.rehoming.json"), "w"), indent=2)

    print(f"re-homing [{tag}]: {len(by_sp)} flows in pcap, "
          f"{rehomed_total} re-homed "
          f"(survived {cnt['rehomed_survived']}, broken {cnt['rehomed_broken']}); "
          f"stayed (survived {cnt['stayed_survived']}, broken {cnt['stayed_broken']}); "
          f"unknown {cnt['unknown']}")
    if rehomed_total == 0:
        print("  -> NO re-homing observed: the failure did not move flows to a new ingress "
              "node, so this run does not exercise Maglev.")
    elif cnt["rehomed_broken"] == 0:
        print("  -> Maglev WORKING: every re-homed flow kept its backend and survived.")
    elif cnt["rehomed_survived"] == 0:
        print("  -> Maglev NOT working: every re-homed flow broke (backend changed on re-home).")
    else:
        print("  -> MIXED: some re-homed flows survived, some broke.")


if __name__ == "__main__":
    main()
