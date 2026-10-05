#!/usr/bin/env bash
# Комбайн — установщик-меню для голого VPS: прокси для нейронок, VLESS, AmneziaWG,
# WARP, Telegram-прокси. Запуск одной командой:
#   bash <(curl -Ls https://raw.githubusercontent.com/ln71v/kombain/main/kombain.sh)
# Потом из любого места: kombain

set -uo pipefail

KB_REPO="ln71v/kombain"
KB_BRANCH="main"
KB_SRC="/opt/kombain/src"

if [ "$(id -u)" -ne 0 ]; then
  echo "Запусти от root (зайди как root или добавь sudo в начало команды)." >&2
  exit 1
fi

# Скачиваем свежую версию в /opt/kombain/src, если запущены не оттуда
kb_fetch() {
  command -v curl >/dev/null 2>&1 || { apt-get update -qq && apt-get install -y -qq curl >/dev/null; }
  local tmp
  tmp=$(mktemp -d)
  if ! curl -fsSL "https://codeload.github.com/$KB_REPO/tar.gz/refs/heads/$KB_BRANCH" | tar -xz -C "$tmp"; then
    echo "Не смогла скачать Комбайн с GitHub. Проверь интернет на сервере." >&2
    rm -rf "$tmp"
    exit 1
  fi
  rm -rf "$KB_SRC"
  mkdir -p "$(dirname "$KB_SRC")"
  mv "$tmp"/kombain-* "$KB_SRC"
  rm -rf "$tmp"
  chmod +x "$KB_SRC/kombain.sh"
  ln -sf "$KB_SRC/kombain.sh" /usr/local/bin/kombain
}

SELF_DIR=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" 2>/dev/null && pwd)
if [ "${1:-}" = "--update" ] || [ ! -f "$SELF_DIR/lib/common.sh" ]; then
  kb_fetch
  exec "$KB_SRC/kombain.sh" --no-fetch
fi
KB_SRC="$SELF_DIR"

# shellcheck source=lib/common.sh
. "$KB_SRC/lib/common.sh"
# shellcheck source=modules/secrets.sh
. "$KB_SRC/modules/secrets.sh"
# shellcheck source=modules/aiproxy.sh
. "$KB_SRC/modules/aiproxy.sh"
# shellcheck source=modules/bot.sh
. "$KB_SRC/modules/bot.sh"

# Режим для бота: kombain cli <модуль> <команда> [аргументы]
if [ "${1:-}" = "cli" ]; then
  shift
  mod="${1:-}"; shift || true
  case "$mod" in
    aiproxy) aip_cli "$@"; exit $? ;;
    secrets) sec_cli "$@"; exit $? ;;
    *) err "Неизвестный модуль: $mod"; exit 2 ;;
  esac
fi

soon() { warn "Этот пункт ещё в работе. Следи за обновлениями: kombain --update"; }

main_menu() {
  while true; do
    cat <<EOF

${C_BOLD}${C_CYAN}╔══════════════ КОМБАЙН ══════════════╗${C_RESET}
 IP сервера: $(server_ip)

 1) Бот — управлять всем из Telegram
 2) Прокси для нейронок (AdGuard + nginx)
 3) VLESS Reality + сайт-заглушка      ${C_YELLOW}[скоро]${C_RESET}
 4) AmneziaWG                          ${C_YELLOW}[скоро]${C_RESET}
 5) WARP                               ${C_YELLOW}[скоро]${C_RESET}
 6) Telegram-прокси                    ${C_YELLOW}[скоро]${C_RESET}

 9) Обновить Комбайн
 0) Выход
EOF
    case "$(ask "Выбор")" in
      1) bot_menu ;;
      2) aip_menu ;;
      3|4|5|6) soon ;;
      9) exec "$KB_SRC/kombain.sh" --update ;;
      0) exit 0 ;;
      *) warn "Нет такого пункта" ;;
    esac
  done
}

check_os
main_menu
