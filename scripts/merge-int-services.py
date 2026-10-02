#!/usr/bin/env python3
"""
merge-int-services.py — fold the per-Service in-cluster flow files of a tests/05 run made
with SVC_COUNT=N (<run>.int-svc01.json .. <run>.int-svcNN.json) into the single
<run>.int.json the summarizer reads. Each flow gets a "svc" field (1..N); the summary is
the sum over Services plus per-Service broken counts, so a disruption that hits some
Services but not others is visible.

Usage: merge-int-services.py <results-dir> <run-tag> <svc-count>
"""
import json
import os
import sys

d, r, n = sys.argv[1], sys.argv[2], int(sys.argv[3])
flows = []
summ = {"count": 0, "established": 0, "never_established": 0, "broken_after_establish": 0,
        "broken_reset": 0, "broken_timeout": 0, "survived": 0, "services": 0,
        "per_service": {}, "backend_distribution": {}}
for i in range(1, n + 1):
    p = os.path.join(d, f"{r}.int-svc{i:02d}.json")
    if not os.path.exists(p):
        continue
    j = json.load(open(p))
    s = j["summary"]
    summ["services"] += 1
    for k in ("count", "established", "never_established", "broken_after_establish",
              "broken_reset", "broken_timeout", "survived"):
        summ[k] += s.get(k, 0)
    summ["per_service"][f"{i:02d}"] = {"established": s.get("established", 0),
                                        "broken": s.get("broken_after_establish", 0)}
    for b, c in s.get("backend_distribution", {}).items():
        summ["backend_distribution"][b] = summ["backend_distribution"].get(b, 0) + c
    for f in j["flows"]:
        f["svc"] = i
        flows.append(f)
with open(os.path.join(d, f"{r}.int.json"), "w") as out:
    json.dump({"summary": summ, "flows": flows}, out, indent=1)
print(f"  int: merged {summ['services']} Services, {summ['established']} flows established, "
      f"{summ['broken_after_establish']} broken")
