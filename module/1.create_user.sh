#!/bin/bash

echo "Starting User setup..."
read -p "Enter the username to create: " username

if ! id -u "$username" > /dev/null 2>&1; then
  sudo useradd -m "$username"
  sudo groupadd "$username"
  sudo usermod -a -G "$username" "$username"

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
        echo "Sudo without password already configured"
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
    echo "Allowed docker"
    sudo usermod -aG docker "$username"
  else
    echo "Forbidden docker"
  fi

  sudo mkdir -p /home/"$username"/.ssh

  if [ ! -f /home/"$username"/.ssh/authorized_keys ]; then
    sudo touch /home/"$username"/.ssh/authorized_keys
  fi

  echo "Add SSH KEY? (y/n):"
  read add_ssh_key

  if [ "$add_ssh_key" = "y" ]; then
    echo "Enter ssh key: "
    read ssh_key
    sudo echo "$ssh_key" >> /home/"$username"/.ssh/authorized_keys
  else
    echo "Skipping SSH key..."
  fi

  sudo usermod -s /bin/bash "$username"

  password=$(openssl rand -base64 16)
  echo "$username:$password" | sudo chpasswd
  echo "Password for user $username: $password"
fi

sudo chmod 700 /home/"$username"/.ssh
sudo chmod 600 /home/"$username"/.ssh/authorized_keys
sudo chown -R "$username":"$username" /home/"$username"/.ssh

echo "User setup completed."
