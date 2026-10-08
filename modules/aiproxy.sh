#!/usr/bin/env bash
# Модуль «Прокси для нейронок»: AdGuard Home + nginx (SNI-прокси).
#
# Как это работает:
#  - AdGuard Home — твой DNS. На вопрос «где chatgpt.com?» он отвечает IP этого сервера.
#  - nginx на 443 смотрит, к какому сайту шло подключение (SNI), и пересылает его
#    в настоящий сервис уже отсюда. Шифрование не вскрывается.
#  - dns.<домен> nginx отдаёт самому AdGuard: это шифрованный DNS (DoH) и админка.
#  - Шифрованный DNS нужен, чтобы провайдер не подменял ответы.

AIP_DIR="$KB_HOME/aiproxy"
AIP_ENV="$AIP_DIR/env"
AIP_LE="$AIP_DIR/letsencrypt"
AIP_SECRETS="$KB_SECRETS"   # общий для всех модулей, см. secrets.sh
AIP_AGH="$AIP_DIR/adguard"
AIP_NGX="$AIP_DIR/nginx"
AIP_API="http://127.0.0.1:3000/control"
AIP_DOMAINS_FILE="$KB_SRC/data/ai-domains.txt"
AIP_C_AGH="kombain-adguard"
AIP_C_NGX="kombain-nginx"
AIP_CRON="/etc/cron.d/kombain-cert"

aip_load_env() {
  # shellcheck disable=SC1090
  [ -r "$AIP_ENV" ] && . "$AIP_ENV"
}

aip_installed() { [ -r "$AIP_ENV" ]; }

aip_api() {
  # aip_api METHOD path [json]
  local m="$1" p="$2" body="${3:-}"
  if [ -n "$body" ]; then
    curl -fsS -u "$AGH_USER:$AGH_PASS" -X "$m" -H 'Content-Type: application/json' --data "$body" "$AIP_API$p"
  else
    curl -fsS -u "$AGH_USER:$AGH_PASS" -X "$m" "$AIP_API$p"
  fi
}

# Домены из файла без комментариев
aip_domain_list() {
  grep -vE '^\s*(#|$)' "$AIP_DOMAINS_FILE" | tr -d ' \r' | tr 'A-Z' 'a-z'
}

# ───────────────────────── установка ─────────────────────────

aip_explain_domain() { aip_txt_domain | todo; }
aip_txt_intro() {
  cat <<'EOF'
Сейчас будет неожиданно, но без этого никак.

Сначала — домен. Это самое долгое и самое важное:
купить домен и привязать его к Cloudflare. Займёт от 20 минут до вечера,
потому что часть времени просто ждёшь.

Как идём:
 1. Собираем. Всё, что добудешь, складываешь в Сейф — по пунктам.
    Можно закрыть чат и вернуться завтра — собранное никуда не денется.
 2. Жмёшь одну кнопку «Устанавливай» и ждёшь пару минут.

Думать не надо, выбирать тоже. Тыкаешь, куда скажу. Погнали.
EOF
}

aip_txt_buy() {
  cat <<'EOF'
ЭТАП 1. ПОКУПАЕМ ДОМЕН

1. Открой https://www.reg.ru и зарегистрируйся.
   Попросят телефон и паспорт — не пугайся, так везде по закону.
   Пиши правду, иначе домен могут заблокировать. Наружу данные не попадут,
   ниже мы их скроем.
2. В поиске на главной впиши любое имя. Название вообще не важно:
   хоть «koshka-na-korove», хоть своё имя. Зона (.ru, .site, .pro…) — любая,
   бери самую дешёвую из того, что предложат.
3. «В корзину» → «Оформить».
4. АВТОПРОДЛЕНИЕ НЕ ВКЛЮЧАЙ. Галку снимай, если стоит.
5. Оплати. Домен твой.
6. Сразу скрой свои данные, иначе твои телефон и почту увидит любой:
   reg.ru → «Домены» → твой домен → «Управление» → внизу «Ещё услуги» →
   «Скрытие персональных данных» → «Заказать».
   (Для .ru это обычно уже включено само.)
EOF
}

