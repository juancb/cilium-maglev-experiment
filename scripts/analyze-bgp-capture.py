#!/usr/bin/env python3
"""
analyze-bgp-capture.py — what did each Cilium agent say to bird when it re-peered?

Reads, for one tests/05 run made with CAPTURE_BGP=1:
  <run>.bgp.<node>.txt     tcpdump -vv decode of tcp/179 on the node (Cilium <-> bird)
  <run>.bird.<node>.log    bird's log (debug all on the cilium protocol)
  <run>.agent.<node>.log   the restarted agent pod's log
  <run>.bgp.jsonl          leaf1 route timeline (vip_cil nexthops, sessions)
  <run>.meta.json          failtime etc.

For every BGP session the agent opened after failtime it prints, in order, the
messages the agent sent: OPEN, each UPDATE (announced / withdrawn prefixes), the
End-of-RIB marker, Route Refresh. It flags the pattern under investigation:

  End-of-RIB sent BEFORE the Service VIP(s) were (re-)announced.
  With graceful restart, the helper (bird) flushes every stale route not yet
  re-announced when it receives End-of-RIB (RFC 4724 §4.2), so a VIP announced
  after the marker is withdrawn toward the fabric and re-announced a moment later.

It also lists bird log lines about stale/flushed routes and GR, counts the agent's
"soft reset" / route-refresh log lines, and reports any dip of the Cilium-only VIP
at leaf1 within a few seconds of each End-of-RIB.

Usage: python3 scripts/analyze-bgp-capture.py <results-dir> <run-tag> [--vip 192.0.2.20]
"""
import argparse
import datetime
import glob
import json
import os
import re
import sys

PKT_RE = re.compile(r"^(\d+\.\d+)\s+(\S+)\s+(In|Out|P|B)?\s*IP\b")
FLOW_RE = re.compile(r"^\s+(\d+\.\d+\.\d+\.\d+)\.(\d+) > (\d+\.\d+\.\d+\.\d+)\.(\d+): Flags \[([^\]]*)\].*?length (\d+)")
MSG_RE = re.compile(r"^\s+(Open|Update|Keepalive|Notification|Route Refresh) Message \((\d)\), length: (\d+)")
PFX_RE = re.compile(r"(\d+\.\d+\.\d+\.\d+/\d+)")


