#!/usr/bin/env bash
# Build the k3s-bird node image and the flowgen client image.
# Run as root from WSL, or via: make images
set -euo pipefail
REPO="$(cd "$(dirname "$0")/.." && pwd)"

green() { echo -e "\033[32m$*\033[0m"; }
info()  { echo -e "\033[36m==> $*\033[0m"; }

info "building maglev/k3s-bird:latest"
docker build -t maglev/k3s-bird:latest "$REPO/nodes/"

info "building maglev/client:latest"
docker build -t maglev/client:latest "$REPO/tests/lib/flowgen/"

green "images built."
