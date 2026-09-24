# OpenVPN for Proxmox VE 9 / Debian 13

Интерактивный набор Bash-скриптов для установки и обслуживания OpenVPN на Proxmox VE 9.x / Debian 13.

Главный принцип интерфейса: **обычному администратору не нужно запоминать аргументы команд**.

После установки достаточно запускать:

```bash
sudo ovpn
```

и выбирать действия из меню.

## Структура

```text
openvpn/
├── .gitignore
├── README.md
├── SECURITY.md
├── install.sh
├── uninstall.sh
├── bin/
│   ├── ovpn
│   ├── ovpn-add-client
│   ├── ovpn-list-clients
│   ├── ovpn-restart
│   ├── ovpn-revoke-client
│   ├── ovpn-routes
│   ├── ovpn-scrub-client-secret
│   ├── ovpn-set-mode
│   ├── ovpn-set-proto
│   ├── ovpn-upload-nextcloud
│   └── ovpn-status
├── lib/
│   ├── common.sh
│   ├── verify-crl-health
│   ├── pve-openvpn-fw
│   └── pve-openvpn-render-server
├── tests/
│   └── selftest.sh
└── pki-example/
    ├── README.md
    └── pki/
        ├── README.md
        ├── vars.example
        ├── private/
        ├── issued/
        ├── reqs/
        ├── certs_by_serial/
        ├── revoked/
        ├── inline/
        ├── tls-crypt-v2-clients/
        └── secret-scrubbed/
```

`pki-example/pki/` — **только безопасный пример структуры**. Там не должно быть настоящих сертификатов, ключей, CRL или Easy-RSA database.

Реальная PKI на Proxmox создаётся в:

```text
/etc/openvpn/easy-rsa/pki/
```

---

## 1. Установка

На Proxmox:

```bash
cd /path/to/vps-setup/openvpn
chmod +x install.sh uninstall.sh bin/* lib/pve-openvpn-* lib/verify-crl-health
sudo ./install.sh
```

### Повторный запуск / обновление скриптов

Если OpenVPN уже установлен **этим набором** и найдены защищённые маркеры `pve-openvpn-kit`, повторный:

```bash
sudo ./install.sh
```

работает как быстрый updater. Он **не запускает мастер установки** и не выполняет повторную настройку сервера.

Обновляются только:

```text
/usr/local/sbin/ovpn*
/usr/local/lib/pve-openvpn/*
```

При этом updater не делает:

```text
apt update / apt install
пересоздание CA/PKI
перевыпуск сертификатов
изменение server.conf
изменение текущего UDP/TCP/порта
изменение firewall rules
изменение systemd units
restart OpenVPN
```

Перед заменой helpers берутся config/PKI locks, чтобы не обновлять файлы посреди операции add/revoke/switch. Если это старая установка и в системе нет `curl`, updater только предупредит об этом и всё равно не будет запускать `apt`; для `ovpn-upload-nextcloud` тогда установи `curl` вручную.

Обычный мастер ниже запускается только для новой установки. Чужой или вручную настроенный OpenVPN не считается нашей установкой только по наличию пакета: installer не перезаписывает его конфигурацию молча. Если пакет `openvpn` уже установлен, но это первая установка toolkit, `apt` поставит только реально недостающие зависимости и не будет повторно устанавливать уже имеющиеся пакеты.

Без аргументов на новой системе установщик запускает мастер и последовательно спрашивает:

1. публичный IPv4 или DNS VPN-сервера;
2. транспорт OpenVPN: UDP или TCP;
3. порт OpenVPN;
4. WAN/bridge интерфейс, обычно `vmbr0`;
5. VPN subnet;
6. лимит клиентов;
7. split/full режим;
8. LAN/VM сети;
9. DNS для full-tunnel;
10. совместимость tls-crypt-v2 cookie handshake в UDP-режиме;
11. нужно ли защищать CA passphrase;
12. финальное подтверждение перед изменением системы.

Пример вопросов:

