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
fi

primary_group=$(id -gn "$username")
home_dir=$(getent passwd "$username" | cut -d: -f6)
[ -n "$home_dir" ] || { echo "Error: user has no home directory." >&2; exit 1; }

password=$(openssl rand -base64 24)
printf '%s:%s\n' "$username" "$password" | chpasswd
usermod -U "$username"
echo "Password for user $username: $password"

install -d -m 0700 -o "$username" -g "$primary_group" "$home_dir/.ssh"
touch "$home_dir/.ssh/authorized_keys"
chmod 600 "$home_dir/.ssh/authorized_keys"
chown "$username:$primary_group" "$home_dir/.ssh/authorized_keys"
mkdir -p /opt/docker/ssh/"$project"

key_path="/opt/docker/ssh/$project/id_rsa"

if [ ! -f "$key_path" ]; then
	ssh-keygen -q -t rsa -b 4096 -C "deploy@example.com" -f "$key_path" -N ""
fi

pub_key_path="$key_path.pub"
if [ ! -f "$pub_key_path" ]; then
	ssh-keygen -y -f "$key_path" > "$pub_key_path"
fi

public_key=$(cat "$pub_key_path")
if ! grep -qxF "$public_key" "$home_dir/.ssh/authorized_keys"; then
	printf '%s\n' "$public_key" >> "$home_dir/.ssh/authorized_keys"
fi

chmod 400 "$key_path"
chown -R "$username:$primary_group" /opt/docker/ssh/"$project"

# SSH_PORT, SSH_HOST, SSH_USERNAME, SSH_KEY (private), Deploy key (public)

echo "Deploy project setup completed."
