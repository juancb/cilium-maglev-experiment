#!/usr/bin/env bash
# Build the k3s-bird node image and the flowgen client image.
# Run as root from WSL, or via: make images
set -euo pipefail

# The lab runs on the native Docker CE daemon (scripts/install-native-docker.sh), which
# listens on docker-native.sock because Docker Desktop's WSL proxy owns docker.sock.
[ -S /var/run/docker-native.sock ] && export DOCKER_HOST="${DOCKER_HOST:-unix:///var/run/docker-native.sock}"
REPO="$(cd "$(dirname "$0")/.." && pwd)"

green() { echo -e "\033[32m$*\033[0m"; }
info()  { echo -e "\033[36m==> $*\033[0m"; }

info "building maglev/k3s-bird:latest"
docker build -t maglev/k3s-bird:latest "$REPO/nodes/"

info "building maglev/client:latest"
docker build -t maglev/client:latest "$REPO/tests/lib/flowgen/"

green "images built."
