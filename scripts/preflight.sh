#!/usr/bin/env bash
# Preflight: validate every generated artifact (shell/JSON/YAML/python syntax) and report which
# tools + images are present, before a (slow) `make up`. Safe to run anywhere with bash+python3.
#   bash scripts/preflight.sh
set -uo pipefail
cd "$(dirname "$0")/.."
fail=0
pass(){ printf '  \033[32mOK\033[0m   %s\n' "$*"; }
err(){  printf '  \033[31mFAIL\033[0m %s\n' "$*"; fail=1; }
warn(){ printf '  \033[33mWARN\033[0m %s\n' "$*"; }

echo "== shell syntax (bash -n) =="
while IFS= read -r s; do
  bash -n "$s" 2>/dev/null && pass "$s" || err "$s"
done < <(find tests scripts nodes/startup fabric/tor -name '*.sh' | sort)

echo "== python =="
python3 -m py_compile tests/lib/flowgen/flowgen.py 2>/dev/null && pass "flowgen.py" || err "flowgen.py"
for p in tests/lib/flowgen/connprobe.py scripts/disruption-summary.py; do
  python3 -m py_compile "$p" 2>/dev/null && pass "$p" || err "$p"
done

echo "== JSON =="
python3 -m json.tool fabric/tor/config_db.json >/dev/null 2>&1 && pass "config_db.json" || err "config_db.json"

echo "== YAML =="
if python3 -c 'import yaml' 2>/dev/null; then
  while IFS= read -r y; do
    python3 -c 'import yaml,sys; list(yaml.safe_load_all(open(sys.argv[1])))' "$y" 2>/dev/null \
      && pass "$y" || err "$y"
  done < <(find topo k8s -name '*.y*ml' | sort)
else
  warn "pyyaml not installed — skipping YAML deep-parse (install: pip install pyyaml)"
fi

echo "== tools =="
for t in docker containerlab kubectl helm jq; do
  if command -v "$t" >/dev/null 2>&1; then pass "$t present"; else warn "$t missing"; fi
done

echo "== images =="
for img in docker-sonic-vs:latest quay.io/frrouting/frr:9.1.0 maglev/k3s-bird:latest maglev/client:latest ubuntu:24.04; do
  if docker image inspect "$img" >/dev/null 2>&1; then pass "image $img"; else warn "image $img not pulled/built"; fi
done

echo
[ "$fail" -eq 0 ] && echo "preflight: all syntax checks passed" \
                  || { echo "preflight: syntax FAILURES above"; exit 1; }
