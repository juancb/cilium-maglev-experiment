#!/usr/bin/env bash
# One-shot installer for the lab host tools in WSL Ubuntu (run as root).
# Installs: jq, containerlab (.deb), helm (tarball). Idempotent-ish.
set -uo pipefail

echo "== apt: jq =="
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq jq curl ca-certificates >/dev/null && echo "jq OK" || echo "jq FAIL"

echo "== containerlab (.deb) =="
if ! command -v containerlab >/dev/null 2>&1; then
  VER=$(curl -sL https://api.github.com/repos/srl-labs/containerlab/releases/latest | jq -r .tag_name | sed 's/^v//')
  echo "latest containerlab: ${VER}"
  curl -sL -o /tmp/clab.deb "https://github.com/srl-labs/containerlab/releases/download/v${VER}/containerlab_${VER}_linux_amd64.deb"
  apt-get install -y /tmp/clab.deb >/dev/null 2>&1 || dpkg -i /tmp/clab.deb
fi
containerlab version 2>/dev/null | head -3 || echo "containerlab FAIL"

echo "== helm (tarball) =="
if ! command -v helm >/dev/null 2>&1; then
  HV=v3.16.3
  curl -sL "https://get.helm.sh/helm-${HV}-linux-amd64.tar.gz" | tar xz -C /tmp
  install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm
fi
helm version --short 2>/dev/null || echo "helm FAIL"

echo "== done =="
for t in docker containerlab helm jq kubectl; do
  printf '  %-12s %s\n' "$t" "$(command -v "$t" 2>/dev/null || echo MISSING)"
done
