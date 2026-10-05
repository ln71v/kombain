#!/usr/bin/env bash
# Общие ключи Комбайна. Вводятся один раз, ими пользуются все модули.
#   Cloudflare — сертификаты (нейронки, позже VLESS с сайтом)
#   домен     — общий для всех модулей
# Файлы читает только root.

KB_SECRETS="$KB_HOME/secrets"
KB_CF_FILE="$KB_SECRETS/cloudflare.ini"
KB_DOMAIN_FILE="$KB_HOME/domain"

sec_cf_token() { sed -n 's/^dns_cloudflare_api_token = //p' "$KB_CF_FILE" 2>/dev/null; }

# Проверка ключа у самого Cloudflare. 0 — ключ живой.
sec_cf_verify() {
  local t="$1" st
  st=$(curl -fs --max-time 15 -H "Authorization: Bearer $t" \
    https://api.cloudflare.com/client/v4/user/tokens/verify | jq -r '.result.status // empty' 2>/dev/null)
  [ "$st" = "active" ]
}

sec_cf_save() {
  mkdir -p "$KB_SECRETS"
  chmod 700 "$KB_SECRETS"
  ( umask 077; printf 'dns_cloudflare_api_token = %s\n' "$1" >"$KB_CF_FILE" )
  chmod 600 "$KB_CF_FILE"
}

sec_domain()      { cat "$KB_DOMAIN_FILE" 2>/dev/null; }
sec_domain_save() { mkdir -p "$KB_HOME"; printf '%s\n' "$1" >"$KB_DOMAIN_FILE"; }

sec_mask() { local t="$1"; [ -n "$t" ] && printf '…%s' "${t: -4}"; }

sec_txt_where() {
  cat <<'EOF'
Где брать API-ключ Cloudflare:

• https://dash.cloudflare.com/profile/api-tokens
  «Create Token» → «Edit zone DNS» → «Use template» →
  Zone Resources: Include → Specific zone → твой домен →
  «Continue to summary» → «Create Token» → «Copy».
  Нужен, чтобы сертификаты продлевались сами.

EOF
}

# kombain cli secrets <команда>
sec_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    info)
      local cf; cf=$(sec_cf_token)
      jq -nc --arg cf "$(sec_mask "$cf")" --arg d "$(sec_domain)" \
        --arg bot "$(sed -n 's/^BOT_TOKEN=//p' "$KB_HOME/bot/env" 2>/dev/null | tail -c 5)" \
        '{cloudflare:$cf, domain:$d, bot:(if $bot=="" then "" else "…"+$bot end)}' ;;
    where)  sec_txt_where ;;
    check-cf)
      ensure_pkgs curl jq >/dev/null 2>&1
      sec_cf_verify "${KB_CF_TOKEN:?}" && ok "Cloudflare ключ принял" \
        || { err "Cloudflare этот ключ не принимает. Скопируй его целиком или сделай новый."; return 1; } ;;
    set-cf)
      ensure_pkgs curl jq >/dev/null 2>&1
      sec_cf_verify "${KB_CF_TOKEN:?}" || { err "Cloudflare этот ключ не принимает."; return 1; }
      sec_cf_save "$KB_CF_TOKEN" && ok "Ключ Cloudflare сохранён" ;;
    set-domain)
      local d="${1:-}"
      d=$(printf '%s' "$d" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/.*$##; s#\.$##; s#^dns\.##')
      [[ "$d" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]] || { err "Это не похоже на домен. Пример: mojdns.site"; return 1; }
      sec_domain_save "$d" && ok "Домен $d в сейфе" ;;
    set-bot)
      local t="${KB_BOT_TOKEN:?}" name
      name=$(bot_check_token "$t")
      [ -n "$name" ] || { err "Telegram такой токен не знает."; return 1; }
      sed -i "s|^BOT_TOKEN=.*|BOT_TOKEN=$t|" "$KB_HOME/bot/env"
      ok "Токен сохранён, бот @$name перезапускается"
      ( sleep 2; systemctl restart kombain-bot ) >/dev/null 2>&1 & ;;
    *) err "Неизвестная команда: $cmd"; return 2 ;;
  esac
}
