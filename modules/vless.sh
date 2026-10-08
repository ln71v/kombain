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
#  - Свой домен (домен и ключ Cloudflare из сейфа): маска — твой домен, за ней настоящий сайт-заглушка
#    с настоящим сертификатом (Caddy на 127.0.0.1:8080, сертификат certbot через Cloudflare, порт 80 не нужен).

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

# Сайт-заглушка для своего домена
VLS_CADDY_VER="v2.10.2"
VLS_CADDY_URL="https://github.com/caddyserver/caddy/releases/download/$VLS_CADDY_VER/caddy_${VLS_CADDY_VER#v}_linux_amd64.tar.gz"
VLS_CADDY_SUMS="https://github.com/caddyserver/caddy/releases/download/$VLS_CADDY_VER/caddy_${VLS_CADDY_VER#v}_checksums.txt"
VLS_CADDY="/usr/local/lib/kombain/caddy"
VLS_SITE="/usr/local/share/kombain-site"   # не секрет: страница и Caddyfile, читает служба без прав root
VLS_SITE_PORT=8080
VLS_SITE_UNIT="/etc/systemd/system/kombain-site.service"
VLS_LE="/etc/letsencrypt"

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
  elif grep -qx "kombain-nginx" <<<"$(docker ps --format '{{.Names}}' 2>/dev/null)" && [ "$o" = "nginx" ]; then echo our-nginx
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
# NET_ADMIN — чтобы ставить метку WARP (sockopt mark); без него метка молча не ставится
AmbientCapabilities=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
CapabilityBoundingSet=CAP_NET_BIND_SERVICE CAP_NET_ADMIN
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
  # Кому WARP: имена из $KB_HOME/warp/users (модуль warp). Нет WARP — пустой список.
  local warp_on=false warp_users='[]'
  if [ -r "$KB_HOME/warp/warp.conf" ]; then
    warp_on=true
    warp_users=$(awk '$1=="vless"{print $2}' "$KB_HOME/warp/users" 2>/dev/null | jq -R . | jq -sc .)
  fi
  ( umask 077
    jq -n --arg listen "$listen" --argjson port "$port" --arg sni "$VLS_SNI" --arg priv "$VLS_PRIV" \
      --arg target "${VLS_TARGET:-$VLS_SNI:443}" \
      --arg sid "$VLS_SID" --slurpfile cl "$VLS_DIR/clients.json" \
      --argjson warp "$warp_on" --argjson wu "$warp_users" '
    {
      log: {loglevel: "warning"},
      inbounds: [{
        listen: $listen, port: $port, protocol: "vless", tag: "vless",
        settings: {decryption: "none",
          clients: [$cl[0][] | {id, email: .name, flow: "xtls-rprx-vision"}]},
        streamSettings: {network: "tcp", security: "reality",
          realitySettings: {target: $target, serverNames: [$sni], privateKey: $priv, shortIds: [$sid]}},
        sniffing: {enabled: true, destOverride: ["http", "tls", "quic"]}
      }],
      outbounds: ([{protocol: "freedom", tag: "direct"}, {protocol: "blackhole", tag: "block"}]
        + (if $warp then [{protocol: "freedom", tag: "warp",
             settings: {domainStrategy: "UseIPv4"}, streamSettings: {sockopt: {mark: 119}}}] else [] end)),
      routing: {rules: ([{type: "field", outboundTag: "block",
        ip: ["0.0.0.0/8", "10.0.0.0/8", "100.64.0.0/10", "127.0.0.0/8", "169.254.0.0/16",
             "172.16.0.0/12", "192.168.0.0/16", "::1/128", "fc00::/7", "fe80::/10"]}]
        + ([$cl[0][].name] as $all | ($wu | map(select(. as $u | $all | index($u)))) as $u
           | if $warp and ($u | length) > 0 then [{type: "field", user: $u, outboundTag: "warp"}] else [] end))}
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
VLS_TARGET='${VLS_TARGET:-}'
VLS_DOMAIN='${VLS_DOMAIN:-}'
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
  if grep -q '^Status: active' <<<"$(ufw status 2>/dev/null)"; then fw_apply; fi

  # В сейфе есть домен и ключ Cloudflare — сразу свой домен; не вышло — остаёмся на маске
  if [ -n "$(sec_domain)" ] && [ -n "$(sec_cf_token)" ]; then
    vls_domain_on || warn "Свой домен не включился — VLESS работает на маске $VLS_SNI_DEFAULT. Можно включить позже."
  fi
}

# ───────────────────────── свой домен + сайт-заглушка ─────────────────────────
# Снаружи: <домен>:443 с настоящим сертификатом и обычным сайтом. Xray (Reality) без ключа
# отдаёт всё сайту на 127.0.0.1:8080, с ключом — VPN. Домен и ключ Cloudflare берём из сейфа.

vls_caddy_ok() {
  [ -x "$VLS_CADDY" ] || return 1
  local v; v=$("$VLS_CADDY" version 2>/dev/null) || return 1
  [[ "$v" == "$VLS_CADDY_VER "* ]]
}

vls_get_caddy() {
  vls_caddy_ok && return 0
  ensure_pkgs curl tar >/dev/null 2>&1 || return 1
  step "Скачиваю Caddy $VLS_CADDY_VER (сервер для сайта-заглушки)"
  local tmp want got f="caddy_${VLS_CADDY_VER#v}_linux_amd64.tar.gz"; tmp=$(mktemp -d)
  if ! curl -fsSL --proto '=https' --max-time 180 --retry 2 "$VLS_CADDY_URL" -o "$tmp/c.tgz" \
     || ! curl -fsSL --proto '=https' --max-time 60 --retry 2 "$VLS_CADDY_SUMS" -o "$tmp/sums"; then
    err "Caddy не скачался с GitHub."; rm -rf "${tmp:?}"; return 1
  fi
  want=$(awk -v f="$f" '$2==f {print $1}' "$tmp/sums")
  got=$(sha512sum "$tmp/c.tgz" | cut -d' ' -f1)
  if [ -z "$want" ] || [ "$want" != "$got" ]; then
    err "Caddy скачался битый — контрольная сумма не сходится. Не ставлю."; rm -rf "${tmp:?}"; return 1
  fi
  tar -xzf "$tmp/c.tgz" -C "$tmp" caddy || { err "Архив Caddy не распаковался."; rm -rf "${tmp:?}"; return 1; }
  install -d -m 0755 "$(dirname "$VLS_CADDY")"
  install -o root -g root -m 0755 "$tmp/caddy" "$VLS_CADDY"
  rm -rf "${tmp:?}"
  vls_caddy_ok && ok "Caddy $VLS_CADDY_VER скачан и проверен" || { err "Caddy не запускается."; return 1; }
}

# Сертификат на домен: certbot через Cloudflare (DNS-01), порт 80 не нужен. Продлевает certbot.timer.
vls_cert() {
  local host="$1" live="$VLS_LE/live/$1/fullchain.pem" out
  if [ -r "$live" ] && openssl x509 -checkend 2592000 -noout -in "$live" >/dev/null 2>&1 \
     && grep -q "DNS:$host" <<<"$(openssl x509 -noout -ext subjectAltName -in "$live" 2>/dev/null)"; then
    ok "Сертификат на $host уже есть"; return 0
  fi
  ensure_pkgs certbot python3-certbot-dns-cloudflare >/dev/null 2>&1 \
    || { err "Не поставился certbot (программа для сертификатов)."; return 1; }
  step "Получаю сертификат на $host (это до минуты)"
  if out=$(certbot certonly --non-interactive --agree-tos --register-unsafely-without-email \
        --dns-cloudflare --dns-cloudflare-credentials "$KB_CF_FILE" --dns-cloudflare-propagation-seconds 30 \
        --cert-name "$host" -d "$host" --keep-until-expiring \
        --deploy-hook "systemctl try-restart kombain-site" 2>&1); then
    ok "Сертификат получен, продлевается сам"
  else
    err "Сертификат не получен:"; tail -8 <<<"$out"
    say "Частые причины: ключ Cloudflare сделан для другого домена или домен ещё не Active в Cloudflare."
    return 1
  fi
  systemctl enable --now certbot.timer >/dev/null 2>&1 || true
}

vls_site_write() {
  local host="$1" title
  title="${host%%.*}"; title="${title^}"
  install -d -m 0755 "$VLS_SITE" "$VLS_SITE/www"
  if [ ! -f "$VLS_SITE/www/index.html" ]; then   # свою страницу не перетираем
    local d1 d2 d3
    d1=$(date -d "-$((9 + RANDOM % 20)) days" +%d.%m.%Y); d2=$(date -d "-$((40 + RANDOM % 30)) days" +%d.%m.%Y)
    d3=$(date -d "-$((90 + RANDOM % 60)) days" +%d.%m.%Y)
    sed -e "s|{{TITLE}}|$title|g" -e "s|{{YEAR}}|$(date +%Y)|g" \
        -e "s|{{D1}}|$d1|" -e "s|{{D2}}|$d2|" -e "s|{{D3}}|$d3|" "$KB_SRC/data/site/index.html" >"$VLS_SITE/www/index.html"
    chmod 0644 "$VLS_SITE/www/index.html"
  fi
  cat >"$VLS_SITE/Caddyfile" <<EOF
# Сайт-заглушка VLESS — генерирует Комбайн. Страница: $VLS_SITE/www
{
	admin off
	auto_https off
	persist_config off
	default_sni $host
	servers {
		protocols h1 h2
	}
}

https://$host:$VLS_SITE_PORT {
	bind 127.0.0.1
	tls {\$CREDENTIALS_DIRECTORY}/fullchain.pem {\$CREDENTIALS_DIRECTORY}/privkey.pem
	root * $VLS_SITE/www
	encode gzip
	file_server
	header -Server
}
EOF
  chmod 0644 "$VLS_SITE/Caddyfile"
  cat >"$VLS_SITE_UNIT" <<EOF
[Unit]
Description=Сайт-заглушка VLESS (Kombain)
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
DynamicUser=yes
StateDirectory=kombain-site
Environment=HOME=/var/lib/kombain-site XDG_DATA_HOME=/var/lib/kombain-site XDG_CONFIG_HOME=/var/lib/kombain-site
LoadCredential=fullchain.pem:$VLS_LE/live/$host/fullchain.pem
LoadCredential=privkey.pem:$VLS_LE/live/$host/privkey.pem
ExecStart=$VLS_CADDY run --config $VLS_SITE/Caddyfile --adapter caddyfile
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  CREDENTIALS_DIRECTORY="$VLS_LE/live/$host" "$VLS_CADDY" validate --config "$VLS_SITE/Caddyfile" \
    --adapter caddyfile >/dev/null 2>&1 || { err "Caddy не принял настройки сайта."; return 1; }
}