aip_txt_cf() {
  cat <<'EOF'
ЭТАП 2. CLOUDFLARE

Сайт на английском — ничего страшного, пишу точные названия кнопок.

1. Открой https://dash.cloudflare.com/sign-up
   Впиши почту и пароль → «Sign up». Подтверди почту по письму.
2. В панели нажми «Add a domain» (или «+ Add» → «Connect a domain»).
3. Впиши свой домен, например mojdns.site → «Continue».
4. Тариф: листай вниз до «Free» ($0) → выбери его → «Continue».
5. Cloudflare покажет ДВА адреса вида
      anna.ns.cloudflare.com
      bob.ns.cloudflare.com
   Скопируй их куда-нибудь.
6. Иди обратно в reg.ru → «Домены» → твой домен →
   «DNS-серверы и управление зоной» → «Изменить» →
   «Свой список DNS-серверов» → впиши эти два адреса → «Сохранить».
7. Теперь ЖДИ. Обычно 10–30 минут, иногда до суток.
   Пей пиво, обновляй страницу Cloudflare.
   Когда домен станет «Active» (Cloudflare ещё и письмо пришлёт) —
   всё, самое долгое позади.
EOF
}

aip_txt_domain() { aip_txt_intro; echo; aip_txt_buy; echo; aip_txt_cf; }

aip_explain_records() { aip_txt_records "$1" | todo; }
aip_txt_records() {
  local ip="$1"
  cat <<EOF
ЭТАП 3. ДВЕ ЗАПИСИ В CLOUDFLARE

1. В Cloudflare нажми на свой домен.
2. Слева «DNS» → «Records».
3. Кнопка «+ Add record». Заполни:
     Type:          A
     Name:          dns
     IPv4 address:  $ip
     Proxy status:  нажми на оранжевое облако, чтобы стало СЕРЫМ
                    («DNS only»)
   → «Save».
4. Ещё раз «+ Add record», всё то же самое, только
     Name:          *.dns
   → «Save».

Облако ОБЯЗАТЕЛЬНО серое. Оранжевое — ничего не заработает.
Цифры $ip — это адрес твоего сервера, вписывай ровно их.
EOF
}
aip_explain_token() { aip_txt_token | todo; }
aip_txt_token() {
  cat <<'EOF'
ЭТАП 4. КЛЮЧ CLOUDFLARE

Он нужен, чтобы сервер сам получил сертификат (замочек https).

1. Открой https://dash.cloudflare.com/profile/api-tokens
2. «Create Token».
3. Напротив «Edit zone DNS» нажми «Use template».
4. Найди «Zone Resources». Там три поля, поставь:
     Include  →  Specific zone  →  твой домен
   Если вписал домен вида am.mojdns.site — выбирай основной mojdns.site.
   Остальное не трогай.
5. Внизу «Continue to summary» → «Create Token».
6. Появится длинная строка — это ключ. «Copy».
   Он показывается ОДИН раз. Потерял — просто сделай новый.
EOF
}

aip_ask_domain() {
  local d
  while true; do
    d=$(ask "Впиши свой домен (например mojdns.site)")
    d=$(printf '%s' "$d" | tr 'A-Z' 'a-z' | sed -E 's#^https?://##; s#/.*$##; s#\.$##; s#^dns\.##')
    if [[ "$d" =~ ^([a-z0-9]([a-z0-9-]*[a-z0-9])?\.)+[a-z]{2,}$ ]]; then
      printf '%s' "$d"
      return 0
    fi
    warn "Это не похоже на домен. Пример: mojdns.site"
  done
}

# Смотрят ли dns.<домен> и *.dns.<домен> на наш IP. 0 — да.
aip_dns_ok() {
  local host="$1" ip="$2" a b
  a=$(dig +short @1.1.1.1 "$host" A | tail -1)
  b=$(dig +short @1.1.1.1 "proverka.$host" A | tail -1)
  if [ "$a" = "$ip" ] && [ "$b" = "$ip" ]; then
    ok "Записи видны: $host и *.$host → $ip"
    return 0
  fi
  warn "Пока не вижу: $host → ${a:-ничего}, *.$host → ${b:-ничего} (нужно $ip)"
  return 1
}

# Ждём, пока записи появятся (для терминала)
aip_wait_dns() {
  local host="$1" ip="$2"
  while true; do
    aip_dns_ok "$host" "$ip" && return 0
    say "Если только что поменял NS у регистратора — подожди 10–30 минут."
    if ! confirm "Проверить ещё раз?"; then
      confirm "Продолжить без проверки (сертификат может не получиться)?" && return 0
      return 1
    fi
  done
}

