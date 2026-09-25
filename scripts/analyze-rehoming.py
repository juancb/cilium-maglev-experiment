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

Usage: python3 scripts/analyze-rehoming.py <results-dir> <tag> [--flows F] [--vip V] [--out T]
  --flows F  flowgen json to join with (default <tag>.json); failtime is read from its
             summary, or from <tag>.meta.json when the summary has none
  --vip V    only count client->V packets as ingress evidence (tests/05 captures two VIPs
             from the same client in one pcap)
  --out T    write <T>.rehoming.json instead of <tag>.rehoming.json

If the per-node txt also holds the ingress node's forward packets to the backend pod
(client->pod for DSR, node-IP->pod for SNAT; the source port is preserved), each flow also
gets backend_before / backend_after and backend_changed, which tells a Maglev "same
backend" re-home apart from a random one without relying on the flow surviving.
"""
import json, os, re, sys, glob

# A line may end in a packet count ("<ts> <src>.<sport> > <dst>.<dport> <n>"): tests/05 reduces
# each node capture to 1-second buckets on the node so only a few MB cross the 9p mount.
SRC_RE = re.compile(r"^(\d+\.\d+)\s+.*?\b203\.0\.113\.1\.(\d+)\s+>\s(\d+\.\d+\.\d+\.\d+)\.\d+")
CNT_RE = re.compile(r"\s(\d+)$")
# forward packet to a backend pod: <client or node IP>.<sport> > <pod IP>.8080
FWD_RE = re.compile(r"^(\d+\.\d+)\s+.*?\b(?:203\.0\.113\.1|10\.10\.0\.\d+)\.(\d+)\s+>\s(10\.244\.\d+\.\d+)\.8080")


def parse_node_txt(path, vip=None):
    """node txt -> ({srcport: [ts]} ingress evidence, {srcport: [(ts, pod_ip)]} forwards)"""
    flows, fwds = {}, {}
    if not os.path.exists(path):
        return flows, fwds
    for line in open(path, errors="replace"):
        line = line.strip()
        c = CNT_RE.search(line)
        w = int(c.group(1)) if c and " > " in line and line.count(":") == 0 else 1
        m = FWD_RE.match(line)
        if m:
            fwds.setdefault(int(m.group(2)), []).append((float(m.group(1)), m.group(3), w))
            continue
        m = SRC_RE.match(line)
        if not m:
            continue
        if vip and m.group(3) != vip:
            continue
        flows.setdefault(int(m.group(2)), []).append((float(m.group(1)), w))
    return flows, fwds


def dominant_backend(fwd, lo=None, hi=None):
    cnt = {}
    for ts, pod, w in fwd:
        if (lo is None or ts >= lo) and (hi is None or ts < hi):
            cnt[pod] = cnt.get(pod, 0) + w
    return max(cnt, key=cnt.get) if cnt else None


def dominant_node(per_node_ts, lo=None, hi=None):
    """Among nodes, which saw the most packets for this flow in [lo,hi)."""
    best, bestn = None, 0
    for node, tss in per_node_ts.items():
        n = sum(w for t, w in tss if (lo is None or t >= lo) and (hi is None or t < hi))
        if n > bestn:
            bestn, best = n, node
    return best, bestn


def main():
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("dir"); ap.add_argument("tag")
    ap.add_argument("--flows"); ap.add_argument("--vip"); ap.add_argument("--out")
    args = ap.parse_args()
    d, tag = args.dir, args.tag
    out_tag = args.out or tag

    runjson = args.flows or os.path.join(d, f"{tag}.json")
    if not os.path.exists(runjson):
        sys.stderr.write(f"no flowgen json {runjson}\n"); sys.exit(1)
    data = json.load(open(runjson))
    failtime = (data.get("summary") or {}).get("failtime")
    if not failtime and os.path.exists(os.path.join(d, f"{tag}.meta.json")):
        failtime = json.load(open(os.path.join(d, f"{tag}.meta.json"))).get("failtime")
    if not failtime:
        sys.stderr.write("no failtime in summary; cannot split before/after\n"); sys.exit(1)

    # per-node packet timestamps by source port
    node_txts = sorted(glob.glob(os.path.join(d, f"{tag}.node?.txt")))
    nodes, fwds = {}, {}
    for p in node_txts:
        node = os.path.basename(p)[len(tag) + 1:-4]  # strip "<tag>." and ".txt"
        nodes[node], fwds[node] = parse_node_txt(p, args.vip)
    if not nodes:
        sys.stderr.write("no per-node .txt captures found; was CAPTURE_PCAP=1?\n"); sys.exit(1)

    # invert: srcport -> {node: [ts]}; srcport -> [(ts, pod)] across nodes
    by_sp, fwd_sp = {}, {}
    for node, flows in nodes.items():
        for sp, tss in flows.items():
            by_sp.setdefault(sp, {})[node] = tss
    for node, f in fwds.items():
        for sp, lst in f.items():
            fwd_sp.setdefault(sp, []).extend(lst)

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
    be_cnt = {"rehomed_same_backend": 0, "rehomed_changed_backend": 0, "rehomed_backend_unknown": 0}
    for sp, per_node in by_sp.items():
        if sp not in fg:
            continue   # a probe or warm-up connection, not one of this population's flows
        nb, nbn = dominant_node(per_node, hi=failtime)
        na, nan = dominant_node(per_node, lo=failtime)
        fl = fg.get(sp, {})
        # backend chosen on the ingress node before vs after (from forward packets)
        bb = dominant_backend(fwd_sp.get(sp, []), hi=failtime)
        # "after" = the first backend used on the NEW ingress node, so a flow that
        # re-homes, breaks and is never retried still gets attributed
        ba = dominant_backend([x for x in fwd_sp.get(sp, []) if x[0] >= failtime and x[0] < failtime + 5]) \
             or dominant_backend(fwd_sp.get(sp, []), lo=failtime)
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
        rehomed = (nb is not None and na is not None and nb != na)
        if rehomed:
            if bb and ba:
                be_cnt["rehomed_same_backend" if bb == ba else "rehomed_changed_backend"] += 1
            else:
                be_cnt["rehomed_backend_unknown"] += 1
        records.append({"srcport": sp, "node_before": nb, "node_after": na,
                        "rehomed": rehomed,
                        "backend": fl.get("backend"), "status": status,
                        "backend_before": bb, "backend_after": ba,
                        "backend_changed": (bb != ba) if (bb and ba) else None,
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
        **be_cnt,
    }
    out = {"summary": summary, "flows": sorted(records, key=lambda r: r["srcport"])}
    json.dump(out, open(os.path.join(d, f"{out_tag}.rehoming.json"), "w"), indent=2)

    print(f"re-homing [{out_tag}]: {len(records)} flows in pcap, "
          f"{rehomed_total} re-homed "
          f"(survived {cnt['rehomed_survived']}, broken {cnt['rehomed_broken']}); "
          f"stayed (survived {cnt['stayed_survived']}, broken {cnt['stayed_broken']}); "
          f"unknown {cnt['unknown']}; "
          f"re-homed backend same {be_cnt['rehomed_same_backend']} / changed "
          f"{be_cnt['rehomed_changed_backend']} / unknown {be_cnt['rehomed_backend_unknown']}")
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