# Отвечает ли сайт по-настоящему: правильный сертификат и код 200. $2 — порт (8080 или 443).
vls_site_check() {
  local code
  code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 8 \
    --resolve "$1:$2:127.0.0.1" "https://$1:$2/")
  [ "$code" = "200" ]
}

vls_domain_on() {
  vls_installed || { err "VLESS не установлен."; return 1; }
  vls_load_env
  local host token ip old_env
  host=$(sec_domain); token=$(sec_cf_token)
  [ -n "$host" ] && [ -n "$token" ] || { err "Сначала заполни сейф: домен и ключ Cloudflare."; return 1; }
  if [ "${VLS_DOMAIN:-}" = "$host" ] && vls_running && vls_site_check "$host" "$VLS_SITE_PORT"; then
    ok "VLESS уже работает на своём домене $host"; return 0
  fi
  if grep -qiE "^\.?${host//./\\.}$" "$KB_SRC/data/ai-domains.txt" 2>/dev/null; then
    err "Домен $host есть в списке нейронок — так нельзя."; return 1
  fi
  local o; o=$(port_owner "$VLS_SITE_PORT" tcp)
  [ -z "$o" ] || [ "$o" = "caddy" ] || { err "Порт $VLS_SITE_PORT занят программой «$o»."; return 1; }
  ip="$VLS_ENDPOINT"

  step "Запись $host в Cloudflare"
  sec_cf_records "$host" "$ip" "" only
  case $? in
    0) ;;
    3) err "Имя $host в Cloudflare смотрит на другой сервер. Поправь запись на $ip или впиши в сейф другой домен."; return 1 ;;
    *) return 1 ;;
  esac

  vls_cert "$host" || return 1
  vls_get_caddy || return 1
  step "Запускаю сайт-заглушку"
  vls_site_write "$host" || return 1
  systemctl enable kombain-site >/dev/null 2>&1
  systemctl restart kombain-site; sleep 2
  vls_site_check "$host" "$VLS_SITE_PORT" \
    || { err "Сайт-заглушка не отвечает. Подробности: journalctl -u kombain-site -n 30"; return 1; }
  ok "Сайт-заглушка работает"

  step "Переключаю VLESS на $host"
  old_env=$(cat "$VLS_ENV")
  VLS_SNI="$host"; VLS_TARGET="127.0.0.1:$VLS_SITE_PORT"; VLS_DOMAIN="$host"
  vls_save_env
  if ! { vls_write_conf && vls_restart && { [ "$VLS_MODE" != "behind" ] || vls_nginx_map; }; }; then
    printf '%s\n' "$old_env" >"$VLS_ENV"; vls_load_env; vls_write_conf && vls_restart
    [ "$VLS_MODE" = "behind" ] && vls_nginx_map >/dev/null 2>&1
    err "Не переключилось — вернула как было."; return 1
  fi
  sleep 1
  if vls_site_check "$host" 443; then ok "Снаружи на 443 — твой сайт с настоящим сертификатом"
  else warn "Сайт через 443 не ответил. Посмотри «Состояние»."; fi
  ok "VLESS на своём домене $host"
  warn "Ключи у всех устройств поменялись — пришли каждому новый QR."
}