aip_free_port53() {
  local owner
  owner=$(port_owner 53 udp)
  [ -z "$owner" ] && return 0
  if [ "$owner" = "systemd-resolve" ]; then
    step "Порт 53 занят системным DNS Ubuntu — отключаю его заглушку"
    backup_file /etc/systemd/resolved.conf
    backup_file /etc/resolv.conf
    if grep -qE '^\s*#?\s*DNSStubListener=' /etc/systemd/resolved.conf; then
      sed -i -E 's/^\s*#?\s*DNSStubListener=.*/DNSStubListener=no/' /etc/systemd/resolved.conf
    else
      printf '\n[Resolve]\nDNSStubListener=no\n' >>/etc/systemd/resolved.conf
    fi
    if grep -qE '^\s*#?\s*DNS=' /etc/systemd/resolved.conf; then
      sed -i -E 's/^\s*#?\s*DNS=.*/DNS=1.1.1.1 8.8.8.8/' /etc/systemd/resolved.conf
    fi
    ln -sf /run/systemd/resolve/resolv.conf /etc/resolv.conf
    systemctl restart systemd-resolved
    sleep 2
    owner=$(port_owner 53 udp)
    [ -z "$owner" ] && { ok "Порт 53 свободен"; return 0; }
  fi
  err "Порт 53 занят программой: $owner. Останови её и запусти установку снова."
  return 1
}

aip_check_ports() {
  local p owner bad=0
  for p in 443 853 8443 3000; do
    owner=$(port_owner "$p" tcp)
    if [ -n "$owner" ]; then
      err "Порт $p уже занят: $owner"
      bad=1
    fi
  done
  [ "$bad" -eq 0 ]
}

aip_get_cert() {
  step "Получаю сертификат для $DNS_HOST и *.$DNS_HOST"
  mkdir -p "$AIP_LE"
  sec_cf_save "$CF_TOKEN"
  if docker run --rm \
      -v "$AIP_LE:/etc/letsencrypt" \
      -v "$AIP_SECRETS:/secrets:ro" \
      certbot/dns-cloudflare certonly --non-interactive --agree-tos \
      --register-unsafely-without-email \
      --dns-cloudflare --dns-cloudflare-credentials /secrets/cloudflare.ini \
      --dns-cloudflare-propagation-seconds 30 \
      --cert-name "$DNS_HOST" -d "$DNS_HOST" -d "*.$DNS_HOST"; then
    ok "Сертификат получен"
  else
    err "Сертификат не получен. Частые причины: неверный ключ Cloudflare или домен ещё не переехал в Cloudflare."
    return 1
  fi
}

aip_write_renew() {
  mkdir -p "$KB_HOME/bin"
  cat >"$KB_HOME/bin/cert-renew.sh" <<EOF
#!/usr/bin/env bash
# Продление сертификата AdGuard. Запускается по расписанию.
CERT="$AIP_LE/live/$DNS_HOST/fullchain.pem"
before=\$(stat -L -c %Y "\$CERT" 2>/dev/null)
docker run --rm -v "$AIP_LE:/etc/letsencrypt" -v "$AIP_SECRETS:/secrets:ro" \\
  certbot/dns-cloudflare renew --quiet \\
  --dns-cloudflare --dns-cloudflare-credentials /secrets/cloudflare.ini
after=\$(stat -L -c %Y "\$CERT" 2>/dev/null)
[ "\$before" != "\$after" ] && docker restart $AIP_C_AGH >/dev/null
exit 0
EOF
  chmod 700 "$KB_HOME/bin/cert-renew.sh"
  printf '23 4 * * 1 root %s >/dev/null 2>&1\n' "$KB_HOME/bin/cert-renew.sh" >"$AIP_CRON"
  ok "Сертификат будет продлеваться сам (по понедельникам ночью)"
}

