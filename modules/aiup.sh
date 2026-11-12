#!/usr/bin/env bash
# Модуль «Прокси для нейронок»: купленный прокси нужной страны как выход только для нейронок.
#
# Как это работает:
#  - Человек покупает индивидуальный прокси (SOCKS5 или HTTP) в стране, где пускает Gemini.
#  - Xray (модуль VLESS) отправляет через него ТОЛЬКО домены из data/ai-proxy-domains.txt,
#    остальной трафик идёт с IP сервера, как раньше. Google видит страну прокси, а не сервера.
#  - UDP к этим доменам режем: иначе QUIC пойдёт к Google мимо прокси. Браузер сам перейдёт на TCP.
#  - Настройка живёт отдельно ($AUP_DIR) и вклеивается при КАЖДОЙ сборке конфига Xray (vls_write_conf),
#    поэтому не слетает, когда в боте добавляют/удаляют устройство или включают WARP.
#  - Включено (есть флаг $AUP_ON), а файл прокси битый — сборка останавливается ДО перезапуска:
#    иначе нейронки молча пошли бы с IP сервера.
#  - Прокси упал — нейронки не открываются (сами на IP сервера НЕ переключаемся: Google запомнит не ту страну).
#  - Пока только для устройств VLESS. AmneziaWG и DNS-режим — позже.

AUP_DIR="$KB_HOME/aiup"
AUP_FILE="$AUP_DIR/proxy.json"
AUP_ON="$AUP_DIR/on"
AUP_DOMAINS="$KB_SRC/data/ai-proxy-domains.txt"
# Страны, где Gemini не работает (и ZZ — «неизвестно»). Такой прокси не берём.
AUP_BAD="RU BY CN HK MO IR KP SY CU ZZ"

aup_on() { [ -e "$AUP_ON" ]; }

# Домены из файла → формат Xray: «.x.com» → domain:x.com, «x.com» → full:x.com
aup_domains_json() {
  grep -v '^[[:space:]]*\(#\|$\)' "$AUP_DOMAINS" 2>/dev/null | tr -d '\r ' |
    awk '/^\./{print "domain:" substr($0, 2); next} {print "full:" $0}' | jq -R . | jq -sc .
}