vls_domain_off() {
  vls_installed || { err "VLESS не установлен."; return 1; }
  vls_load_env
  [ -n "${VLS_DOMAIN:-}" ] || { ok "VLESS и так на маске $VLS_SNI"; return 0; }
  VLS_SNI="$VLS_SNI_DEFAULT"; VLS_TARGET=""; VLS_DOMAIN=""
  vls_save_env
  vls_write_conf && vls_restart || return 1
  if [ "$VLS_MODE" = "behind" ]; then vls_nginx_map || return 1; fi
  systemctl disable --now kombain-site >/dev/null 2>&1
  ok "VLESS снова на маске $VLS_SNI. Сертификат оставила — пригодится, если вернёшься."
  warn "Ключи у всех устройств поменялись — пришли каждому новый QR."
}

vls_site_remove() {
  systemctl disable --now kombain-site >/dev/null 2>&1
  rm -f "$VLS_SITE_UNIT"; systemctl daemon-reload
  rm -rf "${VLS_SITE:?}"
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
  grep -qx "$name" <<<"$(vls_clients)" && { err "Устройство $name уже есть."; return 1; }
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
  vls_valid_client "$name" && grep -qx "$name" <<<"$(vls_clients)" || { err "Нет такого устройства: $name"; return 1; }
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
  if [ -n "${VLS_DOMAIN:-}" ]; then
    say "Маска: свой домен $VLS_DOMAIN, за ним сайт-заглушка"
    systemctl is-active --quiet kombain-site && ok "Сайт-заглушка работает" || err "Сайт-заглушка не запущена (kombain-site)"
    local crt="$VLS_LE/live/$VLS_DOMAIN/fullchain.pem"
    [ -r "$crt" ] && ok "Сертификат до: $(openssl x509 -enddate -noout -in "$crt" | cut -d= -f2)"
    if vls_site_check "$VLS_DOMAIN" 443; then ok "Снаружи без ключа — твой сайт с настоящим сертификатом"
    else err "Без ключа сайт не открывается — сервер выглядит странно"; fi
  else
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 --resolve "$VLS_SNI:443:127.0.0.1" "https://$VLS_SNI/")
    if [ "$code" != "000" ]; then ok "Маска отвечает как настоящий $VLS_SNI (код $code)"
    else err "Маска не отвечает — сервер без ключа выглядит странно"; fi
  fi
  say "Устройства: $(vls_clients | tr '\n' ' ')"
}

