#!/bin/bash
# Script for SSH config section
# This configures SSH with interactive input
echo "Starting SSH config..."
# Interactive inputs
read -p "Enter SSH port (default 2001): " port
port=${port:-2001}

read -p "PermitRootLogin (yes/no, default: no): " permit_root
permit_root=${permit_root:-no}

read -p "PubkeyAuthentication (yes/no, default: yes): " pubkey_auth
pubkey_auth=${pubkey_auth:-yes}

read -p "PasswordAuthentication (yes/no, default: no): " pass_auth
pass_auth=${pass_auth:-no}

read -p "ChallengeResponseAuthentication (yes/no, default: no): " challenge_auth
challenge_auth=${challenge_auth:-no}

read -p "UsePAM (yes/no, default yes): " use_pam
use_pam=${use_pam:-yes}

# Edit sshd_config
sudo sed -i "s/^#*Port .*/Port $port/" /etc/ssh/sshd_config
sudo sed -i "s/^#*PermitRootLogin .*/PermitRootLogin $permit_root/" /etc/ssh/sshd_config
sudo sed -i "s/^#*PubkeyAuthentication .*/PubkeyAuthentication $pubkey_auth/" /etc/ssh/sshd_config
sudo sed -i "s/^#*PasswordAuthentication .*/PasswordAuthentication $pass_auth/" /etc/ssh/sshd_config
sudo sed -i "s/^#*ChallengeResponseAuthentication .*/ChallengeResponseAuthentication $challenge_auth/" /etc/ssh/sshd_config
sudo sed -i "s/^#*UsePAM .*/UsePAM $use_pam/" /etc/ssh/sshd_config

sudo systemctl restart ssh

echo "SSH config completed. Reboot recommended."