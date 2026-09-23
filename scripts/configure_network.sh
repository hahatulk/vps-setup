#!/usr/bin/env bash
# Интерактивная постоянная настройка IPv4: Debian / Astra Linux / Ubuntu.
# Запуск: sudo bash scripts/configure_network.sh
# IPv6, Wi-Fi-аутентификация и настройка VLAN/bridge/bond здесь не меняются.
set -Eeuo pipefail
export LC_ALL=C
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
umask 077

fail() { printf 'Ошибка: %s\n' "$*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }
ask() {
    local text=$1 default=${2:-} answer
    printf '%s' "$text" >&2
    [[ -z "$default" ]] || printf ' [%s]' "$default" >&2
    printf ': ' >&2
    IFS= read -r answer || exit 1
    printf '%s' "${answer:-$default}"
}
yes() { [[ $(ask "$1 (yes/нет)" нет) == yes ]]; }
status() {
    printf '\n--- %s ---\n' "$1"
    ip -brief link show dev "$1"
    ip -brief address show dev "$1"
    ip -4 route show dev "$1"
    if has nmcli; then
        nmcli -f GENERAL.STATE,GENERAL.CONNECTION,IP4.DNS device show "$1" 2>/dev/null || true
    fi
    if has resolvectl; then resolvectl status "$1" 2>/dev/null || true; fi
}

main() {
    [[ ${1:-} != --help && ${1:-} != -h ]] || {
        printf 'Запуск: sudo bash %s\nИнтерактивная настройка постоянного статического IPv4, gateway и DNS.\n' "$0"
        return
    }
    [[ $# == 0 ]] || fail 'Неизвестные аргументы; используйте --help.'
    [[ $(uname -s) == Linux ]] || fail 'Скрипт предназначен для Linux.'
    [[ $EUID == 0 ]] || fail 'Запустите скрипт через sudo или от root.'
    [[ -t 0 ]] || fail 'Нужен интерактивный терминал.'
    local cmd
    for cmd in ip python3 flock; do has "$cmd" || fail "Не найдена команда $cmd (установите заранее)."; done
    [[ ! -L /run/configure-network ]] || fail 'Каталог блокировки является symlink.'
    mkdir -p /run/configure-network
    [[ $(stat -c '%u' /run/configure-network) == 0 ]] || fail 'Каталог блокировки должен принадлежать root.'
    chmod 0700 /run/configure-network
    [[ ! -L /run/configure-network/lock ]] || fail 'Lock-файл является symlink.'
    exec 9>/run/configure-network/lock
    flock -n 9 || fail 'Другой экземпляр скрипта уже запущен.'

    local -a interfaces=()
    local path iface n choice
    for path in /sys/class/net/*; do
        iface=${path##*/}
        [[ $iface == lo ]] && continue
        interfaces+=("$iface")
    done
    ((${#interfaces[@]})) || fail 'Сетевые интерфейсы не найдены.'
    printf 'Сетевые интерфейсы (включая отключённые):\n'
    for n in "${!interfaces[@]}"; do
        printf '\n[%d]' "$((n + 1))"
        status "${interfaces[n]}"
    done
    printf '\nТекущий системный DNS:\n'
    if [[ -r /etc/resolv.conf ]]; then cat /etc/resolv.conf; fi
    choice=$(ask 'Номер интерфейса (0 — выход)')
    [[ $choice != 0 ]] || return 0
    [[ $choice =~ ^[0-9]{1,3}$ ]] || fail 'Введите номер из списка.'
    n=$((10#$choice))
    ((n >= 1 && n <= ${#interfaces[@]})) || fail 'Нет такого номера.'
    IFACE=${interfaces[n-1]}
    [[ $IFACE =~ ^[a-zA-Z0-9_.:-]+$ ]] || fail 'Неподдерживаемое имя интерфейса.'
    if [[ -e /sys/class/net/$IFACE/master ]]; then
        fail 'Интерфейс подчинён bridge/bond/VRF. Выберите сам логический интерфейс.'
    fi

    local suggested='' managed='' np_file
    for np_file in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        [[ ! -f $np_file ]] || suggested=netplan
    done
    if has nmcli; then
        managed=$(nmcli -g GENERAL.NM-MANAGED device show "$IFACE" 2>/dev/null || true)
        [[ -n $suggested || $managed != yes ]] || suggested='nm'
    fi
    [[ -n $suggested || ! -f /etc/network/interfaces ]] || suggested=ifupdown
    printf '\nСпособ сохранения: netplan / nm (NetworkManager) / ifupdown.\n'
    printf 'Выберите менеджер, который действительно управляет этим интерфейсом.\n'
    BACKEND=$(ask 'Менеджер сети' "$suggested")
    case $BACKEND in
        netplan) has netplan || fail 'Netplan не установлен.'
            python3 -c 'import yaml' 2>/dev/null || fail 'Для Netplan нужен python3-yaml.'
            netplan try --help >/dev/null 2>&1 || fail 'Эта версия Netplan не поддерживает try.' ;;
        nm) has nmcli || fail 'NetworkManager (nmcli) не установлен.'
            [[ $managed == yes ]] || fail 'NetworkManager не управляет выбранным интерфейсом.' ;;
        ifupdown) has ifup && has ifdown || fail 'ifupdown не установлен.' ;;
        *) fail 'Неизвестный менеджер сети.' ;;
    esac

    local current address mask gateway dns metric normalized
    current=$(ip -o -4 addr show dev "$IFACE" scope global | awk 'NR==1 {print $4}')
    address=$(ask 'IPv4-адрес (без маски)' "${current%/*}")
    mask=$(ask 'Префикс 1–32 или маска, например 255.255.255.0' "${current##*/}")
    gateway=$(ip -4 route show default dev "$IFACE" | awk '/via/ {print $3; exit}')
    gateway=$(ask 'Gateway ("-" — без маршрута по умолчанию)' "${gateway:--}")
    dns=$(ask 'DNS IPv4/IPv6 через пробел ("-" — без DNS)' '1.1.1.1 8.8.8.8')
    metric=$(ask 'Метрика default route (меньше — выше приоритет)' 100)
    # Строгая валидация до изменения системы; netmask преобразуется в prefix.
    normalized=$(python3 - "$address" "$mask" "$gateway" "$dns" "$metric" <<'PY'
import ipaddress, sys
try:
    address, mask, gateway, dns, metric = sys.argv[1:]
    host = ipaddress.IPv4Interface(address + '/' + mask)
    if host.network.prefixlen == 0:
        raise ValueError('префикс /0 не поддерживается')
    if host.ip.is_unspecified or host.ip.is_multicast or host.ip.is_loopback:
        raise ValueError('недопустимый адрес интерфейса')
    if host.network.prefixlen < 31 and host.ip in (host.network.network_address, host.network.broadcast_address):
        raise ValueError('указан адрес сети или broadcast')
    if gateway != '-':
        gw = ipaddress.IPv4Address(gateway)
        if gw == host.ip or gw.is_unspecified or gw.is_multicast or gw.is_loopback:
            raise ValueError('недопустимый gateway')
        if gw not in host.network:
            raise ValueError('gateway должен находиться в выбранной подсети; on-link маршруты не поддерживаются')
        if host.network.prefixlen < 31 and gw in (host.network.network_address, host.network.broadcast_address):
            raise ValueError('gateway не может быть адресом сети/broadcast')
    if dns != '-':
        if not dns.split():
            raise ValueError('укажите DNS или "-"')
        for value in dns.split():
            server = ipaddress.ip_address(value)
            if server.is_unspecified or server.is_multicast or '%' in value:
                raise ValueError('недопустимый DNS')
    if not metric.isascii() or not metric.isdigit() or not 0 <= int(metric) <= 4294967295:
        raise ValueError('метрика должна быть числом 0–4294967295')
    print(host)
except ValueError as exc:
    sys.exit('Ошибка параметров: ' + str(exc))
PY
    ) || fail 'Проверьте параметры сети.'
    CIDR=$normalized GATEWAY=$gateway DNS=$dns METRIC=$metric
    export IFACE BACKEND CIDR GATEWAY DNS METRIC

    printf '\nИнтерфейс: %s\nМенеджер: %s\nIPv4: %s\nGateway: %s\nDNS: %s\nМетрика: %s\n' \
        "$IFACE" "$BACKEND" "$CIDR" "$GATEWAY" "$DNS" "$METRIC"
    printf '\nБудут заменены статические IPv4-адреса и IPv4 default route выбранного профиля.\n'
    printf 'Другие интерфейсы не редактируются; меньшая метрика может изменить общий выход в сеть.\n'
    printf 'ВНИМАНИЕ: соединение SSH может оборваться. Рекомендуется локальная/IPMI-консоль.\n'
    [[ $BACKEND != netplan ]] || printf 'Netplan применяет конфигурацию всей сети, включая другие интерфейсы.\n'
    [[ $BACKEND != ifupdown ]] || printf 'ifupdown: все текущие глобальные IPv4-адреса адаптера будут сброшены.\nБез resolvconf DNS будет записан в обычный /etc/resolv.conf (глобально).\n'
    yes 'Сохранить и применить' || return 0

    BACKUP=$(mktemp -d /var/backups/configure-network.XXXXXXXX)
    export BACKUP
    printf 'Резервная копия: %s\n' "$BACKUP"
    trap 'printf "Ошибка. Резервная копия: %s. Восстановите её с локальной консоли; автоматический откат не гарантируется.\n" "$BACKUP" >&2' ERR
    case $BACKEND in
        nm) configure_nm ;;
        netplan|ifupdown) configure_files ;;
    esac
    printf '\nИтоговое состояние:\n'
    status "$IFACE"
    printf '\nГотово. Проверка: ip route; getent hosts debian.org\n'
    printf 'Доступность Интернета не гарантируется: проверьте шлюз и настройки вышестоящей сети.\n'
}

configure_nm() {
    local uuid backup_uuid connection dns4='' dns6='' server
    uuid=$(nmcli -g GENERAL.CON-UUID device show "$IFACE")
    if [[ -n $uuid && $uuid != -- ]] &&
        [[ $(nmcli -g ipv4.routes connection show uuid "$uuid") == *0.0.0.0/0* ]]; then
        fail 'В профиле NM есть явный default route в ipv4.routes; сначала удалите его вручную.'
    fi
    if [[ -z $uuid || $uuid == -- ]]; then
        [[ $(nmcli -g GENERAL.TYPE device show "$IFACE") == ethernet ]] ||
            fail 'Для Wi-Fi/виртуального устройства сначала создайте профиль подключения.'
        connection="static-${IFACE}-$(date +%Y%m%d-%H%M%S)"
        nmcli connection add type ethernet ifname "$IFACE" con-name "$connection" \
            connection.autoconnect no ipv4.method manual ipv4.addresses "$CIDR"
        uuid=$(nmcli -g connection.uuid connection show "$connection")
        printf 'Для отката: nmcli connection delete uuid %q\n' "$uuid" > "$BACKUP/RESTORE.txt"
    else
        nmcli connection show uuid "$uuid" > "$BACKUP/nm-profile.txt"
        connection="backup-${IFACE}-$(date +%Y%m%d-%H%M%S)"
        nmcli connection clone uuid "$uuid" "$connection"
        backup_uuid=$(nmcli -g connection.uuid connection show "$connection")
        nmcli connection modify uuid "$backup_uuid" connection.autoconnect no
        {
            printf 'Для отката отключите изменённый профиль: nmcli connection modify uuid %q connection.autoconnect no\n' "$uuid"
            printf 'Восстановите autoconnect резервного профиля при необходимости, затем: nmcli connection up uuid %q ifname %q\n' "$backup_uuid" "$IFACE"
        } > "$BACKUP/RESTORE.txt"
        printf 'Резервный профиль NM: %s (autoconnect=no)\n' "$backup_uuid"
    fi
    if [[ $DNS != - ]]; then
        for server in $DNS; do
            if [[ $server == *:* ]]; then dns6+="$server "; else dns4+="$server "; fi
        done
    fi
    # Не меняем метод IPv6, но явно задаём пользовательский DNS для обоих семейств.
    nmcli connection modify uuid "$uuid" \
        connection.autoconnect yes ipv4.method manual ipv4.addresses "$CIDR" \
        ipv4.gateway "${GATEWAY/-/}" ipv4.route-metric "$METRIC" \
        ipv4.never-default "$([[ $GATEWAY == - ]] && echo yes || echo no)" \
        ipv4.ignore-auto-dns yes ipv4.dns "$dns4" ipv6.ignore-auto-dns yes ipv6.dns "$dns6"
    nmcli connection up uuid "$uuid" ifname "$IFACE"
}

configure_files() {
    # Подготовка всех изменений в памяти; отказ от неоднозначных конфигураций.
    python3 - <<'PY'
import copy, glob, json, os, pathlib, re, shutil, sys, tempfile
iface, backend, cidr, gateway, dns, metric, backup = (
    os.environ[k] for k in ('IFACE', 'BACKEND', 'CIDR', 'GATEWAY', 'DNS', 'METRIC', 'BACKUP'))
changes = {}

def abort(message):
    sys.exit('Ошибка: ' + message)

if backend == 'netplan':
    import fnmatch, yaml
    # /run и /lib имеют собственный порядок приоритета: не угадываем итог merge.
    if glob.glob('/run/netplan/*.yaml') or glob.glob('/lib/netplan/*.yaml'):
        abort('найдены Netplan-конфиги в /run или /lib; сначала устраните неоднозначность вручную')
    if glob.glob('/etc/netplan/*.yml'):
        abort('Netplan использует расширение .yaml; сначала проверьте/переименуйте .yml файлы')
    files = sorted(glob.glob('/etc/netplan/*.yaml'))
    class UniqueLoader(yaml.SafeLoader):
        pass
    def unique_mapping(loader, node, deep=False):
        result = {}
        for key_node, value_node in node.value:
            key = loader.construct_object(key_node, deep=deep)
            if key in result:
                abort('повторяющийся YAML-ключ: ' + str(key))
            result[key] = loader.construct_object(value_node, deep=deep)
        return result
    UniqueLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, unique_mapping)
    docs, matches = {}, []
    mac = pathlib.Path('/sys/class/net', iface, 'address').read_text().strip().lower()
    for name in files:
        try:
            if os.path.islink(name):
                abort('Netplan-конфиг является symlink: ' + name)
            doc = yaml.load(pathlib.Path(name).read_text(), Loader=UniqueLoader) or {}
            network = doc.get('network', {})
            for section in ('ethernets', 'wifis', 'bridges', 'bonds', 'vlans', 'tunnels', 'dummy-devices', 'vrfs'):
                for key, cfg in (network.get(section) or {}).items():
                    match = cfg.get('match', {})
                    name_match = match.get('name', '')
                    if 'driver' in match:
                        abort('match/driver требует ручного определения менеджером Netplan')
                    selected = key == iface if not match else (
                        bool(name_match or match.get('macaddress'))
                        and (not name_match or fnmatch.fnmatchcase(iface, name_match))
                        and (not match.get('macaddress') or match['macaddress'].lower() == mac))
                    selected |= cfg.get('set-name') == iface
                    if selected:
                        if 'driver' in match or any(c in name_match for c in '*?['):
                            abort('общий match/driver в Netplan: выделите отдельное определение для интерфейса')
                        matches.append((name, section, key))
            docs[name] = doc
        except (AttributeError, TypeError, yaml.YAMLError) as exc:
            abort('не удалось разобрать Netplan: ' + str(exc))
    if not matches:
        if '/devices/virtual/net/' in os.path.realpath('/sys/class/net/' + iface):
            abort('виртуальный интерфейс должен быть явно описан в Netplan')
        if pathlib.Path('/sys/class/net', iface, 'wireless').exists():
            abort('для Wi-Fi сначала создайте Netplan-определение с SSID/аутентификацией')
        for doc in docs.values():
            for entries in doc.get('network', {}).values():
                if isinstance(entries, dict):
                    for entry in entries.values():
                        if isinstance(entry, dict) and 'match' in entry:
                            abort('есть match-определения; сначала явно опишите интерфейс в Netplan')
        name = '/etc/netplan/99-static-' + iface + '.yaml'
        if os.path.exists(name):
            abort('файл уже существует: ' + name)
        docs[name] = {'network': {'version': 2, 'ethernets': {iface: {}}}}
        matches.append((name, 'ethernets', iface))
    if len(matches) != 1:
        abort('найдено несколько определений интерфейса в Netplan')
    name, section, key = matches[0]
    # Одинаковый ID в нескольких файлах может менять результат слияния.
    if sum(key in (d.get('network', {}).get(section) or {}) for d in docs.values()) != 1:
        abort('ID интерфейса определён в нескольких файлах Netplan')
    # Разрываем YAML aliases: изменение eth0 не должно изменить aliased eth1.
    cfg = copy.deepcopy(docs[name]['network'][section][key])
    docs[name]['network'][section][key] = cfg
    if cfg.get('routing-policy') or any(r.get('table', 254) != 254 for r in cfg.get('routes', [])):
        abort('policy routing/нестандартная таблица требуют ручной настройки')
    if any(not isinstance(a, str) for a in cfg.get('addresses', [])):
        abort('расширенный формат addresses в Netplan требует ручной настройки')
    cfg['dhcp4'] = False
    cfg['addresses'] = [a for a in cfg.get('addresses', []) if ':' in a] + [cidr]
    cfg.pop('gateway4', None)
    routes = [r for r in cfg.get('routes', [])
              if not (r.get('to') == '0.0.0.0/0' or
                      (r.get('to') == 'default' and ':' not in str(r.get('via', ''))))]
    if gateway != '-':
        routes.append({'to': '0.0.0.0/0', 'via': gateway, 'metric': int(metric)})
    cfg['routes'] = routes
    cfg.setdefault('nameservers', {})['addresses'] = [] if dns == '-' else dns.split()
    changes[name] = yaml.safe_dump(docs[name], sort_keys=False)
else:
    root = '/etc/network/interfaces'
    docs, visited = {}, set()
    def load(name):
        name = os.path.abspath(name)
        if name in visited:
            return
        visited.add(name)
        if os.path.islink(name):
            abort('interfaces/source является symlink: ' + name)
        if os.path.exists(name) and not os.path.isfile(name):
            abort('interfaces/source не является обычным файлом: ' + name)
        text = pathlib.Path(name).read_text() if os.path.exists(name) else ''
        if re.search(r'\\\s*\n', text):
            abort('продолжение строк в interfaces требует ручной настройки: ' + name)
        docs[name] = text
        for line in text.splitlines():
            tokens = line.split('#', 1)[0].split()
            if not tokens or tokens[0] not in ('source', 'source-directory'):
                continue
            for pattern in tokens[1:]:
                if not os.path.isabs(pattern):
                    pattern = os.path.join(os.path.dirname(name), pattern)
                for child in sorted(glob.glob(pattern)):
                    if tokens[0] == 'source-directory':
                        if not os.path.isdir(child):
                            abort('source-directory не является каталогом: ' + child)
                        for entry in sorted(pathlib.Path(child).iterdir()):
                            if re.fullmatch(r'[a-zA-Z0-9_-]+', entry.name) and entry.is_file():
                                load(str(entry))
                    else:
                        load(child)
    load(root)
    found = []
    top = re.compile(r'^\s*(?:iface|auto|allow-\S+|mapping|source|source-directory)\s+')
    for name, text in docs.items():
        lines = text.splitlines(keepends=True)
        for i, line in enumerate(lines):
            tokens = line.split('#', 1)[0].split()
            if len(tokens) >= 4 and tokens[:3] == ['iface', iface, 'inet']:
                end = i + 1
                while end < len(lines) and not top.match(lines[end]):
                    end += 1
                # Не удаляем пользовательские hooks, маршруты или Wi-Fi-секреты молча.
                allowed = {'address', 'netmask', 'gateway', 'metric', 'broadcast', 'network',
                           'dns-nameservers', 'dns-search'}
                for option in lines[i+1:end]:
                    words = option.split('#', 1)[0].split()
                    if words and words[0] not in allowed:
                        abort('нестандартные опции ifupdown; настройте вручную: ' + option.strip())
                found.append((name, i, end))
            elif tokens and tokens[0] == 'mapping':
                abort('mapping в ifupdown требует ручной настройки')
    if len(found) > 1:
        abort('несколько IPv4-определений выбранного интерфейса')
    block = f'auto {iface}\niface {iface} inet static\n    address {cidr}\n'
    if gateway != '-':
        block += f'    gateway {gateway}\n    metric {metric}\n'
    if dns != '-':
        block += '    dns-nameservers ' + ' '.join(dns.split()) + '\n'
    if found:
        name, start, end = found[0]
        lines = docs[name].splitlines(keepends=True)
        # Сохраняем поисковые DNS-домены существующего интерфейса.
        block += ''.join(line for line in lines[start+1:end] if line.strip().startswith('dns-search '))
        docs[name] = ''.join(lines[:start]) + block + '\n' + ''.join(lines[end:])
    else:
        docs[root] += '\n' + block
    # Сохраняем остальные интерфейсы в общих auto/allow-hotplug строках.
    for name, text in docs.items():
        lines = []
        for line in text.splitlines(keepends=True):
            tokens = line.split('#', 1)[0].split()
            if tokens and (tokens[0] == 'auto' or tokens[0].startswith('allow-')) and iface in tokens[1:]:
                rest = [t for t in tokens[1:] if t != iface]
                if rest:
                    lines.append(tokens[0] + ' ' + ' '.join(rest) + '\n')
            else:
                lines.append(line)
        result = ''.join(lines)
        if name == (found[0][0] if found else root):
            result = f'auto {iface}\n' + result
        original = pathlib.Path(name).read_text() if os.path.exists(name) else ''
        if result != original:
            changes[name] = result
    if not (shutil.which('resolvconf') and os.path.exists('/etc/network/if-up.d/000resolvconf')):
        if os.path.islink('/etc/resolv.conf'):
            abort('/etc/resolv.conf управляется другим сервисом; настройте DNS через него или установите resolvconf')
        resolver = pathlib.Path('/etc/resolv.conf')
        previous = resolver.read_text() if resolver.exists() else ''
        preserved = ''.join(line for line in previous.splitlines(keepends=True)
                            if not re.match(r'^\s*nameserver\s', line)
                            and line.strip() != '# Static DNS: configure_network.sh')
        changes['/etc/resolv.conf'] = preserved.rstrip() + '\n# Static DNS: configure_network.sh\n' + ''.join(
            f'nameserver {server}\n' for server in ([] if dns == '-' else dns.split()))

# Проверяем все пути до первой записи. Бэкап включает список новых файлов для удаления.
for name in changes:
    if os.path.islink(name):
        abort('нельзя перезаписать symlink: ' + name)
    if os.path.exists(name) and not os.path.isfile(name):
        abort('нельзя перезаписать не-обычный файл: ' + name)
    for parent in pathlib.Path(name).parents:
        if parent.is_symlink():
            abort('родительский каталог является symlink: ' + str(parent))
restore = []
manifest = {}
for name in changes:
    manifest[name] = os.path.exists(name)
    target = pathlib.Path(backup + name)
    target.parent.mkdir(parents=True, exist_ok=True)
    if os.path.exists(name):
        shutil.copy2(name, target)
        restore.append('Восстановить ' + str(target) + ' -> ' + name)
    else:
        restore.append('Удалить созданный файл ' + name)
pathlib.Path(backup, 'files.json').write_text(json.dumps(manifest))
pathlib.Path(backup, 'RESTORE.txt').write_text('\n'.join(restore) +
    '\nПосле восстановления: netplan apply либо ifdown/ifup выбранного интерфейса.\n')
# Атомарная замена каждого файла; при ошибке записи возвращаем уже изменённые.
written = []
try:
    for name, text in changes.items():
        path = pathlib.Path(name)
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, pending = tempfile.mkstemp(prefix='.configure-network-', dir=str(path.parent))
        try:
            with os.fdopen(fd, 'w') as stream:
                stream.write(text)
                stream.flush()
                os.fsync(stream.fileno())
            if path.exists():
                shutil.copystat(path, pending)
                old = path.stat()
                if os.geteuid() == 0:
                    os.chown(pending, old.st_uid, old.st_gid)
            if backend == 'netplan':
                os.chmod(pending, 0o600)
            elif name == '/etc/resolv.conf':
                os.chmod(pending, 0o644)
            os.replace(pending, name)
            written.append(name)
        finally:
            if os.path.exists(pending):
                os.unlink(pending)
except OSError:
    for name in reversed(written):
        if manifest[name]:
            shutil.copy2(backup + name, name)
        else:
            os.unlink(name)
    raise
PY
    if [[ $BACKEND == netplan ]]; then
        if ! netplan generate; then
            restore_files
            fail 'Netplan отклонил конфигурацию. Исходные файлы восстановлены.'
        fi
        printf 'Подтвердите работоспособность в netplan try (120 секунд).\n'
        printf 'При отмене/таймауте обязательно проверьте фактический откат сети.\n'
        if ! netplan try --timeout 120; then
            restore_files
            netplan generate || true
            fail 'Netplan try не подтверждён/завершился с ошибкой. Файлы восстановлены; проверьте сеть с консоли.'
        fi
    else
        ifdown --force "$IFACE" || printf 'ifdown завершился с ошибкой; пробуем поднять интерфейс заново.\n' >&2
        ip -4 address flush dev "$IFACE" scope global
        ip -4 route flush default dev "$IFACE"
        ifup "$IFACE"
    fi
}

restore_files() {
    python3 - "$BACKUP" <<'PY'
import json, pathlib, shutil, sys
backup = pathlib.Path(sys.argv[1])
for name, existed in json.loads((backup / 'files.json').read_text()).items():
    if existed:
        shutil.copy2(str(backup) + name, name)
    elif pathlib.Path(name).exists():
        pathlib.Path(name).unlink()
PY
}

# Можно source-ить для проверки функций без запуска мастера.
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
