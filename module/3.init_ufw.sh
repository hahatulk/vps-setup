#!/bin/bash

# Script for UFW section
# This sets up UFW firewall

echo "Starting UFW setup..."

apt-get install -y ufw

# Allow ports interactively
read -p "Enter SSH port to allow (default 2001): " ssh_port
ssh_port=${ssh_port:-2001}
ufw allow "$ssh_port"

ufw allow ssh  # In case default SSH is needed
ufw allow https
ufw allow ftp

ufw default deny incoming
ufw default allow outgoing

cp ./ufw-docker /usr/local/bin/ufw-docker
chmod +x /usr/local/bin/ufw-docker
ufw-docker install

ufw enable

ufw status verbose

systemctl restart ufw

apt install fail2ban -y

cp ./fail2ban/jail.local /etc/fail2ban/jail.local

systemctl start fail2ban
systemctl enable fail2ban
systemctl status fail2ban

echo "UFW setup completed."
echo "To delete a rule: ufw status numbered; ufw delete <number>"
