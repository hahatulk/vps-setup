#!/bin/bash

echo "Starting User setup..."
read -p "Enter the username to create/update: " username

# === Создание пользователя (только если его ещё нет) ===
if ! id -u "$username" > /dev/null 2>&1; then
  echo "Creating new user..."
  sudo useradd -m "$username"
  sudo groupadd "$username"
  sudo usermod -a -G "$username" "$username"
  sudo usermod -s /bin/bash "$username"

  # Генерация пароля только при первом создании
  password=$(openssl rand -base64 16)
  echo "$username:$password" | sudo chpasswd
  echo "Password for user $username: $password"
else
  echo "User $username already exists. Updating settings..."
fi

# === Настройка прав (работает и при повторном запуске) ===

echo "Allow Sudo? (y/n):"
read allow_sudo

if [ "$allow_sudo" = "y" ]; then
  sudo usermod -aG sudo "$username"

  echo "Sudo without password? (y/n):"
  read sudo_nopasswd

  if [ "$sudo_nopasswd" = "y" ]; then
    if ! grep -q "^$username ALL=(ALL) NOPASSWD: ALL" /etc/sudoers; then
      echo "$username ALL=(ALL) NOPASSWD: ALL" | sudo tee -a /etc/sudoers > /dev/null
      echo "Sudo without password enabled"
    else
      echo "Sudo without password already set"
    fi
  else
    echo "Sudo with password enabled"
  fi
else
  echo "Sudo disabled"
fi

echo "Allow Docker? (y/n):"
read allow_docker

if [ "$allow_docker" = "y" ]; then
  sudo usermod -aG docker "$username"
  echo "Docker access enabled"
else
  echo "Docker access disabled"
fi

# === SSH ключ ===
sudo mkdir -p /home/"$username"/.ssh
sudo chown "$username":"$username" /home/"$username"/.ssh
sudo chmod 700 /home/"$username"/.ssh

echo "Add/Update SSH KEY? (y/n):"
read add_ssh_key

if [ "$add_ssh_key" = "y" ]; then
  echo "Enter ssh key: "
  read ssh_key
  echo "$ssh_key" | sudo tee /home/"$username"/.ssh/authorized_keys > /dev/null
  sudo chmod 600 /home/"$username"/.ssh/authorized_keys
  sudo chown "$username":"$username" /home/"$username"/.ssh/authorized_keys
  echo "SSH key updated"
else
  echo "Skipping SSH key..."
fi

echo "User setup completed."
