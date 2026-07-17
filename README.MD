# Установка
```bash
git clone https://github.com/hahatulk/vps-setup.git && cd vps-setup
```

# Запуск автонастройки
```bash
bash setup_vps.sh
```

# Вручную

### Установки пакетов
```bash
bash ./module/0.init.sh
```

### Создание пользователя
```bash
bash ./module/1.create_user.sh
```

### Настройка sshd
```bash
bash ./module/2.init_ssh.sh
```

### Настройка UFW
```bash
bash ./module/3.init_ufw.sh
```

### Настройка деплоя в проект
```bash
bash ./module/4.init_deploy.sh
```

# Бан IP
```bash
bash ban.sh
```

# Аудит безопасности VPS
```bash
bash audit.sh
```

# Бекап docker app, положить в папку с docker-compose.yml
```bash
bash backup-docker.sh
```

# Восстановление docker app из бекапа, положить в папку с docker-compose.yml
```bash
bash restore-docker.sh
```

