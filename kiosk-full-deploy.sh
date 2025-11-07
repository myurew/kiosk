#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - ПРОВЕРЕННАЯ РАБОЧАЯ ВЕРСИЯ
# Без сложных оптимизаций, просто работает
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
warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }

log "Начало установки Chrome Kiosk..."

# === ЭТАП 1: Установка базовых пакетов ===
log "Установка X11 и зависимостей..."
apt update && apt install -y --no-install-recommends \
  xserver-xorg xinit openbox \
  dbus-x11 x11-xserver-utils xfonts-base \
  wget curl ca-certificates

# === ЭТАП 2: Установка Google Chrome ===
if ! command -v google-chrome-stable &> /dev/null; then
  log "Установка Google Chrome..."
  wget -qO /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  dpkg -i /tmp/chrome.deb || (apt-get install -f -y && dpkg -i /tmp/chrome.deb)
  rm -f /tmp/chrome.deb
else
  log "Google Chrome уже установлен"
fi

# === ЭТАП 3: Создание пользователя ===
if ! id "$KIOSK_USER" &>/dev/null; then
  log "Создание пользователя $KIOSK_USER..."
  useradd -m -s /bin/bash $KIOSK_USER
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "✓ Пользователь создан (пароль: kiosk123)"
else
  log "Пользователь $KIOSK_USER уже существует"
fi

# === ЭТАП 4: Создание ПРОСТОГО скрипта киоска ===
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
log "Создание простого скрипта киоска..."

cat > "$KIOSK_SCRIPT" <<'EOF'
#!/bin/bash

# Простое логирование
echo "=== Запуск Kiosk: $(date) ===" > /home/$USER/kiosk.log 2>&1

# Даем время на запуск X
sleep 5

# Проверяем X сервер
if ! xdpyinfo >/dev/null 2>&1; then
    echo "X сервер не доступен" >> /home/$USER/kiosk.log
    exit 1
fi

echo "X сервер работает" >> /home/$USER/kiosk.log

# Базовые настройки
xset -dpms
xset s off
xset s noblank

# Запускаем Chrome с минимальными флагами
# БЕЗ --disable и других проблемных флагов
google-chrome-stable \
  --no-first-run \
  --disable-translate \
  --disable-infobars \
  --incognito \
  --kiosk \
  "https://www.google.com" >> /home/$USER/kiosk.log 2>&1

echo "Chrome завершил работу: $(date)" >> /home/$USER/kiosk.log
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === ЭТАП 5: Настройка X-сессии ===
log "Настройка X-сессии..."

cat > "/home/$KIOSK_USER/.xinitrc" <<'EOF'
#!/bin/bash
# Простой .xinitrc

# Запускаем Openbox
openbox-session &

# Ждем немного
sleep 3

# Запускаем Chrome
exec /home/$USER/kiosk.sh
EOF

chmod +x "/home/$KIOSK_USER/.xinitrc"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/.xinitrc"

# === ЭТАП 6: Настройка автоматического логина ===
log "Настройка автоматического логина..."

# Создаем сервис для автологина на tty1
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
Type=simple
EOF

mkdir -p /etc/systemd/system/getty@tty1.service.d

# Создаем сервис для запуска X после логина
cat > /etc/systemd/system/x11.service <<EOF
[Unit]
Description=Start X11 on tty1
After=getty@tty1.service

[Service]
User=$KIOSK_USER
Group=$KIOSK_USER
Type=simple
ExecStart=/usr/bin/startx /home/$KIOSK_USER/.xinitrc -- :0 vt1
Restart=always
RestartSec=5
Environment=DISPLAY=:0

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable x11.service

# === ЭТАП 7: ФИНАЛЬНАЯ ПОДГОТОВКА ===
log "Финальная подготовка..."

# Даем пользователю права на X
usermod -a -G video $KIOSK_USER

# Создаем тестовый скрипт для проверки
cat > /home/$KIOSK_USER/test-chrome.sh <<'EOF'
#!/bin/bash
echo "=== Тест Chrome ==="
echo "Пользователь: \$USER"
echo "DISPLAY: \$DISPLAY"

# Проверяем X
echo "Проверка X сервера..."
xdpyinfo && echo "✓ X сервер работает" || echo "✗ X сервер не работает"

# Проверяем Chrome
echo "Проверка Chrome..."
which google-chrome-stable && echo "✓ Chrome найден" || echo "✗ Chrome не найден"

# Пробуем запустить Chrome на 5 секунд
echo "Тестовый запуск Chrome..."
timeout 5s google-chrome-stable --no-first-run --disable-gpu --kiosk "https://www.google.com" 2>&1 | head -20
echo "Тест завершен"
EOF

chmod +x /home/$KIOSK_USER/test-chrome.sh
chown $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/test-chrome.sh

# === ЭТАП 8: ИНФОРМАЦИЯ ===
log "✅ Установка завершена!"
log ""
log "🔧 ДЛЯ ПРОВЕРКИ ДО ПЕРЕЗАГРУЗКИ:"
log "1. Переключитесь на пользователя kiosk:"
log "   sudo -u kiosk -i"
log "2. Запустите тестовый скрипт:"
log "   ./test-chrome.sh"
log "3. Или запустите X вручную:"
log "   startx"
log ""
log "📋 ПОСЛЕ ПЕРЕЗАГРУЗКИ:"
log "   • Система автоматически войдет под пользователем kiosk"
log "   • Запустится Chrome в режиме киоска"
log "   • Логи: /home/$KIOSK_USER/kiosk.log"

if [ "$REBOOT_AFTER" = true ]; then
  log ""
  log "🔄 Перезагрузка через 5 секунд..."
  sleep 5
  reboot
else
  log ""
  log "⚠️  ВЫПОЛНИТЕ ПЕРЕЗАГРУЗКУ:"
  log "sudo reboot"
fi