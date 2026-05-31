#!/usr/bin/env bash
# Install Docker Engine natively in WSL2 Ubuntu so containerlab can see bridge interfaces
# via netlink (Docker Desktop's daemon runs in a separate VM whose bridges aren't visible
# in WSL2's netns). After this, use the native daemon at /var/run/docker.sock.
set -uo pipefail

export DEBIAN_FRONTEND=noninteractive

echo "== detecting existing Docker =="
if systemctl is-active docker >/dev/null 2>&1; then
  echo "native dockerd already running — skipping install"
  docker version --format '{{.Server.Version}}'
  exit 0
fi

echo "== installing Docker CE =="
apt-get update -qq
apt-get install -y -qq ca-certificates curl gnupg
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc
echo "deb [arch=amd64 signed-by=/etc/apt/keyrings/docker.asc] \
  https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
  > /etc/apt/sources.list.d/docker.list
apt-get update -qq
apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

echo "== starting dockerd =="
# WSL2 doesn't run systemd by default in Ubuntu 24.04 with dockerd; start it directly
# if systemd is not the init.
if pidof systemd >/dev/null 2>&1; then
  systemctl enable --now docker
else
  nohup dockerd --host=unix:///var/run/docker.sock >/var/log/dockerd.log 2>&1 &
  sleep 5
fi

echo "== done =="
docker version --format 'Server: {{.Server.Version}}'
