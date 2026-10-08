#!/usr/bin/env bash
# Общие ключи Комбайна. Вводятся один раз, ими пользуются все модули.
#   Cloudflare — сертификаты (нейронки, позже VLESS с сайтом)
#   домен     — общий для всех модулей
# Файлы читает только root.

KB_SECRETS="$KB_HOME/secrets"
KB_CF_FILE="$KB_SECRETS/cloudflare.ini"
KB_DOMAIN_FILE="$KB_HOME/domain"
KB_CLIENT_FILE="$KB_HOME/first-client"

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

# ── Записи в Cloudflare делаем сами, ключом из сейфа ──
sec_cf_api() {
  # sec_cf_api METHOD path [json] — ответ Cloudflare в JSON
  local m="$1" p="$2" body="${3:-}" t; t=$(sec_cf_token)
  [ -n "$t" ] || { echo '{"success":false}'; return 1; }
  if [ -n "$body" ]; then
    curl -s --max-time 20 -X "$m" -H "Authorization: Bearer $t" -H 'Content-Type: application/json' \
      --data "$body" "https://api.cloudflare.com/client/v4$p"
  else
    curl -s --max-time 20 -X "$m" -H "Authorization: Bearer $t" "https://api.cloudflare.com/client/v4$p"
  fi
}

# Зона в Cloudflare, к которой относится имя: am.site.ru → ищем am.site.ru, потом site.ru
sec_cf_zone() {
  local n="$1" id
  while [[ "$n" == *.* ]]; do
    id=$(sec_cf_api GET "/zones?name=$n" | jq -r '.result[0].id // empty' 2>/dev/null)
    [ -n "$id" ] && { echo "$id"; return 0; }
    n="${n#*.}"
  done
  return 1
}

# sec_cf_records <имя> <ip> [force] — ставит A-записи <имя> и *.<имя> → ip, облако серое.
# 0 — записи на месте; 3 — имя уже занято другим адресом (без force не трогаем); 1 — ошибка.
sec_cf_records() {
  local host="$1" ip="$2" force="${3:-}" zone name recs n id cur typ body busy=0
  zone=$(sec_cf_zone "$host") || {
    err "Cloudflare не показывает зону для $host. Ключ сделан для другого домена или домен ещё не Active."
    return 1; }
  body=$(jq -nc --arg ip "$ip" '{type:"A", content:$ip, ttl:1, proxied:false}')
  for name in "$host" "*.$host"; do
    recs=$(sec_cf_api GET "/zones/$zone/dns_records?name=$name")
    [ "$(jq -r '.success' <<<"$recs" 2>/dev/null)" = "true" ] || { err "Cloudflare не отдал записи для $name"; return 1; }
    n=$(jq '.result | length' <<<"$recs")
    if [ "$n" -eq 0 ]; then
      sec_cf_api POST "/zones/$zone/dns_records" "$(jq -c --arg n "$name" '. + {name:$n}' <<<"$body")" \
        | jq -e '.success' >/dev/null || { err "Не получилось создать $name"; return 1; }
      ok "Создала запись $name → $ip"
      continue
    fi
    id=$(jq -r '.result[0].id' <<<"$recs"); typ=$(jq -r '.result[0].type' <<<"$recs")
    cur=$(jq -r '.result[0].content' <<<"$recs")
    if [ "$n" -eq 1 ] && [ "$typ" = "A" ] && [ "$cur" = "$ip" ]; then
      [ "$(jq -r '.result[0].proxied' <<<"$recs")" = "true" ] && \
        sec_cf_api PATCH "/zones/$zone/dns_records/$id" '{"proxied":false}' >/dev/null
      ok "Запись $name уже смотрит сюда"
      continue
    fi
    if [ "$force" != "force" ]; then
      warn "Имя $name уже занято: $typ → $cur"
      busy=1; continue
    fi
    [ "$n" -eq 1 ] || { err "У $name несколько записей — разберись руками в Cloudflare"; return 1; }
    sec_cf_api PUT "/zones/$zone/dns_records/$id" "$(jq -c --arg n "$name" '. + {name:$n}' <<<"$body")" \
      | jq -e '.success' >/dev/null || { err "Не получилось перезаписать $name"; return 1; }
    ok "Перезаписала $name: было $cur, стало $ip"
  done
  [ "$busy" -eq 1 ] && return 3
  return 0
}

sec_domain()      { cat "$KB_DOMAIN_FILE" 2>/dev/null; }
sec_domain_save() { mkdir -p "$KB_HOME"; printf '%s\n' "$1" >"$KB_DOMAIN_FILE"; }

sec_client()      { cat "$KB_CLIENT_FILE" 2>/dev/null; }

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
      jq -nc --arg cf "$(sec_mask "$cf")" --arg d "$(sec_domain)" --arg c "$(sec_client)" \
        '{cloudflare:$cf, domain:$d, client:$c}' ;;
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
    set-client)
      local c; c=$(printf '%s' "${1:-}" | tr 'A-Z' 'a-z' | tr -d ' ')
      [[ "$c" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] || { err "Только маленькие латинские буквы, цифры и дефис. Пример: vasya-phone"; return 1; }
      mkdir -p "$KB_HOME"; printf '%s\n' "$c" >"$KB_CLIENT_FILE"; ok "Имя телефона $c в сейфе" ;;
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
