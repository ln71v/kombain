#!/usr/bin/env bash
# Модуль «WARP»: выход в интернет через Cloudflare WARP — по выбору, для отдельных устройств.
#
# Как это работает (основа — репа ln71v/WARP, только без Docker):
#  - wgcf заводит бесплатный аккаунт WARP и выдаёт профиль WireGuard → интерфейс «warp».
#    Table = off: основной маршрут сервера не трогаем, через WARP идёт только то, что выбрали.
#  - Таблица маршрутов 100: «всё — в warp».
#  - AmneziaWG: устройство по своему адресу (10.8.1.x) попадает в таблицу 100 правилом ip rule.
#  - VLESS: Xray метит трафик выбранных устройств (mark 0x77), метку правило ip rule тоже шлёт в таблицу 100.
#  - Кто через WARP — файл $KB_HOME/warp/users: строки «vless имя» / «awg имя».
#  - После перезагрузки всё поднимает служба kombain-warp.

WARP_DIR="$KB_HOME/warp"
WARP_CONF="$WARP_DIR/warp.conf"
WARP_USERS="$WARP_DIR/users"
WARP_TABLE=100
WARP_MARK=119            # 0x77
WARP_PRIO=20000          # приоритет наших правил ip rule
WARP_UNIT="/etc/systemd/system/kombain-warp.service"
WGCF_VER="v2.3.0"
WGCF_BIN="/usr/local/lib/kombain/wgcf"

warp_installed() { [ -r "$WARP_CONF" ]; }
warp_up()        { ip link show warp >/dev/null 2>&1; }

warp_get_wgcf() {
  "$WGCF_BIN" --help >/dev/null 2>&1 && return 0
  [ "$(uname -m)" = "x86_64" ] || { err "WARP пока только для обычных серверов (x86_64)."; return 1; }
  step "Скачиваю wgcf $WGCF_VER"
  install -d -m 0755 "$(dirname "$WGCF_BIN")"
  curl -fsSL --proto '=https' --max-time 120 --retry 2 \
    "https://github.com/ViRb3/wgcf/releases/download/$WGCF_VER/wgcf_${WGCF_VER#v}_linux_amd64" -o "$WGCF_BIN.new" \
    || { err "wgcf не скачался с GitHub."; rm -f "${WGCF_BIN:?}.new"; return 1; }
  chmod 755 "$WGCF_BIN.new"
  "$WGCF_BIN.new" --help >/dev/null 2>&1 || { err "wgcf не запускается."; rm -f "${WGCF_BIN:?}.new"; return 1; }
  mv -f "$WGCF_BIN.new" "$WGCF_BIN"
}

# Новый аккаунт и профиль WARP → $WARP_CONF
warp_register() {
  local tmp; tmp=$(mktemp -d)
  ( cd "$tmp" && "$WGCF_BIN" register --accept-tos >/dev/null 2>&1 && "$WGCF_BIN" generate >/dev/null 2>&1 ) \
    || { err "Cloudflare не выдал аккаунт WARP. Попробуй позже."; rm -rf "${tmp:?}"; return 1; }
  mkdir -p "$WARP_DIR"; chmod 700 "$WARP_DIR"
  # без DNS (не трогаем систему), Table = off (основной маршрут не трогаем), MTU 1280
  awk '/^\[Interface\]/ {print; print "Table = off"; next}
       /^DNS *=/ {next}
       /^MTU *=/ {print "MTU = 1280"; next}
       {print}' "$tmp/wgcf-profile.conf" >"$WARP_CONF.new"
  install -m 600 "$WARP_CONF.new" "$WARP_CONF"; rm -f "${WARP_CONF:?}.new"
  install -m 600 "$tmp/wgcf-account.toml" "$WARP_DIR/wgcf-account.toml"
  rm -rf "${tmp:?}"
}

# Список адресов AmneziaWG-устройств, которым включён WARP
warp_awg_ips() {
  local n
  awk '$1=="awg"{print $2}' "$WARP_USERS" 2>/dev/null | while read -r n; do
    sed -n 's#^Address = \([0-9.]*\)/32#\1#p' "$KB_HOME/awg/clients/$n.conf" 2>/dev/null
  done
}

