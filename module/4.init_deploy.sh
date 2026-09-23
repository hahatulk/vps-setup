#!/bin/bash

echo "Starting Deploy project setup..."

read -p "Deploy username (default: deploy): " username
username=${username:-deploy}

read -p "Project name (default: nginx-proxy-manager): " project
project=${project:-nginx-proxy-manager}

if ! id -u "$username" > /dev/null 2>&1; then
	useradd -m "$username"
	usermod -aG docker "$username"
	groupadd "$username"
	usermod -a -G "$username" "$username"

	mkdir -p /home/"$username"/.ssh
	chmod 700 /home/"$username"/.ssh

	if [ ! -f /home/"$username"/.ssh/authorized_keys ]; then
		touch /home/"$username"/.ssh/authorized_keys
		chmod 600 /home/"$username"/.ssh/authorized_keys
		chown -R "$username":"$username" /home/"$username"/.ssh
	fi

	usermod -s /bin/bash "$username"
fi

mkdir -p /opt/docker
mkdir -p /opt/docker/"$project"
mkdir -p /opt/docker/ssh
mkdir -p /opt/docker/ssh/"$project"

key_path="/opt/docker/ssh/$project/id_rsa"

if [ ! -f "$key_path" ]; then
	ssh-keygen -q -t rsa -b 4096 -C "deploy@example.com" -f "$key_path" -N ""
fi

docker_compose_path="/opt/docker/$project/docker-compose.yml"

if [ ! -f "$docker_compose_path" ]; then
	touch "$docker_compose_path"
fi

chmod 400 "$key_path"
chown -R "$username":"$username" /opt/docker/ssh/"$project"
chown -R "$username":"$username" /opt/docker/"$project"

# SSH_PORT, SSH_HOST, SSH_USERNAME, SSH_KEY (private), Deploy key (public)

echo "Deploy project setup completed."
