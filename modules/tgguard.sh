#!/usr/bin/env bash
# Модуль «Сторож Telegram-прокси».
# Баг: прокси (замечено на mtg) иногда виснет — порт слушает, а новые подключения не берёт,
# они копятся в очереди (ss -tlnp, второй столбец: сотни вместо 0). В Telegram вечное «Соединение…».
# Служба при этом «работает», поэтому Restart=on-failure не спасает. Лечится перезапуском.
#
# Сторож ставится сам, если на сервере есть любой Telegram-прокси Комбайна
# (telegram-mtg, kombain-telemt, WEB-прокси), и сам удаляется, когда их нет.
#   - раз в минуту: очередь > TGG_LIMIT, прокси не слушает порт или упал — перезапуск;
#   - каждую ночь в 3:00 по часам сервера — плановый перезапуск.
# Журнал: journalctl -t kombain-tg-guard

TGG_VER="1"
TGG_BIN="/usr/local/lib/kombain/tg-guard.sh"
TGG_CRON="/etc/cron.d/kombain-tg-guard"
TGG_LIMIT=50
TGG_UNITS="telegram-mtg kombain-telemt tproxy-server mtproxy"

# Есть ли хоть один Telegram-прокси (файл службы на месте)
tgg_needed() {
  local u
  for u in $TGG_UNITS; do [ -f "/etc/systemd/system/$u.service" ] && return 0; done
  return 1
}
tgg_installed() { [ -x "$TGG_BIN" ] && [ -f "$TGG_CRON" ]; }
tgg_current()   { tgg_installed && grep -q "^# kombain-tg-guard v$TGG_VER\$" "$TGG_BIN"; }

tgg_script() {
  mkdir -p "$(dirname "$TGG_BIN")"
  cat >"$TGG_BIN" <<EOF
#!/usr/bin/env bash
# kombain-tg-guard v$TGG_VER
# Сторож Telegram-прокси. Ставит Комбайн (модуль tgguard) — руками не править, затрётся при обновлении.
# Без аргументов (раз в минуту): прокси завис (очередь входящих > $TGG_LIMIT), не слушает порт или упал — перезапуск.
# --nightly: плановый перезапуск всех Telegram-прокси.
LIMIT=$TGG_LIMIT
UNITS="$TGG_UNITS"
EOF
  cat >>"$TGG_BIN" <<'EOF'
log() { logger -t kombain-tg-guard "$*"; }
up_us=$(awk '{printf "%d", $1*1000000}' /proc/uptime)
for u in $UNITS; do
  systemctl is-enabled --quiet "$u" 2>/dev/null || continue
  if [ "${1:-}" = "--nightly" ]; then
    systemctl restart "$u" && log "$u: ночной перезапуск"; continue
  fi
  if ! systemctl is-active --quiet "$u"; then
    systemctl reset-failed "$u" >/dev/null 2>&1
    systemctl restart "$u" && log "$u: был остановлен — запустил"; continue
  fi
  # Только что запустился — даём минуту подняться
  since=$(systemctl show -p ActiveEnterTimestampMonotonic --value "$u")
  [ $(( up_us - ${since:-0} )) -gt 60000000 ] || continue
  # Все процессы службы (MTProxy бывает с дочерними) → их порты и очередь
  cg=$(systemctl show -p ControlGroup --value "$u")
  pids=""
  for f in "/sys/fs/cgroup$cg/cgroup.procs" "/sys/fs/cgroup/systemd$cg/cgroup.procs"; do
    [ -r "$f" ] && { pids=$(tr '\n' ' ' <"$f"); break; }
  done
  [ -n "${pids// /}" ] || pids=$(systemctl show -p MainPID --value "$u")
  [ "${pids// /}" != "0" ] && [ -n "${pids// /}" ] || continue
  q=$(ss -Hltnp 2>/dev/null | awk -v pids="$pids" '
        BEGIN { n = split(pids, a, " "); for (i = 1; i <= n; i++) want["pid=" a[i] ","] = 1 }
        { for (k in want) if (index($0, k)) { print $2; break } }' | sort -n | tail -1)
  if [ -z "$q" ]; then
    systemctl restart "$u" && log "$u: не слушает порт — перезапуск"
  elif [ "$q" -gt "$LIMIT" ]; then
    systemctl restart "$u" && log "$u: завис, в очереди $q — перезапуск"
  fi
done
exit 0
EOF
  chmod 0755 "$TGG_BIN"
}

tgg_install() {
  command -v cron >/dev/null 2>&1 || ensure_pkgs cron >/dev/null 2>&1 || { err "Не смог поставить cron для сторожа."; return 1; }
  systemctl enable --now cron >/dev/null 2>&1
  tgg_script
  printf '%s\n' \
    "# Сторож Telegram-прокси Комбайна (модуль tgguard). Журнал: journalctl -t kombain-tg-guard" \
    "* * * * * root $TGG_BIN" \
    "0 3 * * * root $TGG_BIN --nightly" >"$TGG_CRON"
  chmod 0644 "$TGG_CRON"
  # Сторож, поставленный руками до Комбайна, — убираем, чтобы не перезапускали вдвоём
  rm -f /etc/cron.d/mtg-watchdog /usr/local/bin/mtg-watchdog.sh
  ok "Сторож Telegram-прокси стоит (журнал: journalctl -t kombain-tg-guard)"
}

tgg_remove() {
  tgg_installed || return 0
  rm -f "$TGG_CRON" "$TGG_BIN"
  ok "Сторож Telegram-прокси убран — Telegram-прокси на сервере больше нет"
}

# mtg старых установок: concurrency = 512 — при стольких висящих подключениях mtg перестаёт
# брать новые (похоже на причину зависаний). Поднимаем до 4096 и лимит файлов под это.
tgg_fix_mtg() {
  local conf=/etc/telegram-mtg/config.toml unit=/etc/systemd/system/telegram-mtg.service ch=0
  [ -f "$conf" ] && [ -f "$unit" ] || return 0
  if grep -q '^concurrency = 512$' "$conf"; then
    backup_file "$conf"
    sed -i 's/^concurrency = 512$/concurrency = 4096/' "$conf"; ch=1
  fi
  if grep -q '^LimitNOFILE=8192$' "$unit"; then
    backup_file "$unit"
    sed -i 's/^LimitNOFILE=8192$/LimitNOFILE=65536/' "$unit"; ch=1
  fi
  [ "$ch" = 1 ] || return 0
  systemctl daemon-reload
  systemctl is-enabled --quiet telegram-mtg && systemctl restart telegram-mtg
  ok "Telegram-прокси (mtg): поднял лимит подключений 512 → 4096"
}

# Привести в порядок: прокси есть — сторож стоит свежий, прокси нет — сторожа нет.
# Зовут модули Telegram-прокси после установки/удаления и сам Комбайн при запуске (так долетает обновление).
tgg_sync() {
  if tgg_needed; then
    tgg_fix_mtg
    tgg_current || tgg_install
  else
    tgg_remove
  fi
}

# kombain cli tgguard status|sync
tgg_cli() {
  case "${1:-}" in
    status)
      if tgg_installed; then
        jq -nc --arg v "$TGG_VER" --arg last "$(journalctl -t kombain-tg-guard -n 1 -o short-iso --no-pager 2>/dev/null | tail -1)" \
          '{installed:true, version:$v, last:$last}'
      else
        jq -nc '{installed:false}'
      fi ;;
    sync) tgg_sync ;;
    *) err "Неизвестная команда: ${1:-}"; return 2 ;;
  esac
}