# Разбор строки прокси. Понимает:
#   socks5://логин:пароль@IP:порт   (socks5h://, socks:// — то же самое)
#   http://логин:пароль@IP:порт
#   IP:порт:логин:пароль            (так часто пишут в кабинетах продавцов)
#   IP:порт                          (без пароля)
# Печатает JSON {type, address, port, user, pass} или возвращает 1.
aup_parse() {
  local s="$1" type="socks" rest cred="" hp host port user="" pass=""
  s=$(printf '%s' "$s" | tr -d '\r\n\t ')
  case "$s" in
    socks5h://*|socks5://*|socks://*|socks4://*) [[ "$s" == socks4* ]] && return 1; rest="${s#*://}" ;;
    http://*) type="http"; rest="${s#*://}" ;;
    *://*) return 1 ;;
    *) rest="$s" ;;
  esac
  rest="${rest%/}"
  if [[ "$s" == *://* ]]; then
    if [[ "$rest" == *@* ]]; then cred="${rest%@*}"; hp="${rest##*@}"; else hp="$rest"; fi
    if [ -n "$cred" ]; then user="${cred%%:*}"; [[ "$cred" == *:* ]] && pass="${cred#*:}"; fi
    local re6='^\[([0-9a-fA-F:]+)\]:([0-9]{1,5})$' re4='^([^]:[]+):([0-9]{1,5})$'
    if [[ "$hp" =~ $re6 ]] || [[ "$hp" =~ $re4 ]]; then
      host="${BASH_REMATCH[1]}"; port="${BASH_REMATCH[2]}"
    else return 1; fi
  else
    # IP:порт:логин:пароль — пароль может содержать двоеточие, берём всё после третьего
    IFS=: read -r host port user pass <<<"$rest"
    [[ "$port" =~ ^[0-9]{1,5}$ ]] || return 1
  fi
  [[ "$host" =~ ^[A-Za-z0-9.:-]+$ ]] || return 1
  [ "$port" -ge 1 ] && [ "$port" -le 65535 ] || return 1
  # %XX в логине/пароле (если продавец закодировал спецсимволы)
  aup_unpct() { if [[ "$1" =~ %[0-9A-Fa-f]{2} ]] && [[ "$1" != *\\* ]]; then printf '%b' "${1//%/\\x}"; else printf '%s' "$1"; fi; }
  user=$(aup_unpct "$user"); pass=$(aup_unpct "$pass")
  jq -nc --arg t "$type" --arg a "$host" --argjson p "$port" --arg u "$user" --arg w "$pass" \
    '{type: $t, address: $a, port: $p, user: $u, pass: $w}'
}

# curl через прокси из JSON (логин и пароль — через stdin, чтобы не светить их в списке процессов)
aup_curl() {
  local j="$1"; shift
  local type addr port user pass scheme host
  type=$(jq -r .type <<<"$j"); addr=$(jq -r .address <<<"$j"); port=$(jq -r .port <<<"$j")
  user=$(jq -r .user <<<"$j"); pass=$(jq -r .pass <<<"$j")
  scheme="socks5h"; [ "$type" = http ] && scheme="http"
  host="$addr"; [[ "$addr" == *:* ]] && host="[$addr]"
  esc_cfg() { local v="${1//\\/\\\\}"; printf '%s' "${v//\"/\\\"}"; }
  {
    printf 'proxy = "%s://%s:%s"\n' "$scheme" "$host" "$port"
    [ -n "$user" ] && printf 'proxy-user = "%s:%s"\n' "$(esc_cfg "$user")" "$(esc_cfg "$pass")"
  } | curl -s --connect-timeout 10 --max-time 25 -K - "$@"
}

# Проверка прокси. Печатает понятные строки, последней — JSON для бота:
#   {verdict: ok|bad|unknown, ip, country, org, google, reason}
aup_check() {
  local j="$1" ipj ip="" cc="" org="" gl="" verdict reason
  ipj=$(aup_curl "$j" https://ipinfo.io/json)
  ip=$(jq -r '.ip // empty' <<<"$ipj" 2>/dev/null); cc=$(jq -r '.country // empty' <<<"$ipj" 2>/dev/null)
  org=$(jq -r '.org // empty' <<<"$ipj" 2>/dev/null)
  if [ -z "$ip" ]; then   # ipinfo мог упереться в лимит — запасной сайт
    ipj=$(aup_curl "$j" 'http://ip-api.com/json/?fields=query,countryCode,isp')
    ip=$(jq -r '.query // empty' <<<"$ipj" 2>/dev/null); cc=$(jq -r '.countryCode // empty' <<<"$ipj" 2>/dev/null)
    org=$(jq -r '.isp // empty' <<<"$ipj" 2>/dev/null)
  fi
  if [ -n "$ip" ]; then
    # Страна, как её видит сам Google: [["yt.sw.adr",null,[[["nl","NL",...
    gl=$(aup_curl "$j" https://www.youtube.com/sw.js_data | head -c 400 |
      sed -n 's/.*\[\[\["[^"]*","\([A-Z][A-Z]\)".*/\1/p' | head -1)
  fi
  if [ -z "$ip" ]; then
    verdict=bad; reason="Прокси не отвечает: неверный логин/пароль, адрес или порт, либо прокси выключен"
  elif [ -n "$gl" ] && [[ " $AUP_BAD " == *" $gl "* ]]; then
    verdict=bad; reason="Google видит страну $gl — там Gemini не работает. Нужна другая страна"
  elif [ -z "$gl" ] && [ -n "$cc" ] && [[ " $AUP_BAD " == *" $cc "* ]]; then
    verdict=bad; reason="IP из страны $cc — там Gemini не работает. Нужна другая страна"
  elif [ -z "$gl" ]; then
    verdict=unknown; reason="Прокси работает, но страну для Google проверить не смог. Можно включить и проверить Gemini вживую"
  else
    verdict=ok; reason="Годится"
  fi
  say "Выход прокси: ${ip:-нет ответа} ${cc:+($cc)} ${org:+— $org}"
  [ -n "$ip" ] && say "Google видит страну: ${gl:-не определил}"
  case "$verdict" in ok) ok "$reason" ;; unknown) warn "$reason" ;; *) err "$reason" 2>&1 ;; esac
  jq -nc --arg v "$verdict" --arg ip "$ip" --arg cc "$cc" --arg org "$org" --arg gl "$gl" --arg r "$reason" \
    '{verdict: $v, ip: $ip, country: $cc, org: $org, google: $gl, reason: $r}'
}

