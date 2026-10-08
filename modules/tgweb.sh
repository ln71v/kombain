#!/usr/bin/env bash
# Модуль «Telegram WEB-прокси» — новый вид прокси Telegram (t.me/webproxy).
# Поток Telegram идёт по HTTPS на обычный сайт tg.<домен>, снаружи — просто сайт.
#
# Как устроено (официальные части Telegram, версии закреплены):
#   Telegram → 443 (Xray VLESS, чужой SNI) → сайт-заглушка Комбайна (Caddy) → tg.<домен>
#            → tproxy-server 127.0.0.1:8080 → официальный MTProxy 127.0.0.1:2398 → Telegram
# Порты 8080, 8081 (служебный), 2398, 8888 — жёстко заданы в официальных файлах.
# Нужно: домен и ключ Cloudflare в сейфе, VLESS на своём домене (он держит вход 443).
# Сборка из исходников: Go + MTProxy, ~1,5 ГБ на диске, 5–10 минут.
# Звонков нет — как у любого Telegram-прокси.

TGW_REPO="https://github.com/telegramdesktop/tproxy-server"
TGW_COMMIT="c8adb8b7c6b7fc46c12ae3acb68be9070c26a8e8"
TGW_GO_VER="1.26.5"
TGW_GO_SUM="5c2c3b16caefa1d968a94c1daca04a7ca301a496d9b086e17ad77bb81393f053"
TGW_SRC="/opt/tproxy-server-src"
TGW_CONF="/etc/tproxy-server"
TGW_PORTS="8080 8081 2398 8888"
TGW_UNITS="tproxy-server mtproxy tproxy-firewall refresh-mtproxy-config"
TGW_SNIPPET_NAME="tgweb"
TGW_MAP_NAME="25-tgweb.map"

tgw_host()      { local d; d=$(sec_domain); [ -n "$d" ] && echo "tg.$d"; }
tgw_installed() { [ -r "$TGW_CONF/config.json" ] && [ -f "$VLS_SITE/$TGW_SNIPPET_NAME.caddy" ]; }
tgw_running()   { systemctl is-active --quiet tproxy-server && systemctl is-active --quiet mtproxy; }
tgw_secret()    { sed -n 's/.*"secret":"\([0-9a-f]*\)".*/\1/p' "$TGW_CONF/profiles.json" 2>/dev/null | head -1; }
tgw_conf_host() { sed -n 's/.*"public_hostname"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TGW_CONF/config.json" 2>/dev/null; }

tgw_link() {
  local h s; h=$(tgw_conf_host); s=$(tgw_secret)
  [ -n "$h" ] && [ -n "$s" ] || return 1
  printf 'https://t.me/webproxy?server=%s&secret=%s' "$h" "$s"
}

# Что мешает поставить. Печатает причину, 0 — можно.
tgw_check() {
  [ "$(uname -m)" = "x86_64" ] || { err "Официальный MTProxy собирается только на обычных серверах (x86_64)."; return 1; }
  [ -n "$(sec_domain)" ] && [ -n "$(sec_cf_token)" ] || { err "Нужны домен и ключ Cloudflare в сейфе."; return 1; }
  local free p o
  free=$(df -Pm / | awk 'NR==2 {print $4}')
  [ "${free:-0}" -ge 1500 ] || { err "Мало места на диске: свободно ${free} МБ, нужно 1500."; return 1; }
  for p in $TGW_PORTS; do
    o=$(port_owner "$p" tcp)
    case "$o" in ""|tproxy-server|mtproto-proxy) ;;   # свободен или уже наш WEB-прокси
      *) err "Порт $p занят программой «$o». WEB-прокси нужны ровно 8080, 8081, 2398, 8888."; return 1 ;;
    esac
  done
}

