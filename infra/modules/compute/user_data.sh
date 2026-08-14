#!/usr/bin/env bash
# Installs Docker and the compose plugin, makes sure the SSM agent is running,
# and creates the directory the SSM restart document expects.
# Log: /var/log/cloud-init-output.log
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

APP_DIR="${app_dir}"

apt-get update -y
apt-get install -y \
  ca-certificates \
  curl \
  gnupg \
  git \
  jq \
  make \
  python3 \
  unzip

# Docker from the official Docker repo, so we get the compose v2 plugin.
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg \
  -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# shellcheck source=/dev/null
UBUNTU_CODENAME="$(. /etc/os-release && echo "$${UBUNTU_CODENAME:-$$VERSION_CODENAME}")"
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $${UBUNTU_CODENAME} stable
EOF

apt-get update -y
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

# Let the default user run docker without sudo. Needs a new login to take
# effect, which is why the SSM document runs as root instead.
usermod -aG docker ubuntu || true

# Ubuntu 24.04 ships the SSM agent as a snap. Make sure it is installed and up.
if ! snap list amazon-ssm-agent >/dev/null 2>&1; then
  snap install amazon-ssm-agent --classic
fi
snap start amazon-ssm-agent || true
snap set amazon-ssm-agent refresh.hold=forever || true

# The SSM restart document runs: cd $APP_DIR/monitoring && docker compose restart app
mkdir -p "$APP_DIR"
chown -R ubuntu:ubuntu "$APP_DIR"

# Marker used by the "how to verify" check in the README.
date -u +"%Y-%m-%dT%H:%M:%SZ" >"$APP_DIR/.user-data-complete"
echo "user_data finished"
