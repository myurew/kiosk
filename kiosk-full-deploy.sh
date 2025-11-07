#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - СТАБИЛЬНАЯ ВЕРСИЯ ДЛЯ VIRTUALBOX
# Исправлены проблемы с перезапуском Chrome
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

log "Начало установки стабильного Chrome Kiosk для VirtualBox..."

# === ЭТАП 1: Установка базовых пакетов ===
log "Установка X11 и зависимостей..."
apt update && apt install -y --no-install-recommends \
  xserver-xorg xinit openbox lightdm \
  dbus-x11 x11-xserver-utils xfonts-base \
  wget curl ca-certificates locales \
  alsa-utils

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
  useradd -m -s /bin/bash -G audio,video $KIOSK_USER
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "✓ Пользователь создан (пароль: kiosk123)"
else
  log "Пользователь $KIOSK_USER уже существует"
fi

# === ЭТАП 4: Создание СТАБИЛЬНОГО скрипта киоска ===
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
log "Создание стабильного скрипта киоска..."

cat > "$KIOSK_SCRIPT" <<'EOF'
#!/bin/bash

# Логирование
exec > "/home/$USER/kiosk.log" 2>&1
echo "=== Запуск Kiosk: $(date) ==="

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

# Отключаем энергосбережение
xset -dpms
xset s off
xset s noblank

# Очищаем сессии Chrome (аккуратно)
if [ -d ~/.config/google-chrome ]; then
    echo "Очистка старых сессий Chrome..."
    rm -rf ~/.config/google-chrome/Singleton*
    # Создаем базовый профиль если нужно
    mkdir -p ~/.config/google-chrome/Default
fi

# Устанавливаем раскладку
setxkbmap us

# МИНИМАЛЬНЫЕ флаги Chrome для стабильности
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
--disable-background-timer-throttling
--disable-renderer-backgrounding
--disable-backgrounding-occluded-windows
--disable-features=TranslateUI,BlinkGenPropertyTrees
--enable-features=OverlayScrollbar
--password-store=basic
--autoplay-policy=no-user-gesture-required
"

echo "Запуск Chrome..."
echo "URL: https://www.google.com"

# ЕДИНСТВЕННЫЙ запуск Chrome (без цикла)
# Если Chrome закроется, система перезапустит сервис
google-chrome-stable $CHROME_FLAGS "https://www.google.com"

EXIT_CODE=$?
echo "Chrome завершил работу с кодом: $EXIT_CODE"
echo "Время: $(date)"

# Не перезапускаем сразу - пусть systemd управляет перезапуском
sleep 10
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === ЭТАП 5: Настройка LightDM (автологин) ===
log "Настройка LightDM для автоматического входа..."

if ! command -v lightdm >/dev/null 2>&1; then
    apt install -y lightdm
fi

# Настраиваем автоматический логин
cat > /etc/lightdm/lightdm.conf <<EOF
[Seat:*]
autologin-user=$KIOSK_USER
autologin-user-timeout=0
user-session=openbox
greeter-session=lightdm-greeter
session-cleanup-script=/bin/true
EOF

# Создаем сессию Openbox для LightDM
mkdir -p /home/$KIOSK_USER/.config/openbox
cat > /home/$KIOSK_USER/.config/openbox/autostart <<'EOF'
#!/bin/bash
# Ждем полной инициализации
sleep 3

# Экспортируем переменные
export DISPLAY=:0
export XAUTHORITY=/home/$USER/.Xauthority

# Устанавливаем разрешение (если нужно)
xrandr -s 1024x768 2>/dev/null || true

# Запускаем скрипт киоска
exec /home/$USER/kiosk.sh
EOF

chmod +x /home/$KIOSK_USER/.config/openbox/autostart
chown -R $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/.config

# === ЭТАП 6: Создание ОПТИМИЗИРОВАННОЙ службы ===
log "Создание оптимизированной службы..."

cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chrome Kiosk for VirtualBox
After=lightdm.service
Wants=lightdm.service

