#!/usr/bin/env bash
# Общие функции Комбайна: вывод, вопросы, проверки, Docker.

KB_HOME="/opt/kombain"
KB_BACKUP="$KB_HOME/backup"

if [ -t 1 ]; then
  C_RESET=$'\e[0m'; C_RED=$'\e[31m'; C_GREEN=$'\e[32m'
  C_YELLOW=$'\e[33m'; C_CYAN=$'\e[36m'; C_BOLD=$'\e[1m'
else
  # без цвета, когда вывод читает бот
  C_RESET=""; C_RED=""; C_GREEN=""; C_YELLOW=""; C_CYAN=""; C_BOLD=""
fi

say()  { printf '%s\n' "$*"; }
ok()   { printf '%s✔ %s%s\n' "$C_GREEN" "$*" "$C_RESET"; }
warn() { printf '%s! %s%s\n' "$C_YELLOW" "$*" "$C_RESET"; }
err()  { printf '%s✖ %s%s\n' "$C_RED" "$*" "$C_RESET" >&2; }
step() { printf '\n%s%s▶ %s%s\n' "$C_BOLD" "$C_CYAN" "$*" "$C_RESET"; }

# Блок «сделай руками» — выделен рамкой, чтобы не потерялся в выводе.
todo() {
  printf '\n%s┌─ СДЕЛАЙ САМ ─────────────────────────────────────%s\n' "$C_YELLOW" "$C_RESET"
  local line
  while IFS= read -r line; do
    printf '%s│%s %s\n' "$C_YELLOW" "$C_RESET" "$line"
  done
  printf '%s└──────────────────────────────────────────────────%s\n' "$C_YELLOW" "$C_RESET"
}

pause() { read -r -p "Нажми Enter, чтобы продолжить..." _ </dev/tty; }

# ask "Вопрос" [значение_по_умолчанию] -> печатает ответ
ask() {
  local q="$1" def="${2:-}" a
  if [ -n "$def" ]; then
    read -r -p "$q [$def]: " a </dev/tty
    printf '%s' "${a:-$def}"
  else
    read -r -p "$q: " a </dev/tty
    printf '%s' "$a"
  fi
}

# ask_secret "Вопрос" -> печатает ответ, ввод не видно
ask_secret() {
  local a
  read -r -s -p "$1: " a </dev/tty
  printf '\n' >/dev/tty
  printf '%s' "$a"
}

# confirm "Вопрос" -> 0 если ответили y/д
confirm() {
  local a
  read -r -p "$1 (y/n): " a </dev/tty
  [[ "$a" =~ ^[YyДд]$ ]]
}

need_root() {
  if [ "$(id -u)" -ne 0 ]; then
    err "Запусти от root (зайди как root или добавь sudo в начало команды)."
    exit 1
  fi
}

check_os() {
  if [ ! -r /etc/os-release ]; then
    warn "Не могу определить систему. Комбайн проверялся на Ubuntu 22.04 и 24.04."
    return
  fi
  # shellcheck disable=SC1091
  . /etc/os-release
  if [ "${ID:-}" != "ubuntu" ]; then
    warn "У тебя ${PRETTY_NAME:-неизвестная система}. Комбайн проверялся на Ubuntu 22.04 и 24.04."
    confirm "Всё равно продолжить?" || exit 1
  fi
}

