#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - ДЛЯ VMWARE/VIRTUALBOX
# С корректной настройкой графики
# ==========================================

set -e
KIOSK_USER="kiosk"
KIOSK_URL="https://www.google.com"
REBOOT_AFTER=false
KEYBOARD_LAYOUT="us"

if [ "$EUID" -ne 0 ]; then echo "Запустите от root: sudo $0"; exit 1; fi

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
  case $1 in
    -u|--user) KIOSK_USER="$2"; shift 2 ;;
    -url|--url) KIOSK_URL="$2"; shift 2 ;;
    -r|--reboot) REBOOT_AFTER=true; shift ;;
    -k|--keyboard) KEYBOARD_LAYOUT="$2"; shift 2 ;;
    *) error "Неизвестный параметр: $1" ;;
  esac
done

log "Настройка Chrome Kiosk для виртуальной машины..."

# === ЭТАП 1: Установка VM графики ===
step "Настройка графики для VMWare/VirtualBox..."
apt update

# Установка VMWare Tools (для VMWare)
if lsmod | grep -q vmwgfx; then
  log "Обнаружена VMWare, устанавливаю open-vm-tools..."
  apt install -y --no-install-recommends open-vm-tools open-vm-tools-desktop
fi

# Установка VirtualBox Guest Utils (для VirtualBox)
if lspci | grep -qi virtualbox; then
  log "Обнаружена VirtualBox, устанавливаю guest utils..."
  apt install -y --no-install-recommends virtualbox-guest-utils
fi

# === ЭТАП 2: Установка X11 и Chrome ===
log "Установка X11 и Chrome..."
apt install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-video-all xserver-xorg-video-vmware \
  xserver-xorg-video-fbdev xserver-xorg-video-vesa \
  xinit openbox dbus-x11 x11-xserver-utils xfonts-base \
  wget ca-certificates

# Установка Chrome
if ! command -v google-chrome-stable &> /dev/null; then
  log "Установка Google Chrome..."
  wget -qO /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  dpkg -i /tmp/chrome.deb || apt-get install -f -y
  rm /tmp/chrome.deb
fi

# === ЭТАП 3: Создание конфига Xorg для VM ===
log "Создание конфигурации Xorg для VM..."
mkdir -p /etc/X11/xorg.conf.d

# Конфиг для VMWare
cat > /etc/X11/xorg.conf.d/99-vmware-kiosk.conf <<EOF
Section "Device"
    Identifier "VMware GPU"
    Driver "vmware"
    Option "AsyncUTPut" "on"
EndSection

Section "Screen"
    Identifier "Default Screen"
    Device "VMware GPU"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080" "1280x720" "1024x768"
    EndSubSection
EndSection

Section "ServerFlags"
    Option "AutoAddGPU" "off"
    Option "DontVTSwitch" "on"
    Option "DontZap" "on"
EndSection
EOF

# Резервный конфиг (если vmware не сработает)
cat > /etc/X11/xorg.conf.d/99-fallback.conf <<EOF
Section "Device"
    Identifier "Fallback GPU"
    Driver "vesa"
EndSection
EOF

# === ЭТАП 4: Создание пользователя ===
if ! id "$KIOSK_USER" &>/dev/null; then
  useradd -m -s /bin/bash -G audio,video,cdrom "$KIOSK_USER"
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "Создан пользователь $KIOSK_USER"
fi

# === ЭТАП 5: Скрипт киоска с ожиданием X ===
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
cat > "$KIOSK_SCRIPT" <<'EOF'
#!/bin/bash

# Логирование
LOGFILE="/home/$USER/kiosk-$(date +%Y%m%d-%H%M%S).log"
exec > "$LOGFILE" 2>&1

echo "=== Запуск Kiosk: $(date) ==="
echo "Дисплей: $DISPLAY"
echo "XAUTHORITY: $XAUTHORITY"

# Ждем готовности X сервера (до 30 секунд)
for i in {1..30}; do
  if xdpyinfo &>/dev/null; then
    echo "X сервер готов!"
    break
  fi
  echo "Ожидание X сервера... $i/30"
  sleep 1
done

# Настройки энергосбережения
xset -dpms
xset s off
xset s noblank

# Установка разрешения (безопасно для VM)
xrandr --size 1024x768 2>/dev/null || true

# Очистка сессий
rm -rf ~/.config/google-chrome/Singleton*

# Установка раскладки
setxkbmap us

# Запуск Chrome в цикле
while true; do
  echo "Запуск Chrome..."
  google-chrome-stable \
    --no-first-run \
    --disable \
    --kiosk \
    --disable-translate \
    --disable-infobars \
    --incognito \
    --disable-gpu-driver-bug-workarounds \
    --disable-gpu \
    --no-sandbox \
    --disable-dev-shm-usage \
    "$KIOSK_URL"
  
  echo "Chrome закрыт. Перезапуск через 2 секунды..."
  sleep 2
done
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === ЭТАП 6: .xinitrc (ИСПРАВЛЕННЫЙ) ===
cat > "/home/$KIOSK_USER/.xinitrc" <<'EOF'
#!/bin/bash

# Запуск Openbox в фоне
openbox-session &

# Даем время на инициализацию
sleep 3

# Запуск киоск-скрипта
exec /home/$USER/kiosk.sh
EOF
chmod +x "/home/$KIOSK_USER/.xinitrc"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/.xinitrc"

# === ЭТАП 7: Systemd service (НАДЕЖНЫЙ) ===
log "Создание systemd service..."
cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chrome Kiosk
After=network.target

[Service]
User=$KIOSK_USER
PAMName=login
TTYPath=/dev/tty1
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$KIOSK_USER/.Xauthority
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/xinit /home/$KIOSK_USER/.xinitrc -- /usr/bin/Xorg :0 -novtswitch -keeptty -noreset
StandardInput=tty
StandardOutput=tty
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

# === ЭТАП 8: Настройки VM ===
log "Отключение заставок консоли..."
sed -i 's/BLANK_TIME=.*/BLANK_TIME=0/' /etc/kbd/config 2>/dev/null || true
sed -i 's/POWERDOWN_TIME=.*/POWERDOWN_TIME=0/' /etc/kbd/config 2>/dev/null || true

# Перезагрузка systemd
systemctl daemon-reload
systemctl enable kiosk.service

# === ЗАВЕРШЕНИЕ ===
log "✅ VM-совместимый Kiosk готов!"
log "После перезагрузки Chrome запустится в VM"
log ""
log "📋 ОТЛАДКА:"
log "  • Логи: tail -f /home/$KIOSK_USER/kiosk-*.log"
log "  • Systemd: sudo journalctl -u kiosk -f"
log "  • Xorg: cat /home/$KIOSK_USER/.xsession-errors"
log ""
log "🔧 Если всё равно ошибка:"
log "  1. Включите 3D-ускорение в настройках VM"
log "  2. Увеличьте видеопамять до 128МБ"
log "  3. Попробуйте драйвер VESA: в скрипте замените 'Driver vmware' на 'Driver vesa'"

if [ "$REBOOT_AFTER" = true ]; then
  log "Перезагрузка через 5 секунд..."
  sleep 5
  reboot
else
  log "Перезагрузитесь вручную: sudo reboot"
fi