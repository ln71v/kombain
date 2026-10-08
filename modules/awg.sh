#!/usr/bin/env bash
# Модуль «AmneziaWG 3.1»: VPN без Docker, модулем ядра из официального репозитория Amnezia.
#
# Как это работает:
#  - Пакет amneziawg (ppa:amnezia/ppa) — модуль ядра + утилиты awg / awg-quick, версия протокола 3.1.
#  - Сервер — интерфейс awg0, поднимает systemd (awg-quick@awg0). Конфиг /etc/amnezia/amneziawg/awg0.conf.
#  - Клиенты лежат в $KB_HOME/awg/clients/<имя>.conf — готовые файлы для приложения Amnezia VPN (5.0.1.5+).
#  - Параметры маскировки — как у самого приложения Amnezia при установке 3.1 (см. amnezia-client,
#    protocolConstants.h и awgInstaller.cpp): защита заголовков, случайные хвосты, разброс таймингов.
#  - Порт 443/udp (docs/DEV-PORTS.md). С xray/nginx на 443/tcp не пересекается.

AWG_DIR="$KB_HOME/awg"
AWG_CLIENTS="$AWG_DIR/clients"
AWG_ENV="$AWG_DIR/env"
AWG_IF="awg0"
AWG_CONF="/etc/amnezia/amneziawg/$AWG_IF.conf"
AWG_PORT="${KB_AWG_PORT:-443}"   # свой порт на сервере хранится в env (AWG_PORT)
AWG_NET="10.8.1"          # 10.8.1.1 — сервер, клиенты с .2
AWG_MTU=1280              # Amnezia советует 1280 для 3.1
AWG_SYSCTL="/etc/sysctl.d/99-kombain-awg.conf"
# Пакет из I1 — как у приложения Amnezia по умолчанию (маскировка первого пакета под DNS-ответ)
AWG_I1='<r 2><b 0x858000010001000000000669636c6f756403636f6d0000010001c00c000100010000105a00044d583737>'

awg_installed() { [ -r "$AWG_ENV" ] && [ -r "$AWG_CONF" ]; }
awg_running()   { ip link show "$AWG_IF" >/dev/null 2>&1; }

awg_load_env() {
  # shellcheck disable=SC1090
  [ -r "$AWG_ENV" ] && . "$AWG_ENV"
}

# Версия модуля ядра и утилит — обе должны быть 3.1
awg_versions() {
  local m t
  m=$(modinfo -F version amneziawg 2>/dev/null)
  t=$(awg --version 2>/dev/null | grep -o 'v[0-9][0-9.]*' | head -1)
  printf 'модуль %s, утилиты %s' "${m:-нет}" "${t:-нет}"
}
awg_version_ok() {
  modinfo -F version amneziawg 2>/dev/null | grep -q '^3\.1' && awg --version 2>/dev/null | grep -q 'v3\.1'
}

awg_wan_if() { ip -4 route show default 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="dev") {print $(i+1); exit}}'; }

# ───────────────────────── установка ─────────────────────────

awg_get_pkgs() {
  if awg_version_ok; then ok "AmneziaWG уже есть: $(awg_versions)"; return 0; fi
  step "Ставлю AmneziaWG 3.1 из репозитория Amnezia"
  ensure_pkgs software-properties-common python3-launchpadlib gnupg2 qrencode iptables || return 1
  if ! dpkg -s "linux-headers-$(uname -r)" >/dev/null 2>&1; then
    ensure_pkgs "linux-headers-$(uname -r)" || { err "Нет заголовков ядра $(uname -r). Обнови систему и перезагрузись."; return 1; }
  fi
  if ! grep -rqs 'amnezia/ppa' /etc/apt/sources.list /etc/apt/sources.list.d/; then
    add-apt-repository -y ppa:amnezia/ppa >/dev/null 2>&1 || { err "Не подключился репозиторий Amnezia."; return 1; }
  fi
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq amneziawg >/dev/null 2>&1 \
    || { err "Пакет amneziawg не встал. Подробности: apt-get install amneziawg"; return 1; }
  modprobe amneziawg 2>/dev/null
  if ! awg_version_ok; then
    err "Встала не та версия: $(awg_versions). Нужна 3.1."
    say "Если модуль ядра «нет» — скорее всего, сервер ждёт перезагрузки после обновления ядра."
    return 1
  fi
  ok "AmneziaWG 3.1 готов: $(awg_versions)"
}