[Service]
User=$KIOSK_USER
Group=$KIOSK_USER
Type=simple
WorkingDirectory=/home/$KIOSK_USER
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$KIOSK_USER/.Xauthority
ExecStart=/home/$KIOSK_USER/kiosk.sh
Restart=on-failure
RestartSec=10
StartLimitInterval=60
StartLimitBurst=5

# Логирование
StandardOutput=journal
StandardError=journal
SyslogIdentifier=kiosk

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable kiosk.service

# === ЭТАП 7: Настройка Xorg для VirtualBox ===
log "Создание упрощенной конфигурации Xorg..."

mkdir -p /etc/X11/xorg.conf.d

# Минимальная конфигурация Xorg
cat > /etc/X11/xorg.conf.d/10-vbox-simple.conf <<'EOF'
Section "Device"
    Identifier "Card0"
    Driver "modesetting"
EndSection

Section "Screen"
    Identifier "Screen0"
    Device "Card0"
    Monitor "Monitor0"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1024x768"
    EndSubSection
EndSection

Section "Monitor"
    Identifier "Monitor0"
    HorizSync 28.0 - 33.0
    VertRefresh 43.0 - 72.0
EndSection
EOF

# === ЭТАП 8: Дополнительные настройки стабильности ===
log "Дополнительные настройки для стабильности..."

# Отключаем ненужные сервисы
systemctl disable bluetooth 2>/dev/null || true
systemctl stop bluetooth 2>/dev/null || true

# Увеличиваем лимиты для Chrome
echo "kernel.shmmax = 268435456" >> /etc/sysctl.conf
echo "kernel.shmall = 65536" >> /etc/sysctl.conf

# Создаем диагностический скрипт
cat > /home/$KIOSK_USER/debug-chrome.sh <<'EOF'
#!/bin/bash
echo "=== ДЕБАГ CHROME ==="
echo "Время: $(date)"
echo "Пользователь: $USER"
echo "DISPLAY: $DISPLAY"
echo ""
echo "Процессы Chrome:"
ps aux | grep chrome | grep -v grep
echo ""
echo "Процессы X:"
ps aux | grep Xorg | grep -v grep
echo ""
echo "Память:"
free -h
echo ""
echo "Логи Chrome:"
tail -20 /home/$USER/kiosk.log 2>/dev/null || echo "Логи не найдены"
echo ""
echo "Статус сервиса:"
systemctl status kiosk.service --no-pager -l
EOF

chmod +x /home/$KIOSK_USER/debug-chrome.sh
chown $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/debug-chrome.sh

# === ЭТАП 9: ФИНАЛЬНАЯ НАСТРОЙКА ===
log "Финальная настройка..."

# Включаем LightDM
systemctl enable lightdm

# Даем права на X сервер
echo "xserver-auth-file=/home/$KIOSK_USER/.Xauthority" >> /etc/lightdm/lightdm.conf

# Создаем Xauthority файл
touch /home/$KIOSK_USER/.Xauthority
chown $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/.Xauthority

# === ЭТАП 10: ИНФОРМАЦИЯ И ПЕРЕЗАГРУЗКА ===
log "✅ Установка завершена!"
log ""
log "🔧 ОСОБЕННОСТИ ЭТОЙ ВЕРСИИ:"
log "   • Chrome запускается ОДИН раз (без бесконечного цикла)"
log "   • Systemd управляет перезапуском при сбоях"
log "   • Минимальные стабильные флаги Chrome"
log "   • Упрощенная конфигурация Xorg"
log ""
log "📋 ДЛЯ ДИАГНОСТИКИ ПРОБЛЕМ:"
log "   • Логи Chrome: tail -f /home/$KIOSK_USER/kiosk.log"
log "   • Логи systemd: journalctl -u kiosk.service -f"
log "   • Дебаг скрипт: sudo -u $KIOSK_USER /home/$KIOSK_USER/debug-chrome.sh"
log ""
log "⚙️  ЕСЛИ CHROME ПАДАЕТ:"
log "   • Systemd автоматически перезапустит через 10 секунд"
log "   • Проверьте логи для выявления причины падения"

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