#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - БЕЗ ЦИКЛИЧЕСКОГО ПЕРЕЗАПУСКА
# Chrome запускается один раз, перезапуск через systemd
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

log "Начало установки Chrome Kiosk (без цикла)..."

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

# Даем права доступа
usermod -a -G audio,video,tty $KIOSK_USER

# === ЭТАП 4: Создание скрипта киоска БЕЗ ЦИКЛА ===
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
log "Создание скрипта киоска (без цикла)..."

cat > "$KIOSK_SCRIPT" <<'EOF'
#!/bin/bash

# Логирование
exec > "/home/$USER/kiosk.log" 2>&1
echo "=== Запуск Kiosk: $(date) ==="
echo "Пользователь: $USER"

# Ждем запуска X сервера
echo "Ожидание X сервера..."
for i in {1..30}; do
    if xdpyinfo >/dev/null 2>&1; then
        echo "✓ X сервер готов на попытке $i"
        break
    fi
    echo "Ожидание X сервера... $i/30"
    sleep 1
done

# Финальная проверка
if ! xdpyinfo >/dev/null 2>&1; then
    echo "❌ X сервер не доступен после 30 секунд"
    exit 1
fi

echo "X сервер запущен успешно"

# Настройки энергосбережения
xset -dpms
xset s off
xset s noblank

# Очистка старых сессий Chrome
rm -rf ~/.config/google-chrome/Singleton*

# Установка раскладки
setxkbmap us

# Флаги Chrome для VirtualBox
CHROME_FLAGS="
--no-first-run
--disable-translate
--disable-infobars
--disable-suggestions-service
--disable-save-password-bubble
--disable-sync
--no-default-browser-check
--incognito
--kiosk
--start-maximized
--disable-gpu
--no-sandbox
--disable-dev-shm-usage
"

echo "Запуск Chrome..."
echo "URL: https://www.google.com"

# ЗАПУСК CHROME ОДИН РАЗ - БЕЗ ЦИКЛА
# Если Chrome закроется, systemd перезапустит сервис
google-chrome-stable $CHROME_FLAGS "https://www.google.com"

EXIT_CODE=$?
echo "Chrome завершил работу с кодом: $EXIT_CODE"
echo "Время завершения: $(date)"

# Выходим - systemd сам решит, нужно ли перезапускать
exit $EXIT_CODE
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === ЭТАП 5: Настройка X-сессии ===
log "Настройка X-сессии..."

cat > "/home/$KIOSK_USER/.xinitrc" <<'EOF'
#!/bin/bash

# Запускаем Openbox в фоне
openbox-session &

# Даем время на запуск
sleep 3

# Запускаем киоск-скрипт ОДИН РАЗ
exec /home/$USER/kiosk.sh
EOF

chmod +x "/home/$KIOSK_USER/.xinitrc"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/.xinitrc"

# === ЭТАП 6: Настройка systemd сервиса ===
log "Настройка systemd сервиса..."

# Создаем сервис для запуска X
cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chrome Kiosk
After=network.target

[Service]
User=$KIOSK_USER
Group=$KIOSK_USER
WorkingDirectory=/home/$KIOSK_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$KIOSK_USER/.Xauthority
ExecStart=/usr/bin/startx /home/$KIOSK_USER/.xinitrc -- :0 -novtswitch -keeptty
Restart=on-failure
RestartSec=10
StartLimitInterval=60
StartLimitBurst=3

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable kiosk.service

# === ЭТАП 7: Настройка автоматического логина ===
log "Настройка автоматического логина..."

# Отключаем стандартный getty на tty1
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl mask getty@tty1.service 2>/dev/null || true

# Разрешаем запуск X любым пользователям
echo "allowed_users=anybody" > /etc/X11/Xwrapper.config

# === ЭТАП 8: Создание скрипта для ручного тестирования ===
log "Создание тестового скрипта..."

cat > /home/$KIOSK_USER/test-kiosk.sh <<'EOF'
#!/bin/bash

echo "=== ТЕСТ KIOSK ==="
echo "Пользователь: \$USER"
echo ""

# Проверяем X
echo "1. Проверка X сервера:"
if xdpyinfo >/dev/null 2>&1; then
    echo "   ✓ X сервер работает"
else
    echo "   ✗ X сервер не доступен"
fi

# Проверяем Chrome
echo ""
echo "2. Проверка Chrome:"
if command -v google-chrome-stable >/dev/null 2>&1; then
    echo "   ✓ Chrome найден"
    echo "   Версия: \$(google-chrome-stable --version 2>/dev/null)"
else
    echo "   ✗ Chrome не найден"
fi

# Проверяем сервис
echo ""
echo "3. Проверка сервиса:"
systemctl is-active kiosk.service >/dev/null 2>&1 && echo "   ✓ Сервис активен" || echo "   ✗ Сервис не активен"

echo ""
echo "Тест завершен"
EOF

chmod +x /home/$KIOSK_USER/test-kiosk.sh
chown $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/test-kiosk.sh

# === ЭТАП 9: ИНФОРМАЦИЯ ===
log "✅ Установка завершена!"
log ""
log "🔧 ОСОБЕННОСТИ:"
log "   • Chrome запускается ОДИН раз (без цикла)"
log "   • Systemd перезапускает при сбоях (Restart=on-failure)"
log "   • Задержка между перезапусками: 10 секунд"
log "   • Максимум 3 перезапуска в минуту"
log ""
log "📋 ДЛЯ ПРОВЕРКИ:"
log "   • Статус сервиса: systemctl status kiosk.service"
log "   • Логи Chrome: tail -f /home/$KIOSK_USER/kiosk.log"
log "   • Логи systemd: journalctl -u kiosk.service -f"
log ""
log "🔧 РУЧНОЙ ЗАПУСК:"
log "   sudo -u $KIOSK_USER startx /home/$KIOSK_USER/.xinitrc"

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