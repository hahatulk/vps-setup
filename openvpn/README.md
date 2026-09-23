# OpenVPN for Proxmox VE 9 / Debian 13

Набор Bash-скриптов для установки и обслуживания OpenVPN на Proxmox VE 9.x / Debian 13 (Trixie).

Комплект рассчитан на OpenVPN 2.6+ и Easy-RSA 3.x. На Debian 13 текущие stable-пакеты — OpenVPN 2.6.x и Easy-RSA 3.2.x.

## Структура репозитория

```text
openvpn/
├── .gitignore
├── README.md
├── SECURITY.md
├── install.sh
├── uninstall.sh
├── bin/
│   ├── ovpn-add-client
│   ├── ovpn-fw
│   ├── ovpn-list-clients
│   ├── ovpn-render-server
│   ├── ovpn-revoke-client
│   ├── ovpn-scrub-client-secret
│   ├── ovpn-set-mode
│   └── ovpn-status
├── lib/
│   ├── common.sh
│   └── verify-crl-health
└── pki-example/
    ├── README.md
    └── pki/
        ├── README.md
        ├── vars.example
        ├── private/
        ├── issued/
        ├── reqs/
        ├── certs_by_serial/
        ├── tls-crypt-v2-clients/
        ├── secret-scrubbed/
        ├── revoked/
        └── inline/
```

`pki-example/` — только безопасный пример структуры. Настоящие ключи туда не кладутся.

Реальная PKI создаётся на сервере:

```text
/etc/openvpn/easy-rsa/pki/
```

## Основные меры безопасности

- CA private key **по умолчанию защищён паролем**.
- Режим CA без пароля доступен только явным `--ca-nopass`.
- `umask 077`, PKI и client export directories закрыты от обычных пользователей.
- Конфигурация, которая source-ится root-скриптами, должна принадлежать root и иметь права не шире `0600`.
- PKI-операции сериализованы через `flock`.
- Используется `tls-crypt-v2` с отдельным transport key для каждого клиента.
- Сервер по умолчанию требует `force-cookie` для tls-crypt-v2.
- CRL проверяется fail-closed отдельным `tls-verify` hook: отсутствующий, повреждённый или просроченный CRL блокирует handshake.
- Server startup дополнительно блокируется systemd `ExecStartPre`, если отсутствуют необходимые cert/key/CRL файлы.
- Client CN не переиспользуется после revoke.
- Сертификат сервера проверяется против CA, а public key сертификата сверяется с private key.
- VPN subnet проверяется на пересечение с существующими маршрутами и заданными LAN.
- Split-tunnel firewall разрешает forwarding только к явно указанным `--lan`.
- Full-tunnel forwarding ограничен выбранным WAN-интерфейсом.
- Скрипты не добавляют широкое INPUT-правило на Proxmox и не пытаются обходить Proxmox Firewall.
- В `.gitignore` блокируются PKI/private keys, `.ovpn`, PKCS#12 и runtime PKI state.

Подробнее: [SECURITY.md](SECURITY.md).

---

## 1. Подготовка

Проверь интерфейсы:

```bash
ip -br link
ip -br addr
ip route
```

Типичный Proxmox:

```text
default via 192.168.1.1 dev vmbr0
```

Пример схемы:

```text
Proxmox/LAN: 192.168.1.0/24
VM network:  10.20.0.0/24
VPN pool:    10.8.0.0/24
WAN bridge:  vmbr0
```

VPN pool не должен пересекаться с LAN, VM networks или существующими маршрутами сервера.

---

## 2. Установка

```bash
cd /path/to/vps-setup/openvpn
chmod +x install.sh uninstall.sh bin/* lib/verify-crl-health
```

### Рекомендуемый split-tunnel

```bash
sudo ./install.sh \
  --endpoint vpn.example.com \
  --wan vmbr0 \
  --lan 192.168.1.0/24 \
  --lan 10.20.0.0/24
```

Если `--wan` не указан, скрипт пытается определить его по default IPv4 route.

При первой установке Easy-RSA попросит пароль CA. Сохрани пароль в password manager: без него нельзя будет штатно выпускать и отзывать сертификаты.

