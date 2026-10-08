#!/usr/bin/env bash
# Модуль «VLESS Reality»: Xray без панели, маскировка под чужой большой сайт (по умолчанию www.yahoo.com).
#
# Как это работает:
#  - Xray снаружи выглядит как сайт-маска: без ключа сервер честно показывает настоящий yahoo.
#  - Клиент с ключом (Hiddify, Amnezia VPN, v2rayNG, Streisand) получает VPN по TCP 443 — его режут реже всего.
#  - Порт 443:
#      • свободен                     → Xray слушает 443 сам;
#      • занят движком Комбайна (nginx) → Xray на 127.0.0.1:8444, движок отдаёт ему SNI маски (docs/DEV-PORTS.md).
#  - Свой бинарник и своя служба (kombain-xray), чужой xray на сервере не трогаем.
#  - Позже: вариант «свой домен + сайт-заглушка» (нужен домен).

VLS_VER="v26.2.6"   # как на Германии (3x-ui): с ней Hiddify дружит, с 26.9.30 — нет
VLS_URL="https://github.com/XTLS/Xray-core/releases/download/$VLS_VER/Xray-linux-64.zip"
VLS_BIN="/usr/local/lib/kombain/xray"
VLS_DIR="$KB_HOME/vless"
VLS_CONF="$VLS_DIR/config.json"
VLS_ENV="$VLS_DIR/env"
VLS_UNIT="/etc/systemd/system/kombain-xray.service"
VLS_INNER=8444
VLS_MAP_NAME="20-vless.map"
VLS_SNI_DEFAULT="www.yahoo.com"

vls_installed() { [ -r "$VLS_ENV" ] && [ -r "$VLS_CONF" ]; }
vls_running()   { systemctl is-active --quiet kombain-xray; }
vls_load_env()  { [ -r "$VLS_ENV" ] && . "$VLS_ENV"; }   # shellcheck disable=SC1090

# Вывод берём целиком: обрезка через head ломала проверку (pipefail + SIGPIPE у xray)
vls_bin_ok() {
  [ -x "$VLS_BIN" ] || return 1
  local v; v=$("$VLS_BIN" version 2>/dev/null) || return 1
  [[ "${v%%$'\n'*}" == "Xray ${VLS_VER#v} "* ]]
}

vls_get_bin() {
  vls_bin_ok && return 0
  [ "$(uname -m)" = "x86_64" ] || { err "VLESS пока только для обычных серверов (x86_64)."; return 1; }
  ensure_pkgs curl unzip jq openssl qrencode >/dev/null 2>&1 || return 1
  step "Скачиваю Xray $VLS_VER"
  local tmp want got; tmp=$(mktemp -d)
  if ! curl -fsSL --proto '=https' --max-time 180 --retry 2 "$VLS_URL" -o "$tmp/x.zip" \
     || ! curl -fsSL --proto '=https' --max-time 60 --retry 2 "$VLS_URL.dgst" -o "$tmp/x.dgst"; then
    err "Не скачалось с GitHub. Проверь интернет на сервере."; rm -rf "${tmp:?}"; return 1
  fi
  want=$(sed -n 's/^SHA2-256= *//p' "$tmp/x.dgst" | tr -d '\r ' | head -1)
  got=$(sha256sum "$tmp/x.zip" | cut -d' ' -f1)
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    err "Файл скачался битый — контрольная сумма не сходится. Не ставлю."; rm -rf "${tmp:?}"; return 1
  fi
  unzip -q -o "$tmp/x.zip" xray -d "$tmp" || { err "Архив не распаковался."; rm -rf "${tmp:?}"; return 1; }
  install -d -m 0755 "$(dirname "$VLS_BIN")"
  install -o root -g root -m 0755 "$tmp/xray" "$VLS_BIN"
  rm -rf "${tmp:?}"
  vls_bin_ok && ok "Xray $VLS_VER скачан и проверен" || { err "Xray не запускается."; return 1; }
}

# Кто держит 443: our-nginx | free | <имя программы>
vls_port443() {
  local o; o=$(port_owner 443 tcp)
  if [ -z "$o" ]; then echo free
  elif docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "kombain-nginx" && [ "$o" = "nginx" ]; then echo our-nginx
  else echo "$o"; fi
}