aip_start_adguard() {
  step "Запускаю AdGuard Home"
  docker rm -f "$AIP_C_AGH" >/dev/null 2>&1
  rm -rf "$AIP_AGH"   # установка всегда с чистого AdGuard
  mkdir -p "$AIP_AGH/work" "$AIP_AGH/conf"
  docker run -d --name "$AIP_C_AGH" --restart unless-stopped --network host \
    -v "$AIP_AGH/work:/opt/adguardhome/work" \
    -v "$AIP_AGH/conf:/opt/adguardhome/conf" \
    -v "$AIP_LE:/etc/letsencrypt:ro" \
    adguard/adguardhome >/dev/null || { err "AdGuard не запустился"; return 1; }

  local up=0
  for _ in $(seq 1 30); do
    curl -fs -o /dev/null "$AIP_API/install/get_addresses" && { up=1; break; }
    sleep 2
  done
  [ "$up" -eq 1 ] || { err "AdGuard не отвечает. Логи: docker logs $AIP_C_AGH"; return 1; }

  local body
  body=$(jq -nc --arg u "$AGH_USER" --arg p "$AGH_PASS" \
    '{web:{ip:"127.0.0.1",port:3000}, dns:{ip:"0.0.0.0",port:53}, username:$u, password:$p}')
  local resp code
  resp=$(curl -sS -w '\n%{http_code}' -X POST -H 'Content-Type: application/json' --data "$body" \
    "$AIP_API/install/configure" 2>&1)
  code=$(tail -n1 <<<"$resp")
  if [ "$code" != "200" ]; then
    err "Не смогла выполнить первичную настройку AdGuard (код $code)"
    say "AdGuard ответил: $(sed '$d' <<<"$resp" | head -c 600)"
    say "Кто держит порты 53 и 3000:"
    ss -H -tulnp 2>/dev/null | grep -E ':(53|3000) ' | head -10
    return 1
  fi

  for _ in $(seq 1 30); do
    aip_api GET /status >/dev/null 2>&1 && break
    sleep 2
  done
  ok "AdGuard запущен"
}

aip_configure_adguard() {
  step "Настраиваю AdGuard: шифрованный DNS, доступ, нейронки"
  local tls
  tls=$(jq -nc --arg h "$DNS_HOST" \
    '{enabled:true, server_name:$h, force_https:false,
      port_https:8443, port_dns_over_tls:853, port_dns_over_quic:853,
      certificate_chain:"", private_key:"",
      certificate_path:("/etc/letsencrypt/live/"+$h+"/fullchain.pem"),
      private_key_path:("/etc/letsencrypt/live/"+$h+"/privkey.pem")}')
  aip_api POST /tls/configure "$tls" >/dev/null || { err "Не включился шифрованный DNS"; return 1; }
  ok "Шифрованный DNS (DoH/DoT/DoQ) включён"

  aip_tune_dns

  aip_set_clients "$FIRST_CLIENT" || return 1
  aip_sync_rewrites
}

# Настройки DNS — ставятся сами, юзер не выбирает
aip_tune_dns() {
  local cfg
  cfg=$(jq -nc '{
    upstream_dns: ["https://dns.cloudflare.com/dns-query", "https://dns.google/dns-query", "https://dns.quad9.net/dns-query"],
    bootstrap_dns: ["1.1.1.1", "8.8.8.8", "9.9.9.9"],
    fallback_dns: ["1.1.1.1", "8.8.8.8"],
    upstream_mode: "parallel",
    cache_enabled: true, cache_size: 16777216, cache_optimistic: true,
    ratelimit: 100,
    dnssec_enabled: true,
    edns_cs_enabled: false,
    disable_ipv6: true
  }')
  # disable_ipv6: иначе часть трафика нейронок пойдёт мимо сервера по IPv6
  aip_api POST /dns_config "$cfg" >/dev/null || { err "Не применились настройки DNS"; return 1; }
  ok "DNS: Cloudflare + Google + Quad9 по шифрованному каналу, кэш, DNSSEC, без IPv6"

  aip_api PUT /querylog/config/update \
    '{"enabled":true,"interval":86400000,"anonymize_client_ip":false,"ignored":[],"ignored_enabled":false}' >/dev/null \
    && ok "Журнал запросов: хранится 1 сутки"
  aip_api PUT /stats/config/update \
    '{"enabled":true,"interval":604800000,"ignored":[],"ignored_enabled":false}' >/dev/null \
    && ok "Статистика: за 7 дней"
}

# Ходит ли устройство через сервер: последние запросы из журнала
aip_check_client() {
  local c="$1" log total ai
  log=$(aip_api GET "/querylog?limit=1000" | jq -c --arg c "$c" '[.data[]? | select(.client_id == $c)]') \
    || { err "Не смогла прочитать журнал"; return 1; }
  total=$(jq 'length' <<<"$log")
  if [ "$total" -eq 0 ]; then
    err "От «$c» за последние сутки ни одного запроса."
    say "Значит, DNS на устройстве не настроен или настроен с ошибкой в имени."
    say "Проверь адрес в настройках: «Как подключить» → $c."
    return 0
  fi
  ai=$(jq '[.[] | select(.reason == "Rewrite" or .reason == "RewriteEtcHosts" or .reason == "RewriteRule")] | length' <<<"$log")
  ok "«$c» ходит через сервер: $total запросов в последних записях журнала"
  if [ "$ai" -gt 0 ]; then
    ok "Нейронки идут через сервер ($ai запросов)"
  else
    say "Нейронок пока не было — открой chatgpt.com и проверь ещё раз."
  fi
  say ""
  say "Последние 15 (время московское):"
  jq -r '.[:15][] | "\((try (.time | sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") | fromdateiso8601 + 10800 | strftime("%H:%M:%S")) catch .time[11:19]))  \(.question.name)\(if (.reason|startswith("Rewrite")) then "  ← нейронка" else "" end)"' <<<"$log"
}

