#!/usr/bin/env python3
import json, os, sys
d = sys.argv[1] if len(sys.argv) > 1 else "results"
for f in sorted(os.listdir(d)):
    if not f.endswith(".json"):
        continue
    data = json.load(open(f"{d}/{f}"))
    s = data.get("summary", {})
    flows = data.get("flows", [])
    backends = set(fl.get("backend") for fl in flows if fl.get("backend"))
    broke_after = [fl for fl in flows if fl.get("status") == "broken" and fl.get("established_at")]
    print(f"{f}:")
    print(f"  established={s.get('established')} broken_after={len(broke_after)} backends={sorted(backends)[:3]}")
