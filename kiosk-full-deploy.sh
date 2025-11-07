#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - ИСПРАВЛЕННАЯ ВЕРСИЯ
# ==========================================

set -e

# --- Настройки ---
KIOSK_USER="kiosk"
KIOSK_URL="https://www.google.com"
CHROME_TYPE="chrome"  # chrome или chromium
REBOOT_AFTER=false
KEYBOARD_LAYOUT="us"
# -----------------

# Проверка root
if [ "$EUID" -ne 0 ]; then echo "Запустите от root: sudo $0"; exit 1; fi

# Цвета
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log() { echo -e "${GREEN}[INFO]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; exit 1; }

# Парсинг аргументов
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

log "Начало установки Chrome Kiosk для $KIOSK_USER..."

# === ЭТАП 1: Установка пакетов ===
log "Установка X11 и браузера..."
apt update && apt install -y --no-install-recommends \
  xorg xinit openbox dbus-x11 x11-xserver-utils xfonts-base \
  wget ca-certificates

# Установка браузера
if [ "$CHROME_TYPE" = "chrome" ]; then
  if ! command -v google-chrome-stable &> /dev/null; then
    wget -qO /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
    dpkg -i /tmp/chrome.deb || apt-get install -f -y
    rm /tmp/chrome.deb
  fi
  BROWSER_CMD="google-chrome-stable"
  CONFIG_DIR="google-chrome"
else
  apt install -y chromium-browser
  BROWSER_CMD="chromium-browser"
  CONFIG_DIR="chromium"  # или chromium-browser в некоторых версиях
fi

# === ЭТАП 2: Создание пользователя ===
if ! id "$KIOSK_USER" &>/dev/null; then
  useradd -m -s /bin/bash -G audio,video,cdrom "$KIOSK_USER"
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "Создан пользователь $KIOSK_USER (пароль: kiosk123)"
fi

# === ЭТАП 3: Настройка автологина (НАДЕЖНЫЙ СПОСОБ) ===
log "Настройка автологина..."
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
Type=idle
TimeoutStartSec=0

[Install]
WantedBy=getty.target
EOF

# Альтернативный метод через getty override
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
Type=idle
StandardInput=tty
StandardOutput=tty
EOF

# === ЭТАП 4: Создание скрипта киоска ===
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
cat > "$KIOSK_SCRIPT" <<EOF
#!/bin/bash

# Логирование
exec > /home/$KIOSK_USER/kiosk.log 2>&1
set -x

# Настройки X11
export DISPLAY=:0
xset -dpms
xset s off
xset s noblank

# Очистка старых сессий
rm -rf ~/.config/$CONFIG_DIR/Singleton*

# Запуск браузера в цикле
while true; do
  $BROWSER_CMD \
    --no-first-run \
    --disable \
    --kiosk \
    --disable-translate \
    --disable-infobars \
    --incognito \
    "$KIOSK_URL"
  
  sleep 2  # Подождать 2 секунды перед перезапуском
done
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === ЭТАП 5: Настройка X через .profile (НАДЕЖНО) ===
# .bashrc не всегда выполняется при автологине
PROFILE_FILE="/home/$KIOSK_USER/.profile"
if ! grep -q "CHROME_KIOSK" "$PROFILE_FILE"; then
  cat >> "$PROFILE_FILE" <<EOF

# CHROME_KIOSK - Автозапуск
if [ "\$(tty)" = "/dev/tty1" ]; then
  startx >> /home/$KIOSK_USER/xorg.log 2>&1
fi
EOF
  chown $KIOSK_USER:$KIOSK_USER "$PROFILE_FILE"
fi

# === ЭТАП 6: Настройка .xinitrc (ИСПРАВЛЕННАЯ ВЕРСИЯ) ===
cat > "/home/$KIOSK_USER/.xinitrc" <<EOF
#!/bin/bash

# Запуск Openbox в фоне (без exec!)
openbox-session &

# Запуск киоск-скрипта
exec $KIOSK_SCRIPT
EOF

chmod +x "/home/$KIOSK_USER/.xinitrc"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/.xinitrc"

# === ЭТАП 7: Создание systemd service (РЕЗЕРВНЫЙ ВАРИАНТ) ===
log "Создание systemd service..."
cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chrome Kiosk
After=graphical.target

[Service]
User=$KIOSK_USER
PAMName=login
TTYPath=/dev/tty1
ExecStart=/usr/bin/startx
StandardInput=tty
StandardOutput=tty
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

# Включаем сервис
systemctl daemon-reload
systemctl enable kiosk.service

# === ЭТАП 8: Завершение ===
log "Настройка завершена!"
log "Логи будут сохраняться в /home/$KIOSK_USER/kiosk.log"

if [ "$REBOOT_AFTER" = true ]; then
  log "Перезагрузка через 5 секунд..."
  sleep 5
  reboot
else
  echo ""
  log "⚠️ НУЖНА ПЕРЕЗАГРУЗКА!"
  log "После перезагрузки проверьте логи:"
  log "  tail -f /home/$KIOSK_USER/kiosk.log"
  log "  cat /home/$KIOSK_USER/.xsession-errors"
fi