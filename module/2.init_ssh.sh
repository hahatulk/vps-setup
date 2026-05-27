#!/bin/bash

echo "Starting SSH config..."

# Удаляем облачный конфиг (если есть)
sudo rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf

# Копируем наш улучшенный конфиг
sudo cp sshd_config.d/99.custom.conf /etc/ssh/sshd_config.d/99.custom.conf
sudo chmod 644 /etc/ssh/sshd_config.d/99.custom.conf

# Проверка конфига
if ! sudo sshd -t; then
  echo "ERROR: SSH config has errors!"
  exit 1
fi

sudo systemctl restart ssh

echo "SSH config completed successfully."
