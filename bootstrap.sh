#!/usr/bin/env bash
# Первичная подготовка планшета на чистой Ubuntu Server 24.04 (ADR-0053).
#
# Делает ровно то, без чего Ansible не дотянется до планшета, и так, как это
# сделано руками на CF-20 и CF-33 (снято с обоих 2026-10-08): пользователи, вход
# по SSH, сеть по Ethernet, имя хоста. Всё остальное — роли ansible/site.yml с
# рабочей станции (инвариант №9): пакеты, конфиг, юниты, часовой пояс.
#
# Лежит в ansible/, а не в tools/: этот файл едет на планшет (инвариант №10).
# Самодостаточный — ключ рабочей станции вписан ниже, сеть нужна только если
# при установке не отметили OpenSSH. Запуск — на самом планшете, под root:
#
#   sudo bash bootstrap.sh
#
# Доставить — любым путём:
#   scp ansible/bootstrap.sh <пользователь установщика>@<адрес>:   с рабочей станции
#   флешка
#   curl -fsSLO <ссылка на файл>                                     когда будет откуда
#
# Повторный запуск безопасен: что уже как надо, не трогается. Прежние версии
# изменённых файлов — в /root/bootstrap-backup-<время>/.
#
# Что делает, по порядку:
#   1. openssh-server — если при установке его не отметили;
#   2. cloud-init выключается: иначе на загрузке он перепишет сеть и sshd;
#   3. root — пароль (спросит, если не задан) и ключ рабочей станции;
#   4. kiosk — создаётся, если его нет; ключ; sudo снимается;
#   5. sshd — root по паролю и по ключу (10-kiosk.conf, как на CF-20);
#   6. имя хоста;
#   7. netplan — Ethernet по DHCP, любой en* (01-kiosk.yaml, как на CF-20).
# Сеть — последней: если адрес сменится, сессия SSH оборвётся, а всё прочее уже
# сделано.
#
# Ключи:
#   --hostname ИМЯ     имя хоста; умолчание kiosk — как у CF-20 и CF-33
#   --key 'ssh-… …'    ещё один открытый ключ для root и kiosk; можно несколько раз
#   --passwords        спросить пароли root и kiosk, даже если они уже заданы
#   --no-network       сеть не трогать
#
# Без терминала пароли берутся из окружения, хешем crypt (openssl passwd -6):
# ROOT_PASSWORD_HASH, KIOSK_PASSWORD_HASH. Открытым текстом — никогда. sudo
# окружение чистит, поэтому так:
#   sudo ROOT_PASSWORD_HASH='$6$…' bash bootstrap.sh
set -euo pipefail

# PATH — свой, а не унаследованный: useradd, chpasswd, visudo, sshd и netplan
# лежат в /usr/sbin, а под su без «-» и из чужого окружения его может не быть.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

# Ключи, которые пускают на планшет root и kiosk. Тело ключа — то, что стоит на
# CF-20 и CF-33 (SHA256:2PPbnwJHIuFwcdJpNLwIUho7xyUWMaNOs1W3crBjAE4): им ходят
# Ansible (ansible_user: root), tools/deploy*.sh и отладчик студии.
KEYS=(
    'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIGFVGhWxTmf1H7ymvidClwHwmTMZur1OUFLdG+aAWdKV tauruna@wsl → kiosk CF-33'
)

NAME_HOST=kiosk
ASK_PASSWORDS=0
DO_NETWORK=1

say()  { printf '\n== %s\n' "$*"; }
note() { printf '   %s\n' "$*"; }
die()  { printf '\nОШИБКА: %s\n' "$*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case "$1" in
        --hostname)   NAME_HOST="${2:?--hostname требует имя}"; shift ;;
        --key)        KEYS+=("${2:?--key требует открытый ключ одной строкой}"); shift ;;
        --passwords)  ASK_PASSWORDS=1 ;;
        --no-network) DO_NETWORK=0 ;;
        -h|--help)    sed -n '2,/^set -euo/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        *)            die "неизвестный ключ: $1 (--help)" ;;
    esac
    shift