tgw_go() {
  local g minor
  if command -v go >/dev/null 2>&1; then
    minor=$(go env GOVERSION 2>/dev/null | sed -E 's/^go1\.([0-9]+).*/\1/')
    [[ "$minor" =~ ^[0-9]+$ ]] && [ "$minor" -ge 20 ] && { command -v go; return 0; }
  fi
  g="/opt/go$TGW_GO_VER/bin/go"
  if [ ! -x "$g" ]; then
    step "Скачиваю Go $TGW_GO_VER (нужен только для сборки)" >&2
    local tmp; tmp=$(mktemp -d)
    curl -fsSL --proto '=https' --max-time 600 --retry 2 "https://go.dev/dl/go$TGW_GO_VER.linux-amd64.tar.gz" -o "$tmp/go.tgz" \
      || { err "Go не скачался." >&2; rm -rf "${tmp:?}"; return 1; }
    [ "$(sha256sum "$tmp/go.tgz" | cut -d' ' -f1)" = "$TGW_GO_SUM" ] \
      || { err "Go скачался битый — контрольная сумма не сходится." >&2; rm -rf "${tmp:?}"; return 1; }
    tar -C "$tmp" -xzf "$tmp/go.tgz" && mv "$tmp/go" "/opt/go$TGW_GO_VER"
    rm -rf "${tmp:?}"
  fi
  [ -x "$g" ] && echo "$g"
}

tgw_build() {
  ensure_pkgs git curl openssl nftables ca-certificates >/dev/null 2>&1 || { err "Не поставились пакеты."; return 1; }
  step "Беру исходники tproxy-server (коммит ${TGW_COMMIT:0:7})"
  if [ ! -d "$TGW_SRC/.git" ]; then
    git clone --quiet "$TGW_REPO" "$TGW_SRC" || { err "Исходники не скачались с GitHub."; return 1; }
  fi
  git -C "$TGW_SRC" fetch --quiet origin 2>/dev/null || true
  git -C "$TGW_SRC" -c advice.detachedHead=false checkout --quiet --force "$TGW_COMMIT" \
    && [ "$(git -C "$TGW_SRC" rev-parse HEAD)" = "$TGW_COMMIT" ] || { err "Не тот коммит исходников."; return 1; }

  step "Собираю официальный MTProxy (пара минут)"
  local out
  out=$(bash "$TGW_SRC/deploy/install-mtproxy.sh" 2>&1) || { err "MTProxy не собрался:"; tail -10 <<<"$out"; return 1; }
  ok "MTProxy собран"

  local go; go=$(tgw_go) || return 1
  id tproxy >/dev/null 2>&1 || useradd --system --home /nonexistent --shell /usr/sbin/nologin tproxy
  step "Собираю tproxy-server (несколько минут)"
  # бот работает как служба без HOME — Go нужны свои папки для кэша
  out=$(cd "$TGW_SRC" && HOME=/root GOCACHE=/var/cache/kombain-go/build GOPATH=/var/cache/kombain-go/path \
        GOTOOLCHAIN=local "$go" build -trimpath -ldflags='-s -w' -o /usr/local/bin/tproxy-server.new ./cmd/tproxy-server 2>&1) \
    || { err "tproxy-server не собрался:"; tail -10 <<<"$out"; return 1; }
  install -o root -g root -m 0755 /usr/local/bin/tproxy-server.new /usr/local/bin/tproxy-server
  rm -f /usr/local/bin/tproxy-server.new
  ok "tproxy-server собран"
}

