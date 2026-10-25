#!/usr/bin/env bash
# One-time setup. Does not change or restart existing web/VPN services.
set -euo pipefail
[[ $(id -u) == 0 ]] || { echo 'Запустите от root.' >&2; exit 1; }
source_ref=${1:-}
[[ $source_ref =~ ^[0-9a-f]{40}$ ]] || { echo 'Нужен SHA проверенного коммита.' >&2; exit 1; }
command -v python3 >/dev/null
command -v curl >/dev/null
command -v systemctl >/dev/null
page_root=/usr/local/share/kombain-site/www
[[ -d "$page_root" && ! -L "$page_root" && -f "$page_root/index.html" ]] || {
  echo 'Ожидаемый каталог сайта отсутствует. Ничего не изменено.' >&2; exit 1;
}
grep -Eq '^[[:space:]]*root[[:space:]]+\*[[:space:]]+/usr/local/share/kombain-site/www[[:space:]]*$' /usr/local/share/kombain-site/Caddyfile || {
  echo 'Корень в Caddyfile отличается. Ничего не изменено.' >&2; exit 1;
}
systemctl is-active --quiet kombain-site || { echo 'kombain-site не работает. Установка остановлена.' >&2; exit 1; }
setup_tmp=$(mktemp -d)
trap 'rm -rf -- "$setup_tmp"' EXIT
curl --fail --silent --show-error --proto '=https' --tlsv1.2 \
  "https://raw.githubusercontent.com/ln71v/kombain/$source_ref/deploy/sync.py" -o "$setup_tmp/sync.py"
python3 - "$setup_tmp/sync.py" <<'PY'
from pathlib import Path
import sys
compile(Path(sys.argv[1]).read_text(), 'sync.py', 'exec')
PY

backup_root=$(mktemp -d /root/vaska-site-setup-"$(date +%Y%m%d-%H%M%S)"-XXXXXX)
cp -a -- "$page_root" "$backup_root/www"
printf 'Копия текущего сайта: %s/www\n' "$backup_root"
install -d -m 0755 /usr/local/lib/vaska-site-sync
install -d -m 0700 /var/lib/vaska-site-sync
install -m 0644 "$setup_tmp/sync.py" /usr/local/lib/vaska-site-sync/sync.py
cat >/etc/systemd/system/vaska-site-sync.service <<'UNIT'
[Unit]
Description=Vaska de Gamma static site update from GitHub
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/bin/python3 /usr/local/lib/vaska-site-sync/sync.py
User=root
UMask=0077
TimeoutStartSec=300
NoNewPrivileges=yes
PrivateTmp=yes
ProtectHome=yes
ProtectSystem=strict
ReadWritePaths=/usr/local/share/kombain-site/www /var/lib/vaska-site-sync
UNIT
cat >/etc/systemd/system/vaska-site-sync.timer <<'UNIT'
[Unit]
Description=Check Vaska de Gamma site updates every two minutes

[Timer]
OnBootSec=60
OnUnitInactiveSec=120
RandomizedDelaySec=10
Unit=vaska-site-sync.service

[Install]
WantedBy=timers.target
UNIT
systemctl daemon-reload
systemctl start vaska-site-sync.service
systemctl enable --now vaska-site-sync.timer
echo 'Готово: оформление обновляется из GitHub каждые две минуты.'
echo 'Caddy, Nginx, VPN, порты и сертификаты не менялись.'
