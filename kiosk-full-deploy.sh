#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - РАБОЧАЯ ВЕРСИЯ
# ==========================================

set -e
KIOSK_USER="kiosk"
KIOSK_URL="https://www.google.com"
CHROME_TYPE="chromium"  # Рекомендую chromium для теста
REBOOT_AFTER=false
KEYBOARD_LAYOUT="us"

if [ "$EUID" -ne 0 ]; then echo "Запустите от root: sudo $0"; exit 1; fi

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }

while [[ $# -gt 0 ]]; do
  case $1 in
    -u|--user) KIOSK_USER="$2"; shift 2 ;;
    -url|--url) KIOSK_URL="$2"; shift 2 ;;
    -t|--type) CHROME_TYPE="$2"; shift 2 ;;
    -r|--reboot) REBOOT_AFTER=true; shift ;;
    -k|--keyboard) KEYBOARD_LAYOUT="$2"; shift 2 ;;
    *) error "Неизвестный параметр: $1" ;;
  esac
done

log "Установка Chrome Kiosk..."

# === УСТАНОВКА ПАКЕТОВ ===
apt update && apt install -y --no-install-recommends \
  xorg xinit openbox dbus-x11 x11-xserver-utils xfonts-base \
  wget ca-certificates

# Установка браузера
if [ "$CHROME_TYPE" = "chrome" ]; then
  wget -qO /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  dpkg -i /tmp/chrome.deb || apt-get install -f -y
  rm /tmp/chrome.deb
  BROWSER_CMD="google-chrome-stable"
  CONFIG_DIR="google-chrome"
else
  apt install -y chromium-browser
  BROWSER_CMD="chromium-browser"
  CONFIG_DIR="chromium"
fi

# === СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ===
if ! id "$KIOSK_USER" &>/dev/null; then
  useradd -m -s /bin/bash -G audio,video,cdrom "$KIOSK_USER"
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "Создан пользователь $KIOSK_USER"
fi

# === СОЗДАНИЕ СКРИПТА КИОСКА ===
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
cat > "$KIOSK_SCRIPT" <<EOF
#!/bin/bash
# ЛОГИРОВАНИЕ ВСЕГО!
exec > /home/$KIOSK_USER/kiosk-\$(date +%Y%m%d-%H%M%S).log 2>&1
set -x

# Ждем готовности X сервера (КРИТИЧНО!)
while ! xdpyinfo &>/dev/null; do
  echo "Ожидание X сервера..."
  sleep 1
done

# Очистка сессий
rm -rf ~/.config/$CONFIG_DIR/Singleton*

# Запуск браузера
while true; do
  $BROWSER_CMD \
    --no-first-run \
    --disable \
    --kiosk \
    --incognito \
    "$KIOSK_URL"
  sleep 2
done
EOF
chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === НАСТРОЙКА .xinitrc (ИСПРАВЛЕННАЯ) ===
cat > "/home/$KIOSK_USER/.xinitrc" <<EOF
#!/bin/bash

# Настройки ДО запуска оконного менеджера
xset -dpms
xset s off
xset s noblank

# Запускаем Openbox В ФОНЕ (без exec!)
openbox-session &

# Даем Openbox 2 секунды на инициализацию
sleep 2

# ТЕПЕРЬ запускаем Chrome (exec заменяет процесс)
exec $KIOSK_SCRIPT
EOF
chmod +x "/home/$KIOSK_USER/.xinitrc"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/.xinitrc"

# === НАДЕЖНЫЙ АВТОЛОГИН ЧЕРЕЗ SYSTEMD ===
log "Создание надежного systemd-сервиса..."

# Отключаем стандартный getty на TTY1
systemctl disable getty@tty1.service
systemctl mask getty@tty1.service

# Создаем собственный сервис киоска
cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chrome Kiosk
After=network.target

[Service]
User=$KIOSK_USER
PAMName=login
TTYPath=/dev/tty1
ExecStart=/usr/bin/xinit /home/$KIOSK_USER/.xinitrc -- /usr/bin/Xorg :0 -novtswitch -keeptty
StandardInput=tty
StandardOutput=tty
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable kiosk.service

# === ФИНАЛ ===
log "✅ Готово!"
log "После перезагрузки Chrome запустится автоматически"
log "Логи: /home/$KIOSK_USER/kiosk-*.log"
log "Для отладки: sudo journalctl -u kiosk -f"

if [ "$REBOOT_AFTER" = true ]; then
  log "Перезагрузка..."
  sleep 3
  reboot
fi