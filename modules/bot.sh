#!/usr/bin/env bash
# Модуль «Бот»: пульт управления Комбайном в Telegram.
# Бот работает от root и ставит программы, поэтому отвечает только владельцу.

BOT_DIR="$KB_HOME/bot"
BOT_ENV="$BOT_DIR/env"
BOT_UNIT="/etc/systemd/system/kombain-bot.service"

bot_installed() { [ -r "$BOT_ENV" ] && [ -f "$BOT_UNIT" ]; }

bot_txt_token() {
  cat <<'EOF'
Создай своего бота — это 1 минута:

1. В Telegram найди @BotFather (с синей галочкой)
2. Напиши ему /newbot
3. Придумай имя бота — любое, например «Мой сервер»
4. Придумай адрес бота — латиницей, в конце обязательно bot,
   например vasya_server_bot
5. BotFather пришлёт длинный ключ вида 1234567890:AAH...
   Скопируй его — это и есть токен.

Никому токен не показывай: с ним можно управлять твоим ботом.
EOF
}

bot_txt_id() {
  cat <<'EOF'
Теперь твой номер в Telegram (ID), чтобы бот слушался только тебя:

1. В Telegram найди @userinfobot
2. Нажми «Запустить» (или напиши /start)
3. Он пришлёт строку «Id: 123456789» — нужны только цифры.
EOF
}

# Проверка токена: печатает @имя бота или пусто
bot_check_token() {
  curl -fs --max-time 10 "https://api.telegram.org/bot$1/getMe" | jq -r '.result.username // empty' 2>/dev/null
}

bot_install() {
  if bot_installed; then
    warn "Бот уже стоит. Чтобы поставить заново — сначала «Удалить»."
    return 0
  fi
  step "Бот: управлять сервером из Telegram"
  say "Поставишь бота — всё остальное можно ставить и настраивать прямо из Telegram."
  ensure_pkgs curl jq python3 || return 1

  step "Токен бота"
  bot_txt_token | todo
  local token name
  while true; do
    token=$(ask_secret "Вставь токен (ввод не видно, это нормально)")
    name=$(bot_check_token "$token")
    [ -n "$name" ] && { ok "Бот найден: @$name"; break; }
    warn "Telegram такой токен не знает. Скопируй его у @BotFather ещё раз, целиком."
  done

  local code; code=$(shuf -i 100000-999999 -n 1)
  bot_install_core "$token" 0 "$code" || return 1
  say ""
  say "${C_BOLD}Последний шаг:"
  say "  1. Открой в Telegram @$name"
  say "  2. Внизу нажми большую кнопку «ЗАПУСТИТЬ» (START) — без неё писать боту нельзя"
  say "  3. В появившемся поле набери код:  $code  и отправь${C_RESET}"
  say "Кто пришлёт код — того бот и слушается. Больше никого."
}

# Ставит сервис бота. ID владельца или код привязки (кто пришлёт код — тот хозяин).
bot_install_core() {
  local token="$1" id="${2:-0}" code="${3:-}"
  mkdir -p "$BOT_DIR"
  ( umask 077; printf 'BOT_TOKEN=%s\nADMIN_ID=%s\nCLAIM_CODE=%s\nKB_SRC=%s\n' \
      "$token" "$id" "$code" "$KB_SRC" >"$BOT_ENV" )
  chmod 600 "$BOT_ENV"

  cat >"$BOT_UNIT" <<EOF
[Unit]
Description=Kombain Telegram bot
After=network-online.target
Wants=network-online.target

[Service]
EnvironmentFile=$BOT_ENV
ExecStart=/usr/bin/python3 $KB_SRC/bot/kombain_bot.py
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now kombain-bot >/dev/null 2>&1
  sleep 3
  if systemctl is-active --quiet kombain-bot; then
    ok "Бот запущен"
  else
    err "Бот не запустился. Логи: journalctl -u kombain-bot -n 40"
    return 1
  fi
}

# kombain cli bot <команда> — для установщика kombain-start.exe
bot_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    install)
      # токен — в KB_BOT_TOKEN. Печатает JSON: {"bot":"имя","code":"1234"}
      ensure_pkgs curl jq python3 >/dev/null || return 1
      local token="${KB_BOT_TOKEN:?}" name code
      name=$(bot_check_token "$token")
      [ -n "$name" ] || { err "Telegram такой токен не знает. Скопируй его у @BotFather ещё раз, целиком."; return 1; }
      bot_installed && systemctl disable --now kombain-bot >/dev/null 2>&1
      code=$(shuf -i 100000-999999 -n 1)
      bot_install_core "$token" 0 "$code" >&2 || return 1
      jq -nc --arg b "$name" --arg c "$code" '{bot:$b, code:$c}' ;;
    owner)
      # 0 — хозяин ещё не привязан
      sed -n 's/^ADMIN_ID=//p' "$BOT_ENV" 2>/dev/null ;;
    *) err "Неизвестная команда: $cmd"; return 2 ;;
  esac
}

bot_status() {
  bot_installed || { warn "Бот не установлен."; return 0; }
  systemctl is-active --quiet kombain-bot && ok "Бот работает" || err "Бот остановлен"
}

bot_logs() {
  bot_installed || { warn "Бот не установлен."; return 0; }
  journalctl -u kombain-bot -n 40 --no-pager
  say "Ищи слова Error / Traceback. Если их нет — всё нормально."
}

bot_restart() {
  bot_installed || { warn "Бот не установлен."; return 0; }
  systemctl restart kombain-bot && ok "Бот перезапущен"
}

bot_remove() {
  bot_installed || { warn "Бот не установлен."; return 0; }
  confirm "Удалить бота? Сервер продолжит работать, пропадёт только пульт" || return 0
  systemctl disable --now kombain-bot >/dev/null 2>&1
  rm -f "$BOT_UNIT"
  systemctl daemon-reload
  rm -rf "$BOT_DIR"
  ok "Бот удалён. Самого бота в Telegram можно удалить у @BotFather: /deletebot"
}

bot_menu() {
  while true; do
    cat <<EOF

${C_BOLD}══ Бот — пульт в Telegram ══${C_RESET}
 1) Установить
 2) Состояние
 3) Логи бота
 4) Перезапустить
 5) Удалить
 0) Назад
EOF
    case "$(ask "Выбор")" in
      1) bot_install ;;
      2) bot_status ;;
      3) bot_logs ;;
      4) bot_restart ;;
      5) bot_remove ;;
      0) return ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}
