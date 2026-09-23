#!/bin/bash

# Script for VPS SETTING section
# This installs Docker and related packages

echo "Starting VPS SETTING..."

apt update && apt upgrade -y
apt install -y ca-certificates curl ufw fail2ban
install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

apt update
apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

# Оставить только последние 2 недели + уменьшить до 500 МБ
mkdir -p /etc/systemd/journald.conf.d
cat <<EOF | tee /etc/systemd/journald.conf.d/size.conf
[Journal]
SystemMaxUse=500M
RuntimeMaxUse=200M
EOF

systemctl restart systemd-journald

echo "VPS SETTING completed."