aip_set_clients() {
  # aip_set_clients id1 [id2...] — добавляет к уже разрешённым
  local cur new
  cur=$(aip_api GET /access/list | jq -c '.allowed_clients // []')
  new=$(jq -nc --argjson cur "$cur" --args '$cur + $ARGS.positional | unique' "$@")
  aip_api POST /access/set "$(jq -nc --argjson a "$new" '{allowed_clients:$a, disallowed_clients:[], blocked_hosts:[]}')" >/dev/null \
    || { err "Не смогла обновить список устройств"; return 1; }
  ok "Разрешённые устройства: $(printf '%s' "$new" | jq -r 'join(", ")')"
}

aip_sync_rewrites() {
  local have d name added=0 names
  have=$(aip_api GET /rewrite/list | jq -r '.[].domain')
  while IFS= read -r d; do
    names=("${d#.}")
    [ "${d:0:1}" = "." ] && names+=("*.${d#.}")
    for name in "${names[@]}"; do
      grep -qxF "$name" <<<"$have" && continue
      aip_api POST /rewrite/add "$(jq -nc --arg d "$name" --arg a "$SERVER_IP" '{domain:$d, answer:$a}')" >/dev/null && added=$((added+1))
    done
  done < <(aip_domain_list)
  ok "Подмена адресов нейронок: добавлено $added записей"
}

