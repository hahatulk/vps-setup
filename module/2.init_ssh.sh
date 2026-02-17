#!/bin/bash
# Script for SSH config section
# This configures SSH with interactive input
echo "Starting SSH config..."

sudo rm -rf /etc/ssh/sshd_config.d/50-cloud-init.conf
sudo cp sshd_config.d/10-custom.conf /etc/ssh/sshd_config.d/10.custom.conf

sudo systemctl restart ssh

echo "SSH config completed. Reboot recommended."
