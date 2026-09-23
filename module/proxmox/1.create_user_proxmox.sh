#!/usr/bin/env bash

set -Eeuo pipefail

echo "Starting Proxmox user setup..."

if [ "${EUID}" -ne 0 ]; then
  echo "Error: run this script as root."
  exit 1
fi

if ! command -v pveum >/dev/null 2>&1; then
  echo "Warning: pveum was not found. Linux/PAM user setup will work, but Proxmox GUI/API setup will be skipped."
fi

read -rp "Enter the username to create/update: " username

if [[ ! "$username" =~ ^[a-z_][a-z0-9_-]*$ ]]; then
  echo "Error: invalid Linux username."
  exit 1
fi

# === Linux/PAM user ===
if ! id -u "$username" >/dev/null 2>&1; then
  echo "Creating Linux user..."

  if command -v adduser >/dev/null 2>&1; then
    adduser --disabled-password --gecos "" "$username"
  else
    useradd -m -s /bin/bash "$username"
  fi

  password="$(openssl rand -base64 24)"
  echo "$username:$password" | chpasswd

  echo "Password for user $username: $password"
  echo "Save it now; the script will not print it again."
else
  echo "Linux user $username already exists. Updating settings..."
fi

usermod -s /bin/bash "$username"

primary_group="$(id -gn "$username")"
home_dir="$(getent passwd "$username" | cut -d: -f6)"

if [ -z "$home_dir" ]; then
  echo "Error: could not determine home directory for $username."
  exit 1
fi

# === sudo ===
read -rp "Allow sudo? (y/n): " allow_sudo

if [[ "$allow_sudo" == "y" || "$allow_sudo" == "Y" ]]; then
  if ! command -v sudo >/dev/null 2>&1; then
    read -rp "sudo is not installed. Install it now? (y/n): " install_sudo
    if [[ "$install_sudo" == "y" || "$install_sudo" == "Y" ]]; then
      apt-get update
      DEBIAN_FRONTEND=noninteractive apt-get install -y sudo
    else
      echo "Skipping sudo setup because sudo is not installed."
      allow_sudo="n"
    fi
  fi
fi

if [[ "$allow_sudo" == "y" || "$allow_sudo" == "Y" ]]; then
  if getent group sudo >/dev/null 2>&1; then
    usermod -aG sudo "$username"
  else
    echo "Error: sudo group does not exist."
    exit 1
  fi

  read -rp "Sudo without password? (y/n): " sudo_nopasswd
  sudoers_file="/etc/sudoers.d/90-$username"

  if [[ "$sudo_nopasswd" == "y" || "$sudo_nopasswd" == "Y" ]]; then
    tmp_sudoers="$(mktemp)"
    printf '%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$username" > "$tmp_sudoers"
    chmod 0440 "$tmp_sudoers"

    if visudo -cf "$tmp_sudoers" >/dev/null; then
      install -m 0440 "$tmp_sudoers" "$sudoers_file"
      echo "Passwordless sudo enabled via $sudoers_file"
    else
      rm -f "$tmp_sudoers"
      echo "Error: generated sudoers rule failed validation."
      exit 1
    fi

    rm -f "$tmp_sudoers"
  else
    rm -f "$sudoers_file"
    echo "Sudo with password enabled."
  fi
else
  echo "Sudo setup skipped."
fi

# === Docker (optional; Docker is not assumed to exist on a Proxmox host) ===
read -rp "Allow Docker access if Docker is installed? (y/n): " allow_docker

if [[ "$allow_docker" == "y" || "$allow_docker" == "Y" ]]; then
  if getent group docker >/dev/null 2>&1; then
    usermod -aG docker "$username"
    echo "Docker access enabled."
  else
    echo "Docker group not found; skipping Docker access."
  fi
else
  echo "Docker access skipped."
fi

# === SSH key ===
install -d -m 0700 -o "$username" -g "$primary_group" "$home_dir/.ssh"

read -rp "Add/Update SSH key? (y/n): " add_ssh_key

if [[ "$add_ssh_key" == "y" || "$add_ssh_key" == "Y" ]]; then
  read -rp "Enter SSH public key: " ssh_key

  if [ -z "$ssh_key" ]; then
    echo "Error: SSH key cannot be empty."
    exit 1
  fi

  printf '%s\n' "$ssh_key" > "$home_dir/.ssh/authorized_keys"
  chown "$username:$primary_group" "$home_dir/.ssh/authorized_keys"
  chmod 0600 "$home_dir/.ssh/authorized_keys"
  echo "SSH key updated."
else
  echo "Skipping SSH key."
fi

# === Proxmox GUI/API user (PAM realm) ===
if command -v pveum >/dev/null 2>&1; then
  pve_user="${username}@pam"

  read -rp "Add/Update Proxmox GUI/API user $pve_user? (y/n): " add_pve_user

  if [[ "$add_pve_user" == "y" || "$add_pve_user" == "Y" ]]; then
    if pveum user list 2>/dev/null | awk 'NR > 1 {print $1}' | grep -Fxq "$pve_user"; then
      echo "Proxmox user $pve_user already exists."
    else
      pveum user add "$pve_user"
      echo "Proxmox user $pve_user created."
    fi

    echo "Select Proxmox role on /:"
    echo "  1) Administrator - full access, including permissions"
    echo "  2) PVEAdmin      - broad admin access, without permission management"
    echo "  3) PVEAuditor    - read-only"
    echo "  4) None          - create user without ACL"
    read -rp "Role [1-4]: " pve_role_choice

    case "$pve_role_choice" in
      1)
        pveum acl modify / -user "$pve_user" -role Administrator
        echo "Granted Administrator on /."
        ;;
      2)
        pveum acl modify / -user "$pve_user" -role PVEAdmin
        echo "Granted PVEAdmin on /."
        ;;
      3)
        pveum acl modify / -user "$pve_user" -role PVEAuditor
        echo "Granted PVEAuditor on /."
        ;;
      4|"")
        echo "No Proxmox ACL assigned."
        ;;
      *)
        echo "Unknown role selection; no Proxmox ACL assigned."
        ;;
    esac
  else
    echo "Proxmox GUI/API setup skipped."
  fi
fi

echo
echo "User setup completed."
echo "Linux user: $username"
if command -v pveum >/dev/null 2>&1; then
  echo "Proxmox PAM identity: ${username}@pam"
fi
