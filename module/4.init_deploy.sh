#!/bin/bash

echo "Starting Deploy project setup..."

read -p "Deploy username (default: deploy): " username
username=${username:-deploy}

read -p "Project name (default: nginx-proxy-manager): " project
project=${project:-nginx-proxy-manager}

if ! id -u "$username" > /dev/null 2>&1; then
	sudo useradd -m "$username"
	sudo usermod -aG docker "$username"
	sudo groupadd "$username"
	sudo usermod -a -G "$username" "$username"

	sudo mkdir -p /home/"$username"/.ssh
	sudo chmod 700 /home/"$username"/.ssh

	if [ ! -f /home/"$username"/.ssh/authorized_keys ]; then
		sudo touch /home/"$username"/.ssh/authorized_keys
		sudo chmod 600 /home/"$username"/.ssh/authorized_keys
		sudo chown -R "$username":"$username" /home/"$username"/.ssh
	fi

	sudo usermod -s /bin/bash "$username"
fi

sudo mkdir -p /var/docker
sudo mkdir -p /var/docker/"$project"
sudo mkdir -p /var/docker/ssh
sudo mkdir -p /var/docker/ssh/"$project"

key_path="/var/docker/ssh/$project/id_rsa"

if [ ! -f "$key_path" ]; then
	sudo ssh-keygen -q -t rsa -b 4096 -C "deploy@example.com" -f "$key_path" -N ""
fi

docker_compose_path="/var/docker/$project/docker-compose.yml"

if [ ! -f "$docker_compose_path" ]; then
	sudo touch "$docker_compose_path"
fi

sudo chmod 400 "$key_path"
sudo chown -R "$username":"$username" /var/docker/ssh/"$project"
sudo chown -R "$username":"$username" /var/docker/"$project"

# SSH_PORT, SSH_HOST, SSH_USERNAME, SSH_KEY (private), Deploy key (public)

echo "Deploy project setup completed."
