#!/usr/bin/env bash
# Модуль «Telegram-прокси по именам» на движке telemt (Rust, github.com/telemt/telemt).
#
# Чем отличается от модуля tgproxy (mtg): у каждого человека свой ключ и своя ссылка.
# Можно выключить одного — остальные работают; видно трафик и сколько у кого адресов.
#  - Маскировка Fake TLS (ссылки с ee), сайт-маска как у mtg — www.cloudflare.com.
#  - Порт: 9443, а если его держит старый mtg — 9444 (ставится рядом, mtg не трогаем).
#  - Пульт telemt — только 127.0.0.1:9091, им пользуются Комбайн и бот.
#  - Конфиг и кэш — /var/lib/kombain-telemt (служба kombain-telemt пишет туда сама через пульт).
#    Пользователь системный, не «одноразовый» (DynamicUser): telemt не читает конфиг через ярлыки,
#    а DynamicUser делает из /var/lib/<имя> ярлык.

TGU_VER="3.5.14"
TGU_URL="https://github.com/telemt/telemt/releases/download/$TGU_VER/telemt-x86_64-linux-gnu.tar.gz"
TGU_BIN="/usr/local/lib/kombain/telemt"
TGU_STATE="/var/lib/kombain-telemt"
TGU_CONF="$TGU_STATE/config.toml"
TGU_UNIT="/etc/systemd/system/kombain-telemt.service"
TGU_API="http://127.0.0.1:9091/v1"
TGU_FRONT="www.cloudflare.com"
TGU_ENV="$KB_HOME/tgusers/env"
TGU_USER="kombain-telemt"

tgu_installed() { [ -r "$TGU_ENV" ] && [ -f "$TGU_UNIT" ]; }
tgu_running()   { systemctl is-active --quiet kombain-telemt; }
tgu_load_env()  { [ -r "$TGU_ENV" ] && . "$TGU_ENV"; }   # shellcheck disable=SC1090

# Пульт telemt: tgu_api METHOD путь [json] → поле data из ответа
tgu_api() {
  local m="$1" p="$2" body="${3:-}" out
  if [ -n "$body" ]; then
    out=$(curl -s --max-time 10 -X "$m" -H 'Content-Type: application/json' --data "$body" "$TGU_API$p")
  else
    out=$(curl -s --max-time 10 -X "$m" "$TGU_API$p")
  fi
  if [ "$(jq -r '.ok // false' <<<"$out" 2>/dev/null)" != "true" ]; then
    err "telemt ответил ошибкой: $(jq -r '.error.message // empty' <<<"$out" 2>/dev/null || echo "$out" | head -c 200)"
    return 1
  fi
  jq -c '.data' <<<"$out"
}

tgu_bin_ok() {
  [ -x "$TGU_BIN" ] || return 1
  local v; v=$("$TGU_BIN" --version 2>/dev/null) || return 1
  [[ "$v" == *"$TGU_VER"* ]]
}

tgu_get_bin() {
  tgu_bin_ok && return 0
  [ "$(uname -m)" = "x86_64" ] || { err "Пока только для обычных серверов (x86_64)."; return 1; }
  step "Скачиваю telemt $TGU_VER"
  local tmp; tmp=$(mktemp -d)
  curl -fsSL --proto '=https' --max-time 180 --retry 2 "$TGU_URL" -o "$tmp/t.tar.gz" \
    || { err "Не скачалось с GitHub."; rm -rf "${tmp:?}"; return 1; }
  tar -xzf "$tmp/t.tar.gz" -C "$tmp" --no-same-owner || { err "Архив битый."; rm -rf "${tmp:?}"; return 1; }
  local b; b=$(find "$tmp" -type f -name telemt | head -1)
  [ -n "$b" ] || { err "В архиве нет программы."; rm -rf "${tmp:?}"; return 1; }
  install -d -m 0755 "$(dirname "$TGU_BIN")"
  install -o root -g root -m 0755 "$b" "$TGU_BIN"
  rm -rf "${tmp:?}"
  tgu_bin_ok && ok "telemt $TGU_VER скачан" || { err "telemt не запускается."; return 1; }
}