# Применить: интерфейс, таблица, правила по устройствам. Можно звать сколько угодно раз.
warp_apply() {
  warp_installed || return 0
  warp_up || wg-quick up "$WARP_CONF" >/dev/null 2>&1 || { err "Интерфейс warp не поднялся."; return 1; }
  ip route replace default dev warp table "$WARP_TABLE"
  sysctl -q -w net.ipv4.conf.warp.rp_filter=2 2>/dev/null
  iptables -t mangle -C FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null \
    || iptables -t mangle -A FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu
  iptables -t nat -C POSTROUTING -o warp -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -o warp -j MASQUERADE

  # наши правила — с приоритетом WARP_PRIO: сносим все и ставим заново
  while ip rule del priority "$WARP_PRIO" 2>/dev/null; do :; done
  ip rule add fwmark "$WARP_MARK" table "$WARP_TABLE" priority "$WARP_PRIO"
  local ip
  for ip in $(warp_awg_ips); do
    ip rule add from "$ip/32" table "$WARP_TABLE" priority "$WARP_PRIO"
  done

  # VLESS сам читает список при сборке конфига
  if declare -F vls_installed >/dev/null && vls_installed; then
    vls_load_env; vls_write_conf && vls_restart
  fi
  return 0
}

warp_unit() {
  cat >"$WARP_UNIT" <<EOF
[Unit]
Description=Cloudflare WARP для выбранных устройств (Kombain)
After=network-online.target awg-quick@awg0.service
Wants=network-online.target

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$KB_SRC/kombain.sh cli warp apply
ExecStop=$KB_SRC/kombain.sh cli warp down

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable kombain-warp >/dev/null 2>&1
}

warp_down() {
  while ip rule del priority "$WARP_PRIO" 2>/dev/null; do :; done
  while iptables -t nat -D POSTROUTING -o warp -j MASQUERADE 2>/dev/null; do :; done
  while iptables -t mangle -D FORWARD -o warp -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --clamp-mss-to-pmtu 2>/dev/null; do :; done
  warp_up && wg-quick down "$WARP_CONF" >/dev/null 2>&1
  return 0
}

# Адрес, с которым выходит WARP (проверка, что Cloudflare пускает)
warp_trace() {
  curl -s --interface warp --max-time 10 https://www.cloudflare.com/cdn-cgi/trace 2>/dev/null \
    | awk -F= '$1=="ip"{ip=$2} $1=="warp"{w=$2} END{if(ip!="") print ip, w}'
}

warp_install_core() {
  warp_installed && { warn "WARP уже установлен."; warp_apply; return 0; }
  ensure_pkgs wireguard-tools iptables curl jq || return 1
  warp_get_wgcf || return 1
  step "Регистрирую WARP у Cloudflare"
  warp_register || return 1
  touch "$WARP_USERS"
  warp_apply || return 1
  warp_unit
  local t; t=$(warp_trace)
  if [ -n "$t" ]; then ok "WARP работает: выход через ${t% *} (warp=${t#* })"
  else warn "Интерфейс поднят, но Cloudflare не ответил. Проверь «Состояние» через минуту."; fi
  ok "Пока через WARP никто не ходит — включай по устройствам."
}

warp_remove_core() {
  warp_installed || { warn "WARP не установлен."; return 0; }
  systemctl disable kombain-warp >/dev/null 2>&1
  warp_down
  rm -f /etc/systemd/system/kombain-warp.service; systemctl daemon-reload
  rm -rf "${KB_HOME:?}/warp"
  if declare -F vls_installed >/dev/null && vls_installed; then vls_load_env; vls_write_conf && vls_restart; fi
  ok "WARP удалён, все устройства ходят напрямую"
}

warp_reissue() {
  warp_installed || { err "WARP не установлен."; return 1; }
  step "Перевыпускаю ключ WARP"
  warp_up && wg-quick down "$WARP_CONF" >/dev/null 2>&1
  cp -a "$WARP_CONF" "$WARP_CONF.bak"
  warp_register || { cp -a "$WARP_CONF.bak" "$WARP_CONF"; warp_apply; return 1; }
  warp_apply && ok "Новый ключ WARP, устройства остались как были"
}

# ───────────────────────── устройства ─────────────────────────

