#!/usr/bin/env python3
"""
Visualise cilium-maglev-experiment flow results.

Reads all *.json files under results/ (or a given directory) and produces:
  - results/summary.html   — full summary with tables and inline SVG plots
  - results/plots/*.png    — per-cell timeline PNGs (if matplotlib available)

Usage:
  python3 scripts/visualise.py [results-dir]
"""
import json
import os
import sys
import glob
import math
from pathlib import Path
from datetime import datetime

# --- matplotlib is optional; fall back to SVG-in-HTML ---
try:
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    import matplotlib.patches as mpatches
    HAS_MPL = True
except ImportError:
    HAS_MPL = False

RESULTS_DIR = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("results")
PLOTS_DIR   = RESULTS_DIR / "plots"
PLOTS_DIR.mkdir(parents=True, exist_ok=True)


def load_results(results_dir: Path) -> dict:
    """Load all flow JSON files; return {tag: data}."""
    data = {}
    for fpath in sorted(results_dir.glob("*.json")):
        if fpath.name.startswith("_"):
            continue
        try:
            with open(fpath) as f:
                d = json.load(f)
            data[fpath.stem] = d
        except Exception as e:
            print(f"  warning: could not load {fpath}: {e}", file=sys.stderr)
    return data


def flow_stats(data: dict) -> dict:
    """Compute per-tag summary stats."""
    stats = {}
    for tag, d in data.items():
        flows = d.get("flows", [])
        summary = d.get("summary", {})
        established = summary.get("established", len([f for f in flows if f.get("established_at")]))
        broken = [f for f in flows if f.get("status") == "broken" and f.get("established_at")]
        pct = 100 * len(broken) / established if established else 0
        # find failtime from summary or infer as min broke_at
        failtime = summary.get("failtime") or summary.get("fail_time")
        if not failtime and broken:
            failtime = min(f.get("broke_at", 0) for f in broken if f.get("broke_at"))
        backends = list({f.get("backend", "?") for f in flows if f.get("backend")})
        stats[tag] = {
            "established": established,
            "broken": len(broken),
            "pct": pct,
            "failtime": failtime,
            "backends": backends,
            "flows": flows,
        }
    return stats


def timeline_data(flows: list, failtime) -> tuple:
    """Return (times_rel, cumulative_broken, has_failtime) relative to failtime.

    Returns non-empty has_failtime even when 0 flows broke, so the caller can
    still draw the failure marker and a flat-0 line for the cell.
    """
    if not failtime:
        return [], [], False
    broke_times = sorted(
        f["broke_at"] for f in flows
        if f.get("status") == "broken" and f.get("broke_at") and f.get("established_at")
    )
    rel = [t - failtime for t in broke_times]
    cum = list(range(1, len(rel) + 1))
    return rel, cum, True