tgu_unit() {
  cat >"$TGU_UNIT" <<EOF
[Unit]
Description=Telegram-прокси по именам (telemt, Kombain)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=$TGU_USER
Group=$TGU_USER
StateDirectory=kombain-telemt
WorkingDirectory=$TGU_STATE
ExecStart=$TGU_BIN $TGU_CONF
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=on-failure
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
}

tgu_install_core() {
  if tgu_installed; then
    tgu_running && grep -q '^200' <<<"$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$TGU_API/users")" \
      && { warn "Уже установлено и работает."; return 0; }
    warn "Стоит, но не работает — переставляю начисто."
    tgu_remove_core >/dev/null
  fi
  ensure_pkgs curl jq tar qrencode || return 1
  local port="${KB_TGU_PORT:-9443}" ip
  if [ -n "$(port_owner "$port" tcp)" ]; then
    [ -z "${KB_TGU_PORT:-}" ] && [ "$(port_owner "$port" tcp)" = "telegram-mtg" ] && port=9444
    [ -z "$(port_owner "$port" tcp)" ] || { err "Порт $port занят: $(port_owner "$port" tcp)"; return 1; }
    [ "$port" = 9444 ] && warn "9443 держит старый прокси (mtg) — ставлю рядом, на 9444. Старый не трогаю."
  fi
  [ -z "$(port_owner 9091 tcp)" ] || { err "Порт 9091 (пульт telemt) занят: $(port_owner 9091 tcp)"; return 1; }
  ip="${KB_SERVER_IP:-$(server_ip)}"
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { err "Не узнала внешний IP сервера."; return 1; }

  tgu_get_bin || return 1
  step "Настраиваю Telegram-прокси по именам"
  id "$TGU_USER" >/dev/null 2>&1 || useradd --system --no-create-home --shell /usr/sbin/nologin "$TGU_USER"
  # хвост прошлой попытки: ярлык от DynamicUser
  if [ -L "$TGU_STATE" ]; then rm -f "${TGU_STATE:?}"; rm -rf /var/lib/private/kombain-telemt; fi
  install -d -m 0750 -o "$TGU_USER" -g "$TGU_USER" "$TGU_STATE"
  cat >"$TGU_CONF" <<EOF
# Комбайн: telemt. Людей добавляет бот через пульт — руками не правь.
[general]
use_middle_proxy = true
log_level = "normal"

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"
public_host = "$ip"
public_port = $port

[server]
port = $port

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.1/32"]

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "$TGU_FRONT"
mask = true
tls_emulation = true
tls_front_dir = "tlsfront"

[access.users]
admin = "$(openssl rand -hex 16)"
EOF
  chown "$TGU_USER:$TGU_USER" "$TGU_CONF"; chmod 640 "$TGU_CONF"
  mkdir -p "$(dirname "$TGU_ENV")"
  printf "TGU_PORT='%s'\nTGU_IP='%s'\n" "$port" "$ip" >"$TGU_ENV"
  tgu_unit
  systemctl enable kombain-telemt >/dev/null 2>&1
  systemctl restart kombain-telemt
  local _ up=0
  for _ in $(seq 1 20); do tgu_api GET /users >/dev/null 2>&1 && { up=1; break; }; sleep 1; done
  [ "$up" = 1 ] || { err "telemt не запустился. Логи: journalctl -u kombain-telemt -n 30"; return 1; }

  fw_register tgusers "$port/tcp"
  if grep -q '^Status: active' <<<"$(ufw status 2>/dev/null)"; then fw_apply; fi
  ok "Telegram-прокси по именам работает на порту $port. Первый ключ — admin (твой)."
}

tgu_remove_core() {
  tgu_installed || { warn "Не установлено."; return 0; }
  systemctl disable --now kombain-telemt >/dev/null 2>&1
  rm -f /etc/systemd/system/kombain-telemt.service; systemctl daemon-reload
  rm -rf /var/lib/kombain-telemt /var/lib/private/kombain-telemt "${KB_HOME:?}/tgusers"
  userdel kombain-telemt >/dev/null 2>&1
  fw_unregister tgusers
  ok "Telegram-прокси по именам удалён"
}

