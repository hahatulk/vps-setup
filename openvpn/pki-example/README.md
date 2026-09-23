# PKI example

Эта директория показывает **только структуру** Easy-RSA PKI, которую создаёт установщик на Proxmox.

Реальная PKI хранится не в Git-репозитории, а здесь:

```text
/etc/openvpn/easy-rsa/pki/
```

Пример:

```text
pki/
├── ca.crt                    # public CA certificate
├── index.txt                 # база выданных/отозванных сертификатов
├── serial                    # serial state
├── crl.pem                   # certificate revocation list
├── vars                      # Easy-RSA policy/settings
├── private/
│   ├── ca.key                # СЕКРЕТ: private key CA
│   ├── server.key            # СЕКРЕТ
│   └── <client>.key          # СЕКРЕТ
├── issued/
│   ├── server.crt
│   └── <client>.crt
├── reqs/
├── certs_by_serial/
├── tls-crypt-v2-clients/
│   └── <client>.key          # СЕКРЕТ: уникальный transport key клиента
└── secret-scrubbed/
    └── <client>              # marker: server-side client secrets намеренно удалены
```

В этом репозитории намеренно **нет** настоящих ключей, сертификатов, serial/index или CRL.

Никогда не копируй сюда рабочий `/etc/openvpn/easy-rsa/pki` целиком для коммита.
Если нужен backup PKI — храни его отдельно, в зашифрованном backup/storage с ограниченным доступом.

Самые чувствительные файлы:

```text
private/ca.key
private/*.key
tls-crypt-v2-clients/*.key
/root/openvpn-clients/*.ovpn
```

Компрометация `ca.key` особенно критична: злоумышленник сможет выпускать доверенные сертификаты.
