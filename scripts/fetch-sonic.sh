#!/usr/bin/env bash
# Self-contained: fetch the sonic.software build index, extract the 202505 docker-sonic-vs.gz
# URL, download it, and docker load it as docker-sonic-vs:latest. One process (no cross-session
# temp-file races). Output image: docker-sonic-vs:latest
set -uo pipefail
REL="${SONIC_RELEASE:-202505}"
OUT="/root/docker-sonic-vs.gz"

echo "[fetch-sonic] release=${REL}"
curl -sL https://sonic.software/builds.json -o /root/builds.json
URL=$(python3 - "$REL" <<'PY'
import json,sys
d=json.load(open("/root/builds.json"))
print(d[sys.argv[1]]["docker-sonic-vs.gz"]["url"], end="")
PY
)
echo "[fetch-sonic] url length=${#URL}"
[ "${#URL}" -gt 50 ] || { echo "ERROR: empty URL"; exit 1; }

echo "[fetch-sonic] downloading -> ${OUT}"
curl -g -L --retry 3 -o "$OUT" "$URL"
echo "[fetch-sonic] downloaded $(stat -c%s "$OUT" 2>/dev/null) bytes; type: $(file -b "$OUT")"

echo "[fetch-sonic] docker load"
docker load -i "$OUT"
docker images | grep -i sonic || echo "WARN: no sonic image after load"
