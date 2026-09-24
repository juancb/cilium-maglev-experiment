#!/usr/bin/env bash
# Load/pull all lab images into the native Docker CE daemon (now the default daemon).
# The sonic-vs tarball is at /root/docker-sonic-vs.gz from scripts/fetch-sonic.sh.
# FRR is pulled from registry. Node/client images are rebuilt from source.
set -uo pipefail

# The lab runs on the native Docker CE daemon (scripts/install-native-docker.sh), which
# listens on docker-native.sock because Docker Desktop's WSL proxy owns docker.sock.
[ -S /var/run/docker-native.sock ] && export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker-native.sock}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

echo "== docker-sonic-vs from tarball =="
if docker image inspect docker-sonic-vs:latest &>/dev/null; then
  echo "  already present"
else
  docker load -i /root/docker-sonic-vs.gz
fi
docker images docker-sonic-vs:latest --format "  {{.Repository}}:{{.Tag}} ({{.Size}})"

echo "== frr 9.1.0 =="
if docker image inspect quay.io/frrouting/frr:9.1.0 &>/dev/null; then
  echo "  already present"
else
  docker pull quay.io/frrouting/frr:9.1.0
fi

echo "== maglev/client =="
docker build -t maglev/client:latest "${REPO}/tests/lib/flowgen/" 2>&1 | tail -4

echo "== maglev/k3s-bird (takes 3-5 min) =="
docker build -t maglev/k3s-bird:latest "${REPO}/nodes/" 2>&1 | tail -6

echo "== summary =="
docker images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}" | grep -E "sonic|frr|maglev|k3s"
