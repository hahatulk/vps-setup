# Security notes

Этот набор сделан для Proxmox VE 9 / Debian 13 и старается выбирать безопасные defaults, но он не заменяет отдельную модель угроз, firewall policy и backup-процедуры.

## Что защищается

Цель:

- не публиковать Proxmox GUI/SSH напрямую, если доступ можно дать через VPN;
- не хранить реальные PKI secrets в Git;
- не выдавать всем VPN-клиентам больше сетевого доступа, чем задано администратором;
- не допускать молчаливого обхода revocation при пропавшем/просроченном CRL;
- уменьшить последствия компрометации VPN-хоста;
- не перетирать существующую PKI при повторном запуске.

Не является целью:

- защита уже полностью скомпрометированного root;
- автоматический IPv6 full-tunnel;
- управление PVE Firewall policy через API/UI;
- offline CA / HSM workflow;
- защита конечного устройства после импорта client profile.

---

## PKI

Runtime PKI:

```text
/etc/openvpn/easy-rsa/pki/
```

Репозиторий содержит только:

```text
openvpn/pki-example/pki/
```

Это пример дерева без настоящих ключей. Git разрешает внутри него только явно
перечисленные README, `vars.example` и пустые `.gitkeep`; любые другие файлы
игнорируются, включая секреты без стандартного расширения.

Самый чувствительный файл:

```text
/etc/openvpn/easy-rsa/pki/private/ca.key
```

Компрометация CA key означает, что атакующий может выпускать сертификаты, которым доверяет эта PKI. В таком случае недостаточно просто отозвать один клиент: требуется новая CA/PKI и перевыпуск server/client identities.

### CA password

По умолчанию `install.sh` создаёт CA с passphrase.

Менее безопасный unattended-вариант:

```bash
./install.sh ... --ca-nopass
```

Используй его только осознанно.

Пароль CA:

- не сохраняй в repository;
- не передавай параметром командной строки;
- не пиши в shell history;
- храни в password manager/offline secret store.

Для более строгого production-варианта держи CA private key на отдельной/offline системе и передавай только CSR/cert/CRL.

---

## Client private keys

`ovpn-add-client` создаёт client key без passphrase, потому что обычные OpenVPN Connect/daemon сценарии должны подключаться без ручного ввода PEM-passphrase.

Полученный:

```text
/root/openvpn-clients/<client>.ovpn
```

содержит client private key и уникальный tls-crypt-v2 key. Поэтому его нужно считать секретом.

Передавай профиль клиенту только через доверенный канал.

После успешного импорта можно удалить серверные копии client secrets:

```bash
ovpn-scrub-client-secret
```

Это **не revoke**. Уже импортированный профиль продолжит работать.

Для блокировки клиента:

```bash
ovpn-revoke-client
```

После scrub этот же client profile повторно собрать нельзя. Если клиент потерял профиль, отзови старую identity и создай новую с новым CN.

---

## tls-crypt-v2

Вместо одного общего `tls-crypt` key набор использует:

```text
server:
  /etc/openvpn/server/tls-crypt-v2-server.key

clients:
  /etc/openvpn/easy-rsa/pki/tls-crypt-v2-clients/<client>.key
```

Каждый клиент получает отдельный wrapped key.

В UDP-режиме server config по умолчанию использует:

```text
force-cookie
```

Cookie-based stateless handshake относится к UDP и снижает риск replay/state-exhaustion до выделения полноценного состояния соединения. В TCP-режиме этот UDP cookie mode не применяется, но уникальные per-client `tls-crypt-v2` ключи сохраняются.

Для совместимости можно установить сервер с:

```text
--allow-noncookie
```

Используй только если действительно нужен старый клиент.

---

## CRL и fail-closed revocation

OpenVPN сам по себе может продолжить handshake, если CRL-файл, указанный через `crl-verify`, неожиданно отсутствует.

Поэтому набор использует две проверки:

1. systemd `ExecStartPre` не даёт серверу стартовать без CRL;
2. `tls-verify /usr/local/lib/pve-openvpn/verify-crl-health` проверяет на handshake:
   - CRL существует;
   - CRL читается OpenSSL;
   - у CRL есть `nextUpdate`;
   - `nextUpdate` ещё не наступил.

Если проверка не проходит, TLS handshake отклоняется.

Runtime CRL срок выставлен большим, чтобы forgotten maintenance не вызвал внезапный outage, но каждая операция revoke всё равно немедленно генерирует новый CRL.

Проверяй:

```bash
openssl crl -in /etc/openvpn/server/crl.pem -noout -lastupdate -nextupdate
```

---

## PKI concurrency

Операции issuance/revoke/scrub используют:

```text
/run/pve-openvpn/pki.lock
```