def make_timeline_png(stats: dict, out_path: Path):
    """Plot cumulative broken flows vs time for all cells."""
    if not HAS_MPL:
        return None

    fig, ax = plt.subplots(figsize=(10, 6))

    colors = {
        "spine-failure_ch-off_maglev-off": "#95a5a6",
        "spine-failure_ch-on_maglev-off":  "#7f8c8d",
        "spine-failure_ch-off_maglev-on":  "#bdc3c7",
        "spine-failure_ch-on_maglev-on":   "#ecf0f1",
        "single-node_ch-off_maglev-off":   "#e74c3c",
        "single-node_ch-on_maglev-off":    "#e67e22",
        "single-node_ch-off_maglev-on":    "#2ecc71",
        "single-node_ch-on_maglev-on":     "#27ae60",
        "dsr_maglev-off":                  "#9b59b6",
        "dsr_maglev-on":                   "#1abc9c",
        "etp-local_maglev-off":            "#c0392b",
        "etp-local_maglev-on":             "#e74c3c",
        # legacy names (pre-rename)
        "ch-off_maglev-off":  "#e74c3c",
        "ch-on_maglev-off":   "#e67e22",
        "ch-off_maglev-on":   "#2ecc71",
        "ch-on_maglev-on":    "#27ae60",
    }

    # First pass: compute global x window across all datasets with known failtime
    all_rel = []
    has_any_failtime = False
    for tag, s in sorted(stats.items()):
        rel, cum, has_ft = timeline_data(s["flows"], s.get("failtime"))
        if has_ft:
            has_any_failtime = True
            all_rel.extend(rel)

    if not has_any_failtime:
        plt.close(fig)
        return None

    # window: show -90s…+60s by default; expand if data falls outside
    x_min = min(-90, min(all_rel) - 5) if all_rel else -90
    x_max = max(60,  max(all_rel) + 5) if all_rel else 60

    plotted = False
    for tag, s in sorted(stats.items()):
        rel, cum, has_ft = timeline_data(s["flows"], s.get("failtime"))
        if not has_ft:
            continue
        color = colors.get(tag, None)
        # human-readable label: "single node / ch off / Maglev off"
        label = (tag.replace("_", " / ")
                    .replace("-", " ")
                    .replace("maglev", "Maglev"))
        established = s.get("established", 0)
        n_broken = len(cum)
        suffix = f" — {n_broken}/{established} broken" if established else ""
        # plot step from left window edge; flat at 0 if no breaks
        xs = [x_min] + rel + [x_max]
        ys = [0]     + cum + [cum[-1] if cum else 0]
        ax.step(xs, ys, where="post",
                label=label + suffix, color=color, linewidth=1.8)
        plotted = True

    if not plotted:
        plt.close(fig)
        return None

    ax.axvline(0, color="black", linewidth=1.5, linestyle="--", label="failure (t=0)")
    ax.axvspan(0, 9, alpha=0.08, color="red", label="BGP holdtime (~9s)")
    ax.set_xlim(x_min, x_max)
    ax.set_xlabel("Seconds relative to failure")
    ax.set_ylabel("Cumulative broken flows")
    ax.set_title("Cilium Maglev × Switch CH — flow breakage timeline")
    ax.legend(loc="upper left", fontsize=9)
    ax.grid(True, alpha=0.3)
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  Wrote {out_path}")
    return out_path


def make_backend_dist_png(stats: dict, out_path: Path):
    """Bar chart of backend distribution per cell."""
    if not HAS_MPL:
        return None

    cells = list(stats.keys())
    if not cells:
        return None

    # Count unique backends per cell
    backend_counts = {}
    for tag, s in stats.items():
        bc = {}
        for f in s["flows"]:
            b = f.get("backend") or "unknown"
            bc[b] = bc.get(b, 0) + 1
        backend_counts[tag] = bc

    all_backends = sorted({b for bc in backend_counts.values() for b in bc})
    if not all_backends:
        return None

    x = list(range(len(cells)))
    width = 0.8 / max(len(all_backends), 1)

    fig, ax = plt.subplots(figsize=(max(10, len(cells) * 2), 5))
    cmap = matplotlib.colormaps.get_cmap("tab20").resampled(len(all_backends))

    for i, backend in enumerate(all_backends):
        counts = [backend_counts[tag].get(backend, 0) for tag in cells]
        offsets = [xi + (i - len(all_backends)/2) * width for xi in x]
        ax.bar(offsets, counts, width=width * 0.9,
               label=backend[-20:], color=cmap(i), alpha=0.8)

    ax.set_xticks(x)
    ax.set_xticklabels([t.replace("_", "\n") for t in cells], fontsize=8)
    ax.set_ylabel("Flows served")
    ax.set_title("Backend distribution per cell")
    ax.legend(loc="upper right", fontsize=7, ncol=2)
    ax.grid(True, alpha=0.3, axis="y")
    fig.tight_layout()
    fig.savefig(out_path, dpi=150)
    plt.close(fig)
    print(f"  Wrote {out_path}")
    return out_path


