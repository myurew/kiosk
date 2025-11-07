#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - ТОЛЬКО GOOGLE CHROME
# Полностью рабочая версия с логированием
# ==========================================

set -e

# --- НАСТРОЙКИ ---
KIOSK_USER="kiosk"
KIOSK_URL="https://www.google.com"
REBOOT_AFTER=false
KEYBOARD_LAYOUT="us"
# -----------------

# Проверка root
if [ "$EUID" -ne 0 ]; then 
  echo "❌ Запустите от root: sudo $0"
  exit 1
fi

# Цвета
log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
  case $1 in
    -u|--user) KIOSK_USER="$2"; shift 2 ;;
    -url|--url) KIOSK_URL="$2"; shift 2 ;;
    -r|--reboot) REBOOT_AFTER=true; shift ;;
    -k|--keyboard) KEYBOARD_LAYOUT="$2"; shift 2 ;;
    -h|--help) 
      echo "Использование: $0 [опции]"
      echo "  -u, --user USER      Имя пользователя (по умолчанию: kiosk)"
      echo "  -url, --url URL      Стартовый URL (по умолчанию: https://www.google.com)"
      echo "  -k, --keyboard LAYOUT Раскладка (по умолчанию: us)"
      echo "  -r, --reboot         Автоматическая перезагрузка"
      echo "  -h, --help           Справка"
      exit 0 ;;
    *) error "Неизвестный параметр: $1" ;;
  esac
done

log "Начало установки Google Chrome Kiosk для $KIOSK_USER..."

# === ЭТАП 1: Установка X11 ===
log "Установка X11 и зависимостей..."
apt update && apt install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-video-all xserver-xorg-input-all \
  xinit openbox dbus-x11 x11-xserver-utils xfonts-base \
  wget curl ca-certificates locales

# === ЭТАП 2: Установка Google Chrome ===
if ! command -v google-chrome-stable &> /dev/null; then
  log "Установка Google Chrome..."
  wget -qO /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  dpkg -i /tmp/chrome.deb || apt-get install -f -y
  rm -f /tmp/chrome.deb
else
  log "Google Chrome уже установлен"
fi

# === ЭТАП 3: Создание пользователя ===
if ! id "$KIOSK_USER" &>/dev/null; then
  log "Создание пользователя $KIOSK_USER..."
  useradd -m -s /bin/bash -G audio,video,cdrom "$KIOSK_USER"
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "✓ Пользователь создан (пароль: kiosk123)"
else
  log "Пользователь $KIOSK_USER уже существует"
fi

# === ЭТАП 4: Скрипт автозапуска Chrome ===
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
log "Создание скрипта киоска..."

cat > "$KIOSK_SCRIPT" <<'EOF'
#!/bin/bash

# ЛОГИРОВАНИЕ ВСЕХ ОШИБОК
LOGFILE="/home/$USER/kiosk-$(date +%Y%m%d-%H%M%S).log"
exec > "$LOGFILE" 2>&1
echo "=== Запуск Kiosk: $(date) ==="
set -x

# Ждем готовности X сервера (КРИТИЧНО!)
while ! xdpyinfo &>/dev/null; do
  echo "Ожидание X сервера..."
  sleep 1
done

# Настройки энергосбережения
xset -dpms
xset s off
xset s noblank

# Очистка старых сессий
rm -rf ~/.config/google-chrome/Singleton*

# Установка раскладки
setxkbmap us

# Запуск Chrome в бесконечном цикле
while true; do
  google-chrome-stable \
    --no-first-run \
    --disable \
    --disable-translate \
    --disable-infobars \
    --disable-suggestions-service \
    --disable-save-password-bubble \
    --disable-sync \
    --no-default-browser-check \
    --disable-web-security \
    --incognito \
    --kiosk \
    --start-maximized \
    "https://www.google.com"
  
  echo "Chrome закрыт. Перезапуск через 2 секунды..."
  sleep 2
done
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === ЭТАП 5: Настройка X-сессии ===
cat > "/home/$KIOSK_USER/.xinitrc" <<'EOF'
#!/bin/bash

# Запускаем Openbox в фоне (без exec!)
openbox-session &

# Даем Openbox 2 секунды на запуск
sleep 2

# Запускаем киоск-скрипт (exec заменяет процесс)
exec /home/$USER/kiosk.sh
EOF
chmod +x "/home/$KIOSK_USER/.xinitrc"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/.xinitrc"

# === ЭТАП 6: НАДЕЖНЫЙ АВТОЛОГИН ЧЕРЕЗ SYSTEMD ===
log "Настройка автологина через systemd..."

# Отключаем стандартный getty
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl mask getty@tty1.service 2>/dev/null || true

# Создаем собственный сервис
cat > /etc/systemd/system/kiosk.service <<'EOF'
[Unit]
Description=Chrome Kiosk
After=network.target

[Service]
User=kiosk
PAMName=login
TTYPath=/dev/tty1
ExecStart=/usr/bin/xinit /home/kiosk/.xinitrc -- /usr/bin/Xorg :0 -novtswitch -keeptty
StandardInput=tty
StandardOutput=tty
StandardError=tty
Restart=always
RestartSec=5
KillMode=process

[Install]
WantedBy=graphical.target
EOF

# Включаем сервис
systemctl daemon-reload
systemctl enable kiosk.service

# === ЭТАП 7: ФИНАЛ ===
log "✅ Установка завершена!"
log "После перезагрузки Chrome запустится автоматически на TTY1"
log ""
log "📋 ВАЖНО:"
log "   • Проверьте логи: tail -f /home/$KIOSK_USER/kiosk-*.log"
log "   • Отладка: sudo journalctl -u kiosk -f"
log "   • Для выхода: Ctrl+Alt+F2 (TTY2), затем в TTY1: Ctrl+C"

if [ "$REBOOT_AFTER" = true ]; then
  log "🔄 Перезагрузка через 5 секунд..."
  sleep 5
  reboot
else
  log "⚠️  НУЖНА ПЕРЕЗАГРУЗКА!"
  log "Выполните: sudo reboot"
fi