vls_unit() {
  cat >"$VLS_UNIT" <<EOF
[Unit]
Description=Xray VLESS Reality (Kombain)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
DynamicUser=yes
LoadCredential=config.json:$VLS_CONF
ExecStart=$VLS_BIN run -config \${CREDENTIALS_DIRECTORY}/config.json
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
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

# Конфиг Xray собирается из env + списка клиентов (clients.json: [{"name":..,"id":..}])
vls_write_conf() {
  local listen port
  if [ "$VLS_MODE" = "behind" ]; then listen="127.0.0.1"; port=$VLS_INNER; else listen="0.0.0.0"; port=443; fi
  ( umask 077
    jq -n --arg listen "$listen" --argjson port "$port" --arg sni "$VLS_SNI" --arg priv "$VLS_PRIV" \
      --arg sid "$VLS_SID" --slurpfile cl "$VLS_DIR/clients.json" '
    {
      log: {loglevel: "warning"},
      inbounds: [{
        listen: $listen, port: $port, protocol: "vless", tag: "vless",
        settings: {decryption: "none",
          clients: [$cl[0][] | {id, email: .name, flow: "xtls-rprx-vision"}]},
        streamSettings: {network: "tcp", security: "reality",
          realitySettings: {target: ($sni + ":443"), serverNames: [$sni], privateKey: $priv, shortIds: [$sid]}},
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}
      }],
      outbounds: [{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "block"}],
      routing: {rules: [{type: "field", outboundTag: "block",
        ip: ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
             "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10"]}]}
    }' >"$VLS_DIR/config.new.json"
  )
  if ! "$VLS_BIN" run -test -config "$VLS_DIR/config.new.json" >/dev/null 2>&1; then
    err "Xray не принял новый конфиг:"; "$VLS_BIN" run -test -config "$VLS_DIR/config.new.json" 2>&1 | tail -5
    rm -f "${VLS_DIR:?}/config.new.json"; return 1
  fi
  [ -f "$VLS_CONF" ] && cp -a "$VLS_CONF" "$VLS_CONF.bak"
  mv -f "$VLS_DIR/config.new.json" "$VLS_CONF"
}

vls_restart() {
  systemctl restart kombain-xray; sleep 1
  vls_running && return 0
  err "Xray не запустился. Подробности: journalctl -u kombain-xray -n 30"
  if [ -f "$VLS_CONF.bak" ]; then cp -a "$VLS_CONF.bak" "$VLS_CONF"; systemctl restart kombain-xray; warn "Вернула прошлый конфиг"; fi
  return 1
}

vls_save_env() {
  ( umask 077
    cat >"$VLS_ENV" <<EOF
VLS_PRIV='$VLS_PRIV'
VLS_PUB='$VLS_PUB'
VLS_SID='$VLS_SID'
VLS_SNI='$VLS_SNI'
VLS_MODE='$VLS_MODE'
VLS_ENDPOINT='$VLS_ENDPOINT'
EOF
  )
}

# Подключить Xray за движком: строка в карту SNI и перезагрузка nginx
vls_nginx_map() {
  local dir="$KB_HOME/aiproxy/nginx/sni.d"
  [ -d "$dir" ] || { err "Не нашла карту движка ($dir)."; return 1; }
  if grep -qiE "^\.?${VLS_SNI//./\\.}\b" "$KB_SRC/data/ai-domains.txt" 2>/dev/null; then
    err "Маска $VLS_SNI есть в списке нейронок — движок отправит её не туда. Выбери другую."; return 1
  fi
  printf '# VLESS Reality — генерирует Комбайн\n%s 127.0.0.1:%s;\n' "$VLS_SNI" "$VLS_INNER" >"$dir/$VLS_MAP_NAME"
  docker exec kombain-nginx nginx -t >/dev/null 2>&1 || { rm -f "${dir:?}/$VLS_MAP_NAME"; err "Движок не принял карту."; return 1; }
  docker exec kombain-nginx nginx -s reload >/dev/null 2>&1
  ok "Движок отдаёт $VLS_SNI в VLESS"
}

# Нейронки ставятся после VLESS: уводим Xray с 443 за будущий движок (его зовёт модуль нейронок).
vls_go_behind() {
  vls_installed || return 0
  vls_load_env
  [ "$VLS_MODE" = "behind" ] && return 0
  step "Переношу VLESS за движок: 443 займёт nginx"
  VLS_MODE=behind; vls_save_env
  vls_write_conf && vls_restart || return 1
  mkdir -p "$KB_HOME/aiproxy/nginx/sni.d"
  printf '# VLESS Reality — генерирует Комбайн\n%s 127.0.0.1:%s;\n' "$VLS_SNI" "$VLS_INNER" \
    >"$KB_HOME/aiproxy/nginx/sni.d/$VLS_MAP_NAME"
  ok "VLESS теперь внутри, на 127.0.0.1:$VLS_INNER"
}

