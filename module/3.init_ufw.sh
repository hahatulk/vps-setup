#!/bin/bash

# Script for UFW section
# This sets up UFW firewall

echo "Starting UFW setup..."

sudo apt-get install ufw

# Allow ports interactively
read -p "Enter SSH port to allow (default 2001): " ssh_port
ssh_port=${ssh_port:-2001}
sudo ufw allow "$ssh_port"

sudo ufw allow ssh  # In case default SSH is needed
sudo ufw allow https
sudo ufw allow ftp

sudo ufw default deny incoming
sudo ufw default allow outgoing

sudo cp ./ufw-docker /usr/local/bin/ufw-docker
sudo chmod +x /usr/local/bin/ufw-docker
sudo ufw-docker install

sudo ufw enable

sudo ufw status verbose

sudo systemctl restart ufw

echo "UFW setup completed."
echo "To delete a rule: sudo ufw status numbered; sudo ufw delete <number>"