```text
Публичный IPv4 или DNS-имя VPN: vpn.example.com

Транспорт OpenVPN:
  1) UDP — рекомендуется
  2) TCP — если UDP блокируется
Выбор [1]: 1

UDP-порт OpenVPN [1194]:
WAN/bridge интерфейс [vmbr0]:
VPN IPv4 subnet [10.8.0.0/24]:
Максимум одновременных клиентов [64]:

Режим:
  1) split
  2) full
Выбор [1]: 1

LAN CIDR: 192.168.1.0/24
LAN CIDR: 10.20.0.0/24
LAN CIDR:
```

Установщик показывает итоговую конфигурацию и **ничего не меняет**, пока ты её не подтвердил.

### CA

Рекомендуемый вариант — CA private key с passphrase.

Пароль:

- не передаётся аргументом shell;
- не сохраняется в Git;
- не должен храниться рядом с PKI;
- лучше хранить в password manager/offline secret store.

Если сознательно выбрать CA без пароля, мастер потребует дополнительное слово `NOPASS`.

---

## 2. Главное меню

После установки:

```bash
sudo ovpn
```

Меню:

```text
1) Статус сервера
2) Список клиентов
3) Добавить клиента
4) Отозвать клиента
5) Удалить серверные копии client secrets
6) Переключить split/full tunnel
7) TCP/UDP сервера + конвертация .ovpn
8) Перезапустить OpenVPN
9) Отправить файл в Nextcloud
10) Показать последние логи OpenVPN
11) Управление server push routes
0) Выход
```

Команда `ovpn` не принимает произвольные команды/аргументы и запускает только фиксированные управляющие скрипты.

---

## 3. Отдельные команды

Все пользовательские `ovpn-*` команды запускаются **без параметров**.

### Добавить клиента

```bash
sudo ovpn-add-client
```

Скрипт сам спросит имя:

```text
Имя нового клиента (например laptop или phone):
```

При создании клиента мастер дополнительно спрашивает **внешний входящий порт**, который видит клиент. По умолчанию предлагается текущий `OVPN_PORT`, но его можно изменить, если на роутере/NAT используется другой внешний порт.

Например сервер слушает внутри:

```text
UDP/1194
```

а роутер пробрасывает:

```text
UDP/443 -> Proxmox:1194
```

тогда при создании клиента укажи `443`. В `.ovpn` получится:

```text
remote vpn.example.com 443
```

Это **не меняет порт самого OpenVPN-сервера**.

После выпуска получится:

```text
/root/openvpn-clients/<client>.ovpn
```

Файл содержит client private key и уникальный tls-crypt-v2 transport key, поэтому его нужно считать секретом. Транспорт подставляется автоматически из серверной конфигурации: для UDP профиль получает `proto udp`, для TCP — `proto tcp-client`; вручную менять client transport не нужно.

### Список клиентов

```bash
sudo ovpn-list-clients
```

После запуска скрипт сначала предложит фильтр: все / ACTIVE / REVOKED / EXPIRED. Никаких аргументов вводить не нужно.

### Отозвать клиента

```bash
sudo ovpn-revoke-client
```

Скрипт:

1. показывает список подходящих клиентов;
2. предлагает выбрать клиента номером;
3. требует ввести `REVOKE`;
4. спрашивает, нужно ли сразу разорвать все текущие VPN-сессии;
5. отзывает сертификат;
6. генерирует и проверяет новый CRL;
7. удаляет локальный client profile/transport key.

Имя отозванного клиента повторно не используется.

### Удалить серверные копии client secrets

```bash
sudo ovpn-scrub-client-secret
```

Скрипт покажет клиентов и потребует `ERASE`.

Удаляются серверные копии:

```text
pki/private/<client>.key
pki/tls-crypt-v2-clients/<client>.key
/root/openvpn-clients/<client>.ovpn
```

Это **не revoke**. Уже импортированный клиент продолжит работать.

После scrub повторно экспортировать тот же профиль нельзя.

### Добавить/удалить server-side push routes

