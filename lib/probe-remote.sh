#!/usr/bin/env bash
# Проверка нового сервера. Бот запускает этот файл НА ПРОВЕРЯЕМОМ сервере по SSH:
#   ssh root@IP 'bash -s' < probe-remote.sh
# Ничего не ставит (кроме curl, если его нет) и ничего не оставляет.
# Печатает строки КЛЮЧ=значение между PROBE_BEGIN и PROBE_END — их разбирает бот.
# pipefail не включаем: «вывод | grep -q» с ним даёт ложное «нет».

export LC_ALL=C
if ! command -v curl >/dev/null 2>&1; then
  (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq curl) >/dev/null 2>&1
fi

UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0 Safari/537.36"
get() { curl -4 -s --max-time 15 -A "$UA" "$@" 2>/dev/null; }
one() { tr -d '\r\n' | tr -s ' ' | cut -c1-200; }
jf() { sed -n "s/.*\"$1\": *\"\([^\"]*\)\".*/\1/p" <<<"$2" | head -n1 | one; }

echo PROBE_BEGIN

# Сервер
. /etc/os-release 2>/dev/null
echo "OS=${PRETTY_NAME:-?}"
echo "RAM_MB=$(free -m 2>/dev/null | awk '/Mem:/ {print $2}')"
echo "DISK=$(df -h / 2>/dev/null | awk 'NR==2 {print $2}')"

# Чья сеть
info=$(get https://ipinfo.io/json)
echo "IP=$(jf ip "$info")"
echo "ORG=$(jf org "$info")"
echo "COUNTRY=$(jf country "$info")"
echo "CITY=$(jf city "$info")"
echo "HOST=$(jf hostname "$info")"

# Кем видит Google (от этого зависит Gemini)
yt=$(get https://www.youtube.com/sw.js_data | head -c 3000)
gl=$(grep -oE '"GL"[^A-Z]{1,6}[A-Z]{2}"' <<<"$yt" | head -n1 | grep -oE '[A-Z]{2}"$' | tr -d '"')
echo "GL=${gl:-?}"

# Gemini
gm=$(get -L https://gemini.google.com)
# Ответ без WIZ_global_data — это не страница Gemini (заглушка, капча), судить нельзя.
if ! grep -q 'WIZ_global_data' <<<"$gm"; then echo "GEMINI=?"
elif grep -q '45631641,null,true' <<<"$gm"; then echo "GEMINI=yes"
else echo "GEMINI=no"; fi

# ChatGPT
c1=$(get https://api.openai.com/compliance/cookie_requirements -H 'authorization: Bearer null' -H 'origin: https://platform.openai.com' -H 'referer: https://platform.openai.com/')
c2=$(get https://ios.chat.openai.com/)
if grep -qi 'unsupported_country' <<<"$c1" || grep -qi 'VPN' <<<"$c2"; then echo "CHATGPT=no"
elif grep -q '{' <<<"$c1"; then echo "CHATGPT=yes"
else echo "CHATGPT=?"; fi

# Claude
cl=$(get -L -o /dev/null -w '%{http_code} %{url_effective}' https://claude.ai/)
if [ -z "$cl" ] || [ "${cl%% *}" = "000" ]; then echo "CLAUDE=?"
elif grep -q 'unavailable-in-region' <<<"$cl"; then echo "CLAUDE=no"
else echo "CLAUDE=yes"; fi

echo PROBE_END