# Настройки ретранслятора. Секрет и base_path прошлой установки сохраняем — старая ссылка живёт.
tgw_configure() {
  local host="$1" secret base=""
  secret=$(tgw_secret)
  [[ "$secret" =~ ^[0-9a-f]{32}$ ]] || secret=$(openssl rand -hex 16)
  [ -r "$TGW_CONF/config.json" ] && \
    base=$(sed -n 's/.*"base_path"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TGW_CONF/config.json" | head -1)

  # Сайт, который ретранслятор показывает на tg.<домен> без ключа — тот же блог
  if [ ! -f /srv/tproxy-site/index.html ]; then
    install -d -o root -g root -m 0755 /srv/tproxy-site
    cp -a "$VLS_SITE/www/." /srv/tproxy-site/
    find /srv/tproxy-site -type d -exec chmod 0755 {} +; find /srv/tproxy-site -type f -exec chmod 0644 {} +
  fi

  install -d -o root -g tproxy -m 0750 "$TGW_CONF"
  ( umask 077; bash "$TGW_SRC/deploy/ensure-token-key.sh" ) || { err "Не создался ключ ретранслятора."; return 1; }
  ( umask 077
    cat >"$TGW_CONF/config.json" <<EOF
{
  "public_hostname": "$host",
  "base_path": "$base",
  "listen": "127.0.0.1:8080",
  "admin_listen": "127.0.0.1:8081",
  "public_dir": "/srv/tproxy-site",
  "static_routes": "exact",
  "profiles_file": "/run/credentials/tproxy-server.service/profiles.json"
}
EOF
    printf '{"profiles":[{"name":"default","secret":"%s","backend":"127.0.0.1:2398"}]}\n' "$secret" >"$TGW_CONF/profiles.json"
  )
  chown root:tproxy "$TGW_CONF/config.json" "$TGW_CONF/profiles.json"
  chmod 0640 "$TGW_CONF/config.json"; chmod 0400 "$TGW_CONF/profiles.json"

  # MTProxy за NAT должен знать свой внешний адрес, иначе молча не отвечает
  local lip pip nat=""
  lip=$(ip -4 route get 149.154.175.50 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p' | head -1)
  pip=$(server_ip)
  [ -n "$lip" ] && [ -n "$pip" ] && [ "$lip" != "$pip" ] && nat="--nat-info $lip:$pip"
  ( umask 077
    printf 'MTPROXY_SECRET=%s\nMTPROXY_WORKERS=1\nMTPROXY_MAX_CONNECTIONS=4096\nMTPROXY_NAT_ARGS=%s\n' "$secret" "$nat" >/etc/mtproxy/mtproxy.env )
  chown root:mtproxy /etc/mtproxy/mtproxy.env; chmod 0640 /etc/mtproxy/mtproxy.env

  # Официальные службы и файрвол (2398 и 8888 снаружи закрыты) — файлы как есть
  install -m 0644 "$TGW_SRC/deploy/firewall.nft" "$TGW_CONF/firewall.nft"
  local u
  for u in tproxy-server.service mtproxy.service tproxy-firewall.service \
           refresh-mtproxy-config.service refresh-mtproxy-config.timer; do
    install -m 0644 "$TGW_SRC/deploy/$u" "/etc/systemd/system/$u"
  done
  install -m 0755 "$TGW_SRC/deploy/refresh-mtproxy-config.sh" /usr/local/sbin/refresh-mtproxy-config
  /usr/local/bin/tproxy-server -config "$TGW_CONF/config.json" -profiles-file "$TGW_CONF/profiles.json" -check >/dev/null 2>&1 \
    || { err "tproxy-server не принял настройки."; return 1; }
}

tgw_start() {
  systemctl daemon-reload
  systemctl enable --now tproxy-firewall.service >/dev/null 2>&1
  systemctl enable mtproxy.service tproxy-server.service refresh-mtproxy-config.timer >/dev/null 2>&1
  systemctl restart mtproxy.service tproxy-server.service
  systemctl start refresh-mtproxy-config.timer
  local i
  for i in $(seq 20); do
    curl --noproxy '*' -fs -o /dev/null --max-time 3 http://127.0.0.1:8081/readyz && { ok "Ретранслятор готов"; return 0; }
    sleep 1
  done
  err "Ретранслятор не поднялся: journalctl -u tproxy-server -u mtproxy -n 50"; return 1
}

# Кусок для сайта-заглушки: tg.<домен> → ретранслятор (как официальный Caddyfile)
tgw_site_snippet() {
  local host="$1"
  cat >"$VLS_SITE/$TGW_SNIPPET_NAME.caddy" <<EOF
# Telegram WEB-прокси — генерирует Комбайн (модуль tgweb)
https://$host:$VLS_SITE_PORT {
	bind 127.0.0.1
	tls {\$CREDENTIALS_DIRECTORY}/tg-fullchain.pem {\$CREDENTIALS_DIRECTORY}/tg-privkey.pem
	encode zstd gzip
	header {
		-Via
		-Server
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
	}
	reverse_proxy 127.0.0.1:8080 {
		flush_interval -1
		transport http {
			response_header_timeout 40s
		}
	}
	handle_errors {
		header Cache-Control "no-store"
		respond "{http.error.status_code} {http.error.status_text}" {http.error.status_code}
	}
}
EOF
  printf 'LoadCredential=tg-fullchain.pem:%s\nLoadCredential=tg-privkey.pem:%s\n' \
    "$VLS_LE/live/$host/fullchain.pem" "$VLS_LE/live/$host/privkey.pem" >"$VLS_SITE/$TGW_SNIPPET_NAME.cred"
  chmod 0644 "$VLS_SITE/$TGW_SNIPPET_NAME.caddy" "$VLS_SITE/$TGW_SNIPPET_NAME.cred"
}

# Вход 443: VLESS на своём домене. Нет VLESS — ставим (сейф полный — сразу на домене).
# VLESS на чужой маске — переводим только с разрешения (KB_TGW_SWITCH=1): у устройств сменятся ключи.
tgw_front() {
  if ! vls_installed; then
    step "Ставлю VLESS — через него WEB-прокси принимает вход на 443"
    vls_install_core || return 1
  fi
  vls_load_env
  if [ -z "${VLS_DOMAIN:-}" ]; then
    if [ "${KB_TGW_SWITCH:-}" != 1 ]; then
      err "VLESS сейчас на чужой маске ($VLS_SNI). WEB-прокси нужен VLESS на своём домене — ключи VLESS-устройств сменятся."
      return 3
    fi
    vls_domain_on || return 1
  fi
  vls_load_env
  [ "${VLS_DOMAIN:-}" = "$(sec_domain)" ] || { err "VLESS на домене ${VLS_DOMAIN:-}, а в сейфе $(sec_domain). Они должны совпадать."; return 1; }
  [ -n "${VLS_TARGET:-}" ] && VLS_SITE_PORT="${VLS_TARGET##*:}"
  return 0
}

tgw_install_core() {
  local host rc; host=$(tgw_host)
  tgw_check || return 1
  tgw_front; rc=$?; [ $rc -eq 0 ] || return $rc

  step "Запись $host в Cloudflare"
  sec_cf_records "$host" "$VLS_ENDPOINT" "" only
  case $? in 0) ;; 3) err "Имя $host смотрит на другой сервер. Поправь запись на $VLS_ENDPOINT."; return 1 ;; *) return 1 ;; esac
  vls_cert "$host" || return 1

  tgw_build || return 1
  tgw_configure "$host" || return 1
  tgw_start || return 1

  step "Подключаю $host к сайту на 443"
  tgw_site_snippet "$host"
  if ! vls_site_reload; then
    rm -f "$VLS_SITE/$TGW_SNIPPET_NAME".{caddy,cred}; vls_site_reload >/dev/null 2>&1
    err "Сайт не принял WEB-прокси — убрала, VLESS работает как раньше."; return 1
  fi
  if [ "$VLS_MODE" = "behind" ] && [ -d "$KB_HOME/aiproxy/nginx/sni.d" ]; then
    printf '# Telegram WEB-прокси — генерирует Комбайн\n%s 127.0.0.1:%s;\n' "$host" "$VLS_INNER" \
      >"$KB_HOME/aiproxy/nginx/sni.d/$TGW_MAP_NAME"
    docker exec kombain-nginx nginx -t >/dev/null 2>&1 && docker exec kombain-nginx nginx -s reload >/dev/null 2>&1
  fi

  local code i
  for i in $(seq 10); do
    code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$host:443:127.0.0.1" "https://$host/")
    [ "$code" = "200" ] && break; sleep 1
  done
  if [ "$code" = "200" ]; then ok "WEB-прокси отвечает через 443 ($host)"
  else warn "Через 443 ответ $code — посмотри «Состояние»."; fi
  ok "Telegram WEB-прокси готов"
}