```bash
sudo ovpn-routes
```

Или пункт `11` в `sudo ovpn`.

Команда показывает текущий список сетей и предлагает:

```text
1) Добавить push route
2) Удалить push route
0) Назад
```

Маршрут вводится в CIDR, например:

```text
10.0.209.0/24
```

В server config он автоматически превращается в:

```text
push "route 10.0.209.0 255.255.255.0"
```

Список хранится в `OVPN_LANS` внутри `/etc/openvpn/pve-openvpn.conf`. Поэтому добавление/удаление синхронно меняет три вещи:

```text
OpenVPN push route
FORWARD rules для VPN -> выбранная сеть
MASQUERADE/NAT для VPN -> выбранная сеть
```

Например для твоей сети Proxmox/LAN:

```text
VPN:      10.8.0.0/24
Proxmox:  10.0.209.11
LAN:      10.0.209.0/24
```

добавь:

```text
10.0.209.0/24
```

После применения OpenVPN перезапускается, поэтому клиенты переподключаются и получают новый route.

Удаление работает по номеру из списка и убирает одновременно push/FORWARD/NAT. Изменение делается транзакционно с backup/rollback.

Важно: доступ к **самому Proxmox** `10.0.209.11` проходит через `INPUT`, а не `FORWARD`. `ovpn-routes` не открывает TCP/8006, TCP/22 или другие host-порты автоматически. Если включён PVE Firewall, разрешай их отдельно только от `10.8.0.0/24`.

`0.0.0.0/0` через `ovpn-routes` запрещён; для полного default route используй `ovpn-set-mode -> full`.

### Переключить split/full

```bash
sudo ovpn-set-mode
```

Скрипт покажет текущий режим и предложит:

```text
1) split
2) full
0) Отмена
```

Перед применением будет отдельное подтверждение.

### Переключить UDP/TCP и конвертировать профили

```bash
sudo ovpn-set-proto
```

Команда полностью интерактивная. Она показывает текущий transport/port и предлагает:

```text
1) UDP
2) TCP
3) Только синхронизировать .ovpn с текущим сервером
0) Отмена
```

При переключении можно оставить текущий порт или выбрать новый. Затем можно:

```text
1) синхронизировать все сохранённые .ovpn
2) выбрать один .ovpn
3) изменить только сервер
```

Преобразование делается без перевыпуска сертификата и private key:

```text
UDP server:  proto udp
UDP client:  proto udp

TCP server:  proto tcp-server
TCP client:  proto tcp-client
```

При смене TCP/UDP внутренний порт сервера можно изменить, но существующий `remote ... PORT` в клиентских `.ovpn` **сохраняется**. Это важно для NAT/port-forward, где внешний порт может отличаться от внутреннего. Перед изменением скрипт проверяет формат и права профилей. Серверная конфигурация и выбранные `.ovpn` резервируются во временной root-only директории; при ошибке запуска нового server transport выполняется rollback.

После изменения транспорта проверь внешний NAT/port-forward и PVE Firewall: они должны разрешать **новый transport и port**. Уже импортированные на телефоны/ноутбуки старые профили автоматически не меняются — обновлённый `.ovpn` нужно переимпортировать либо вручную синхронизировать соответствующий клиент.

### Отправить файл в Nextcloud WebDAV

```bash
sudo ovpn-upload-nextcloud
```

Или пункт `9` в `sudo ovpn`.

Сначала выбирается тип доступа:

```text
1) Public share DAV
2) Private DAV
0) Отмена
```

Для **Public share DAV** скрипт спрашивает:

```text
Домен Nextcloud / base URL
Public-share токен
X-NC-Nickname
Пароль public share (опционально)
Локальный файл
Удалённую папку
Имя файла в Nextcloud
```

Используется endpoint:

```text
https://NEXTCLOUD/public.php/dav/files/SHARE_TOKEN/...
```

Для `PUT`/`MKCOL` public share отправляются:

```text
X-Requested-With: XMLHttpRequest
X-NC-Nickname: <выбранный nickname>
```