# Случайное число в диапазоне: awg_rand 4 6
awg_rand() { shuf -i "$1-$2" -n 1; }

# Конфиг сервера всегда собирается целиком: интерфейс + все клиенты из $AWG_CLIENTS.
awg_write_server() {
  local wan="$AWG_WAN" n f priv ip
  mkdir -p "$(dirname "$AWG_CONF")" "$AWG_CLIENTS"
  chmod 700 "$AWG_DIR" "$(dirname "$AWG_CONF")"
  backup_file "$AWG_CONF"
  ( umask 077
    cat >"$AWG_CONF" <<EOF
# Комбайн: AmneziaWG 3.1. Руками не правь — клиентов добавляет «kombain».
[Interface]
PrivateKey = $AWG_SRV_PRIV
Address = $AWG_NET.1/24
ListenPort = $AWG_PORT
MTU = $AWG_MTU
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S
S2 = $AWG_S
S3 = $AWG_S
S4 = $AWG_S
H1 = 1
H2 = 2
H3 = 3
H4 = 4
HeaderProtectionKey = $AWG_HPK
ContentPaddingAddition = 10-100
RekeyAfterTime = 100-120
RekeyTimeout = 3-7
RejectAfterTime = 150-180
KeepaliveTimeout = 5-15
MaxHandshakeAttempts = 15-20
RandomTrailers = on
DisableCookies = on
PostUp = iptables -I FORWARD 1 -i %i -j ACCEPT; iptables -I FORWARD 1 -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -A POSTROUTING -s $AWG_NET.0/24 -o $wan -j MASQUERADE
PostDown = iptables -D FORWARD -i %i -j ACCEPT; iptables -D FORWARD -o %i -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT; iptables -t nat -D POSTROUTING -s $AWG_NET.0/24 -o $wan -j MASQUERADE
EOF
    for n in $(awg_clients); do
      f="$AWG_CLIENTS/$n.conf"
      priv=$(sed -n 's/^PrivateKey = //p' "$f"); ip=$(sed -n 's/^Address = //p' "$f")
      printf '\n# %s\n[Peer]\nPublicKey = %s\nPresharedKey = %s\nAllowedIPs = %s\n' \
        "$n" "$(printf '%s' "$priv" | awg pubkey)" "$AWG_PSK" "$ip" >>"$AWG_CONF"
    done
  )
}

# Применить конфиг к работающему серверу, не обрывая остальных
awg_apply() {
  awg_running || return 0
  awg syncconf "$AWG_IF" <(awg-quick strip "$AWG_IF" 2>/dev/null) \
    || { err "Сервер не принял новый конфиг."; return 1; }
}

awg_save_env() {
  ( umask 077
    cat >"$AWG_ENV" <<EOF
AWG_SRV_PRIV='$AWG_SRV_PRIV'
AWG_SRV_PUB='$AWG_SRV_PUB'
AWG_PSK='$AWG_PSK'
AWG_HPK='$AWG_HPK'
AWG_JC='$AWG_JC'
AWG_JMIN='$AWG_JMIN'
AWG_JMAX='$AWG_JMAX'
AWG_S='$AWG_S'
AWG_ENDPOINT='$AWG_ENDPOINT'
AWG_WAN='$AWG_WAN'
AWG_PORT='$AWG_PORT'
EOF
  )
}