tgw_status() {
  tgw_installed || { warn "WEB-прокси не установлен."; return 0; }
  local h; h=$(tgw_conf_host)
  step "Состояние WEB-прокси ($h)"
  local u
  for u in mtproxy tproxy-server tproxy-firewall; do
    systemctl is-active --quiet "$u" && ok "$u работает" || err "$u не запущен"
  done
  curl --noproxy '*' -fs -o /dev/null --max-time 5 http://127.0.0.1:8081/readyz && ok "Ретранслятор готов" || err "Ретранслятор не отвечает"
  local crt="$VLS_LE/live/$h/fullchain.pem"
  [ -r "$crt" ] && ok "Сертификат до: $(openssl x509 -enddate -noout -in "$crt" | cut -d= -f2)"
  local code; code=$(curl --noproxy '*' -s -o /dev/null -w '%{http_code}' --max-time 10 --resolve "$h:443:127.0.0.1" "https://$h/")
  [ "$code" = "200" ] && ok "Снаружи через 443 — сайт открывается" || err "Через 443 ответ $code"
}

tgw_remove_core() {
  local h u; h=$(tgw_conf_host)
  for u in $TGW_UNITS; do systemctl disable --now "$u.service" >/dev/null 2>&1; done
  systemctl disable --now refresh-mtproxy-config.timer >/dev/null 2>&1
  for u in tproxy-server.service mtproxy.service tproxy-firewall.service refresh-mtproxy-config.service refresh-mtproxy-config.timer; do
    rm -f "/etc/systemd/system/$u"
  done
  systemctl daemon-reload
  rm -f "$VLS_SITE/$TGW_SNIPPET_NAME".{caddy,cred} "${KB_HOME:?}/aiproxy/nginx/sni.d/$TGW_MAP_NAME"
  vls_installed && vls_site_reload >/dev/null 2>&1
  rm -rf "${TGW_CONF:?}" /etc/mtproxy /opt/MTProxy "${TGW_SRC:?}" /srv/tproxy-site
  rm -f /usr/local/bin/tproxy-server /usr/local/sbin/refresh-mtproxy-config
  ok "WEB-прокси удалён${h:+ ($h)}. Сертификат и запись в Cloudflare оставила."
}

