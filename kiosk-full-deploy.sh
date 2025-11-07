#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - ОПТИМИЗИРОВАННЫЙ ДЛЯ VIRTUALBOX
# Упрощенная графическая настройка для VirtualBox
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

log "Начало установки Google Chrome Kiosk для VirtualBox..."

# === ЭТАП 1: Установка базовых пакетов ===
log "Установка X11 и зависимостей..."
apt update && apt install -y --no-install-recommends \
  xserver-xorg xinit openbox lightdm \
  dbus-x11 x11-xserver-utils xfonts-base \
  wget curl ca-certificates locales \
  alsa-utils pulseaudio

# === ЭТАП 2: Минимальная установка VirtualBox пакетов ===
log "Установка VirtualBox Guest Utils..."
apt install -y --no-install-recommends \
  linux-headers-amd64 \
  build-essential \
  dkms

# Пробуем найти пакеты VirtualBox
if apt-cache show virtualbox-guest-utils > /dev/null 2>&1; then
    apt install -y --no-install-recommends virtualbox-guest-utils
elif apt-cache show virtualbox-guest-x11 > /dev/null 2>&1; then
    apt install -y --no-install-recommends virtualbox-guest-x11
else
    warn "Пакеты VirtualBox не найдены, используем базовый Xorg"
fi

# === ЭТАП 3: Установка Google Chrome ===
if ! command -v google-chrome-stable &> /dev/null; then
  log "Установка Google Chrome..."
  wget -qO /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  dpkg -i /tmp/chrome.deb || apt-get install -f -y
  rm -f /tmp/chrome.deb
else
  log "Google Chrome уже установлен"
fi

# === ЭТАП 4: Создание пользователя ===
if ! id "$KIOSK_USER" &>/dev/null; then
  log "Создание пользователя $KIOSK_USER..."
  useradd -m -s /bin/bash -G audio,video $KIOSK_USER
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "✓ Пользователь создан (пароль: kiosk123)"
else
  log "Пользователь $KIOSK_USER уже существует"
fi

# === ЭТАП 5: Создание УПРОЩЕННОГО скрипта киоска ===
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
log "Создание упрощенного скрипта киоска..."

cat > "$KIOSK_SCRIPT" <<'EOF'
#!/bin/bash

# Логирование
exec > "/home/$USER/kiosk.log" 2>&1
echo "=== Запуск Kiosk: $(date) ==="

# Ждем запуска X сервера
echo "Ожидание X сервера..."
while [ -z "$(ps aux | grep Xorg | grep -v grep)" ]; do
    sleep 1
done

# Дополнительная пауза для инициализации
sleep 3

# Проверяем X сервер
if ! xdpyinfo >/dev/null 2>&1; then
    echo "ОШИБКА: X сервер не доступен"
    exit 1
fi

echo "X сервер запущен успешно"

# Отключаем энергосбережение
xset -dpms
xset s off
xset s noblank

# Очищаем сессии Chrome
rm -rf ~/.config/google-chrome/Singleton*

# Устанавливаем раскладку
setxkbmap us

# Флаги Chrome для VirtualBox
CHROME_FLAGS="
--no-first-run
--disable
--disable-translate
--disable-infobars
--disable-suggestions-service
--disable-save-password-bubble
--disable-sync
--no-default-browser-check
--disable-web-security
--incognito
--kiosk
--start-maximized
--disable-gpu
--no-sandbox
--disable-dev-shm-usage
--disable-software-rasterizer
--disable-features=VizDisplayCompositor
--use-gl=swiftshader
--ignore-gpu-blocklist
"

echo "Запуск Chrome..."
echo "Флаги: $CHROME_FLAGS"

# Запускаем Chrome
while true; do
    google-chrome-stable $CHROME_FLAGS "https://www.google.com"
    echo "Chrome перезапуск через 3 секунды..."
    sleep 3
done
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === ЭТАП 6: Настройка LightDM (автологин) ===
log "Настройка LightDM для автоматического входа..."

# Устанавливаем lightdm если не установлен
if ! command -v lightdm >/dev/null 2>&1; then
    apt install -y lightdm
fi

# Настраиваем автоматический логин
cat > /etc/lightdm/lightdm.conf <<EOF
[Seat:*]
autologin-user=$KIOSK_USER
autologin-user-timeout=0
user-session=openbox
session-setup-script=/bin/bash -c 'sleep 1; startx &'
EOF

