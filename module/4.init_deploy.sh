#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Error: run this script as root." >&2
  exit 1
fi

echo "Starting Deploy project setup..."

read -p "Deploy username (default: deploy): " username
username=${username:-deploy}

read -p "Project name (default: nginx-proxy-manager): " project
project=${project:-nginx-proxy-manager}

if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || [ "$username" = root ]; then
	echo "Error: invalid or unsafe username." >&2
	exit 1
fi
if [[ ! "$project" =~ ^[A-Za-z0-9][A-Za-z0-9_.-]*$ ]]; then
	echo "Error: invalid project name." >&2
	exit 1
fi
getent group docker >/dev/null || { echo "Error: docker group does not exist." >&2; exit 1; }

if ! id -u "$username" > /dev/null 2>&1; then
	useradd -m -s /bin/bash "$username"
	usermod -aG docker "$username"

	mkdir -p /home/"$username"/.ssh
	chmod 700 /home/"$username"/.ssh

	if [ ! -f /home/"$username"/.ssh/authorized_keys ]; then
		touch /home/"$username"/.ssh/authorized_keys
		chmod 600 /home/"$username"/.ssh/authorized_keys
		chown -R "$username":"$username" /home/"$username"/.ssh
	fi

fi

primary_group=$(id -gn "$username")
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
chown -R "$username:$primary_group" /opt/docker/ssh/"$project"
chown -R "$username:$primary_group" /opt/docker/"$project"

# SSH_PORT, SSH_HOST, SSH_USERNAME, SSH_KEY (private), Deploy key (public)

echo "Deploy project setup completed."