### Публичный IP вместо DNS

```bash
sudo ./install.sh \
  --endpoint 203.0.113.10 \
  --lan 192.168.1.0/24
```

### Другой UDP-порт

```bash
sudo ./install.sh \
  --endpoint vpn.example.com \
  --port 443 \
  --lan 192.168.1.0/24
```

Это UDP/443, не TCP/443.

### Другой VPN subnet

```bash
sudo ./install.sh \
  --endpoint vpn.example.com \
  --vpn-cidr 10.50.0.0/24 \
  --lan 192.168.1.0/24
```

### Full-tunnel IPv4

```bash
sudo ./install.sh \
  --endpoint vpn.example.com \
  --mode full \
  --lan 192.168.1.0/24 \
  --dns 1.1.1.1 \
  --dns 9.9.9.9
```

**Важно:** этот комплект маршрутизирует full-tunnel только для IPv4. Он не является IPv6 kill-switch. Если клиент имеет рабочий IPv6, часть трафика может пойти мимо VPN. См. SECURITY.md.

### CA без пароля

Только если unattended issuance важнее защиты CA при краже файлов:

```bash
sudo ./install.sh \
  --endpoint vpn.example.com \
  --lan 192.168.1.0/24 \
  --ca-nopass
```

Это менее безопасный режим.

---

## 3. Что создаётся на сервере

```text
/etc/openvpn/pve-openvpn.conf
/etc/openvpn/server/server.conf
/etc/openvpn/server/ca.crt
/etc/openvpn/server/server.crt
/etc/openvpn/server/server.key
/etc/openvpn/server/crl.pem
/etc/openvpn/server/tls-crypt-v2-server.key

/etc/openvpn/easy-rsa/pki/
/root/openvpn-clients/
```

Управляющие команды:

```text
ovpn-add-client
ovpn-revoke-client
ovpn-scrub-client-secret
ovpn-list-clients
ovpn-status
ovpn-set-mode
ovpn-render-server
ovpn-fw
```

Services:

```text
openvpn-server@server.service
pve-openvpn-fw.service
```

---

## 4. Port forwarding

Если Proxmox стоит за роутером:

```text
Protocol:      UDP
External port: 1194
Internal IP:   IP Proxmox
Internal port: 1194
```

При другом `--port` используй соответствующий UDP-порт.

Если провайдер использует CGNAT и у тебя нет доступного входящего публичного адреса, обычный port-forward не решит проблему.

---

## 5. Proxmox Firewall

Комплект **намеренно не открывает INPUT хоста автоматически**.

Если PVE Firewall включён, создай штатное правило для OpenVPN:

```text
Direction: IN
Action:    ACCEPT
Protocol:  UDP
Dest port: 1194
Source:    при возможности ограничить известными адресами
```

Для доступа VPN-клиентов к самому Proxmox также разреши необходимые host INPUT порты из VPN subnet, например:

```text
source 10.8.0.0/24 -> TCP/8006
source 10.8.0.0/24 -> TCP/22
```

Не публикуй 8006/22 в интернет без необходимости.

Если после reload PVE Firewall перестал работать forwarding, пересобери собственные chains набора:

```bash
systemctl restart pve-openvpn-fw
```

---

## 6. Создание клиента

```bash
sudo ovpn-add-client laptop
```

Если CA защищён паролем, Easy-RSA запросит его для подписи.

Результат:

```text
/root/openvpn-clients/laptop.ovpn
```

Файл содержит:

- CA certificate;
- client certificate;
- client private key;
- уникальный tls-crypt-v2 client key;
- endpoint/port;
- crypto settings.

Поэтому `.ovpn` — **секретный файл**.

Другие примеры:

```bash
sudo ovpn-add-client phone
sudo ovpn-add-client home-pc
```

---

## 7. После передачи профиля клиенту

Если клиент уже безопасно импортировал профиль и ты не хочешь хранить его private key на VPN-сервере:

```bash
sudo ovpn-scrub-client-secret laptop
```

После подтверждения `ERASE` удаляются серверные копии:

```text
pki/private/laptop.key
pki/tls-crypt-v2-clients/laptop.key
/root/openvpn-clients/laptop.ovpn
```

