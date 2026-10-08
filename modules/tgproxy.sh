#!/usr/bin/env bash
# Модуль «Telegram-прокси»: MTProxy с маскировкой под обычный сайт (Fake TLS).
# Нужен первым шагом, когда Telegram без VPN не грузится: без Telegram не будет и бота.
# Ничего не требует: ни домена, ни Cloudflare. Обкатан на стенде (репа ln71v/telegram-proxy).
# Порт 9443/tcp — отдельный, чтобы не мешать nginx на 443 (см. docs/DEV-PORTS.md).

TGP_BIN="/usr/local/bin/telegram-mtg"
TGP_DIR="/etc/telegram-mtg"
TGP_CONF="$TGP_DIR/config.toml"
TGP_UNIT="/etc/systemd/system/telegram-mtg.service"
TGP_PORT=9443
# Под какой сайт маскируемся. Не из data/ai-domains.txt.
TGP_FRONT="www.cloudflare.com"

TGP_VER="2.2.8"
TGP_URL="https://github.com/9seconds/mtg/releases/download/v$TGP_VER/mtg-$TGP_VER-linux-amd64.tar.gz"
TGP_SHA="7ef19d079d85f4e00d4f8334ec1f3f3c8718e3d0ed1f3109ea9a8673138a2102"

tgp_installed() { [ -f "$TGP_CONF" ] && [ -f "$TGP_UNIT" ]; }
tgp_running()   { systemctl is-active --quiet telegram-mtg && [ -n "$(ss -H -ltn "sport = :$TGP_PORT")" ]; }

tgp_secret() { sed -n 's/^secret = "\(ee[0-9a-f]*\)"$/\1/p' "$TGP_CONF" 2>/dev/null; }
tgp_ip()     { sed -n 's/^public-ipv4 = "\([0-9.]*\)"$/\1/p' "$TGP_CONF" 2>/dev/null; }

# Ссылки: tg:// открывает Telegram сразу, https://t.me — для пересылки
tgp_link_tg()  { printf 'tg://proxy?server=%s&port=%s&secret=%s' "$(tgp_ip)" "$TGP_PORT" "$(tgp_secret)"; }
tgp_link_web() { printf 'https://t.me/proxy?server=%s&port=%s&secret=%s' "$(tgp_ip)" "$TGP_PORT" "$(tgp_secret)"; }

tgp_bin_ok() { [ -x "$TGP_BIN" ] && grep -q "^$TGP_VER " <<<"$("$TGP_BIN" --version 2>/dev/null)"; }

tgp_get_bin() {
  tgp_bin_ok && return 0
  [ "$(uname -m)" = "x86_64" ] || { err "Telegram-прокси пока только для обычных серверов (x86_64)."; return 1; }
  step "Скачиваю MTProxy $TGP_VER"
  local tmp; tmp=$(mktemp -d)
  if ! curl -fsSL --proto '=https' --max-time 180 --retry 2 "$TGP_URL" -o "$tmp/mtg.tar.gz"; then
    err "Не скачалось с GitHub. Проверь интернет на сервере."; rm -rf "$tmp"; return 1
  fi
  if ! printf '%s  %s\n' "$TGP_SHA" "$tmp/mtg.tar.gz" | sha256sum --check --status; then
    err "Файл скачался битый или подменённый — не ставлю."; rm -rf "$tmp"; return 1
  fi
  tar -xzf "$tmp/mtg.tar.gz" -C "$tmp" --no-same-owner
  local b; b=$(find "$tmp" -type f -name mtg | head -1)
  [ -n "$b" ] || { err "В архиве нет программы."; rm -rf "$tmp"; return 1; }
  install -o root -g root -m 0755 "$b" "$TGP_BIN"
  rm -rf "$tmp"
  tgp_bin_ok && ok "MTProxy скачан и проверен"
}

tgp_unit() {
  cat >"$TGP_UNIT" <<'EOF'
[Unit]
Description=Telegram MTProxy (Kombain, Fake TLS)
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
DynamicUser=yes
LoadCredential=config.toml:/etc/telegram-mtg/config.toml
# ${CREDENTIALS_DIRECTORY}, а не %d: %d нет в systemd Ubuntu 22.04
ExecStart=/usr/local/bin/telegram-mtg run ${CREDENTIALS_DIRECTORY}/config.toml
Restart=on-failure
RestartSec=3
NoNewPrivileges=yes
PrivateTmp=yes
ProtectSystem=strict
ProtectHome=yes
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
UMask=0077
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF
}