# kombain cli tgweb <команда>
tgw_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    info)
      local vd="" vm=""
      if vls_installed; then vls_load_env; vd="${VLS_DOMAIN:-}"; vm="$VLS_SNI"; fi
      jq -nc --argjson inst "$(tgw_installed && echo true || echo false)" \
        --argjson run "$(tgw_running && echo true || echo false)" \
        --arg host "$(tgw_conf_host)" --arg want "$(tgw_host)" \
        --argjson vls "$(vls_installed && echo true || echo false)" --arg vdom "$vd" --arg vmask "$vm" \
        --argjson safe "$([ -n "$(sec_domain)" ] && [ -n "$(sec_cf_token)" ] && echo true || echo false)" \
        '{installed:$inst, running:$run, host:$host, want_host:$want, vless:$vls, vless_domain:$vdom, vless_mask:$vmask, safe:$safe}' ;;
    check)   tgw_check ;;
    install) tgw_install_core ;;
    link)    tgw_installed && tgw_link || { err "WEB-прокси не установлен"; return 1; } ;;
    qr-png)  local l; l=$(tgw_link) || { err "WEB-прокси не установлен"; return 1; }
             qrencode -t PNG -s 6 -m 2 -o - "$l" ;;
    status)  tgw_status ;;
    remove)  tgw_remove_core ;;
    *) err "Неизвестная команда: $cmd"; return 2 ;;
  esac
}