и `flock`. Каталог `/run/pve-openvpn/` закрыт правами `0700`; lock-файлы
не размещаются напрямую в потенциально общедоступном `/run/lock/`.

Не запускай Easy-RSA вручную параллельно с этими командами. Если используешь свои automation/scripts для PKI, они должны использовать тот же lock либо работать в отдельной PKI.

---

## Interactive management

Пользовательские команды `ovpn`, `ovpn-add-client`, `ovpn-revoke-client`, `ovpn-scrub-client-secret`, `ovpn-set-mode`, `ovpn-set-proto`, `ovpn-upload-nextcloud` и `ovpn-restart` требуют настоящий TTY и не принимают параметры из CLI. Это снижает риск случайного запуска из pipe/cron и делает чувствительные/опасные действия явными через меню и подтверждения.

Внутренние systemd helpers находятся в `/usr/local/lib/pve-openvpn/` и не являются пользовательскими `ovpn-*` командами.

## Nextcloud WebDAV upload

`ovpn-upload-nextcloud` умеет два режима: public-share DAV и private DAV аккаунта.

Безопасные свойства:

- разрешён только HTTPS;
- TLS verification curl не отключается;
- public token/share password/private app password вводятся скрыто;
- secrets не передаются обычными аргументами `curl` и не должны быть видны через обычный `ps`;
- чувствительные URL/auth данные живут только во временных `0600` curl-config файлах в `/run/pve-openvpn/`;
- последние успешные настройки сохраняются в `/etc/openvpn/pve-nextcloud-upload.conf` с `root:root 0600`;
- временные файлы удаляются через trap;
- remote path не принимает `.`/`..` и URL-encode’ится по UTF-8 bytes;
- HTTP success проверяется явно;
- при выборе key/profile форматов показывается дополнительное предупреждение.

Public DAV использует `/public.php/dav/files/SHARE_TOKEN/...`. Для password-protected share применяется Basic Auth с username `anonymous`; для `PUT`/`MKCOL` отправляется `X-Requested-With: XMLHttpRequest`.

Private DAV использует `/remote.php/dav/files/USERNAME/...` и Basic Auth `USERNAME + app password/token`. Основной пароль аккаунта использовать не рекомендуется; app password можно отдельно отозвать без смены основного пароля.

Важно: `/etc/openvpn/pve-nextcloud-upload.conf` содержит credentials в base64-представлении. Base64 **не является шифрованием**; защита этого файла основана на root-only permissions. Компрометация root означает компрометацию сохранённого Nextcloud token/app-password.

Public-share token фактически даёт права, настроенные владельцем share. Утёкший public token или private app password нужно считать скомпрометированным и заменить/отозвать в Nextcloud.

Никогда не загружай CA private key или client profile в public share, если модель доступа к этому share не соответствует чувствительности файла.

---

## Permissions

Установщик использует `umask 077`.

Ожидаемые права:

```text
/etc/openvpn/pve-openvpn.conf                root:root 0600
/etc/openvpn/server/server.key               root:root 0600
/etc/openvpn/server/tls-crypt-v2-server.key  root:root 0600
/etc/openvpn/easy-rsa/pki/private/           0700
/root/openvpn-clients/                       0700
/root/openvpn-clients/*.ovpn                 0600
```

Проверка:

```bash
ovpn-status
stat /etc/openvpn/pve-openvpn.conf
find /etc/openvpn/easy-rsa/pki/private -maxdepth 1 -type f -ls
```

Важно: `/etc/openvpn/pve-openvpn.conf` source-ится root-командами. Поэтому helper отказывается читать его, если файл:

- symlink;
- не принадлежит UID 0;
- доступен group/other.

Это защищает от превращения конфигурации в root command injection через ослабленные permissions.

---

## Git safety

`openvpn/.gitignore` блокирует:

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

Но `.gitignore` — не security boundary.

Если секрет уже был закоммичен, добавление его в `.gitignore` **не удаляет его из Git history**. Такой secret нужно считать скомпрометированным, ротировать и отдельно очищать историю при необходимости.

Перед commit:

```bash
git status --short
git diff --cached --name-only
```

Никогда не используй `git add -f` для PKI/private artifacts.

---

## Server-side push routes

`ovpn-routes` управляет только CIDR-маршрутами из `OVPN_LANS`. Произвольные строки `push` не принимаются: это специально ограничивает возможность через меню внедрить небезопасные OpenVPN directives.

При добавлении сети одновременно обновляются server-side `push "route ..."`, разрешённый `FORWARD` и MASQUERADE/NAT. При удалении эти три элемента убираются вместе. Изменение выполняется под config lock с backup и rollback при ошибке render/firewall/OpenVPN restart.

Запрещаются:

- `0.0.0.0/0` — для default route используется контролируемый full mode;
- сети, пересекающиеся с VPN pool;
- дублирующиеся или перекрывающиеся `OVPN_LANS`.

`ovpn-routes` не открывает `INPUT` к самому Proxmox. Доступ к `10.0.209.11:8006`, SSH и другим host services должен разрешаться отдельными правилами PVE Firewall только для нужных VPN sources.

---

## Network isolation

Split mode разрешает VPN forwarding только к сетям, перечисленным через:

```text
--lan CIDR
```

Пример:

```bash
./install.sh \
  --endpoint vpn.example.com \
  --lan 192.168.1.0/24 \
  --lan 10.20.0.0/24
```

VPN pool проверяется на overlap с:

- каждым `--lan`;
- существующими IPv4 routes на хосте.

Это снижает риск неожиданного routing conflict.

### NAT

В split mode MASQUERADE применяется только при обращении VPN clients к явно разрешённым LAN.

В full mode дополнительный forwarding/NAT разрешается через выбранный WAN.

Набор использует отдельные chains:

```text
PVE-OVPN-IN-GUARD
PVE-OVPN-GUARD
PVE-OVPN-ALLOW
PVE-OVPN-NAT
```

`PVE-OVPN-IN-GUARD` подключается в начале `INPUT` и выполняет только anti-spoof проверку: source из VPN pool допускается к дальнейшей policy только через `tun`, а пакет из `tun` не может использовать source вне VPN pool. Этот chain **не открывает** GUI/SSH или другие host-порты.

`PVE-OVPN-GUARD` подключается в начале `FORWARD`: разрешённые направления возвращаются в обычную firewall policy, а любой другой forwarded traffic с VPN source блокируется. `PVE-OVPN-ALLOW` подключается в конце и помогает при обычной `FORWARD DROP` policy, но не может обойти более ранний явный DROP Proxmox Firewall. Набор не очищает чужие firewall tables/chains.

---

## Proxmox Firewall

Набор не создаёт широкое INPUT allow rule.

Порт OpenVPN разрешай штатно в PVE Firewall только для выбранного транспорта: UDP или TCP.

Для доступа к самому Proxmox через VPN также создай INPUT правила только от VPN subnet на нужные порты, например:

```text
10.8.0.0/24 -> TCP/8006
10.8.0.0/24 -> TCP/22
```

Если SSH не нужен через VPN, не открывай его.

Если PVE Firewall перезагрузил ruleset и helper chain исчез:

```bash
systemctl restart pve-openvpn-fw
```

После изменений firewall проверяй доступ через отдельную emergency console/IPMI/iDRAC/iLO/KVM, если она есть.

---

## IPv6

Этот комплект сознательно реализует VPN routing для IPv4.

В режиме:

```bash
ovpn-set-mode
```

IPv4 идёт через VPN, но существующий native IPv6 клиента может продолжить идти напрямую.

Это означает возможный IPv6 bypass/leak.

Для систем, где требуется настоящий full-tunnel:

- либо отдельно настрой IPv6 внутри VPN и firewall;
- либо отключи IPv6 на клиентском uplink на время VPN;
- либо используй отдельную проверенную IPv6 kill-switch policy на клиенте.

Не считай текущий `full` режим dual-stack kill-switch.

---

## DNS

DNS push применяется только в full mode.

Фактическое применение `dhcp-option DNS` зависит от клиента/OS. После подключения проверяй DNS resolver фактически, а не только наличие строки в `.ovpn`.

Если нужна строгая защита от DNS leak, она должна обеспечиваться также клиентской ОС/firewall policy.

---

## Endpoint / NAT / CGNAT

Если сервер за NAT, нужен port-forward выбранного транспорта и порта (UDP или TCP) на Proxmox.

CGNAT у провайдера может делать входящее подключение невозможным. В этом случае понадобится публичный relay/VPS, IPv6-доступ или иной overlay design.

---

## Смена UDP/TCP

`ovpn-set-proto` меняет transport сервера транзакционно и может синхронизировать сохранённые клиентские `.ovpn`.

Для TCP сервер использует `proto tcp-server`, а клиентский профиль — `proto tcp-client`. Для UDP обе стороны используют `proto udp`. Внешний `remote` port клиента может отличаться от внутреннего `OVPN_PORT` из-за NAT/port-forward; `ovpn-set-proto` сохраняет существующий client remote port и не подменяет его внутренним listener port.

Перед изменением проверяется выбранный TCP/UDP listener. Конвертируются только root-owned `.ovpn` без group/other permissions, находящиеся в защищённом client directory и имеющие ожидаемую структуру этого сервера. Изменение `proto` и `remote ... PORT` выполняется через временный файл с mode `0600` и атомарный `mv`.

