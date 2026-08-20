#!/usr/bin/env bash
#
# Installs everything needed to run the TechStream stack on Ubuntu 24.04.
# Idempotent: safe to run twice.
#
# The EC2 instance created by infra/stack already does all of this in user_data.
# Use this only if user_data failed, or on a machine built by hand. Check first:
#   cat /opt/techstream/.user-data-complete
#
# References:
#   Docker Engine on Ubuntu   https://docs.docker.com/engine/install/ubuntu/
#   Docker post-install steps https://docs.docker.com/engine/install/linux-postinstall/
#   SSM Agent on Ubuntu       https://docs.aws.amazon.com/systems-manager/latest/userguide/agent-install-ubuntu.html
#   AWS CLI v2                https://docs.aws.amazon.com/cli/latest/userguide/getting-started-install.html
#
# Usage:
#   curl -fsSL <raw-url>/scripts/install-prereqs.sh | sudo bash
#   or: sudo bash scripts/install-prereqs.sh

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "error: run with sudo" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-ubuntu}"
APP_DIR="${APP_DIR:-/opt/techstream}"
export DEBIAN_FRONTEND=noninteractive

echo "==> base packages"
apt-get update -y
apt-get install -y --no-install-recommends \
  ca-certificates \
  curl \
  gnupg \
  git \
  jq \
  make \
  python3 \
  unzip \
  rsync

echo "==> Docker apt repository"
# Per docs.docker.com/engine/install/ubuntu. Do NOT use the docker.io package
# from Ubuntu's own repo: it does not ship the compose v2 plugin, and this stack
# needs "docker compose", not the old standalone "docker-compose".
install -m 0755 -d /etc/apt/keyrings
if [ ! -f /etc/apt/keyrings/docker.asc ]; then
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
fi

CODENAME="$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")"
cat >/etc/apt/sources.list.d/docker.list <<EOF
deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${CODENAME} stable
EOF

echo "==> Docker Engine and the compose plugin"
apt-get update -y
apt-get install -y \
  docker-ce \
  docker-ce-cli \
  containerd.io \
  docker-buildx-plugin \
  docker-compose-plugin

systemctl enable --now docker

echo "==> allow ${TARGET_USER} to use docker without sudo"
# Takes effect on next login. Per the post-install docs. Note this is equivalent
# to granting root, because the docker socket can start privileged containers.
usermod -aG docker "${TARGET_USER}" || true

echo "==> SSM Agent"
# Ubuntu 24.04 on AWS ships it as a snap and it is usually already running.
# SSM is how you reach the box without SSH, so it is worth confirming.
if ! snap list amazon-ssm-agent >/dev/null 2>&1; then
  snap install amazon-ssm-agent --classic
fi
snap start amazon-ssm-agent 2>/dev/null || true
snap set amazon-ssm-agent refresh.hold=forever 2>/dev/null || true

echo "==> AWS CLI v2"
# Not needed to run the stack, but needed to read Lambda logs and SSM command
# results from the box itself.
if ! command -v aws >/dev/null 2>&1; then
  ARCH="$(uname -m)"
  case "${ARCH}" in
    x86_64)  PKG="awscli-exe-linux-x86_64.zip" ;;
    aarch64) PKG="awscli-exe-linux-aarch64.zip" ;;
    *) echo "warn: unknown arch ${ARCH}, skipping AWS CLI"; PKG="" ;;
  esac
  if [ -n "${PKG}" ]; then
    TMP="$(mktemp -d)"
    curl -fsSL "https://awscli.amazonaws.com/${PKG}" -o "${TMP}/awscliv2.zip"
    unzip -q "${TMP}/awscliv2.zip" -d "${TMP}"
    "${TMP}/aws/install" --update
    rm -rf "${TMP}"
  fi
fi

echo "==> application directory"
# The SSM remediation document runs:
#   cd /opt/techstream && docker compose restart app
# so the repo must end up exactly here.
mkdir -p "${APP_DIR}"
chown -R "${TARGET_USER}:${TARGET_USER}" "${APP_DIR}"
date -u +"%Y-%m-%dT%H:%M:%SZ" >"${APP_DIR}/.user-data-complete"

echo
echo "======================= verification ======================="
printf '  %-22s %s\n' "docker"         "$(docker --version 2>/dev/null || echo MISSING)"
printf '  %-22s %s\n' "docker compose" "$(docker compose version --short 2>/dev/null || echo MISSING)"
printf '  %-22s %s\n' "git"            "$(git --version 2>/dev/null || echo MISSING)"
printf '  %-22s %s\n' "make"           "$(make --version 2>/dev/null | head -1 || echo MISSING)"
printf '  %-22s %s\n' "python3"        "$(python3 --version 2>/dev/null || echo MISSING)"
printf '  %-22s %s\n' "jq"             "$(jq --version 2>/dev/null || echo MISSING)"
printf '  %-22s %s\n' "aws"            "$(aws --version 2>/dev/null || echo 'MISSING (optional)')"
printf '  %-22s %s\n' "docker service" "$(systemctl is-active docker 2>/dev/null || echo inactive)"
printf '  %-22s %s\n' "ssm agent"      "$(snap services amazon-ssm-agent 2>/dev/null | awk 'NR==2{print $3}' || echo unknown)"
printf '  %-22s %s\n' "app dir"        "${APP_DIR} ($(stat -c '%U:%G %a' "${APP_DIR}" 2>/dev/null || echo missing))"
echo "==========================================================="
echo
echo "Docker group membership needs a new login. Either log out and back in, or:"
echo "  newgrp docker"
echo
echo "Next:"
echo "  cd ${APP_DIR} && cp .env.example .env    # set the password and token"
echo "  make up"
