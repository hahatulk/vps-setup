#!/bin/bash

echo "Starting SSH config..."

# Удаляем облачный конфиг (если есть)
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf

# Копируем наш улучшенный конфиг
cp sshd_config.d/99.custom.conf /etc/ssh/sshd_config.d/99.custom.conf
chmod 644 /etc/ssh/sshd_config.d/99.custom.conf

# Проверка конфига
if ! sshd -t; then
  echo "ERROR: SSH config has errors!"
  exit 1
fi

systemctl restart ssh
systemctl restart sshd

echo "SSH config completed successfully."