При ошибке запуска нового server transport набор пытается восстановить старый `/etc/openvpn/pve-openvpn.conf`, server config и сохранённые client profiles. Если rollback сервера не удаётся, OpenVPN останавливается fail-closed.

Важно: toolkit не может автоматически изменить профиль, который уже импортирован на отдельный телефон/ноутбук, и не управляет внешним router/PVE Firewall правилом. После `UDP ↔ TCP` синхронизируй port-forward/firewall и переимпортируй обновлённый профиль на клиенте.

---

## Port conflicts

Установщик проверяет, занят ли выбранный порт **на выбранном транспорте** другим процессом: UDP socket проверяется отдельно от TCP socket. Если соответствующий порт занят не OpenVPN, установка останавливается до изменения конфигурации.

---

## Обновление управляющих скриптов

Повторный запуск `install.sh` на уже установленном `pve-openvpn-kit` работает в update-only режиме. Детектирование основано на root-owned regular files и маркерах набора, а не просто на наличии пакета `openvpn`.

Update-only режим:

- берёт config lock и PKI lock;
- заменяет только `/usr/local/sbin/ovpn*` и `/usr/local/lib/pve-openvpn/*`;
- не запускает `apt`;
- не меняет PKI/CA/server config;
- не меняет firewall/systemd configuration;
- не перезапускает OpenVPN.

Это уменьшает риск неожиданного outage при обычном обновлении toolkit. Чужие файлы в целевых путях не перезаписываются, если они не проходят проверки owner/type/marker.

---

## Re-running installer

Скрипт не должен автоматически перетирать:

- существующий CA;
- существующий server certificate/private key;
- существующую PKI.

Частично созданный CA или server cert/key трактуется как ошибка, требующая ручной проверки.

Никогда не удаляй один файл из пары cert/key с целью “пусть installer пересоздаст” — это может разрушить ожидаемую identity.

---

## Backup

Минимум резервируй:

```text
/etc/openvpn/easy-rsa/pki/
/etc/openvpn/server/tls-crypt-v2-server.key
/etc/openvpn/pve-openvpn.conf
```

Backup должен:

- быть зашифрован;
- иметь отдельный access control;
- не лежать в Git;
- иметь проверяемое восстановление.

Если client secrets были scrub-нуты с сервера, backup, сделанный **до scrub**, всё ещё может содержать эти private keys. Учитывай это при retention/rotation.

---

## Host compromise

Если атакующий получил root на Proxmox, считай скомпрометированными как минимум:

- server private key;
- tls-crypt-v2 server key;
- все client private keys, которые ещё не scrub-нуты;
- CA private key, если он хранится на этом же хосте.

Passphrase CA снижает риск использования украденного `ca.key`, но не делает полностью скомпрометированный работающий хост безопасным.

Для высокой assurance используй offline CA/HSM и отдельный VPN gateway вместо хранения CA на гипервизоре.

---

## Emergency access

Перед изменением Proxmox networking/firewall желательно иметь:

- IPMI/iDRAC/iLO;
- KVM-over-IP;
- console хостера;
- физический доступ.

Ошибка в bridge, route или PVE Firewall может одновременно отрезать GUI, SSH и VPN.

---

## Проверки после установки

```bash
ovpn-status

systemctl is-active openvpn-server@server
systemctl is-active pve-openvpn-fw

sysctl net.ipv4.ip_forward
ip -br addr show tun0

iptables -S PVE-OVPN-IN-GUARD
iptables -S PVE-OVPN-GUARD
iptables -S PVE-OVPN-ALLOW
iptables -t nat -S PVE-OVPN-NAT

openssl verify \
  -CAfile /etc/openvpn/easy-rsa/pki/ca.crt \
  /etc/openvpn/easy-rsa/pki/issued/server.crt

openssl crl \
  -in /etc/openvpn/server/crl.pem \
  -noout -lastupdate -nextupdate
```

С внешнего клиента проверь:

- handshake;
- доступ только к ожидаемым split networks;
- отсутствие доступа к запрещённым сетям;
- Proxmox GUI/SSH согласно PVE Firewall policy;
- DNS behavior;
- IPv4 public address в full mode;
- отдельно IPv6 behavior.

---

## Если секрет случайно попал в Git

Не ограничивайся удалением файла последующим commit.

Действия зависят от секрета:

- client private key -> revoke client cert и выпустить новую identity;
- client tls-crypt-v2 key -> вместе с client identity лучше перевыпустить profile;
- server private key -> перевыпустить server cert/key;
- tls-crypt-v2 server key -> сгенерировать новый server key и новые client transport keys/profiles;
- CA private key -> считать всю PKI скомпрометированной и заменить CA.

После ротации отдельно очисти Git history/remote copies согласно правилам твоего репозитория.