# Все устройства: «протокол имя вкл(1/0)»
warp_devices() {
  local n on
  if [ -r "$KB_HOME/vless/clients.json" ]; then
    for n in $(jq -r '.[].name' "$KB_HOME/vless/clients.json"); do
      on=0; grep -qx "vless $n" "$WARP_USERS" 2>/dev/null && on=1; echo "vless $n $on"
    done
  fi
  for n in $(ls "$KB_HOME/awg/clients" 2>/dev/null | sed -n 's/\.conf$//p'); do
    on=0; grep -qx "awg $n" "$WARP_USERS" 2>/dev/null && on=1; echo "awg $n $on"
  done
}

warp_set() {
  local proto="$1" name="$2" want="$3"
  warp_installed || { err "Сначала установи WARP."; return 1; }
  [[ "$proto" =~ ^(vless|awg)$ ]] && [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { err "Нет такого устройства"; return 1; }
  warp_devices | grep -q "^$proto $name " || { err "Нет такого устройства: $proto $name"; return 1; }
  grep -vx "$proto $name" "$WARP_USERS" >"$WARP_USERS.new" 2>/dev/null
  [ "$want" = on ] && echo "$proto $name" >>"$WARP_USERS.new"
  mv -f "$WARP_USERS.new" "$WARP_USERS"
  warp_apply || return 1
  [ "$want" = on ] && ok "$name ($proto) — через WARP" || ok "$name ($proto) — напрямую"
}

warp_set_all() {
  local want="$1"
  warp_installed || { err "Сначала установи WARP."; return 1; }
  if [ "$want" = on ]; then warp_devices | awk '{print $1, $2}' >"$WARP_USERS"; else : >"$WARP_USERS"; fi
  warp_apply && { [ "$want" = on ] && ok "Все устройства — через WARP" || ok "Все устройства — напрямую"; }
}

warp_status() {
  warp_installed || { warn "WARP не установлен."; return 0; }
  step "Состояние WARP"
  if warp_up; then ok "Интерфейс warp поднят"; else err "Интерфейс warp не поднят"; fi
  local t; t=$(warp_trace)
  if [ -n "$t" ]; then ok "Cloudflare отвечает: выход ${t% *}, warp=${t#* }"; else err "Cloudflare через WARP не отвечает"; fi
  say "Устройства (✅ — через WARP):"
  warp_devices | while read -r p n on; do say "  $([ "$on" = 1 ] && echo ✅ || echo ⬜) $n ($p)"; done
}

# ───────────────────────── меню и команды ─────────────────────────

warp_menu() {
  while true; do
    cat <<EOF

${C_BOLD}══ WARP ══${C_RESET}
 1) Установить
 2) Состояние и устройства
 3) Включить устройству
 4) Выключить устройству
 5) Всех через WARP
 6) Всех напрямую
 7) Перевыпустить ключ WARP
 8) Удалить WARP
 0) Назад
EOF
    case "$(ask "Выбор")" in
      1) warp_install_core ;;
      2) warp_status ;;
      3) warp_devices | awk '{print "  " $1 " " $2}'
         warp_set "$(ask "Протокол (vless или awg)")" "$(ask "Имя устройства")" on ;;
      4) warp_devices | awk '{print "  " $1 " " $2}'
         warp_set "$(ask "Протокол (vless или awg)")" "$(ask "Имя устройства")" off ;;
      5) warp_set_all on ;;
      6) warp_set_all off ;;
      7) warp_reissue ;;
      8) confirm "Удалить WARP? Все устройства пойдут напрямую." && warp_remove_core ;;
      0) return ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

# kombain cli warp <команда>
warp_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    info)
      if warp_installed; then
        local t; t=$(warp_trace)
        warp_devices | jq -Rnc --arg ip "${t% *}" --argjson up "$(warp_up && echo true || echo false)" \
          '{installed:true, up:$up, ip:$ip,
            devices:[inputs | split(" ") | {proto:.[0], name:.[1], on:(.[2]=="1")}]}'
      else
        jq -nc '{installed:false}'
      fi ;;
    install) warp_install_core ;;
    remove)  warp_remove_core ;;
    apply)   warp_apply ;;
    down)    warp_down ;;
    on|off)  warp_set "${1:-}" "${2:-}" "$cmd" ;;
    all-on)  warp_set_all on ;;
    all-off) warp_set_all off ;;
    reissue) warp_reissue ;;
    status)  warp_status ;;
    *) err "Неизвестная команда: $cmd"; return 2 ;;
  esac
}
