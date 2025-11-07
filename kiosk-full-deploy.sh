#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - ИСПРАВЛЕНЫ ПРАВА ДОСТУПА
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

# === ЭТАП 3: Создание пользователя и настройка прав ===
if ! id "$KIOSK_USER" &>/dev/null; then
  log "Создание пользователя $KIOSK_USER..."
  useradd -m -s /bin/bash $KIOSK_USER
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "✓ Пользователь создан (пароль: kiosk123)"
else
  log "Пользователь $KIOSK_USER уже существует"
fi

# ДАЕМ ПРАВА ДОСТУПА К X СЕРВЕРУ
log "Настройка прав доступа..."
usermod -a -G audio,video,tty $KIOSK_USER

# Разрешаем пользователю запускать X сервер
if [ -f /etc/X11/Xwrapper.config ]; then
  echo "allowed_users=anybody" > /etc/X11/Xwrapper.config
else
  echo "allowed_users=anybody" > /etc/X11/Xwrapper.config
fi

# === ЭТАП 4: Создание скрипта киоска ===
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
log "Создание скрипта киоска..."

cat > "$KIOSK_SCRIPT" <<'EOF'
#!/bin/bash

# Создаем директорию для логов
mkdir -p /home/$USER/.logs
LOGFILE="/home/$USER/.logs/kiosk.log"

echo "=== Запуск Kiosk: $(date) ===" > $LOGFILE
echo "Пользователь: $USER" >> $LOGFILE
echo "Домашняя директория: $HOME" >> $LOGFILE

# Даем время на запуск X
sleep 3

# Проверяем X сервер
echo "Проверка X сервера..." >> $LOGFILE
if xdpyinfo >> $LOGFILE 2>&1; then
    echo "✓ X сервер работает" >> $LOGFILE
else
    echo "✗ X сервер не доступен" >> $LOGFILE
    exit 1
fi

echo "Настройка энергосбережения..." >> $LOGFILE
xset -dpms >> $LOGFILE 2>&1
xset s off >> $LOGFILE 2>&1
xset s noblank >> $LOGFILE 2>&1

echo "Запуск Chrome..." >> $LOGFILE
exec google-chrome-stable \
  --no-first-run \
  --disable-translate \
  --disable-infobars \
  --incognito \
  --kiosk \
  "https://www.google.com" >> $LOGFILE 2>&1
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === ЭТАП 5: Настройка X-сессии ===
log "Настройка X-сессии..."

cat > "/home/$KIOSK_USER/.xinitrc" <<'EOF'
#!/bin/bash

# Логируем запуск
echo "Запуск .xinitrc: $(date)" > /home/$USER/.logs/xinitrc.log

# Ждем инициализации
sleep 2

# Запускаем Openbox
echo "Запуск Openbox..." >> /home/$USER/.logs/xinitrc.log
openbox-session >> /home/$USER/.logs/xinitrc.log 2>&1 &

# Ждем запуска Openbox
sleep 3

# Запускаем киоск
echo "Запуск kiosk.sh..." >> /home/$USER/.logs/xinitrc.log
exec /home/$USER/kiosk.sh >> /home/$USER/.logs/xinitrc.log 2>&1
EOF

chmod +x "/home/$KIOSK_USER/.xinitrc"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/.xinitrc"

# === ЭТАП 6: Настройка автоматического запуска ===
log "Настройка автоматического запуска..."

# Создаем systemd сервис для запуска X при загрузке
cat > /etc/systemd/system/x11-kiosk.service <<EOF
[Unit]
Description=X11 Kiosk
After=network.target

[Service]
User=$KIOSK_USER
Group=$KIOSK_USER
WorkingDirectory=/home/$KIOSK_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$KIOSK_USER/.Xauthority
ExecStartPre=/bin/sleep 5
ExecStart=/usr/bin/startx /home/$KIOSK_USER/.xinitrc -- :0 -nocursor -novtswitch
Restart=always
RestartSec=10
KillMode=mixed

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable x11-kiosk.service

# === ЭТАП 7: Настройка прав для X сервера ===
log "Настройка прав X сервера..."

# Разрешаем любому пользователю запускать X
if ! grep -q "allowed_users=anybody" /etc/X11/Xwrapper.config 2>/dev/null; then
  echo "allowed_users=anybody" > /etc/X11/Xwrapper.config
fi

# Создаем xinitrc для системы
mkdir -p /etc/X11/xinit
cat > /etc/X11/xinit/xinitrc <<'EOF'
#!/bin/bash

# Системный xinitrc
exec openbox-session
EOF