Если public share защищён паролем, используется Basic Auth `anonymous:<share password>`.

Для **Private DAV** скрипт спрашивает:

```text
Домен Nextcloud / base URL
Логин Nextcloud
App password / token
Локальный файл
Удалённую папку
Имя файла в Nextcloud
```

Используется endpoint:

```text
https://NEXTCLOUD/remote.php/dav/files/USERNAME/...
```

Для private DAV рекомендуется именно **app password**, а не основной пароль аккаунта.

Public token, share password и private app password вводятся скрыто. Credentials и URL с public token не передаются в обычных аргументах `curl`: временные curl-config файлы создаются в `/run/pve-openvpn/` с root-only правами и удаляются через trap.

После **успешной** загрузки последние настройки сохраняются отдельно в:

```text
/etc/openvpn/pve-nextcloud-upload.conf
```

с правами `root:root 0600`. При следующем запуске появляется выбор:

```text
1) Использовать прошлые данные
2) Ввести новые
0) Отмена
```

Сохраняются режим public/private, домен, token/app-password, nickname/user и последняя удалённая папка. Секреты внутри файла base64-кодируются только для безопасного парсинга — **это не шифрование**.

При выборе локального файла сначала показываются файлы из:

```text
/root/openvpn-clients
```

и первый файл предлагается по умолчанию. Также всегда можно выбрать `m` и указать любой другой путь вручную.

Если указана удалённая папка, скрипт может рекурсивно создать отсутствующие уровни через `MKCOL`. `HTTP 405` при `MKCOL` считается нормальным случаем существующей коллекции. Загрузка считается успешной только при `HTTP 200`, `201` или `204`.

HTTPS обязателен. Скрипт не использует `-k` и не отключает TLS verification. Имена пользователя, папок и файлов URL-encode’ятся по сегментам, включая пробелы и UTF-8/кириллицу.

Если загружается `.ovpn`, `.key`, `.pem`, `.p12` и похожий файл, будет отдельное предупреждение: такие файлы могут содержать приватные ключи.

### Перезапустить OpenVPN

```bash
sudo ovpn-restart
```

Перед рестартом есть подтверждение. Рестарт оборвёт текущие VPN-сессии, после чего клиенты смогут переподключиться.

### Статус

```bash
sudo ovpn-status
```

Сначала появляется меню, где можно выбрать: краткий статус, PKI/CRL, systemd, firewall/NAT, активные подключения или полный отчёт. Никаких аргументов вводить не нужно.

---

## 4. Split и full tunnel

### Split

Рекомендуется по умолчанию.

Через VPN идут только сети, которые были добавлены мастером установки.

Например:

```text
192.168.1.0/24
10.20.0.0/24
```

### Full

Весь **IPv4** клиента отправляется через VPN.

Важно: этот комплект сознательно не реализует IPv6 full-tunnel/kill-switch. Если у клиента есть native IPv6, он может идти мимо VPN.

Подробнее: `SECURITY.md`.

---

## 5. Port forward

Если Proxmox находится за роутером, пробрось **тот же транспорт и порт**, которые выбраны в мастере.

Для стандартного UDP-варианта:

```text
Protocol:      UDP
External:      1194
Internal host: IP Proxmox
Internal port: 1194
```

Если в мастере выбран TCP, правило должно быть TCP, например:

```text
Protocol:      TCP
External:      1194
Internal host: IP Proxmox
Internal port: 1194
```

При CGNAT обычный входящий port-forward может быть невозможен.

---

## 6. Proxmox Firewall

Набор **не открывает широкий INPUT автоматически**.

Если PVE Firewall включён, разреши выбранный **TCP или UDP** OpenVPN port штатным правилом PVE — строго тот транспорт, который выбран при установке.

Для доступа через VPN к самому Proxmox отдельно разреши только нужные host ports из VPN subnet, например:

```text
10.8.0.0/24 -> TCP/8006
10.8.0.0/24 -> TCP/22
```