vls_install_core() {
  vls_installed && { warn "VLESS уже установлен."; return 0; }
  local p443; p443=$(vls_port443)
  case "$p443" in
    free)      VLS_MODE=direct ;;
    our-nginx) VLS_MODE=behind
               [ -z "$(port_owner "$VLS_INNER" tcp)" ] || { err "Порт $VLS_INNER занят: $(port_owner "$VLS_INNER" tcp)"; return 1; } ;;
    *) err "Порт 443 занят программой «$p443» — это не Комбайн. Останови её или убери с 443 и запусти снова."; return 1 ;;
  esac

  vls_get_bin || return 1

  step "Настраиваю VLESS Reality"
  local keys
  keys=$("$VLS_BIN" x25519)
  VLS_PRIV=$(sed -n '1p' <<<"$keys" | awk '{print $NF}')
  VLS_PUB=$(sed -n '2p' <<<"$keys" | awk '{print $NF}')
  [ -n "$VLS_PRIV" ] && [ -n "$VLS_PUB" ] || { err "Xray не выдал ключи."; return 1; }
  VLS_SID=$(openssl rand -hex 8)
  VLS_SNI="${KB_VLS_SNI:-$VLS_SNI_DEFAULT}"
  VLS_ENDPOINT="${KB_SERVER_IP:-$(server_ip)}"
  [ -n "$VLS_ENDPOINT" ] || { err "Не узнала внешний IP сервера."; return 1; }

  mkdir -p "$VLS_DIR"; chmod 700 "$VLS_DIR"
  [ -f "$VLS_DIR/clients.json" ] || echo '[]' >"$VLS_DIR/clients.json"
  vls_save_env
  vls_write_conf || return 1
  vls_unit
  systemctl enable kombain-xray >/dev/null 2>&1
  vls_restart || return 1
  if [ "$VLS_MODE" = "behind" ]; then vls_nginx_map || return 1; fi
  ok "VLESS работает: $VLS_ENDPOINT:443, маска $VLS_SNI"

  fw_register vless "443/tcp"
  if ufw status 2>/dev/null | grep -q '^Status: active'; then fw_apply; fi
}

# ───────────────────────── клиенты ─────────────────────────

vls_valid_client() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; }
vls_clients() { jq -r '.[].name' "$VLS_DIR/clients.json" 2>/dev/null; }

vls_link() {
  local name="$1" id
  vls_load_env
  id=$(jq -r --arg n "$name" '.[] | select(.name==$n) | .id' "$VLS_DIR/clients.json")
  [ -n "$id" ] || return 1
  printf 'vless://%s@%s:443?encryption=none&flow=xtls-rprx-vision&security=reality&sni=%s&fp=chrome&pbk=%s&sid=%s&type=tcp#%s' \
    "$id" "$VLS_ENDPOINT" "$VLS_SNI" "$VLS_PUB" "$VLS_SID" "$name"
}

vls_add_client() {
  local name="$1" id
  vls_valid_client "$name" || { err "Имя: маленькие латинские буквы, цифры и дефис. Пример: vasya-phone"; return 1; }
  vls_clients | grep -qx "$name" && { err "Устройство $name уже есть."; return 1; }
  vls_load_env
  id=$("$VLS_BIN" uuid)
  cp -a "$VLS_DIR/clients.json" "$VLS_DIR/clients.json.bak"
  jq --arg n "$name" --arg id "$id" '. + [{name: $n, id: $id}]' "$VLS_DIR/clients.json.bak" >"$VLS_DIR/clients.json"
  if ! { vls_write_conf && vls_restart; }; then
    cp -a "$VLS_DIR/clients.json.bak" "$VLS_DIR/clients.json"; return 1
  fi
  ok "Устройство $name добавлено"
}

vls_remove_client() {
  local name="$1"
  vls_valid_client "$name" && vls_clients | grep -qx "$name" || { err "Нет такого устройства: $name"; return 1; }
  vls_load_env
  cp -a "$VLS_DIR/clients.json" "$VLS_DIR/clients.json.bak"
  jq --arg n "$name" 'map(select(.name != $n))' "$VLS_DIR/clients.json.bak" >"$VLS_DIR/clients.json"
  vls_write_conf && vls_restart || return 1
  ok "Устройство $name удалено"
}