ensure_pkgs() {
  local missing=() p
  for p in "$@"; do
    dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
  done
  [ ${#missing[@]} -eq 0 ] && return 0
  step "Ставлю пакеты: ${missing[*]}"
  apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}" >/dev/null
}

ensure_docker() {
  if command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1; then
    return 0
  fi
  step "Ставлю Docker (официальный скрипт get.docker.com)"
  curl -fsSL https://get.docker.com | sh >/dev/null 2>&1 || { err "Docker не встал."; return 1; }
  systemctl enable --now docker >/dev/null 2>&1
  docker info >/dev/null 2>&1 && ok "Docker готов" || { err "Docker не запустился."; return 1; }
}

# Внешний IPv4 сервера
server_ip() {
  local ip
  ip=$(curl -4 -fs --max-time 5 https://api.ipify.org || true)
  [ -z "$ip" ] && ip=$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}')
  printf '%s' "$ip"
}

# Кто держит порт: port_owner 53 udp|tcp -> имя процесса или пусто
port_owner() {
  local port="$1" proto="${2:-tcp}" flag="-ltnp"
  [ "$proto" = "udp" ] && flag="-lunp"
  ss "$flag" "sport = :$port" 2>/dev/null | awk 'NR>1' | grep -o 'users:(("[^"]*' | head -1 | cut -d'"' -f2
}

# Бэкап файла перед правкой: backup_file /etc/xxx
backup_file() {
  local f="$1"
  [ -e "$f" ] || return 0
  mkdir -p "$KB_BACKUP"
  cp -a "$f" "$KB_BACKUP/$(basename "$f").$(date +%Y%m%d-%H%M%S)"
}

gen_password() {
  openssl rand -base64 32 | tr -dc 'A-Za-z0-9' | head -c 16
}

# ───────────────────────── файрвол ─────────────────────────
# Каждый модуль регистрирует свои порты, fw_apply открывает их и SSH,
# остальное входящее закрывает. Чужие уже работающие программы не ломаем:
# их порты тоже оставляем открытыми и предупреждаем.

KB_FW_DIR="$KB_HOME/fw.d"

fw_register()   { mkdir -p "$KB_FW_DIR"; printf '%s\n' $2 >"$KB_FW_DIR/$1"; }

fw_unregister() {
  local f="$KB_FW_DIR/$1" r rules
  [ -f "$f" ] || return 0
  rules=$(cat "$f")
  rm -f "$f"
  command -v ufw >/dev/null 2>&1 || return 0
  while IFS= read -r r; do
    [ -z "$r" ] && continue
    cat "$KB_FW_DIR"/* 2>/dev/null | grep -qxF "$r" && continue   # нужен другому модулю
    ufw delete allow "$r" >/dev/null 2>&1
  done <<<"$rules"
}

# Порты, на которых слушает sshd
fw_ssh_ports() {
  ss -H -ltnp 2>/dev/null | awk '/"sshd"/ {n=split($4,a,":"); print a[n]}' | sort -u
}

# Публичные порты, которые уже кто-то слушает: 443/tcp ...
fw_listening() {
  ss -H -ltun 2>/dev/null | awk '{
    proto=$1; addr=$5; n=split(addr,a,":"); port=a[n]; host=substr(addr,1,length(addr)-length(port)-1)
    if (host ~ /^(127\.|\[::1\]|::1$)/) next
    if (proto=="tcp" && $2!="LISTEN") next
    print port "/" proto }' | sort -u
}

fw_apply() {
  ensure_pkgs ufw || return 1
  step "Файрвол: открываю только нужное"
  local want=() p extra=()
  for p in $(fw_ssh_ports); do want+=("$p/tcp"); done
  [ ${#want[@]} -eq 0 ] && want+=("22/tcp")   # sshd не нашли — 22 не закрываем
  if ls "$KB_FW_DIR"/* >/dev/null 2>&1; then
    while IFS= read -r p; do [ -n "$p" ] && want+=("$p"); done < <(cat "$KB_FW_DIR"/*)
  fi
  for p in $(fw_listening); do
    printf '%s\n' "${want[@]}" | grep -qxF "$p" || extra+=("$p")
  done

  ufw default deny incoming >/dev/null
  ufw default allow outgoing >/dev/null
  for p in "${want[@]}" "${extra[@]}"; do ufw allow "$p" >/dev/null; done
  ufw --force enable >/dev/null && ok "Файрвол включён. Открыто: $(printf '%s ' "${want[@]}")"
  if [ ${#extra[@]} -gt 0 ]; then
    warn "Оставила открытыми порты других программ: ${extra[*]}"
    warn "Не нужны — закрой: ufw delete allow <порт>"
  fi
}