Если SSH через VPN не нужен — TCP/22 не открывай.

Не публикуй GUI `:8006` напрямую в интернет без необходимости.

---

## 7. PKI example

Репозиторий содержит:

```text
openvpn/pki-example/pki/
```

Это дерево предназначено только для понимания структуры.

Настоящая PKI:

```text
/etc/openvpn/easy-rsa/pki/
```

Особенно чувствительные файлы:

```text
private/ca.key
private/*.key
tls-crypt-v2-clients/*.key
/root/openvpn-clients/*.ovpn
```

Никогда не копируй рабочую PKI в repository ради backup.

Backup PKI должен быть:

- зашифрован;
- отдельно защищён ACL;
- не находиться в Git;
- регулярно проверяться на восстановление.

---

## 8. Защита Git

`openvpn/.gitignore` блокирует типовые секреты и runtime PKI state:

```text
pki/
easy-rsa/
runtime/
clients/
openvpn-clients/
*.key
*.ovpn
*.p12
*.pfx
*.pkcs12
*.pem
*.csr
*.req
*.crt
index.txt*
serial*
crlnumber*
crl.pem
```

`.gitignore` не спасает секрет, который уже попал в Git history. Такой ключ нужно считать скомпрометированным и ротировать.

Перед commit:

```bash
git status --short
git diff --cached --name-only
```

---

## 9. Удаление

Запускай без аргументов:

```bash
sudo ./uninstall.sh
```

Меню предложит:

```text
1) удалить сервисы/команды, сохранить PKI и client profiles
2) полностью удалить конфигурацию, PKI и client profiles
3) полностью удалить всё + пакеты OpenVPN/Easy-RSA
0) отмена
```

Для вариантов с удалением PKI потребуется отдельно ввести:

```text
DELETE
```

Это подтверждение происходит **до начала изменений системы**.

---

## 10. Проверка после установки

Через меню выбери статус или запусти:

```bash
sudo ovpn-status
```

Дополнительно:

```bash
systemctl is-active openvpn-server@server
systemctl is-active pve-openvpn-fw

sysctl net.ipv4.ip_forward
ip -br addr show tun0

iptables -S PVE-OVPN-GUARD
iptables -S PVE-OVPN-ALLOW
iptables -t nat -S PVE-OVPN-NAT

openssl crl \
  -in /etc/openvpn/server/crl.pem \
  -noout -lastupdate -nextupdate
```

С внешнего клиента проверь:

- VPN handshake;
- доступ только к ожидаемым LAN в split mode;
- отсутствие доступа к запрещённым сетям;
- GUI/SSH согласно PVE Firewall policy;
- DNS;
- публичный IPv4 в full mode;
- отдельно поведение IPv6.

---

## 11. Внутренние helpers

Эти файлы **не являются пользовательскими `ovpn` командами**:

```text
/usr/local/lib/pve-openvpn/pve-openvpn-fw
/usr/local/lib/pve-openvpn/pve-openvpn-render-server
```

Их вызывает systemd и управляющие скрипты.

Они принимают технические параметры там, где это необходимо для systemd, но вручную использовать их не требуется.

---

## 12. Автоматизация

Для человека рекомендуемый интерфейс — только интерактивный:

```bash
sudo ./install.sh
sudo ovpn
```

У `install.sh` сохранены CLI flags для CI/provisioning, но это дополнительный режим. Пользовательские `ovpn-*` команды намеренно не принимают параметры, чтобы destructive операции проходили через явный выбор и подтверждение.

---

## 13. Self-test перед commit/deploy

Без изменения systemd/firewall/PKI можно выполнить:

```bash
./tests/selftest.sh
```

Проверяются Bash syntax, базовая CIDR/endpoint-логика, zero-argument policy пользовательских `ovpn*`, отсутствие внутренних helpers в `bin/`, Git ignore-policy для секретов и структура `pki-example/`.

Подробная модель безопасности и ограничения: [SECURITY.md](SECURITY.md).