vls_show_client() {
  local link; link=$(vls_link "$1") || { err "Нет такого устройства: $1"; return 1; }
  qrencode -t ANSIUTF8 -m 1 "$link" 2>/dev/null
  echo; echo "$link"; echo
  say "Приложение: Hiddify или Amnezia VPN → «+» → вставить из буфера или сканировать QR."
}

# ───────────────────────── обслуживание ─────────────────────────

vls_status() {
  vls_installed || { warn "VLESS не установлен."; return 0; }
  vls_load_env
  step "Состояние VLESS"
  vls_running && ok "Xray работает ($("$VLS_BIN" version | head -1 | cut -d' ' -f1-2))" || err "Xray не запущен"
  if [ "$VLS_MODE" = "behind" ]; then say "Режим: за движком Комбайна, внутри 127.0.0.1:$VLS_INNER"
  else say "Режим: сам на 443"; fi
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$VLS_SNI:443:127.0.0.1" "https://$VLS_SNI/")
  if [ "$code" != "000" ]; then ok "Маска отвечает как настоящий $VLS_SNI (код $code)"
  else err "Маска не отвечает — сервер без ключа выглядит странно"; fi
  say "Устройства: $(vls_clients | tr '\n' ' ')"
}

vls_remove_core() {
  vls_installed || { warn "VLESS не установлен."; return 0; }
  systemctl disable --now kombain-xray >/dev/null 2>&1
  rm -f /etc/systemd/system/kombain-xray.service "${KB_HOME:?}/aiproxy/nginx/sni.d/20-vless.map"
  systemctl daemon-reload
  docker exec kombain-nginx nginx -s reload >/dev/null 2>&1
  rm -rf "${KB_HOME:?}/vless"
  fw_unregister vless
  ok "VLESS удалён"
}

# ───────────────────────── меню и команды ─────────────────────────

vls_menu() {
  while true; do
    cat <<EOF

${C_BOLD}══ VLESS Reality ══${C_RESET}
 1) Установить (маска $VLS_SNI_DEFAULT)
 2) Добавить устройство
 3) Показать устройство (QR и ссылка)
 4) Состояние
 5) Удалить устройство
 6) Удалить VLESS
 0) Назад
EOF
    case "$(ask "Выбор")" in
      1) vls_install_core ;;
      2) local n; n=$(ask "Имя устройства (латиницей, например vasya-phone)" | tr 'A-Z' 'a-z'); vls_add_client "$n" && vls_show_client "$n" ;;
      3) say "Устройства: $(vls_clients | tr '\n' ' ')"; vls_show_client "$(ask "Какое")" ;;
      4) vls_status ;;
      5) say "Устройства: $(vls_clients | tr '\n' ' ')"; vls_remove_client "$(ask "Какое удалить")" ;;
      6) confirm "Удалить VLESS? Все устройства отключатся." && vls_remove_core ;;
      0) return ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

# kombain cli vless <команда>
vls_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    info)
      if vls_installed; then
        vls_load_env
        jq -nc --arg ip "$VLS_ENDPOINT" --arg sni "$VLS_SNI" --arg mode "$VLS_MODE" \
          --argjson run "$(vls_running && echo true || echo false)" --argjson c "$(jq -c '[.[].name]' "$VLS_DIR/clients.json")" \
          '{installed:true, running:$run, endpoint:$ip, sni:$sni, mode:$mode, clients:$c}'
      else
        jq -nc '{installed:false}'
      fi ;;
    install)    vls_install_core ;;
    add-client) vls_installed || { err "VLESS не установлен"; return 1; }; vls_add_client "${1:-}" ;;
    rm-client)  vls_installed || return 1; vls_remove_client "${1:?имя}" ;;
    link)       vls_valid_client "${1:-}" && vls_link "$1" || { err "Нет такого устройства"; return 1; } ;;
    qr-png)     local l; l=$(vls_valid_client "${1:-}" && vls_link "$1") || { err "Нет такого устройства"; return 1; }
                qrencode -t PNG -s 6 -m 2 -o - "$l" ;;
    status)     vls_status ;;
    remove)     vls_remove_core ;;
    *) err "Неизвестная команда: $cmd"; return 2 ;;
  esac
}
