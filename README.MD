# Установка
```bash
git clone https://github.com/hahatulk/vps-setup.git && cd vps-setup
```

# Запуск автонастройки
```bash
bash setup_vps.sh
```

# Вручную

### Статический IPv4 без DHCP (Debian / Astra Linux / Ubuntu)
```bash
sudo bash scripts/configure_network.sh
```
Мастер показывает все интерфейсы и их состояние, запрашивает адаптер, IPv4,
префикс/маску, gateway, DNS и метрику маршрута. `-` означает отсутствие gateway
или DNS. Настройки сохраняются через NetworkManager, Netplan либо ifupdown.
Нужны `ip`, `python3`, `flock` и установленный сетевой менеджер; для Netplan — `python3-yaml`.
Скрипт не скачивает пакеты и не настраивает SSID, VLAN, bridge или bond.
Неоднозначные конфигурации и пользовательские ifupdown hooks требуют ручной настройки.

**Запускайте с локальной/IPMI-консоли: изменение адреса может оборвать SSH.**
Резервные копии и инструкции `RESTORE.txt` сохраняются в
`/var/backups/configure-network.*`. Netplan использует `try` с таймаутом 120 секунд
и может затронуть всю сеть; после отмены проверьте откат и восстановите файлы из копии.
В ifupdown без resolvconf изменяется глобальный `/etc/resolv.conf`; управляемый
симлинк скрипт не перезаписывает. Файлы Netplan, генерируемые cloud-init, могут быть
перезаписаны им при следующем запуске — проверьте настройки cloud-init отдельно.

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

# OpenVPN / PKI (Proxmox VE 9, Debian 13)

Скрипты и инструкции: [openvpn/README.md](openvpn/README.md).
Отдельная папка-пример: [`openvpn/pki-example/pki/`](openvpn/pki-example/README.md).
Она содержит только структуру и `vars.example`, **не рабочие ключи**.
Реальная PKI хранится вне репозитория: `/etc/openvpn/easy-rsa/pki/`.

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

# Отключение бесполезного containerd

```bash
nano /etc/docker/daemon.json
```
```
{
    "features": {
        "containerd-snapshotter": false
    }
}
```
```bash
systemctl restart docker
```