done

[ "$(id -u)" -eq 0 ] || die "нужен root: sudo bash $0"
# Имя хоста: буквы, цифры, дефис; не с дефиса (RFC 1123).
[[ "$NAME_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9-]{0,62}$ ]] || die "имя хоста не годится: $NAME_HOST"

. /etc/os-release
if [ "${ID:-}" != ubuntu ] || [ "${VERSION_ID:-}" != 24.04 ]; then
    note "ВНИМАНИЕ: планшеты — Ubuntu 24.04, а здесь ${PRETTY_NAME:-неизвестно что}. Продолжаю."
fi

BACKUP=/root/bootstrap-backup-$(date +%Y%m%d-%H%M%S)
backup() { mkdir -p "$BACKUP"; cp -a "$1" "$BACKUP/"; }

# Записать файл, если содержимое другое: put ПУТЬ РЕЖИМ < содержимое.
# Код 0 — записан, 1 — уже такой. Прежний файл — в $BACKUP.
put() {
    local path=$1 mode=$2 tmp
    tmp=$(mktemp)
    cat > "$tmp"
    if [ -f "$path" ] && cmp -s "$tmp" "$path"; then
        rm -f "$tmp"
        return 1
    fi
    if [ -f "$path" ]; then backup "$path"; fi
    install -m "$mode" -o root -g root "$tmp" "$path"
    rm -f "$tmp"
}

# Есть ли управляющий терминал: /dev/tty существует всегда, а открыть его можно
# только с терминалом.
have_tty() { ( : < /dev/tty ) 2>/dev/null; }

# grep без -q: при pipefail ранний выход grep -q дал бы SIGPIPE слева и ложный отказ.
in_group() { id -nG "$1" | tr ' ' '\n' | grep -x "$2" > /dev/null; }

# Статус пароля из passwd -S: P — задан, L — заблокирован, NP — пустой.
pw_status() { passwd -S "$1" | awk '{print $2}'; }

set_password() {  # set_password ПОЛЬЗОВАТЕЛЬ ИМЯ_ПЕРЕМЕННОЙ_С_ХЕШЕМ
    local user=$1 var=$2 hash a b
    hash=${!var:-}
    if [ -n "$hash" ]; then
        printf '%s:%s\n' "$user" "$hash" | chpasswd -e
        note "пароль $user — из $var"
        return
    fi
    have_tty || die "пароль $user нужно задать, а терминала нет: передайте $var (openssl passwd -6)"
    while :; do
        read -rsp "   Пароль для $user: " a < /dev/tty; echo > /dev/tty
        read -rsp "   Ещё раз: " b < /dev/tty; echo > /dev/tty
        if [ -n "$a" ] && [ "$a" = "$b" ]; then break; fi
        echo "   Пусто или не совпало — ещё раз." > /dev/tty
    done
    printf '%s:%s\n' "$user" "$a" | chpasswd
    note "пароль $user задан"
}

ensure_password() {  # ensure_password ПОЛЬЗОВАТЕЛЬ ИМЯ_ПЕРЕМЕННОЙ_С_ХЕШЕМ
    local st
    st=$(pw_status "$1")
    if [ "$st" = P ] && [ "$ASK_PASSWORDS" -eq 0 ] && [ -z "${!2:-}" ]; then
        note "пароль $1 уже задан — не трогаю (сменить: --passwords)"
    else
        set_password "$1" "$2"
    fi
}

add_keys() {  # add_keys ПОЛЬЗОВАТЕЛЬ
    local user=$1 home group f k body added=0
    home=$(getent passwd "$user" | cut -d: -f6)
    group=$(id -gn "$user")
    install -d -m 700 -o "$user" -g "$group" "$home/.ssh"
    f=$home/.ssh/authorized_keys
    [ -f "$f" ] || install -m 600 -o "$user" -g "$group" /dev/null "$f"
    # Последняя строка без перевода — дописанный ключ склеился бы с ней.
    if [ -s "$f" ] && [ -n "$(tail -c1 "$f")" ]; then echo >> "$f"; fi
    for k in "${KEYS[@]}"; do
        # Сравнивается тело ключа: комментарий у одного ключа бывает разный, а
        # дубль в файле — мусор.
        body=$(awk '{print $2}' <<< "$k")
        if ! grep -qF -- "$body" "$f"; then
            echo "$k" >> "$f"
            added=$((added + 1))
        fi
    done
    chown "$user:$group" "$f"
    chmod 600 "$f"
    note "$f: добавлено ключей — $added, всего строк с ключами — $(grep -c '^ssh-' "$f" || true)"
}

# --- проверки до первых изменений --------------------------------------------

for k in "${KEYS[@]}"; do
    ssh-keygen -lf /dev/stdin <<< "$k" > /dev/null 2>&1 || die "не открытый ключ SSH: $k"
done

say "Планшет"
note "модель: $(cat /sys/class/dmi/id/product_name 2>/dev/null || echo неизвестна)"
note "система: ${PRETTY_NAME:-?}, ядро $(uname -r)"
note "адреса сейчас:"
ip -br -4 addr show | grep -v '^lo ' | sed 's/^/     /' || true

# --- 1. openssh-server ---------------------------------------------------------

say "1. OpenSSH"
if dpkg-query -W -f='${Status}' openssh-server 2>/dev/null | grep 'install ok installed' > /dev/null; then
    note "openssh-server уже стоит"
else
    note "ставлю openssh-server (нужен доступ к архиву Ubuntu)"
    # stdin — /dev/null: при запуске «curl … | sudo bash» скрипт приходит по
    # stdin, и apt или debconf съели бы его остаток.
    apt-get update -q < /dev/null
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q openssh-server < /dev/null
fi
# В 24.04 sshd поднимается сокетом. Не включено ни то, ни другое — после
# перезагрузки входа не будет вовсе.
if ! systemctl is-enabled --quiet ssh.socket 2>/dev/null &&
   ! systemctl is-enabled --quiet ssh.service 2>/dev/null; then
    systemctl enable --now ssh.service
    note "ssh включён"
fi

# --- 2. cloud-init -------------------------------------------------------------

say "2. cloud-init"
# На CF-20 и CF-33 выключен. Включённый на загрузке заново пишет
# /etc/netplan/50-cloud-init.yaml и правит sshd — то есть откатывает пункты 5 и 7.
if [ -d /etc/cloud ] && [ ! -e /etc/cloud/cloud-init.disabled ]; then
    touch /etc/cloud/cloud-init.disabled
    note "выключен: /etc/cloud/cloud-init.disabled"
else
    note "уже выключен или не установлен"
fi

# --- 3. root -------------------------------------------------------------------

say "3. root"
# Пароль обязателен: это вход с tty2, когда сеть лежит (RUNBOOK, «Доступ к
# устройству»), и вход по SSH без ключа под рукой. Установщик Ubuntu оставляет
# root заблокированным.
ensure_password root ROOT_PASSWORD_HASH
add_keys root

# --- 4. kiosk ------------------------------------------------------------------

say "4. kiosk"
# Группы — как на CF-20: умолчание установщика без sudo и lxd. kiosk-ingest
# добавляет роль base. Сам киоск идёт под root (kioskd.service), так что video и
# render пользователю не нужны.
KIOSK_GROUPS=adm,cdrom,dip,plugdev
if id kiosk > /dev/null 2>&1; then
    note "пользователь kiosk уже есть"
else
    useradd -m -s /bin/bash kiosk
    note "пользователь kiosk создан"
fi
usermod -aG "$KIOSK_GROUPS" kiosk
ensure_password kiosk KIOSK_PASSWORD_HASH
add_keys kiosk

# sudo у kiosk снят намеренно (роль base, CF-20): единственный административный
# путь — root. Снимать — только когда у root точно есть вход, иначе планшет
# останется без администратора.
[ "$(pw_status root)" = P ] || die "у root нет пароля — sudo у kiosk не снимаю"
for g in sudo admin lxd; do
    # lxd — тот же root: контейнер монтирует корень хоста.
    if getent group "$g" > /dev/null && in_group kiosk "$g"; then
        gpasswd -d kiosk "$g" > /dev/null
        note "kiosk убран из группы $g"
    fi
done
# cloud-init и автоустановка выдают sudo ещё и файлом.
for f in /etc/sudoers.d/*; do
    [ -f "$f" ] || continue
    if grep -qE '^[[:space:]]*kiosk[[:space:]]' "$f"; then
        backup "$f"
        rm -f "$f"
        note "убран $f (выдавал sudo kiosk; копия в $BACKUP)"
    fi
done
if command -v visudo > /dev/null; then
    visudo -c > /dev/null || die "visudo -c: sudoers не разбирается"
fi
note "группы kiosk: $(id -nG kiosk)"

# Других людей на CF-20 и CF-33 нет. Чужого пользователя скрипт не удаляет —
# в нём могут быть чьи-то файлы, — но говорит о нём.
others=$(awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "kiosk" {print $1}' /etc/passwd)
for u in $others; do
    if in_group "$u" sudo || in_group "$u" admin; then
        note "ВНИМАНИЕ: пользователь $u с sudo — на других планшетах такого нет."
    else
        note "ВНИМАНИЕ: пользователь $u — на других планшетах такого нет."
    fi
    note "          Удалить, когда root проверен: userdel -r $u"
done

# --- 5. sshd -------------------------------------------------------------------

say "5. sshd"
# Без каталога разделения привилегий sshd -t и -T отказываются работать, а при
# сокетной активации его создаёт только запуск самого sshd.
mkdir -p /run/sshd
# Первое значение выигрывает, и 10-… читается раньше 50-cloud-init.conf.
if put /etc/ssh/sshd_config.d/10-kiosk.conf 0644 <<'EOF'
# Первичная подготовка (ansible/bootstrap.sh, ADR-0053) — как на CF-20.
#
# Выкладка идёт под root: tools/deploy*.sh кладут бинарник и пакет и дёргают
# systemctl, Ansible ходит root (inventory: ansible_user root).
#
# Вход root по паролю по сети разрешён ЯВНО, по требованию. Это ослабление, и
# оно осознанное: у kiosk снят sudo, поэтому единственный административный
# путь на устройство — root, и он не должен зависеть от наличия ключа под
# рукой. Цена — root по SSH становится доступен перебору пароля.
PermitRootLogin yes
PasswordAuthentication yes
EOF
then
    if ! sshd -t; then
        if [ -f "$BACKUP/10-kiosk.conf" ]; then
            cp -a "$BACKUP/10-kiosk.conf" /etc/ssh/sshd_config.d/10-kiosk.conf
        else
            rm -f /etc/ssh/sshd_config.d/10-kiosk.conf
        fi
        die "sshd -t не принял конфиг — вернул как было"
    fi
    # Открытые сессии reload не рвёт.
    systemctl try-reload-or-restart ssh.service
    note "записан /etc/ssh/sshd_config.d/10-kiosk.conf, sshd перечитал"
else
    note "10-kiosk.conf уже такой"
fi
note "$(sshd -T 2>/dev/null | grep -iE '^(permitrootlogin|passwordauthentication|pubkeyauthentication) ' | tr '\n' ' ')"

# --- 6. имя хоста --------------------------------------------------------------

say "6. Имя хоста"
if [ "$(cat /etc/hostname 2>/dev/null)" != "$NAME_HOST" ]; then
    hostnamectl set-hostname "$NAME_HOST"
    note "имя: $NAME_HOST"
else
    note "уже $NAME_HOST"
fi
# sudo и прочие ищут своё имя в /etc/hosts; без строки — задержка на DNS.
if grep -qE "^127\.0\.1\.1[[:space:]]+$NAME_HOST\$" /etc/hosts; then
    :
elif grep -qE '^127\.0\.1\.1[[:space:]]' /etc/hosts; then
    backup /etc/hosts
    sed -i -E "s/^127\.0\.1\.1[[:space:]].*/127.0.1.1 $NAME_HOST/" /etc/hosts
    note "/etc/hosts: 127.0.1.1 $NAME_HOST"
else
    backup /etc/hosts
    echo "127.0.1.1 $NAME_HOST" >> /etc/hosts
    note "/etc/hosts: дописано 127.0.1.1 $NAME_HOST"
fi

# --- 7. сеть -------------------------------------------------------------------

say "7. Сеть"
NETPLAN=/etc/netplan/01-kiosk.yaml
if [ "$DO_NETWORK" -eq 0 ]; then
    note "пропущено (--no-network)"
else
    # Чужие файлы netplan уходят в $BACKUP: установщик пишет
    # 50-cloud-init.yaml с именем порта и, возможно, Wi-Fi с паролем. На CF-20
    # их так же убрали в /root.
    stale=()
    for f in /etc/netplan/*.yaml /etc/netplan/*.yml; do
        if [ -f "$f" ] && [ "$f" != "$NETPLAN" ]; then stale+=("$f"); fi
    done
    changed=0
    if put "$NETPLAN" 0600 <<'EOF'
# Первичная подготовка (ansible/bootstrap.sh, ADR-0053) — как на CF-20.
#
# Ethernet по DHCP: адрес планшета закрепляет роутер 192.168.3.1. Любой en* —
# имя порта у моделей и переходников разное. Wi-Fi здесь нет: к сети его
# подключает kioskd через wpa_supplicant, адрес берёт networkd по файлу роли
# network (ADR-0038).
network:
    version: 2
    renderer: networkd
    ethernets:
        lan:
            match:
                name: "en*"
            dhcp4: true
EOF
    then
        changed=1
    fi
    for f in "${stale[@]}"; do
        backup "$f"
        rm -f "$f"
        note "убран $f (копия в $BACKUP)"
        changed=1
    done
    if [ "$changed" -eq 0 ]; then
        note "netplan уже такой"
    else
        if ! netplan generate; then
            rm -f "$NETPLAN"
            for f in "${stale[@]}"; do cp -a "$BACKUP/$(basename "$f")" "$f"; done
            if [ -f "$BACKUP/01-kiosk.yaml" ]; then cp -a "$BACKUP/01-kiosk.yaml" "$NETPLAN"; fi
            die "netplan generate не принял конфиг — вернул как было"
        fi
        note "записан $NETPLAN; применяю"
        if [ -n "${SSH_CONNECTION:-}" ]; then
            note "ВНИМАНИЕ: запуск по SSH. Если роутер выдаст другой адрес, сессия"
            note "оборвётся — скрипт при этом доработает: всё прочее уже сделано."
        fi
        # Обрыв SSH не должен убить netplan на полпути.
        trap '' HUP
        netplan apply
        sleep 5
        note "адреса теперь:"
        ip -br -4 addr show | grep -v '^lo ' | sed 's/^/     /' || true
    fi
fi

# --- итог ----------------------------------------------------------------------

addr=$(ip -4 -o addr show scope global | awk '$2 ~ /^en/ {sub(/\/.*/, "", $4); print $4; exit}')
say "Готово"
if [ -d "$BACKUP" ]; then note "прежние версии файлов — $BACKUP"; fi
cat <<EOF

sudo у kiosk больше нет: администрирование — su - или ssh root@${addr:-<адрес>}.

Дальше — с рабочей станции, из WSL, в корне репозитория (docs/RUNBOOK.md,
«Новый планшет»):

  ssh root@${addr:-<адрес>} true          # ключ пускает, пароль не спрашивает
  # хост в ansible/inventory.yml — ansible_host: ${addr:-<адрес>}, ansible_user: root
  ansible-playbook -i ansible/inventory.yml ansible/site.yml --limit <хост> \\
      --tags base,drivers,network,time,boot-silence
  tools/deploy-deb.sh --role slave --install --host root@${addr:-<адрес>}
  ansible-playbook -i ansible/inventory.yml ansible/site.yml --limit <хост>
EOF