Сертификат **не отзывается**, поэтому импортированный профиль продолжает работать.

После scrub повторно экспортировать тот же профиль уже нельзя. При потере клиентом профиля отзови старую identity и выпусти новую с другим именем.

---

## 8. Список клиентов

```bash
sudo ovpn-list-clients
```

Статусы:

```text
ACTIVE
REVOKED
EXPIRED
```

---

## 9. Отзыв клиента

```bash
sudo ovpn-revoke-client laptop
```

Команда:

1. отзывает certificate через Easy-RSA;
2. генерирует новый CRL;
3. атомарно устанавливает новый CRL серверу;
4. удаляет сохранённый `.ovpn`;
5. удаляет серверную копию client tls-crypt-v2 key.

Если CA защищён, потребуется пароль CA.

Для немедленного разрыва уже установленных VPN-сессий:

```bash
sudo ovpn-revoke-client laptop --disconnect-all
```

Это перезапускает OpenVPN и переподключит всех активных клиентов.

---

## 10. Статус

```bash
sudo ovpn-status
```

Дополнительно:

```bash
systemctl status openvpn-server@server
systemctl status pve-openvpn-fw
journalctl -u openvpn-server@server -f
ip -br addr show tun0
ss -lunp | grep 1194
sysctl net.ipv4.ip_forward
```

---

## 11. Split / Full mode

По умолчанию:

```text
split
```

Через VPN идут только сети из `OVPN_LANS`.

Переключить на full IPv4 tunnel:

```bash
sudo ovpn-set-mode full
```

Вернуть split:

```bash
sudo ovpn-set-mode split
```

Команда пересобирает server config и firewall/NAT rules.

---

## 12. Ручное изменение конфигурации

Runtime settings:

```text
/etc/openvpn/pve-openvpn.conf
```

Файл source-ится root-скриптами, поэтому он должен:

- принадлежать root;
- не быть symlink;
- иметь права `0600` или строже.

После изменения параметров server config:

```bash
sudo ovpn-render-server
sudo systemctl restart openvpn-server@server
```

Если менялись mode, WAN, LAN или VPN subnet:

```bash
sudo systemctl restart pve-openvpn-fw
sudo systemctl restart openvpn-server@server
```

---

## 13. Backup PKI

Нужны как минимум:

```text
/etc/openvpn/easy-rsa/pki/
/etc/openvpn/server/tls-crypt-v2-server.key
/etc/openvpn/pve-openvpn.conf
```

Backup должен быть **зашифрованным** и храниться вне Git.

Особенно критичен:

```text
/etc/openvpn/easy-rsa/pki/private/ca.key
```

Если потерять CA key, ты не сможешь нормально продолжать управление существующей PKI.
Если CA key украден, PKI нужно считать скомпрометированной и разворачивать новую.

---

## 14. Удаление

Остановить интеграцию, сохранив PKI и client profiles:

```bash
sudo ./uninstall.sh
```

Полностью удалить PKI/CA/server/client secrets:

```bash
sudo ./uninstall.sh --purge
```

Нужно вручную ввести:

```text
DELETE
```

Также удалить пакеты:

```bash
sudo ./uninstall.sh --purge --purge-packages
```

---

## 15. Быстрый сценарий

```bash
cd openvpn

sudo ./install.sh \
  --endpoint vpn.example.com \
  --wan vmbr0 \
  --lan 192.168.1.0/24 \
  --lan 10.20.0.0/24

sudo ovpn-add-client laptop
sudo ovpn-add-client phone

sudo ovpn-status
sudo ovpn-list-clients
```

После безопасного импорта профиля:

```bash
sudo ovpn-scrub-client-secret laptop
```

Потерянный клиент:

```bash
sudo ovpn-revoke-client laptop --disconnect-all
```

## Ограничения

- IPv4 only.
- Нет IPv6 tunnel/kill-switch.
- Нет web UI.
- Нет offline-CA workflow в автоматическом установщике.
- Скрипты не управляют правилами PVE Firewall UI/API.
- Для production с повышенными требованиями лучше держать CA offline и подписывать CSR отдельно.
