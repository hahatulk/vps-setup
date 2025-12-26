#!/bin/bash

# Script for VPS SETTING section
# This installs Docker and related packages

echo "Starting VPS SETTING..."

sudo apt update
sudo apt install ca-certificates curl -y
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

sudo tee /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/ubuntu
Suites: $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF

sudo apt update
sudo apt install docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin -y

sudo apt install fail2ban -y
sudo systemctl start fail2ban
sudo systemctl enable fail2ban
sudo systemctl status fail2ban

sudo mkdir -p /var/docker
sudo mkdir -p /var/docker/scripts
sudo git clone https://github.com/hahatulk/vps-setup.git /var/docker/scripts/vps-setup

echo "VPS SETTING completed."