vls_remove_core() {
  vls_installed || { warn "VLESS не установлен."; return 0; }
  vls_load_env
  vls_site_remove
  if [ -n "${VLS_DOMAIN:-}" ] && command -v certbot >/dev/null 2>&1; then
    certbot delete --non-interactive --cert-name "$VLS_DOMAIN" >/dev/null 2>&1 || true
  fi
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
 7) Свой домен + сайт-заглушка (домен и ключ Cloudflare из сейфа)
 8) Вернуть маску $VLS_SNI_DEFAULT
 0) Назад
EOF
    case "$(ask "Выбор")" in
      1) vls_install_core ;;
      2) local n; n=$(ask "Имя устройства (латиницей, например vasya-phone)" | tr 'A-Z' 'a-z'); vls_add_client "$n" && vls_show_client "$n" ;;
      3) say "Устройства: $(vls_clients | tr '\n' ' ')"; vls_show_client "$(ask "Какое")" ;;
      4) vls_status ;;
      5) say "Устройства: $(vls_clients | tr '\n' ' ')"; vls_remove_client "$(ask "Какое удалить")" ;;
      6) confirm "Удалить VLESS? Все устройства отключатся." && vls_remove_core ;;
      7) confirm "Переключить на свой домен? Ключи у всех устройств поменяются." && vls_domain_on ;;
      8) confirm "Вернуть маску? Ключи у всех устройств поменяются." && vls_domain_off ;;
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
        jq -nc --arg ip "$VLS_ENDPOINT" --arg sni "$VLS_SNI" --arg mode "$VLS_MODE" --arg dom "${VLS_DOMAIN:-}" \
          --argjson run "$(vls_running && echo true || echo false)" --argjson c "$(jq -c '[.[].name]' "$VLS_DIR/clients.json")" \
          '{installed:true, running:$run, endpoint:$ip, sni:$sni, mode:$mode, domain:$dom, clients:$c}'
      else
        jq -nc --arg d "$(sec_domain)" --argjson cf "$([ -n "$(sec_cf_token)" ] && echo true || echo false)" \
          '{installed:false, safe_domain:$d, safe_cf:$cf}'
      fi ;;
    install)    vls_install_core ;;
    update-bin) vls_installed || { err "VLESS не установлен"; return 1; }
                vls_get_bin && vls_restart && ok "Xray обновлён до $VLS_VER, ключи прежние" ;;
    add-client) vls_installed || { err "VLESS не установлен"; return 1; }; vls_add_client "${1:-}" ;;
    rm-client)  vls_installed || return 1; vls_remove_client "${1:?имя}" ;;
    link)       vls_valid_client "${1:-}" && vls_link "$1" || { err "Нет такого устройства"; return 1; } ;;
    qr-png)     local l; l=$(vls_valid_client "${1:-}" && vls_link "$1") || { err "Нет такого устройства"; return 1; }
                qrencode -t PNG -s 6 -m 2 -o - "$l" ;;
    status)     vls_status ;;
    domain-on)  vls_domain_on ;;
    domain-off) vls_domain_off ;;
    remove)     vls_remove_core ;;
    *) err "Неизвестная команда: $cmd"; return 2 ;;
  esac
}
