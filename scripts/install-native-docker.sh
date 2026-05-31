#!/usr/bin/env bash
# Install Docker CE natively in WSL2 Ubuntu-24.04 and run it alongside Docker Desktop.
# The native daemon uses /var/run/docker-native.sock so there's no conflict.
# Images from Docker Desktop are piped over so we don't have to re-pull/rebuild.
# After this script, all lab commands should use:  DOCKER_HOST=unix:///var/run/docker-native.sock
set -uo pipefail
export DEBIAN_FRONTEND=noninteractive
NATIVE_SOCK="/var/run/docker-native.sock"
NATIVE_DATA="/var/lib/docker-native"

echo "== step 1: install Docker CE from docker.io apt repo =="
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
. /etc/os-release
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin

echo "== step 2: create systemd override for non-conflicting socket =="
mkdir -p /etc/systemd/system/docker.service.d
cat > /etc/systemd/system/docker.service.d/native-sock.conf <<'EOF'
[Service]
ExecStart=
ExecStart=/usr/bin/dockerd -H unix:///var/run/docker-native.sock --data-root=/var/lib/docker-native
EOF

systemctl daemon-reload
systemctl enable docker
systemctl start docker || true

echo "== step 3: wait for native daemon =="
for _ in $(seq 1 30); do
  DOCKER_HOST="unix://${NATIVE_SOCK}" docker info &>/dev/null && break
  sleep 2
done
DOCKER_HOST="unix://${NATIVE_SOCK}" docker version --format 'Native daemon: {{.Server.Version}}' || { echo "FAILED to start native daemon"; exit 1; }

echo "== step 4: transfer images from Docker Desktop daemon =="
TRANSFER_IMAGES=(
  "docker-sonic-vs:latest"
  "quay.io/frrouting/frr:9.1.0"
  "maglev/k3s-bird:latest"
  "maglev/client:latest"
)
for IMG in "${TRANSFER_IMAGES[@]}"; do
  echo "  transferring $IMG ..."
  if DOCKER_HOST="unix://${NATIVE_SOCK}" docker image inspect "$IMG" &>/dev/null; then
    echo "  $IMG already in native daemon — skip"
  else
    docker save "$IMG" | DOCKER_HOST="unix://${NATIVE_SOCK}" docker load
  fi
done

echo "== done =="
echo "Use:  export DOCKER_HOST=unix:///var/run/docker-native.sock"
DOCKER_HOST="unix://${NATIVE_SOCK}" docker images --format "{{.Repository}}:{{.Tag}}\t{{.Size}}" | grep -E "sonic|frr|maglev|k3s"
