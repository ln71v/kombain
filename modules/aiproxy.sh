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
AIP_SECRETS="$AIP_DIR/secrets"
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

aip_explain_domain() {
  todo <<'EOF'
1. КУПИ ДОМЕН. Любой, самый дешёвый.
   Проверено: reg.ru — покупка быстрая, Cloudflare принимает.
   Пример: mojdns.site
   СРАЗУ СКРОЙ СВОИ ДАННЫЕ, иначе телефон и почту видит любой:
   reg.ru → домен → «Управление» → «Ещё услуги» →
   «Скрытие персональных данных» → «Заказать» (платно).

2. ЗАРЕГИСТРИРУЙСЯ В CLOUDFLARE: dash.cloudflare.com → Sign up.
   Это бесплатно. Cloudflare будет держать DNS твоего домена.

3. ДОБАВЬ ДОМЕН В CLOUDFLARE:
   кнопка «Add a domain» → впиши домен → план Free → Continue.
   Cloudflare покажет два адреса вида xxx.ns.cloudflare.com.

4. У РЕГИСТРАТОРА (где купил домен) найди «DNS-серверы» / «NS»
   и замени их на эти два адреса от Cloudflare. Сохрани.
   Обновляется от 10 минут до суток, обычно быстро.
EOF
}

aip_explain_records() {
  local ip="$1"
  todo <<EOF
В Cloudflare открой свой домен → слева DNS → Records → Add record.
Создай ДВЕ записи:

  Type: A   Name: dns     IPv4: $ip   Proxy status: DNS only (СЕРОЕ облако)
  Type: A   Name: *.dns   IPv4: $ip   Proxy status: DNS only (СЕРОЕ облако)

Облако обязательно СЕРОЕ. Оранжевое = не заработает.
EOF
}

aip_explain_token() {
  todo <<'EOF'
Нужен ключ Cloudflare, чтобы сервер сам получил сертификат:

1. Cloudflare → справа вверху значок человечка → My Profile
2. Слева «API Tokens» → «Create Token»
3. Напротив «Edit zone DNS» нажми «Use template»
4. Zone Resources: Include → Specific zone → выбери свой домен
5. Continue to summary → Create Token
6. Скопируй длинный ключ. Он показывается один раз.
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

# Ждём, пока dns.<домен> и test.dns.<домен> смотрят на наш IP
aip_wait_dns() {
  local host="$1" ip="$2" a b
  while true; do
    a=$(dig +short @1.1.1.1 "$host" A | tail -1)
    b=$(dig +short @1.1.1.1 "proverka.$host" A | tail -1)
    if [ "$a" = "$ip" ] && [ "$b" = "$ip" ]; then
      ok "Записи видны: $host и *.$host → $ip"
      return 0
    fi
    warn "Пока не вижу: $host → ${a:-ничего}, *.$host → ${b:-ничего} (нужно $ip)"
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
  mkdir -p "$AIP_LE" "$AIP_SECRETS"
  chmod 700 "$AIP_SECRETS"
  printf 'dns_cloudflare_api_token = %s\n' "$CF_TOKEN" >"$AIP_SECRETS/cloudflare.ini"
  chmod 600 "$AIP_SECRETS/cloudflare.ini"
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
  curl -fsS -X POST -H 'Content-Type: application/json' --data "$body" \
    "$AIP_API/install/configure" >/dev/null || { err "Не смогла выполнить первичную настройку AdGuard"; return 1; }

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

  # IPv6-ответы выключаем, иначе часть трафика пойдёт мимо сервера
  aip_api POST /dns_config '{"disable_ipv6":true}' >/dev/null && ok "IPv6-ответы выключены"

  aip_set_clients "$FIRST_CLIENT" || return 1
  aip_sync_rewrites
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

  ensure_pkgs curl jq dnsutils openssl cron || return 1
  ensure_docker || return 1

  SERVER_IP=$(server_ip)
  SERVER_IP=$(ask "IP этого сервера" "$SERVER_IP")

  step "Шаг 1 из 4: домен"
  aip_explain_domain
  confirm "Домен купил и добавил в Cloudflare?" || { say "Возвращайся, когда будет домен."; return 0; }
  DOMAIN=$(aip_ask_domain)
  DNS_HOST="dns.$DOMAIN"

  step "Шаг 2 из 4: записи в Cloudflare"
  aip_explain_records "$SERVER_IP"
  pause
  aip_wait_dns "$DNS_HOST" "$SERVER_IP" || return 1

  step "Шаг 3 из 4: ключ Cloudflare"
  aip_explain_token
  CF_TOKEN=$(ask_secret "Вставь ключ (ввод не видно, это нормально)")
  [ -z "$CF_TOKEN" ] && { err "Ключ пустой"; return 1; }

  step "Шаг 4 из 4: первое устройство"
  say "Придумай имя для своего телефона латиницей: например vasya-phone."
  while true; do
    FIRST_CLIENT=$(ask "Имя устройства" "phone" | tr 'A-Z' 'a-z')
    [[ "$FIRST_CLIENT" =~ ^[a-z0-9][a-z0-9-]{0,62}$ ]] && break
    warn "Только маленькие латинские буквы, цифры и дефис."
  done

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
  unset CF_TOKEN

  aip_status
  aip_show_howto "$FIRST_CLIENT"
  warn "Пароль от админки сохранён в $AIP_ENV — смотри через пункт «Как подключить»."
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
  docker rm -f "$AIP_C_AGH" "$AIP_C_NGX" >/dev/null 2>&1
  rm -f "$AIP_CRON"
  if confirm "Удалить ещё и данные (настройки, сертификат, пароль)? Это необратимо"; then
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
