#!/usr/bin/env bash
set -Eeuo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Error: run this script as root." >&2
  exit 1
fi

echo "Starting User setup..."
read -rp "Enter the username to create/update: " username

if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]] || [ "$username" = "root" ]; then
  echo "Error: invalid or unsafe username." >&2
  exit 1
fi

# === Создание пользователя (только если его ещё нет) ===
if ! id -u "$username" > /dev/null 2>&1; then
  echo "Creating new user..."
  useradd -m -s /bin/bash "$username"

  # Генерация пароля только при первом создании
  password=$(openssl rand -base64 16)
  echo "$username:$password" | chpasswd
  echo "Password for user $username: $password"
else
  echo "User $username already exists. Updating settings..."
fi

# === Настройка прав (работает и при повторном запуске) ===

echo "Allow Sudo? (y/n):"
read allow_sudo

if [ "$allow_sudo" = "y" ]; then
  getent group sudo >/dev/null || { echo "Error: sudo group does not exist." >&2; exit 1; }
  usermod -aG sudo "$username"

  echo "Sudo without password? (y/n):"
  read -r sudo_nopasswd

  sudoers_file="/etc/sudoers.d/90-$username"
  if [ "$sudo_nopasswd" = "y" ]; then
    command -v visudo >/dev/null || { echo "Error: visudo is required." >&2; exit 1; }
    tmp_sudoers=$(mktemp)
    trap 'rm -f "$tmp_sudoers"' EXIT
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" > "$tmp_sudoers"
    chmod 0440 "$tmp_sudoers"
    visudo -cf "$tmp_sudoers" >/dev/null
    install -m 0440 "$tmp_sudoers" "$sudoers_file"
    rm -f "$tmp_sudoers"
    trap - EXIT
    echo "Sudo without password enabled"
  else
    rm -f "$sudoers_file"
    echo "Sudo with password enabled"
  fi
else
  rm -f "/etc/sudoers.d/90-$username"
  echo "No sudo group changes made; any managed passwordless-sudo rule was removed"
fi

echo "Allow Docker? (y/n):"
read -r allow_docker

if [ "$allow_docker" = "y" ]; then
  getent group docker >/dev/null || { echo "Error: docker group does not exist." >&2; exit 1; }
  usermod -aG docker "$username"
  echo "Docker access enabled"
else
  echo "Docker access disabled"
fi

# === SSH ключ ===
home_dir=$(getent passwd "$username" | cut -d: -f6)
primary_group=$(id -gn "$username")
[ -n "$home_dir" ] || { echo "Error: user has no home directory." >&2; exit 1; }
install -d -m 0700 -o "$username" -g "$primary_group" "$home_dir/.ssh"

echo "Add/Update SSH KEY? (y/n):"
read -r add_ssh_key

if [ "$add_ssh_key" = "y" ]; then
  echo "Enter ssh key: "
  read -r ssh_key
  [[ "$ssh_key" =~ ^(ssh-|ecdsa-|sk-) ]] || { echo "Error: invalid SSH public key." >&2; exit 1; }
  printf '%s\n' "$ssh_key" > "$home_dir/.ssh/authorized_keys"
  chmod 600 "$home_dir/.ssh/authorized_keys"
  chown "$username:$primary_group" "$home_dir/.ssh/authorized_keys"
  echo "SSH key updated"
else
  echo "Skipping SSH key..."
fi

echo "User setup completed."