awg_install_core() {
  awg_installed && { warn "AmneziaWG уже установлен."; return 0; }
  local owner wan
  owner=$(port_owner "$AWG_PORT" udp)
  [ -n "$owner" ] && { err "Порт $AWG_PORT/udp уже занят: $owner"; return 1; }
  ip link show "$AWG_IF" >/dev/null 2>&1 && { err "Интерфейс $AWG_IF уже есть — его поднял кто-то другой."; return 1; }
  ip -4 addr | grep -q "inet $AWG_NET\." && { err "Подсеть $AWG_NET.0/24 уже занята на сервере."; return 1; }
  wan=$(awg_wan_if); [ -n "$wan" ] || { err "Не нашла сетевую карту с выходом в интернет."; return 1; }

  awg_get_pkgs || return 1

  step "Настраиваю сервер AmneziaWG"
  AWG_SRV_PRIV=$(awg genkey); AWG_SRV_PUB=$(printf '%s' "$AWG_SRV_PRIV" | awg pubkey)
  AWG_PSK=$(awg genpsk); AWG_HPK=$(awg genkey)
  AWG_JC=$(awg_rand 4 6); AWG_JMIN=10; AWG_JMAX=50; AWG_S=12
  AWG_ENDPOINT="${KB_SERVER_IP:-$(server_ip)}"
  [ -n "$AWG_ENDPOINT" ] || { err "Не узнала внешний IP сервера."; return 1; }
  mkdir -p "$AWG_DIR"; chmod 700 "$AWG_DIR"
  AWG_WAN="$wan"
  awg_save_env
  awg_write_server

  printf 'net.ipv4.ip_forward = 1\n' >"$AWG_SYSCTL"
  sysctl -q -p "$AWG_SYSCTL"

  systemctl enable --now "awg-quick@$AWG_IF" >/dev/null 2>&1 \
    || { err "Сервер не поднялся. Подробности: journalctl -u awg-quick@$AWG_IF -n 30"; return 1; }
  awg_running || { err "Интерфейс $AWG_IF не появился."; return 1; }
  ok "Сервер AmneziaWG работает на $AWG_ENDPOINT:$AWG_PORT/udp"

  fw_register awg "$AWG_PORT/udp"
  if ufw status 2>/dev/null | grep -q '^Status: active'; then fw_apply; fi
}

# ───────────────────────── клиенты ─────────────────────────

awg_valid_client() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; }
awg_clients() { ls "$AWG_CLIENTS" 2>/dev/null | sed -n 's/\.conf$//p' | sort; }