EXPECTED = {
    # Spine failure: ToR ECMP 3→2; same leaf→node path → no ingress-node change → Maglev irrelevant
    "spine-failure_ch-off_maglev-off":  0,
    "spine-failure_ch-on_maglev-off":   0,
    "spine-failure_ch-off_maglev-on":   0,
    "spine-failure_ch-on_maglev-on":    0,
    # Single-node failure: node removed from VIP ECMP; ~1/3 flows re-homed to new ingress agent
    "single-node_ch-off_maglev-off":   28,   # re-homed flows pick random backend
    "single-node_ch-on_maglev-off":    28,   # CH at spine doesn't affect leaf-level node selection
    "single-node_ch-off_maglev-on":     0,   # Maglev picks same backend on new agent
    "single-node_ch-on_maglev-on":      0,
    # DSR: client IP preserved; Maglev must match on the new ingress node
    "dsr_maglev-off":       28,
    "dsr_maglev-on":         0,
    # ETP=Local: pod must be local to the ingress node; re-homed flows always lose local pod
    "etp-local_maglev-off": 33,
    "etp-local_maglev-on":  33,
    # Legacy (pre-rename)
    "ch-off_maglev-off":   28,
    "ch-on_maglev-off":    28,
    "ch-off_maglev-on":     0,
    "ch-on_maglev-on":      0,
}


def html_color(actual_pct: float, expected_pct: int) -> str:
    delta = abs(actual_pct - expected_pct)
    if delta <= 5:
        return "#2ecc71"   # green
    if delta <= 15:
        return "#e67e22"   # orange
    return "#e74c3c"       # red