# ───────────────────────── люди ─────────────────────────

tgu_valid() { [[ "$1" =~ ^[a-z0-9][a-z0-9_.-]{0,62}$ ]]; }

# Список людей: имя, вкл, трафик, адресов сейчас, ссылка
tgu_list() {
  tgu_api GET /users | jq -c '[.[] | {name: .username, on: .enabled, bytes: .total_octets,
    ips: .active_unique_ips, conns: .current_connections, link: (.links.tls[0] // "")}]'
}

tgu_link() {
  tgu_valid "$1" || { err "Нет такого"; return 1; }
  tgu_api GET "/users/$1" | jq -r '.links.tls[0] // empty'
}

tgu_add()     { tgu_valid "$1" || { err "Имя: маленькие латинские буквы, цифры, точка, дефис"; return 1; }
                tgu_api POST /users "$(jq -nc --arg u "$1" '{username:$u}')" >/dev/null && ok "Добавлен $1"; }
tgu_del()     { tgu_valid "$1" && tgu_api DELETE "/users/$1" >/dev/null && ok "Удалён $1"; }
tgu_disable() { tgu_valid "$1" && tgu_api POST "/users/$1/disable" >/dev/null && ok "$1 выключен"; }
tgu_enable()  { tgu_valid "$1" && tgu_api POST "/users/$1/enable" >/dev/null && ok "$1 включён"; }
tgu_rotate()  { tgu_valid "$1" && tgu_api POST "/users/$1/rotate-secret" >/dev/null && ok "У $1 новый ключ, старая ссылка умерла"; }

tgu_status() {
  tgu_installed || { warn "Не установлено."; return 0; }
  tgu_load_env
  step "Telegram-прокси по именам"
  tgu_running && ok "Работает на порту $TGU_PORT ($("$TGU_BIN" --version 2>/dev/null | head -1))" || err "Не запущен"
  tgu_list | jq -r '.[] | "  \(if .on then "✅" else "⛔" end) \(.name) — \((.bytes/1048576*10|floor)/10) МБ, подключений \(.conns)"'
}

# kombain cli tgusers <команда>
tgu_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    info)
      if tgu_installed; then
        tgu_load_env
        local l; l=$(tgu_list 2>/dev/null || echo '[]')
        jq -nc --argjson run "$(tgu_running && echo true || echo false)" --argjson port "$TGU_PORT" \
          --argjson users "$l" '{installed:true, running:$run, port:$port, users:$users}'
      else
        jq -nc '{installed:false}'
      fi ;;
    install) tgu_install_core ;;
    remove)  tgu_remove_core ;;
    add)     tgu_add "${1:-}" ;;
    del)     tgu_del "${1:-}" ;;
    disable) tgu_disable "${1:-}" ;;
    enable)  tgu_enable "${1:-}" ;;
    rotate)  tgu_rotate "${1:-}" ;;
    link)    tgu_link "${1:-}" ;;
    qr-png)  local l; l=$(tgu_link "${1:-}") && [ -n "$l" ] || { err "Нет ссылки"; return 1; }
             qrencode -t PNG -s 6 -m 2 -o - "$l" ;;
    status)  tgu_status ;;
    exe)
      # Для установщика (exe): поставить и выдать ссылку admin в том же виде, что tgproxy link
      ensure_pkgs jq qrencode >/dev/null 2>&1
      tgu_install_core >&2 || return 1
      local tg; tg=$(tgu_link admin) && [ -n "$tg" ] || { err "Нет ссылки admin"; return 1; }
      jq -nc --arg tg "$tg" --arg web "https://t.me/proxy?${tg#*\?}" \
        --arg qr "$(qrencode -t SVG -m 2 -o - "$tg" 2>/dev/null | base64 -w0)" '{tg:$tg, web:$web, qr:$qr}' ;;
    *) err "Неизвестная команда: $cmd"; return 2 ;;
  esac
}