aip_write_nginx() {
  mkdir -p "$AIP_NGX/sni.d"
  cat >"$AIP_NGX/nginx.conf" <<'EOF'
# Сгенерировано Комбайном. Своё дописывай в sni.d/50-my.map
user nginx;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
events { worker_connections 4096; }

stream {
  # Где искать настоящие адреса сервисов. Не через свой AdGuard — иначе петля.
  resolver 1.1.1.1 8.8.8.8 ipv6=off valid=300s;
  resolver_timeout 5s;

  map $ssl_preread_server_name $kb_backend {
    hostnames;
    include /etc/nginx/sni.d/*.map;
    default "";   # чужие сайты не пропускаем
  }

  server {
    listen 443;
    ssl_preread on;
    proxy_pass $kb_backend;
    proxy_connect_timeout 10s;
  }
}
EOF
  printf '# AdGuard: шифрованный DNS и админка (с поддоменами)\n.%s 127.0.0.1:8443;\n' \
    "$DNS_HOST" >"$AIP_NGX/sni.d/00-adguard.map"
  aip_write_ai_map
}

aip_write_ai_map() {
  {
    printf '# Нейронки. Генерируется из data/ai-domains.txt — руками не правь\n'
    aip_domain_list | while IFS= read -r d; do
      printf '%s $ssl_preread_server_name:443;\n' "$d"
    done
  } >"$AIP_NGX/sni.d/10-ai.map"
}

aip_nginx_test() {
  docker run --rm --network host \
    -v "$AIP_NGX/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$AIP_NGX/sni.d:/etc/nginx/sni.d:ro" \
    nginx:stable nginx -t -q
}

aip_start_nginx() {
  step "Запускаю nginx (SNI-прокси)"
  aip_nginx_test || { err "В настройках nginx ошибка, запуск отменён"; return 1; }
  docker rm -f "$AIP_C_NGX" >/dev/null 2>&1
  docker run -d --name "$AIP_C_NGX" --restart unless-stopped --network host \
    -v "$AIP_NGX/nginx.conf:/etc/nginx/nginx.conf:ro" \
    -v "$AIP_NGX/sni.d:/etc/nginx/sni.d:ro" \
    nginx:stable >/dev/null || { err "nginx не запустился"; return 1; }
  ok "nginx запущен"
}

aip_save_env() {
  mkdir -p "$AIP_DIR"
  umask 077
  cat >"$AIP_ENV" <<EOF
DOMAIN="$DOMAIN"
DNS_HOST="$DNS_HOST"
SERVER_IP="$SERVER_IP"
AGH_USER="$AGH_USER"
AGH_PASS="$AGH_PASS"
EOF
  chmod 600 "$AIP_ENV"
}

aip_show_howto() {
  aip_load_env
  local c="${1:-${FIRST_CLIENT:-имя}}"
  cat <<EOF

${C_BOLD}${C_GREEN}══════ КАК ПОДКЛЮЧИТЬ УСТРОЙСТВО «$c» ══════${C_RESET}

${C_BOLD}Android:${C_RESET} Настройки → Подключения → Другие настройки →
  Частный DNS → «Имя хоста» →  ${C_CYAN}$c.$DNS_HOST${C_RESET}
  (на других Android: Настройки → Сеть → Частный DNS)

${C_BOLD}iPhone / Mac / браузер / роутер (DoH):${C_RESET}
  ${C_CYAN}https://$DNS_HOST/dns-query/$c${C_RESET}

${C_BOLD}Windows 11:${C_RESET} Параметры → Сеть → свойства адаптера → DNS → Изменить:
  IPv4: ${C_CYAN}$SERVER_IP${C_RESET}, шифрование «Только зашифрованные (DNS по HTTPS)»,
  шаблон: ${C_CYAN}https://$DNS_HOST/dns-query/$c${C_RESET}

${C_BOLD}Админка AdGuard:${C_RESET} ${C_CYAN}https://$DNS_HOST${C_RESET}
  логин: $AGH_USER   пароль: $AGH_PASS

Проверка: с телефона на мобильном интернете открой chatgpt.com.

⚠️ Госуслуги иногда не открываются со своим DNS (Сбер работает).
Тогда: Частный DNS → «Автоматически», сделай дела — и включи обратно.
Одно имя = одно устройство. Новое устройство — пункт «Добавить устройство».
EOF
}

aip_install() {
  if aip_installed; then
    warn "Прокси для нейронок уже стоит. Чтобы поставить заново — сначала «Удалить»."
    return 0
  fi
  step "Прокси для нейронок: что понадобится"
  say "Домен, бесплатный аккаунт Cloudflare и 15 минут."
  say "Я буду останавливаться и говорить, что сделать руками."
  confirm "Начинаем?" || return 0

  ensure_pkgs curl jq dnsutils openssl || return 1

  SERVER_IP=$(server_ip)
  SERVER_IP=$(ask "IP этого сервера" "$SERVER_IP")

  aip_txt_intro
  step "Этап 1: домен"
  aip_txt_buy | todo
  confirm "Домен куплен?" || { say "Возвращайся, когда будет домен."; return 0; }
  step "Этап 2: Cloudflare"
  aip_txt_cf | todo
  confirm "Домен в Cloudflare стал Active?" || { say "Подожди и запусти установку снова — начнём с этого места."; return 0; }
  DOMAIN=$(aip_ask_domain)
  DNS_HOST="dns.$DOMAIN"

  step "Этап 3: ключ"
  aip_explain_token
  CF_TOKEN=$(sec_cf_token)
  if [ -n "$CF_TOKEN" ] && confirm "Есть сохранённый ключ $(sec_mask "$CF_TOKEN"). Взять его?"; then
    :
  else
    while true; do
      CF_TOKEN=$(ask_secret "Вставь ключ (ввод не видно, это нормально)")
      sec_cf_verify "$CF_TOKEN" && { ok "Cloudflare ключ принял"; break; }
      warn "Cloudflare этот ключ не принимает. Скопируй целиком или сделай новый."
    done
    sec_cf_save "$CF_TOKEN"
  fi

  step "Этап 4: записи — делаю сама"
  local rc=0
  sec_cf_records "$DNS_HOST" "$SERVER_IP" || rc=$?
  if [ "$rc" -eq 3 ] && confirm "Перезаписать эти имена на этот сервер?"; then
    rc=0; sec_cf_records "$DNS_HOST" "$SERVER_IP" force || rc=$?
  fi
  if [ "$rc" -ne 0 ]; then
    warn "Сама не смогла — сделай руками:"
    aip_explain_records "$SERVER_IP"
    pause
    aip_wait_dns "$DNS_HOST" "$SERVER_IP" || return 1
  fi

  step "Этап 5: твой телефон"
  say "Придумай имя для своего телефона латиницей: например vasya-phone."
  while true; do
    FIRST_CLIENT=$(ask "Имя устройства" "phone" | tr 'A-Z' 'a-z')
    [[ "$FIRST_CLIENT" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] && break
    warn "Только маленькие латинские буквы, цифры и дефис."
  done

  aip_install_core || return 1
  aip_status
  aip_show_howto "$FIRST_CLIENT"
  warn "Пароль от админки сохранён в $AIP_ENV — смотри через пункт «Как подключить»."
}

# Установка без вопросов. Нужны: SERVER_IP, DOMAIN, CF_TOKEN, FIRST_CLIENT.
# Её же зовёт бот.
aip_install_core() {
  DNS_HOST="dns.$DOMAIN"
  ensure_pkgs curl jq dnsutils openssl cron ufw || return 1
  ensure_docker || return 1

  step "Проверяю порты"
  aip_free_port53 || return 1
  aip_check_ports || { err "Освободи порты и запусти установку снова."; return 1; }

  AGH_USER="admin"
  AGH_PASS=$(gen_password)

  aip_get_cert || return 1
  aip_write_renew
  aip_start_adguard || return 1
  aip_configure_adguard || return 1
  aip_write_nginx
  aip_start_nginx || return 1
  aip_save_env
  sec_domain_save "$DOMAIN"
  unset CF_TOKEN

  fw_register aiproxy "443/tcp 53/tcp 53/udp 853/tcp 853/udp"
  fw_apply
}

# ───────────────────────── обслуживание ─────────────────────────

aip_status() {
  aip_installed || { warn "Прокси для нейронок не установлен."; return 0; }
  aip_load_env
  step "Состояние"
  local c st code
  for c in "$AIP_C_AGH" "$AIP_C_NGX"; do
    st=$(docker inspect -f '{{.State.Status}}' "$c" 2>/dev/null || echo "нет")
    [ "$st" = "running" ] && ok "$c: работает" || err "$c: $st"
  done

  local cert="$AIP_LE/live/$DNS_HOST/fullchain.pem"
  if [ -r "$cert" ]; then
    ok "Сертификат до: $(openssl x509 -enddate -noout -in "$cert" | cut -d= -f2)"
  else
    err "Сертификата нет"
  fi

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    --resolve "$DNS_HOST:443:127.0.0.1" "https://$DNS_HOST/")
  [[ "$code" =~ ^(200|302)$ ]] && ok "Админка и DoH через 443 отвечают" || err "https://$DNS_HOST не отвечает (код $code)"

  code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 8 \
    --resolve "chatgpt.com:443:127.0.0.1" "https://chatgpt.com/")
  [ "$code" != "000" ] && ok "Проброс нейронок работает (chatgpt.com ответил $code)" \
    || err "Проброс нейронок не работает"
  say "Нормально: всё зелёное. Код ChatGPT 403 тоже норма — главное, что не 000."
}

aip_logs() {
  aip_installed || { warn "Не установлен."; return 0; }
  step "AdGuard — последние строки"
  docker logs --tail 30 "$AIP_C_AGH" 2>&1
  step "nginx — последние строки"
  docker logs --tail 30 "$AIP_C_NGX" 2>&1
  say "Ищи слова error / fail. Если их нет — всё нормально."
}

aip_restart() {
  aip_installed || { warn "Не установлен."; return 0; }
  docker restart "$AIP_C_AGH" "$AIP_C_NGX" >/dev/null && ok "Перезапущено"
}

aip_add_client() {
  aip_installed || { warn "Не установлен."; return 0; }
  aip_load_env
  local c
  while true; do
    c=$(ask "Имя нового устройства латиницей (например mama-phone)" | tr 'A-Z' 'a-z')
    [[ "$c" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] && break
    warn "Только маленькие латинские буквы, цифры и дефис."
  done
  aip_set_clients "$c" && aip_show_howto "$c"
}

aip_update_domains() {
  aip_installed || { warn "Не установлен."; return 0; }
  aip_load_env
  aip_write_ai_map
  aip_nginx_test || { err "Ошибка в списке доменов, nginx не трогаю"; return 1; }
  docker exec "$AIP_C_NGX" nginx -s reload && ok "nginx подхватил список"
  aip_sync_rewrites
}

aip_remove() {
  aip_installed || { warn "Не установлен."; return 0; }
  warn "Удалю AdGuard, nginx и автопродление сертификата. Устройства перестанут работать."
  confirm "Точно удалить?" || return 0
  local purge=0
  confirm "Удалить ещё и данные (настройки, сертификат, пароль)? Это необратимо" && purge=1
  aip_remove_core "$purge"
}

aip_remove_core() {
  docker rm -f "$AIP_C_AGH" "$AIP_C_NGX" >/dev/null 2>&1
  rm -f "$AIP_CRON"
  fw_unregister aiproxy
  if [ "${1:-0}" = "1" ]; then
    rm -rf "$AIP_DIR" "$KB_HOME/bin/cert-renew.sh"
    ok "Удалено полностью"
  else
    mv "$AIP_ENV" "$AIP_ENV.removed"
    ok "Контейнеры удалены, данные остались в $AIP_DIR"
  fi
}

aip_menu() {
  while true; do
    cat <<EOF

${C_BOLD}══ Прокси для нейронок (AdGuard + nginx) ══${C_RESET}
 1) Установить
 2) Состояние
 3) Как подключить устройство
 4) Добавить устройство
 5) Обновить список нейронок
 6) Логи
 7) Перезапустить
 8) Удалить
 0) Назад
EOF
    case "$(ask "Выбор")" in
      1) aip_install ;;
      2) aip_status ;;
      3) aip_installed && aip_show_howto "$(ask "Имя устройства")" || warn "Не установлен." ;;
      4) aip_add_client ;;
      5) aip_update_domains ;;
      6) aip_logs ;;
      7) aip_restart ;;
      8) aip_remove ;;
      0) return ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

# ───────────────────────── команды для бота ─────────────────────────
# kombain cli aiproxy <команда> [аргументы]

aip_valid_client() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]]; }

aip_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    info)
      if aip_installed; then
        aip_load_env
        jq -nc --arg d "$DOMAIN" --arg h "$DNS_HOST" --arg ip "$SERVER_IP" \
          --argjson c "$(aip_api GET /access/list 2>/dev/null | jq -c '.allowed_clients // []' || echo '[]')" \
          '{installed:true, domain:$d, dns_host:$h, server_ip:$ip, clients:$c}'
      else
        jq -nc --arg ip "$(server_ip)" '{installed:false, server_ip:$ip}'
      fi ;;
    text-domain)  aip_txt_domain ;;
    text-intro)   aip_txt_intro ;;
    text-buy)     aip_txt_buy ;;
    text-cf)      aip_txt_cf ;;
    text-records) aip_txt_records "${1:?ip}" ;;
    text-token)   aip_txt_token ;;
    check-dns)    ensure_pkgs dnsutils >/dev/null 2>&1; aip_dns_ok "dns.${1:?домен}" "${2:-$(server_ip)}" ;;
    make-dns)
      # сами ставим записи dns.<домен> и *.dns.<домен> ключом из сейфа; --force — перезаписать занятые
      ensure_pkgs curl jq >/dev/null 2>&1
      local d ip; d="${KB_DOMAIN:-$(sec_domain)}"; ip="${KB_SERVER_IP:-$(server_ip)}"
      [ -n "$d" ] || { err "Нет домена в сейфе"; return 1; }
      [ -n "$(sec_cf_token)" ] || { err "Нет ключа Cloudflare"; return 1; }
      sec_cf_records "dns.$d" "$ip" "$([ "${1:-}" = "--force" ] && echo force)" ;;
    install)
      aip_installed && { err "Уже установлено"; return 1; }
      DOMAIN="${KB_DOMAIN:-$(sec_domain)}"; [ -n "$DOMAIN" ] || { err "Нет домена в сейфе"; return 1; }; CF_TOKEN="${KB_CF_TOKEN:-$(sec_cf_token)}"; FIRST_CLIENT="${KB_CLIENT:-$(sec_client)}"; FIRST_CLIENT="${FIRST_CLIENT:-phone}"
      SERVER_IP="${KB_SERVER_IP:-$(server_ip)}"
      [ -n "$CF_TOKEN" ] || { err "Нет ключа Cloudflare"; return 1; }
      aip_valid_client "$FIRST_CLIENT" || { err "Плохое имя устройства"; return 1; }
      aip_install_core ;;
    status)         aip_status ;;
    logs)           aip_logs ;;
    restart)        aip_restart ;;
    update-domains) aip_update_domains ;;
    add-client)
      aip_installed || { err "Не установлен"; return 1; }
      aip_load_env
      aip_valid_client "${1:-}" || { err "Только маленькие латинские буквы, цифры и дефис"; return 1; }
      aip_set_clients "$1" ;;
    howto)          aip_installed || return 1; aip_show_howto "${1:?имя}" ;;
    check-client)   aip_installed || return 1; aip_load_env; aip_check_client "${1:?имя}" ;;
    remove)         aip_installed || return 1; aip_remove_core "$([ "${1:-}" = "--purge" ] && echo 1 || echo 0)" ;;
    *) err "Неизвестная команда: $cmd"; return 2 ;;
  esac
}