awg_free_ip() {
  local i used
  used=$(cat "$AWG_CLIENTS"/*.conf 2>/dev/null | sed -n "s#^Address = $AWG_NET\.\([0-9]*\)/32#\1#p")
  for i in $(seq 2 254); do
    grep -qx "$i" <<<"$used" || { echo "$AWG_NET.$i"; return 0; }
  done
  return 1
}

awg_add_client() {
  local name="$1" priv pub ip
  awg_valid_client "$name" || { err "Имя: маленькие латинские буквы, цифры и дефис. Пример: vasya-phone"; return 1; }
  [ -e "$AWG_CLIENTS/$name.conf" ] && { err "Устройство $name уже есть."; return 1; }
  awg_load_env
  ip=$(awg_free_ip) || { err "Свободных адресов не осталось."; return 1; }
  priv=$(awg genkey); pub=$(printf '%s' "$priv" | awg pubkey)

  ( umask 077
    cat >"$AWG_CLIENTS/$name.conf" <<EOF
[Interface]
PrivateKey = $priv
Address = $ip/32
DNS = 1.1.1.1, 8.8.8.8
MTU = $AWG_MTU
Jc = $AWG_JC
Jmin = $AWG_JMIN
Jmax = $AWG_JMAX
S1 = $AWG_S
S2 = $AWG_S
S3 = $AWG_S
S4 = $AWG_S
H1 = 1
H2 = 2
H3 = 3
H4 = 4
I1 = $AWG_I1
HeaderProtectionKey = $AWG_HPK
ContentPaddingAddition = 10-100
RekeyAfterTime = 100-120
RekeyTimeout = 3-7
RejectAfterTime = 150-180
KeepaliveTimeout = 5-15
MaxHandshakeAttempts = 15-20
RandomTrailers = on
DisableCookies = on

[Peer]
PublicKey = $AWG_SRV_PUB
PresharedKey = $AWG_PSK
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = $AWG_ENDPOINT:$AWG_PORT
PersistentKeepalive = 25-35
EOF
  )
  if ! { awg_write_server && awg_apply; }; then
    rm -f "${AWG_CLIENTS:?}/${name:?}.conf"; awg_write_server; return 1
  fi
  ok "Устройство $name добавлено ($ip)"
}

awg_remove_client() {
  local name="$1"
  awg_valid_client "$name" && [ -e "$AWG_CLIENTS/$name.conf" ] || { err "Нет такого устройства: $name"; return 1; }
  awg_load_env
  rm -f "${AWG_CLIENTS:?}/${name:?}.conf"
  awg_write_server && awg_apply || return 1
  ok "Устройство $name удалено"
}

awg_show_client() {
  local f="$AWG_CLIENTS/$1.conf"
  [ -r "$f" ] || { err "Нет такого устройства: $1"; return 1; }
  qrencode -t ANSIUTF8 -m 1 <"$f" 2>/dev/null
  echo
  cat "$f"
  echo
  say "Приложение: Amnezia VPN 5.0.1.5 или новее → «+» → «Файл с настройками» (или «QR-код»)."
}

# ───────────────────────── обслуживание ─────────────────────────

awg_status() {
  awg_installed || { warn "AmneziaWG не установлен."; return 0; }
  awg_load_env
  step "Состояние AmneziaWG"
  if awg_running; then ok "Сервер работает: $(awg_versions)"; else err "Сервер не запущен"; fi
  if [ "$(awg show "$AWG_IF" listen-port 2>/dev/null)" = "$AWG_PORT" ]; then ok "Порт $AWG_PORT/udp слушается"
  else err "Порт $AWG_PORT/udp не слушается"; fi
  say "Устройства и последнее рукопожатие:"
  local n pub hs now ago
  now=$(date +%s)
  for n in $(awg_clients); do
    pub=$(sed -n 's/^PrivateKey = //p' "$AWG_CLIENTS/$n.conf" | awg pubkey)
    hs=$(awg show "$AWG_IF" latest-handshakes 2>/dev/null | awk -v p="$pub" '$1==p{print $2}')
    if [ -z "$hs" ] || [ "$hs" = "0" ]; then ago="ни разу"
    else ago="$(( (now-hs)/60 )) мин назад"; fi
    say "  $n — $ago"
  done
}

awg_remove_core() {
  awg_installed || { warn "AmneziaWG не установлен."; return 0; }
  systemctl disable --now "awg-quick@$AWG_IF" >/dev/null 2>&1
  backup_file "$AWG_CONF"
  rm -f /etc/amnezia/amneziawg/awg0.conf /etc/sysctl.d/99-kombain-awg.conf
  rm -rf "${KB_HOME:?}/awg"
  fw_unregister awg
  ok "AmneziaWG удалён (пакет оставила: apt remove amneziawg — если не нужен совсем)"
}

# ───────────────────────── меню и команды ─────────────────────────

awg_menu() {
  while true; do
    cat <<EOF

${C_BOLD}══ AmneziaWG 3.1 ══${C_RESET}
 1) Установить
 2) Добавить устройство
 3) Показать устройство (QR и файл)
 4) Состояние
 5) Удалить устройство
 6) Удалить AmneziaWG
 0) Назад
EOF
    case "$(ask "Выбор")" in
      1) awg_install_core && { awg_installed && [ -z "$(awg_clients)" ] && awg_add_client phone && awg_show_client phone; } ;;
      2) local n; n=$(ask "Имя устройства (латиницей, например vasya-phone)" | tr 'A-Z' 'a-z'); awg_add_client "$n" && awg_show_client "$n" ;;
      3) say "Устройства: $(awg_clients | tr '\n' ' ')"; awg_show_client "$(ask "Какое")" ;;
      4) awg_status ;;
      5) say "Устройства: $(awg_clients | tr '\n' ' ')"; awg_remove_client "$(ask "Какое удалить")" ;;
      6) confirm "Удалить AmneziaWG? Все устройства отключатся." && awg_remove_core ;;
      0) return ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

# kombain cli awg <команда>
awg_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    info)
      if awg_installed; then
        jq -nc --arg ip "$(awg_load_env; echo "$AWG_ENDPOINT")" --argjson run "$(awg_running && echo true || echo false)" \
          --arg ver "$(awg_versions)" --argjson c "$(awg_clients | jq -R . | jq -sc .)" \
          '{installed:true, running:$run, endpoint:$ip, version:$ver, clients:$c}'
      else
        jq -nc '{installed:false}'
      fi ;;
    install)    awg_install_core ;;
    add-client) awg_installed || { err "AmneziaWG не установлен"; return 1; }; awg_add_client "${1:-}" ;;
    rm-client)  awg_installed || return 1; awg_remove_client "${1:?имя}" ;;
    conf)       awg_valid_client "${1:-}" && [ -r "$AWG_CLIENTS/$1.conf" ] || { err "Нет такого устройства"; return 1; }
                cat "$AWG_CLIENTS/$1.conf" ;;
    qr-png)     awg_valid_client "${1:-}" && [ -r "$AWG_CLIENTS/$1.conf" ] || { err "Нет такого устройства"; return 1; }
                qrencode -t PNG -s 6 -m 2 -o - <"$AWG_CLIENTS/$1.conf" ;;
    status)     awg_status ;;
    remove)     awg_remove_core ;;
    *) err "Неизвестная команда: $cmd"; return 2 ;;
  esac
}
