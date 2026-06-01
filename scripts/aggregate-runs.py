#!/usr/bin/env python3
"""
aggregate-runs.py — collapse N per-run flowgen JSONs into one aggregated result.

A failover cell is now run RUNS times (see tests/lib/failover-lib.sh). Each run
writes results/<tag>.run<k>.json. This script reads all runs for a tag, computes
mean / stddev / min / max of the post-failure broken fraction (and the reset-vs-
timeout split), and writes a single results/<tag>.json that visualise.py and the
writeup consume. Single-run (n=1) input still works — stddev is just 0.

Usage:
  python3 scripts/aggregate-runs.py <results-dir> <tag>
  python3 scripts/aggregate-runs.py results dsr_maglev-on
"""
import json
import sys
import glob
import math
import os


def load_runs(results_dir, tag):
    runs = []
    for fpath in sorted(glob.glob(os.path.join(results_dir, f"{tag}.run*.json"))):
        try:
            with open(fpath) as f:
                runs.append((fpath, json.load(f)))
        except Exception as e:
            sys.stderr.write(f"  warning: skipping {fpath}: {e}\n")
    return runs


def post_failure_broken(data):
    """Count flows broken after failtime, split by error type."""
    summary = data.get("summary", {})
    failtime = summary.get("failtime") or 0
    flows = data.get("flows", [])
    established = summary.get("established", 0)
    reset = timeout = other = 0
    for fl in flows:
        if fl.get("status") != "broken" or not fl.get("established_at"):
            continue
        if (fl.get("broke_at") or 0) < failtime:
            continue
        et = fl.get("error_type") or "other"
        if et == "reset":
            reset += 1
        elif et == "timeout":
            timeout += 1
        else:
            other += 1
    broken = reset + timeout + other
    return established, broken, reset, timeout, other


def mean(xs):
    return sum(xs) / len(xs) if xs else 0.0


def stddev(xs):
    if len(xs) < 2:
        return 0.0
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def main():
    if len(sys.argv) != 3:
        sys.stderr.write("usage: aggregate-runs.py <results-dir> <tag>\n")
        sys.exit(2)
    results_dir, tag = sys.argv[1], sys.argv[2]
    runs = load_runs(results_dir, tag)
    if not runs:
        sys.stderr.write(f"  no run files for tag '{tag}' in {results_dir}\n")
        sys.exit(1)

    pcts, reset_pcts, timeout_pcts = [], [], []
    per_run = []
    # carry the last run's full flow list so timeline plotting still works
    last_data = runs[-1][1]
    for fpath, data in runs:
        est, broken, reset, timeout, other = post_failure_broken(data)
        if est <= 0:
            continue
        pcts.append(100 * broken / est)
        reset_pcts.append(100 * reset / est)
        timeout_pcts.append(100 * timeout / est)
        per_run.append({
            "file": os.path.basename(fpath),
            "established": est, "broken": broken,
            "reset": reset, "timeout": timeout, "other": other,
            "broken_pct": round(100 * broken / est, 2),
        })

    agg = {
        "tag": tag,
        "n_runs": len(per_run),
        "broken_pct_mean": round(mean(pcts), 2),
        "broken_pct_stddev": round(stddev(pcts), 2),
        "broken_pct_min": round(min(pcts), 2) if pcts else 0.0,
        "broken_pct_max": round(max(pcts), 2) if pcts else 0.0,
        "reset_pct_mean": round(mean(reset_pcts), 2),
        "timeout_pct_mean": round(mean(timeout_pcts), 2),
        "per_run": per_run,
    }

    # Write aggregated file. Keep the last run's flows + summary for the timeline,
    # and attach the aggregate block under summary.aggregate.
    out = dict(last_data)
    out.setdefault("summary", {})
    out["summary"]["aggregate"] = agg
    out_path = os.path.join(results_dir, f"{tag}.json")
    with open(out_path, "w") as f:
        json.dump(out, f, indent=2)

    print(f"  {tag}: {agg['broken_pct_mean']:.1f}% ± {agg['broken_pct_stddev']:.1f}% "
          f"(reset {agg['reset_pct_mean']:.1f}%, timeout {agg['timeout_pct_mean']:.1f}%) "
          f"over {agg['n_runs']} run(s)")


if __name__ == "__main__":
    main()