def build_html(stats: dict, timeline_png, backend_png) -> str:
    now = datetime.now().strftime("%Y-%m-%d %H:%M")

    # Group tags by test type for display order
    GROUP_ORDER = ["spine-failure", "single-node", "dsr", "etp-local"]
    GROUP_LABELS = {
        "spine-failure": "Spine failure (baseline — expects ~0% both cells)",
        "single-node":   "Single-node failure (primary Maglev experiment)",
        "dsr":           "DSR mode",
        "etp-local":     "ExternalTrafficPolicy=Local",
    }

    def tag_group(tag: str) -> str:
        for g in GROUP_ORDER:
            if tag.startswith(g):
                return g
        return "other"

    sorted_tags = sorted(stats.keys(), key=lambda t: (GROUP_ORDER.index(tag_group(t)) if tag_group(t) in GROUP_ORDER else 99, t))

    rows = ""
    last_group = None
    for tag in sorted_tags:
        g = tag_group(tag)
        if g != last_group:
            label = GROUP_LABELS.get(g, g)
            rows += f'<tr><td colspan="6" style="background:#f7f7f7;padding:8px 10px;font-weight:bold;border-top:2px solid #ccc">{label}</td></tr>'
            last_group = g
        s = stats[tag]
        pct = s["pct"]
        exp = EXPECTED.get(tag, "—")
        color = html_color(pct, exp) if isinstance(exp, int) else "#888"
        backends_str = ", ".join(sorted(s["backends"])[:5])
        if len(s["backends"]) > 5:
            backends_str += f" (+{len(s['backends'])-5} more)"
        rows += f"""
        <tr>
          <td><code>{tag}</code></td>
          <td align="right">{s['established']}</td>
          <td align="right" style="color:{color};font-weight:bold">{s['broken']}</td>
          <td align="right" style="color:{color};font-weight:bold">{pct:.1f}%</td>
          <td align="right">{exp if exp == '—' else str(exp)+'%'}</td>
          <td style="font-size:0.8em">{backends_str}</td>
        </tr>"""

    def img_tag(path) -> str:
        if path and path.exists():
            rel = path.name
            return f'<img src="plots/{rel}" style="max-width:100%;margin:1em 0">'
        return '<p style="color:#888">Plot unavailable (install matplotlib: pip install matplotlib)</p>'

    return f"""<!DOCTYPE html>
<html><head>
<meta charset="utf-8">
<title>Cilium Maglev Experiment — Results {now}</title>
<style>
  body {{ font-family: monospace; max-width: 1100px; margin: 2em auto; color: #222; }}
  h1 {{ font-size: 1.3em; }} h2 {{ font-size: 1.1em; color: #444; }}
  table {{ border-collapse: collapse; width: 100%; margin: 1em 0; }}
  th {{ background: #f0f0f0; text-align: left; padding: 6px 10px; }}
  td {{ border-top: 1px solid #ddd; padding: 5px 10px; }}
  tr:hover td {{ background: #fafafa; }}
  .legend {{ font-size:0.85em; color:#555; margin: 0.5em 0; }}
</style>
</head><body>
<h1>Cilium Maglev × Switch Consistent-Hashing — Experiment Results</h1>
<p>Generated: {now} | Results dir: {RESULTS_DIR}</p>

<h2>Broken-flow summary</h2>
<p class="legend">
  Green = within 5% of predicted &nbsp;|&nbsp;
  Orange = within 15% &nbsp;|&nbsp;
  Red = &gt;15% from predicted
</p>
<table>
  <tr>
    <th>Cell</th><th>Established</th><th>Broken</th><th>Broken%</th>
    <th>Expected</th><th>Backends observed</th>
  </tr>
  {rows}
</table>

<h2>Theory vs prediction (M=3 nodes, B=6 backends, P=3 spines)</h2>
<pre>
  Spine failure (default test)
    Maglev off / on     →  ~0%   (spine failure doesn't change leaf→node ECMP group;
                                   flows survive; Maglev has no effect to show here)

  Single-node failure (--node-failure; primary Maglev experiment)
    CH off / Maglev off →  ~28%  (~1/3 flows re-homed; random backend pick)
    CH off / Maglev on  →  ~0%   (re-homed flows pick same backend via Maglev)

  DSR + Maglev off      →  ~28%  (client IP preserved; random picks wrong pod)
  DSR + Maglev on       →  ~0%   (client IP preserved; Maglev picks same pod)
  ETP=Local (any)       →  ~33%  (re-homed flows always get different local pod)
</pre>

<h2>Flow breakage timeline</h2>
{img_tag(timeline_png)}

<h2>Backend distribution</h2>
{img_tag(backend_png)}

<hr>
<p style="font-size:0.8em;color:#888">
  Re-run: <code>python3 scripts/visualise.py results/</code>
</p>
</body></html>"""


def main():
    print(f"Loading results from {RESULTS_DIR} ...")
    data  = load_results(RESULTS_DIR)
    if not data:
        print("No result JSON files found.")
        sys.exit(1)

    stats = flow_stats(data)

    print(f"\n{'Cell':<35} {'Est':>6} {'Broken':>8} {'%':>7} {'Pred':>7}")
    print("-" * 65)
    for tag in sorted(stats.keys()):
        s = stats[tag]
        exp = EXPECTED.get(tag, "—")
        mark = ""
        if isinstance(exp, int):
            mark = "OK" if abs(s["pct"] - exp) <= 5 else "!!"
        print(f"  {tag:<33} {s['established']:>6} {s['broken']:>8} {s['pct']:>6.1f}% {str(exp)+'%':>7} {mark}")

    print()
    if not HAS_MPL:
        print("  (matplotlib not available — PNG plots skipped; install with: pip install matplotlib)")

    timeline_png = make_timeline_png(stats, PLOTS_DIR / "timeline.png")
    backend_png  = make_backend_dist_png(stats, PLOTS_DIR / "backends.png")

    html = build_html(stats, timeline_png, backend_png)
    out_html = RESULTS_DIR / "summary.html"
    out_html.write_text(html, encoding="utf-8")
    print(f"  Wrote {out_html}")
    print(f"\nOpen {out_html} in a browser to view the full report.")


if __name__ == "__main__":
    main()
