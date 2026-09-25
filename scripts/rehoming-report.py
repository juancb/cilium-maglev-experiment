#!/usr/bin/env python3
"""
rehoming-report.py — what happened to the flows that re-homed, per tests/05 cell.

Reads results/<dir>/dz_*.run*.<pop>.rehoming.json (from analyze-rehoming.py, CAPTURE_PCAP=1)
and each run's meta.json, and splits every re-homed flow by where its backend lived:

  backend elsewhere        the backend was NOT on the disrupted node, so the outcome is the
                           datapath's doing: same backend (Maglev) vs changed (random), and
                           whether it survived
  backend on disrupted node  the forward was blackholed while that node's pod CIDR was
                           withdrawn; such a flow only "survives" if the route returns and
                           ECMP moves it home before the client gives up (transient re-home)

The pod->node map comes from meta.json["pods"] (recorded by the test) or --pods FILE
("name ip node" per line) for runs that predate it. Backend identity is only visible when
the backend is remote from the ingress node (local delivery uses bpf_redirect_peer, which
the capture can't see), so same/changed counts are "of those visible".

Usage: python3 scripts/rehoming-report.py <results-dir> [--pods FILE] [--pop ext-cil]
"""
import argparse
import collections
import glob
import json
import os


def load_pods(meta, pods_file):
    m = {}
    if meta.get("pods"):
        for p in meta["pods"]:
            m[p["name"]] = p["node"]
    elif pods_file:
        for l in open(pods_file):
            parts = l.split()
            if len(parts) >= 3:
                m[parts[0]] = parts[2]
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("dir")
    ap.add_argument("--pods")
    ap.add_argument("--pop", default="ext-cil")
    a = ap.parse_args()

    rows = collections.OrderedDict()
    for p in sorted(glob.glob(os.path.join(a.dir, f"dz_*.run*.{a.pop}.rehoming.json"))):
        base = p[: -len(f".{a.pop}.rehoming.json")]
        cell = os.path.basename(base).split(".run")[0]
        meta = json.load(open(base + ".meta.json"))
        pods = load_pods(meta, a.pods)
        target = meta.get("target_node")
        r = rows.setdefault(cell, collections.Counter())
        r["runs"] += 1
        for f in json.load(open(p))["flows"]:
            r["flows"] += 1
            if not f.get("rehomed"):
                continue
            r["rehomed"] += 1
            r["returned"] += 1 if f.get("returned") else 0
            bnode = pods.get(f.get("backend"))
            if bnode is None:
                grp = "backend_unknown_node"
            elif bnode == target:
                grp = "backend_on_disrupted_node"
            else:
                grp = "backend_elsewhere"
            r[grp] += 1
            r[grp + (":broken" if f.get("broke_after_fail") else ":survived")] += 1
            if grp == "backend_elsewhere" and f.get("backend_changed") is not None:
                k = grp + (":changed" if f["backend_changed"] else ":same")
                r[k] += 1
                r[k + (":broken" if f.get("broke_after_fail") else ":survived")] += 1

    def cell_pct(r, k):
        n = r[k]
        return f"{n:4d} {100.0 * r[k + ':broken'] / n:5.1f}%" if n else "   0     -"

    print(f"population: {a.pop}   (n = flows, broken% of those)")
    print(f"{'cell':52s} runs flows re-homed returned | backend elsewhere | same backend | changed backend | backend on disrupted node")
    for cell, r in rows.items():
        print(f"{cell:52s} {r['runs']:4d} {r['flows']:5d} {r['rehomed']:8d} {r['returned']:8d} | "
              f"{cell_pct(r, 'backend_elsewhere')} | {cell_pct(r, 'backend_elsewhere:same')} | "
              f"{cell_pct(r, 'backend_elsewhere:changed')} | {cell_pct(r, 'backend_on_disrupted_node')}"
              + (f"  (+{r['backend_unknown_node']} backend node unknown)" if r["backend_unknown_node"] else ""))


if __name__ == "__main__":
    main()