# Вклеить выход и правила в собранный конфиг Xray. Вызывает vls_write_conf ДО проверки xray -test.
aup_apply() {
  local f="$1" d tmp
  aup_on || return 0
  d=$(aup_domains_json)
  if ! jq -e '(.type == "socks" or .type == "http") and (.address | type == "string" and length > 0)
              and (.port | type == "number" and . >= 1 and . <= 65535)' "$AUP_FILE" >/dev/null 2>&1 \
     || [ "$(jq 'length' <<<"${d:-[]}")" -eq 0 ] \
     || [ "$(jq -r '.routing.rules[0].outboundTag' "$f" 2>/dev/null)" != "block" ]; then
    err "Прокси для нейронок включён, но его настройка повреждена — конфиг Xray НЕ меняю."
    err "Вставь прокси заново или выключи: 🧠 Нейронки → 🌍 Прокси для нейронок."
    return 1
  fi
  tmp=$(umask 077; mktemp "$f.aup.XXXXXX") || return 1
  if ! jq --slurpfile p "$AUP_FILE" --argjson d "$d" '
      ($p[0]) as $p
      | ({address: $p.address, port: $p.port}
         + (if ($p.user // "") != "" then {users: [{user: $p.user, pass: ($p.pass // "")}]} else {} end)) as $srv
      | .outbounds += [{tag: "aiproxy", protocol: $p.type, settings: {servers: [$srv]}}]
      | .routing.rules = (.routing.rules[:1]
          + [{type: "field", network: "udp", domain: $d, outboundTag: "block"},
             {type: "field", domain: $d, outboundTag: "aiproxy"}]
          + .routing.rules[1:])' "$f" >"$tmp"; then
    rm -f "$tmp"; err "Не смог вклеить прокси в конфиг Xray."; return 1
  fi
  mv -f "$tmp" "$f"
}

# Пересобрать VLESS с текущей настройкой (если VLESS стоит)
aup_rebuild() {
  declare -F vls_installed >/dev/null && vls_installed || return 0
  vls_load_env; vls_write_conf && vls_restart
}

aup_set() {
  local raw="${KB_AIUP_URL:-${1:-}}" j res v old="" was_on=0
  [ -n "$raw" ] || { err "Пришли строку прокси, например socks5://логин:пароль@1.2.3.4:8000"; return 1; }
  j=$(aup_parse "$raw") || { err "Не понял строку прокси. Нужно так: socks5://логин:пароль@IP:порт"; return 1; }
  step "Проверяю прокси"
  res=$(aup_check "$j"); printf '%s\n' "$res" | sed '$d'
  v=$(tail -1 <<<"$res" | jq -r .verdict)
  [ "$v" = bad ] && { tail -1 <<<"$res"; return 1; }
  install -d -m 0700 "$AUP_DIR"
  [ -r "$AUP_FILE" ] && old=$(cat "$AUP_FILE"); aup_on && was_on=1
  ( umask 077
    jq -c --argjson r "$(tail -1 <<<"$res")" --arg t "$(TZ=Europe/Moscow date '+%d.%m %H:%M МСК')" \
      '. + {ip: $r.ip, country: $r.country, org: $r.org, google: $r.google, verdict: $r.verdict, checked: $t}' \
      <<<"$j" >"$AUP_FILE" )
  touch "$AUP_ON"
  if ! aup_rebuild; then
    err "Xray с прокси не поднялся — вернул как было."
    if [ -n "$old" ]; then ( umask 077; printf '%s\n' "$old" >"$AUP_FILE" ); else rm -f "$AUP_FILE"; fi
    [ "$was_on" = 1 ] || rm -f "$AUP_ON"
    aup_rebuild
    tail -1 <<<"$res"; return 1
  fi
  if declare -F vls_installed >/dev/null && vls_installed; then
    ok "Прокси включён: нейронки на устройствах VLESS идут через $(jq -r .address <<<"$j")"
  else
    warn "Прокси сохранён, но VLESS не установлен — заработает, как только поставишь VLESS."
  fi
  tail -1 <<<"$res"
}

aup_off() {
  aup_on || [ -e "$AUP_FILE" ] || { ok "Прокси для нейронок и так выключен"; return 0; }
  rm -f "$AUP_ON" "$AUP_FILE"
  aup_rebuild || return 1
  ok "Прокси для нейронок выключен — нейронки идут с IP сервера"
}

# Проверить сохранённый прокси ещё раз (и записать результат)
aup_test() {
  aup_on && [ -r "$AUP_FILE" ] || { warn "Прокси для нейронок не включён"; jq -nc '{verdict: "off"}'; return 1; }
  local j res
  j=$(jq -c '{type, address, port, user, pass}' "$AUP_FILE")
  res=$(aup_check "$j"); printf '%s\n' "$res" | sed '$d'
  if declare -F vls_installed >/dev/null && vls_installed; then
    if jq -e '.outbounds[] | select(.tag == "aiproxy")' "$VLS_CONF" >/dev/null 2>&1; then ok "Xray: выход через прокси на месте"
    else err "Xray: выхода через прокси в конфиге нет — включи прокси заново"; fi
    vls_running && ok "Xray работает" || err "Xray не запущен"
  else
    warn "VLESS не установлен — прокси пока ни на что не действует"
  fi
  ( umask 077
    jq -c --argjson r "$(tail -1 <<<"$res")" --arg t "$(TZ=Europe/Moscow date '+%d.%m %H:%M МСК')" \
      '. + {ip: $r.ip, country: $r.country, org: $r.org, google: $r.google, verdict: $r.verdict, checked: $t}' \
      "$AUP_FILE" >"$AUP_FILE.new" ) && mv -f "$AUP_FILE.new" "$AUP_FILE"
  tail -1 <<<"$res"
}

aup_info() {
  local vless=false
  declare -F vls_installed >/dev/null && vls_installed && vless=true
  if aup_on && [ -r "$AUP_FILE" ]; then
    jq -c --argjson vl "$vless" '{on: true, vless: $vl, type, address, port, ip, country, org, google, verdict, checked}' "$AUP_FILE"
  else
    jq -nc --argjson vl "$vless" '{on: false, vless: $vl}'
  fi
}

# kombain cli aiup <команда>   (строку прокси лучше передавать в KB_AIUP_URL, а не аргументом)
aup_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    info)  aup_info ;;
    check) local j; j=$(aup_parse "${KB_AIUP_URL:-${1:-}}") ||
             { err "Не понял строку прокси. Нужно так: socks5://логин:пароль@IP:порт" 2>&1
               jq -nc '{verdict: "bad", reason: "Не понял строку. Нужно так: socks5://логин:пароль@IP:порт"}'; return 1; }
           aup_check "$j" 2>&1 ;;
    set)   aup_set "$@" ;;
    test)  aup_test 2>&1 ;;
    off)   aup_off ;;
    domains) aup_domains_json | jq -r '.[]' ;;
    *) err "Неизвестная команда: $cmd"; return 2 ;;
  esac
}