def parse_capture(path):
    """-> list of (ts, src, sport, dst, dport, msg) where msg = dict(type, announce, withdraw, eor)"""
    out = []
    cur = None       # current packet (ts, src, sport, dst, dport)
    msg = None
    section = None   # "announce" | "withdraw" | None
    seen = set()
    for line in open(path, errors="replace"):
        line = line.rstrip("\n")
        m = PKT_RE.match(line)
        if m:
            if msg:
                out.append((*cur, msg)); msg = None
            cur = [float(m.group(1)), None, None, None, None]
            section = None
            continue
        if cur and cur[1] is None:
            f = FLOW_RE.match(line)
            if f:
                cur[1:5] = [f.group(1), int(f.group(2)), f.group(3), int(f.group(4))]
                continue
        mm = MSG_RE.match(line)
        if mm and cur and cur[1]:
            if msg:
                out.append((*cur, msg))
            msg = {"type": mm.group(1), "announce": [], "withdraw": [], "eor": False}
            section = None
            continue
        if msg:
            if "End-of-Rib" in line or "End-of-RIB" in line:
                msg["eor"] = True
            elif "Withdrawn routes" in line or "Unreach" in line:
                section = "withdraw"
            elif "Updated routes" in line or "Reach NLRI" in line:
                section = "announce"
            elif section and PFX_RE.search(line) and ("Next Hop" not in line):
                msg[section].extend(PFX_RE.findall(line))
            elif re.match(r"^\s+\w[\w ]+ \(\d+\), length", line):
                section = None   # another path attribute
    if msg:
        out.append((*cur, msg))
    # dedupe (lo traffic can appear twice under -i any)
    uniq = []
    for rec in out:
        k = (round(rec[0], 6), rec[1], rec[2], rec[3], rec[4], rec[5]["type"], tuple(rec[5]["announce"]), tuple(rec[5]["withdraw"]), rec[5]["eor"])
        if k in seen:
            continue
        seen.add(k); uniq.append(rec)
    return uniq


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir"); ap.add_argument("tag")
    ap.add_argument("--vip", default="192.0.2.20")
    a = ap.parse_args()
    d, tag = a.dir, a.tag
    meta = json.load(open(os.path.join(d, tag + ".meta.json")))
    ft = meta["failtime"]
    rows = [json.loads(l) for l in open(os.path.join(d, tag + ".bgp.jsonl"))]
    base_nh = rows[0]["vip_cil"] if rows else None

    def vip_dip(t0, t1):
        return [(round(r["t"] - ft, 2), r["vip_cil"]) for r in rows if t0 <= r["t"] <= t1 and r["vip_cil"] < base_nh]

    print(f"== {tag}  ({meta.get('disruption')}, Cilium {meta.get('cilium_version')}, failtime +0.0 = {ft:.3f})")
    flagged = 0
    for cap in sorted(glob.glob(os.path.join(d, f"{tag}.bgp.node?.txt"))):
        node = cap[-9:-4]
        recs = parse_capture(cap)
        # agent -> bird: dport 179
        tx = [r for r in recs if r[4] == 179 and r[0] >= ft - 1]
        opens = [r for r in tx if r[5]["type"] == "Open"]
        print(f"-- {node}: {len(recs)} BGP messages in capture, {len(opens)} OPEN from the agent after failtime")
        for oi, op in enumerate(opens):
            end = opens[oi + 1][0] if oi + 1 < len(opens) else float("inf")
            sess = [r for r in tx if op[0] <= r[0] < end and r[5]["type"] in ("Update", "Route Refresh", "Notification")]
            print(f"   session {oi + 1}: OPEN at +{op[0] - ft:7.2f}s")
            eor_t = None; vip_t = None; refresh = 0
            for r in sess[:40]:
                m = r[5]
                if m["type"] == "Route Refresh":
                    refresh += 1
                    print(f"     +{r[0] - ft:7.2f}s  ROUTE REFRESH")
                    continue
                if m["type"] == "Notification":
                    print(f"     +{r[0] - ft:7.2f}s  NOTIFICATION")
                    continue
                if m["eor"]:
                    eor_t = eor_t or r[0]
                    print(f"     +{r[0] - ft:7.2f}s  UPDATE  End-of-RIB")
                    continue
                ann = ", ".join(m["announce"]) or "-"; wd = ", ".join(m["withdraw"]) or "-"
                print(f"     +{r[0] - ft:7.2f}s  UPDATE  announce [{ann}]  withdraw [{wd}]")
                if a.vip + "/32" in m["announce"] and vip_t is None:
                    vip_t = r[0]
            if len(sess) > 40:
                print(f"     ... {len(sess) - 40} more")
            verdict = "no End-of-RIB seen"
            if eor_t is not None:
                if vip_t is None:
                    verdict = f"End-of-RIB at +{eor_t - ft:.2f}s and the VIP was never announced in this session"
                elif vip_t > eor_t:
                    verdict = f"End-of-RIB at +{eor_t - ft:.2f}s BEFORE the VIP announce at +{vip_t - ft:.2f}s  <-- stale VIP flushed by the helper"
                    flagged += 1
                else:
                    verdict = f"VIP announced at +{vip_t - ft:.2f}s before End-of-RIB at +{eor_t - ft:.2f}s (correct order)"
                dips = vip_dip(eor_t - 1, eor_t + 6)
                if dips:
                    verdict += f"; leaf1 saw {a.vip} drop to {min(x[1] for x in dips)} nexthops at {dips[0][0]}s..{dips[-1][0]}s"
            print(f"     => {verdict}" + (f"; {refresh} route refresh" if refresh else ""))
        # bird log
        bl = os.path.join(d, f"{tag}.bird.{node}.log")
        if os.path.exists(bl):
            hits = [l.strip() for l in open(bl, errors="replace")
                    if re.search(r"stale|flush|Graceful|graceful|restart|End-of-RIB|EOR|withdraw.*192\.0\.2\.20|192\.0\.2\.20.*withdraw", l, re.I)]
            if hits:
                print(f"   bird log ({len(hits)} relevant lines):")
                for l in hits[:12]:
                    print("     " + l[:160])
        # agent log: when did the agent soft-reset the peer, relative to each session's OPEN?
        al = os.path.join(d, f"{tag}.agent.{node}.log")
        if os.path.exists(al):
            txt = open(al, errors="replace").read()
            soft_ts = []
            for l in txt.splitlines():
                if re.search(r"soft.?reset", l, re.I):
                    m = re.match(r"(\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d)(?:\.(\d+))?Z", l)
                    if m:
                        frac = (m.group(2) or "0")[:6].ljust(6, "0")   # 3.9's fromisoformat takes <= 6 digits
                        soft_ts.append(datetime.datetime.fromisoformat(f"{m.group(1)}.{frac}").replace(tzinfo=datetime.timezone.utc).timestamp())
            rr = len(re.findall(r"route.?refresh", txt, re.I)); gr = len(re.findall(r"graceful", txt, re.I))
            rel = [round(t - ft, 2) for t in soft_ts]
            after = []
            for op in opens:
                after += [round(t - ft, 2) for t in soft_ts if t > op[0] + 0.05]
            print(f"   agent log: {len(soft_ts)} soft resets at {rel}; route-refresh {rr}, graceful {gr} mentions")
            if after:
                print(f"     !! soft reset(s) AFTER a session OPEN at {sorted(set(after))}: re-advertisement after End-of-RIB is possible")
    print(f"== flagged sessions (End-of-RIB before VIP announce): {flagged}")


if __name__ == "__main__":
    main()