chmod +x /etc/X11/xinit/xinitrc

# === ЭТАП 8: ТЕСТОВЫЙ СКРИПТ С ПРАВАМИ ===
log "Создание тестового скрипта..."

cat > /home/$KIOSK_USER/test-kiosk.sh <<'EOF'
#!/bin/bash

echo "=== ТЕСТ KIOSK ==="
echo "Время: $(date)"
echo "Пользователь: $USER"
echo "Домашняя директория: $HOME"
echo ""

# Проверяем права
echo "1. Проверка прав:"
echo "   UID: $UID"
echo "   Группы: $(groups)"
echo ""

# Проверяем X сервер
echo "2. Проверка X сервера:"
if command -v xdpyinfo >/dev/null 2>&1; then
    echo "   xdpyinfo найден"
    # Пробуем запустить с перенаправлением ошибок
    xdpyinfo 2>&1 | head -5 && echo "   ✓ X сервер доступен" || echo "   ✗ Ошибка доступа к X серверу"
else
    echo "   ✗ xdpyinfo не найден"
fi
echo ""

# Проверяем Chrome
echo "3. Проверка Chrome:"
if command -v google-chrome-stable >/dev/null 2>&1; then
    echo "   ✓ Chrome найден"
    echo "   Версия: $(google-chrome-stable --version 2>/dev/null || echo 'не доступна')"
else
    echo "   ✗ Chrome не найден"
fi
echo ""

# Проверяем файлы
echo "4. Проверка файлов:"
ls -la /home/$USER/kiosk.sh 2>/dev/null && echo "   ✓ kiosk.sh существует" || echo "   ✗ kiosk.sh не найден"
ls -la /home/$USER/.xinitrc 2>/dev/null && echo "   ✓ .xinitrc существует" || echo "   ✗ .xinitrc не найден"
echo ""

# Простой тест X
echo "5. Простой тест X:"
if xhost >/dev/null 2>&1; then
    echo "   ✓ X сервер отвечает"
else
    echo "   ✗ X сервер не отвечает"
    echo "   Попробуйте запустить: startx"
fi
echo ""

echo "Тест завершен"
EOF

chmod +x /home/$KIOSK_USER/test-kiosk.sh
chown $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/test-kiosk.sh

# === ЭТАП 9: РУЧНОЙ ЗАПУСК ДЛЯ ТЕСТА ===
log "Создание скрипта ручного запуска..."

cat > /home/$KIOSK_USER/start-kiosk.sh <<'EOF'
#!/bin/bash

echo "Ручной запуск Kiosk..."
echo "Если X сервер не запущен, он будет запущен автоматически"

# Проверяем запущен ли X
if ! xdpyinfo >/dev/null 2>&1; then
    echo "Запуск X сервера..."
    startx /home/$USER/.xinitrc -- :0 -nocursor
else
    echo "X сервер уже запущен, запускаем kiosk..."
    /home/$USER/kiosk.sh
fi
EOF

chmod +x /home/$KIOSK_USER/start-kiosk.sh
chown $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/start-kiosk.sh

# === ЭТАП 10: ФИНАЛЬНАЯ НАСТРОЙКА ===
log "Финальная настройка прав..."

# Даем права на /dev/tty0 и /dev/tty1
chmod a+rw /dev/tty0 2>/dev/null || true
chmod a+rw /dev/tty1 2>/dev/null || true

# Создаем директорию для логов
mkdir -p /home/$KIOSK_USER/.logs
chown $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/.logs

# Разрешаем пользователю запускать X
if which setcap >/dev/null 2>&1; then
    setcap 'cap_sys_tty_config+ep' /usr/bin/startx 2>/dev/null || true
fi

log "✅ Установка завершена!"
log ""
log "🔧 ДЛЯ ПРОВЕРКИ:"
log "1. Переключитесь на пользователя kiosk:"
log "   sudo -u kiosk -s"
log "2. Запустите тестовый скрипт:"
log "   ./test-kiosk.sh"
log "3. Если тест проходит, попробуйте ручной запуск:"
log "   ./start-kiosk.sh"
log ""
log "📋 ЛОГИ:"
log "   • Киоск: /home/$KIOSK_USER/.logs/kiosk.log"
log "   • Xinitrc: /home/$KIOSK_USER/.logs/xinitrc.log"

if [ "$REBOOT_AFTER" = true ]; then
  log ""
  log "🔄 Перезагрузка через 5 секунд..."
  sleep 5
  reboot
else
  log ""
  log "⚠️  После перезагрузки система автоматически запустит киоск"
  log "   Или выполните: sudo reboot"
fi