# Создаем сессию Openbox для LightDM
mkdir -p /home/$KIOSK_USER/.config/openbox
cat > /home/$KIOSK_USER/.config/openbox/autostart <<'EOF'
#!/bin/bash
# Ждем инициализации
sleep 2

# Запускаем скрипт киоска
exec /home/$USER/kiosk.sh
EOF

chmod +x /home/$KIOSK_USER/.config/openbox/autostart
chown -R $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/.config

# === ЭТАП 7: Создание службы для надежного запуска ===
log "Создание службы для киоска..."

cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chrome Kiosk for VirtualBox
After=lightdm.service

[Service]
User=$KIOSK_USER
Group=$KIOSK_USER
Type=simple
ExecStart=/home/$KIOSK_USER/kiosk.sh
Restart=always
RestartSec=5
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$KIOSK_USER/.Xauthority

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable kiosk.service

# === ЭТАП 8: Настройка Xorg для VirtualBox ===
log "Создание конфигурации Xorg для VirtualBox..."

mkdir -p /etc/X11/xorg.conf.d

# Простая конфигурация Xorg
cat > /etc/X11/xorg.conf.d/10-vbox.conf <<'EOF'
Section "Device"
    Identifier "VirtualBox Graphics"
    Driver "modesetting"
    Option "AccelMethod" "none"
EndSection

Section "Monitor"
    Identifier "VirtualBox Monitor"
    HorizSync 1.0 - 100.0
    VertRefresh 1.0 - 100.0
EndSection

Section "Screen"
    Identifier "Default Screen"
    Monitor "VirtualBox Monitor"
    Device "VirtualBox Graphics"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1024x768" "800x600" "640x480"
    EndSubSection
EndSection

Section "ServerFlags"
    Option "DontZap" "on"
    Option "DontVTSwitch" "on"
EndSection
EOF

# === ЭТАП 9: Настройка разрешения ===
log "Настройка автоматического разрешения..."

# Создаем скрипт для автоматического разрешения
cat > /usr/local/bin/set-vbox-resolution <<'EOF'
#!/bin/bash
# Ждем запуска X
sleep 5

# Пробуем установить разрешение
for res in "1024x768" "800x600" "1280x720" "1366x768"; do
    if xrandr | grep -q "$res"; then
        xrandr -s "$res"
        echo "Установлено разрешение: $res"
        break
    fi
done
EOF

chmod +x /usr/local/bin/set-vbox-resolution

# Добавляем в автозагрузку
cat > /home/$KIOSK_USER/.xprofile <<'EOF'
#!/bin/bash
/usr/local/bin/set-vbox-resolution &
EOF

chmod +x /home/$KIOSK_USER/.xprofile
chown $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/.xprofile

# === ЭТАП 10: ФИНАЛЬНАЯ НАСТРОЙКА ===
log "Финальная настройка..."

# Разрешаем автоматический логин
mkdir -p /etc/systemd/system/lightdm.service.d
cat > /etc/systemd/system/lightdm.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=/usr/sbin/lightdm --log-dir=/var/log/lightdm --run-dir=/run/lightdm
Restart=always
EOF

# Включаем LightDM
systemctl enable lightdm

# === ЭТАП 11: ИНФОРМАЦИЯ ===
log "✅ Установка завершена!"
log ""
log "🔧 КОНФИГУРАЦИЯ VIRTUALBOX:"
log "   • Видеопамять: 128 МБ минимум"
log "   • Включите 3D-ускорение в настройках VM"
log "   • Разрешение: установите минимум 1024x768"
log ""
log "📋 ДЛЯ ДИАГНОСТИКИ:"
log "   • Логи киоска: tail -f /home/$KIOSK_USER/kiosk.log"
log "   • Логи LightDM: journalctl -u lightdm -f"
log "   • Логи Xorg: cat /var/log/Xorg.0.log"
log ""
log "🔄 ПЕРЕЗАГРУЗКА:"

if [ "$REBOOT_AFTER" = true ]; then
  log "Перезагрузка через 5 секунд..."
  sleep 5
  reboot
else
  log "Выполните: sudo reboot"
fi

echo ""
warn "После перезагрузки система автоматически зайдет под пользователем $KIOSK_USER"
warn "и запустит Chrome в режиме киоска"