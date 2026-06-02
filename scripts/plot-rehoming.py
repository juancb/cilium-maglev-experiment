#!/usr/bin/env python3
"""
plot-rehoming.py — visualise per-flow re-homing outcomes across runs.

Reads results/<tag>.run*.rehoming.json (produced by analyze-rehoming.py) for each
cell tag, sums the four outcome classes over all runs, and draws a stacked bar per
cell. The Maglev story is whether the RED "re-homed & broke" segment is present:
Maglev ON should have ~none (re-homed flows keep their backend), Maglev OFF should
show a clear red band.

Usage:
  python3 scripts/plot-rehoming.py [results-dir] [tag1 tag2 ...]
  (default results dir = results/; default tags = all graceful-drain_* cells found)
"""
import sys, os, glob, json

try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
except ImportError:
    sys.stderr.write("matplotlib not available\n"); sys.exit(1)

RESULTS = sys.argv[1] if len(sys.argv) > 1 else "results"
PLOTS = os.path.join(RESULTS, "plots")
os.makedirs(PLOTS, exist_ok=True)

CLASSES = [
    ("rehomed_survived", "re-homed → survived (Maglev kept backend)", "#2ecc71"),
    ("rehomed_broken",   "re-homed → BROKE (wrong backend)",          "#e74c3c"),
    ("stayed_survived",  "stayed → survived",                          "#bdc3c7"),
    ("stayed_broken",    "stayed → broke",                             "#e67e22"),
]


def tags_from_args():
    if len(sys.argv) > 2:
        return sys.argv[2:]
    tags = set()
    for f in glob.glob(os.path.join(RESULTS, "*.run*.rehoming.json")):
        base = os.path.basename(f)
        tags.add(base.split(".run")[0])
    return sorted(tags)


def agg_tag(tag):
    totals = {k: 0 for k, _, _ in CLASSES}
    n_runs = 0
    for f in sorted(glob.glob(os.path.join(RESULTS, f"{tag}.run*.rehoming.json"))):
        s = json.load(open(f)).get("summary", {})
        for k, _, _ in CLASSES:
            totals[k] += s.get(k, 0)
        n_runs += 1
    return totals, n_runs


def main():
    tags = tags_from_args()
    data = [(t, *agg_tag(t)) for t in tags]
    data = [(t, tot, n) for (t, tot, n) in data if n > 0]
    if not data:
        sys.stderr.write("no *.rehoming.json found\n"); sys.exit(1)

    fig, ax = plt.subplots(figsize=(max(7, 2.4 * len(data)), 6))
    x = range(len(data))
    labels = []
    for k, legend, color in CLASSES:
        bottoms = []
        heights = []
        for _, tot, _ in data:
            heights.append(tot.get(k, 0))
        # compute running bottoms
        base = [0] * len(data)
        # recompute cumulative from earlier classes
        for i, (_, tot, _) in enumerate(data):
            b = 0
            for kk, _, _ in CLASSES:
                if kk == k:
                    break
                b += tot.get(kk, 0)
            bottoms.append(b)
        ax.bar(list(x), heights, bottom=bottoms, color=color, label=legend, width=0.55)

    for i, (t, tot, n) in enumerate(data):
        total = sum(tot.values()) or 1
        rb = tot.get("rehomed_broken", 0)
        rs = tot.get("rehomed_survived", 0)
        rehomed = rb + rs
        labels.append(f"{t.replace('graceful-drain_','').replace('_',' ')}\n"
                      f"{n} run(s), {rehomed} re-homed")
        ax.text(i, total + total * 0.01,
                f"re-homed broke: {rb}", ha="center", va="bottom",
                fontsize=9, fontweight="bold",
                color=("#e74c3c" if rb else "#2ecc71"))

    ax.set_xticks(list(x))
    ax.set_xticklabels(labels, fontsize=9)
    ax.set_ylabel("flows (summed over runs)")
    ax.set_title("Per-flow re-homing outcomes — does Maglev keep the backend after re-home?")
    ax.legend(loc="upper center", bbox_to_anchor=(0.5, -0.08), ncol=2, fontsize=8)
    ax.grid(True, axis="y", alpha=0.3)
    fig.tight_layout()
    out = os.path.join(PLOTS, "rehoming.png")
    fig.savefig(out, dpi=150, bbox_inches="tight")
    print(f"  Wrote {out}")
    for t, tot, n in data:
        print(f"  {t}: {n} runs — " + ", ".join(f"{k}={tot[k]}" for k, _, _ in CLASSES))


if __name__ == "__main__":
    main()
