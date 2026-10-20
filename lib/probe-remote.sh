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

# Кто выдал IP (запись в реестре RIPE/ARIN/...) и как адрес видят разные базы
ip=$(jf ip "$info")
if [ -n "$ip" ] && command -v python3 >/dev/null 2>&1; then
  w=$(get "https://stat.ripe.net/data/whois/data.json?resource=$ip")
  a=$(get "http://ip-api.com/json/$ip?fields=status,countryCode,isp,org,as,hosting,proxy")
  W="$w" A="$a" python3 - <<'PY' 2>/dev/null
import json, os
def clean(v):
    return " ".join(str(v).split())[:120]
try:
    recs = json.loads(os.environ.get("W") or "{}").get("data", {}).get("records", [])
except Exception:
    recs = []
best = {}
for rec in recs:
    kv = {}
    for f in rec:
        k = f.get("key", "").lower()
        kv.setdefault(k, f.get("value", ""))
    if any(k in kv for k in ("inetnum", "netrange", "cidr", "inet6num")):
        best = kv          # последняя запись — самый узкий блок
net = best.get("netname", "")
owner = best.get("org-name") or best.get("orgname") or best.get("descr") or best.get("org") or ""
print("REG_NET=" + clean(net))
print("REG_OWNER=" + clean(owner))
print("REG_COUNTRY=" + clean(best.get("country", "")))
try:
    a = json.loads(os.environ.get("A") or "{}")
except Exception:
    a = {}
if a.get("status") == "success":
    print("IPAPI_ISP=" + clean(a.get("isp", "")))
    print("IPAPI_ORG=" + clean(a.get("org", "")))
    print("IPAPI_COUNTRY=" + clean(a.get("countryCode", "")))
    print("IPAPI_HOSTING=" + ("yes" if a.get("hosting") else "no"))
    print("IPAPI_PROXY=" + ("yes" if a.get("proxy") else "no"))
PY
fi

# Кем видит Google (от этого зависит Gemini)
yt=$(get https://www.youtube.com/sw.js_data | head -c 5000)
gl=$(grep -oE '"GL" *[,:]( *null *,)* *"[A-Z]{2}"' <<<"$yt" | head -n1 | grep -oE '"[A-Z]{2}"$' | tr -d '"')
if [ -z "$gl" ]; then   # запасной способ — с главной YouTube
  yh=$(get -H 'Accept-Language: en' https://www.youtube.com/ | head -c 400000)
  gl=$(grep -oE '"(INNERTUBE_CONTEXT_GL|GL|gl)":"[A-Z]{2}"' <<<"$yh" | head -n1 | grep -oE '"[A-Z]{2}"$' | tr -d '"')
  [ -z "$gl" ] && gl=$(grep -oE '"countryCode":"[A-Z]{2}"' <<<"$yh" | head -n1 | grep -oE '"[A-Z]{2}"$' | tr -d '"')
fi
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