# Ставит или, если уже стоит, просто проверяет. Ссылку печатает tgp_show.
tgp_core() {
  ensure_pkgs curl tar jq qrencode || return 1
  if tgp_installed; then
    # Уже работает (свой или поставленный раньше руками) — ничего не трогаем
    tgp_running && { ok "Telegram-прокси уже стоит и работает"; return 0; }
    # Не работает — чиним файл службы (старые установки с %d на Ubuntu 22.04)
    backup_file "$TGP_UNIT"
    tgp_unit
    systemctl daemon-reload
    systemctl reset-failed telegram-mtg >/dev/null 2>&1
    systemctl enable --now telegram-mtg >/dev/null 2>&1
    sleep 2
    tgp_running && { ok "Telegram-прокси уже стоит и работает"; return 0; }
    err "Telegram-прокси стоит, но не запускается. Логи: journalctl -u telegram-mtg -n 30"
    return 1
  fi
  local owner; owner=$(port_owner "$TGP_PORT" tcp)
  [ -z "$owner" ] || { err "Порт $TGP_PORT уже занят программой $owner. Ничего не меняла."; return 1; }
  tgp_get_bin || return 1

  local ip; ip=$(server_ip)
  [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || { err "Не смогла узнать внешний IP сервера."; return 1; }
  local secret; secret=$("$TGP_BIN" generate-secret --hex "$TGP_FRONT")
  [[ "$secret" =~ ^ee([0-9a-f]{2})+$ ]] || { err "MTProxy выдал странный ключ. Не ставлю."; return 1; }

  step "Настраиваю Telegram-прокси"
  install -d -m 0700 -o root -g root "$TGP_DIR"
  ( umask 077; cat >"$TGP_CONF" <<EOF
debug = false
secret = "$secret"
bind-to = "0.0.0.0:$TGP_PORT"
public-ipv4 = "$ip"
prefer-ip = "only-ipv4"
concurrency = 512

[defense.blocklist]
enabled = false
EOF
  )
  chmod 600 "$TGP_CONF"
  tgp_unit
  systemctl daemon-reload
  systemctl enable --now telegram-mtg >/dev/null 2>&1

  fw_register tgproxy "$TGP_PORT/tcp"
  if command -v ufw >/dev/null 2>&1 && grep -q "^Status: active" <<<"$(ufw status 2>/dev/null)"; then
    ufw allow "$TGP_PORT/tcp" >/dev/null
  fi

  local _
  for _ in $(seq 1 10); do tgp_running && break; sleep 1; done
  tgp_running || { err "Прокси не запустился. Логи: journalctl -u telegram-mtg -n 30"; return 1; }
  ok "Telegram-прокси работает на порту $TGP_PORT"
}

tgp_qr_svg() { qrencode -t SVG -m 2 -o - "$(tgp_link_tg)" 2>/dev/null; }

tgp_show() {
  tgp_installed || { warn "Telegram-прокси не установлен."; return 0; }
  say ""
  say "${C_BOLD}Ссылка для Telegram:${C_RESET}"
  say "  $(tgp_link_web)"
  say ""
  say "Отсканируй камерой телефона или открой ссылку там, где стоит Telegram:"
  qrencode -t ANSIUTF8 -m 1 "$(tgp_link_tg)" 2>/dev/null
  say "Работает: сообщения, фото, видео, кружки, голосовые."
  say "Не работает: звонки — они идут мимо прокси. Для звонков нужен VPN."
}

tgp_install() { tgp_core && tgp_show; }

tgp_status() {
  tgp_installed || { warn "Telegram-прокси не установлен."; return 0; }
  tgp_running && ok "Telegram-прокси работает (порт $TGP_PORT)" || err "Telegram-прокси остановлен"
}

tgp_remove() {
  tgp_installed || { warn "Telegram-прокси не установлен."; return 0; }
  confirm "Удалить Telegram-прокси? Ссылка перестанет работать у всех" || return 0
  systemctl disable --now telegram-mtg >/dev/null 2>&1
  rm -f "$TGP_UNIT"
  systemctl daemon-reload
  rm -rf "$TGP_DIR"
  fw_unregister tgproxy
  ok "Telegram-прокси удалён"
}

tgp_menu() {
  while true; do
    cat <<EOF

${C_BOLD}══ Telegram-прокси ══${C_RESET}
 1) Установить и показать ссылку
 2) Состояние
 3) Показать ссылку ещё раз
 4) Удалить
 0) Назад
EOF
    case "$(ask "Выбор")" in
      1) tgp_install ;;
      2) tgp_status ;;
      3) tgp_show ;;
      4) tgp_remove ;;
      0) return ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

# kombain cli tgproxy <команда> — для установщика и бота.
# install/link печатают последней строкой JSON: {"tg":"tg://…","web":"https://t.me/…","qr":"<svg base64>"}
tgp_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    install) tgp_core >&2 || return 1; tgp_cli link ;;
    link)
      tgp_installed || { err "Telegram-прокси не установлен."; return 1; }
      ensure_pkgs jq qrencode >/dev/null 2>&1
      jq -nc --arg tg "$(tgp_link_tg)" --arg web "$(tgp_link_web)" --arg qr "$(tgp_qr_svg | base64 -w0)" \
        '{tg:$tg, web:$web, qr:$qr}' ;;
    status) tgp_running && echo running || echo stopped ;;
    *) err "Неизвестная команда: $cmd"; return 2 ;;
  esac
}
