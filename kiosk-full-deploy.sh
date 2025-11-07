#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - УНИВЕРСАЛЬНАЯ ВЕРСИЯ
# Работает на VM (VMWare/VirtualBox) и физических машинах
# ==========================================

# === 1. ОПРЕДЕЛЕНИЕ ФУНКЦИЙ (в начале!) ===
log() { echo -e "\033[0;32m[INFO]\033[0m $(date '+%H:%M:%S') $1"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $(date '+%H:%M:%S') $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $(date '+%H:%M:%S') $1"; exit 1; }
step() { echo -e "\n\033[0;34m▶\033[0m \033[0;34m$1\033[0m"; }

# === 2. ПРОВЕРКИ И ПЕРЕМЕННЫЕ ===
set -e
if [ "$EUID" -ne 0 ]; then error "Запустите от root: sudo $0"; fi

KIOSK_USER="kiosk"
KIOSK_URL="https://www.google.com"
REBOOT_AFTER=false
KEYBOARD_LAYOUT="us"

# === 3. АВТООПРЕДЕЛЕНИЕ СРЕДЫ (VM или физическая машина) ===
detect_environment() {
    if lsmod | grep -q vmwgfx 2>/dev/null; then
        echo "vmware"
    elif lspci | grep -qi virtualbox 2>/dev/null; then
        echo "virtualbox"
    elif systemd-detect-virt --quiet --vm 2>/dev/null; then
        echo "other-vm"
    else
        echo "physical"
    fi
}

ENV_TYPE=$(detect_environment)
step "Обнаружена среда: ${ENV_TYPE^^}"

# === 4. ПАРСИНГ АРГУМЕНТОВ ===
while [[ $# -gt 0 ]]; do
  case $1 in
    -u|--user) KIOSK_USER="$2"; shift 2 ;;
    -url|--url) KIOSK_URL="$2"; shift 2 ;;
    -r|--reboot) REBOOT_AFTER=true; shift ;;
    -k|--keyboard) KEYBOARD_LAYOUT="$2"; shift 2 ;;
    *) error "Неизвестный параметр: $1" ;;
  esac
done

log "Настройка Chrome Kiosk для: ${ENV_TYPE^^}"

# === 5. УСТАНОВКА ПАКЕТОВ (условно) ===
step "Установка X11 и базовых пакетов..."
apt update && apt install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-video-all xserver-xorg-input-all \
  xinit openbox dbus-x11 x11-xserver-utils xfonts-base \
  wget ca-certificates locales

# Установка VM-специфичных пакетов только если нужно
if [ "$ENV_TYPE" = "vmware" ]; then
    log "Установка VMWare драйверов..."
    apt install -y --no-install-recommends open-vm-tools open-vm-tools-desktop xserver-xorg-video-vmware
elif [ "$ENV_TYPE" = "virtualbox" ]; then
    log "Установка VirtualBox драйверов..."
    apt install -y --no-install-recommends virtualbox-guest-utils xserver-xorg-video-qxl
fi

# === 6. УСТАНОВКА GOOGLE CHROME ===
step "Установка Google Chrome..."
if ! command -v google-chrome-stable &> /dev/null; then
  log "Загрузка .deb файла..."
  wget -q -O /tmp/google-chrome-stable.deb \
    "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  
  log "Установка пакета..."
  dpkg -i /tmp/google-chrome-stable.deb || apt-get install -f -y
  rm -f /tmp/google-chrome-stable.deb
else
  log "Google Chrome уже установлен"
fi

# === 7. СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ ===
step "Создание пользователя $KIOSK_USER..."
if ! id "$KIOSK_USER" &>/dev/null; then
  useradd -m -s /bin/bash -G audio,video,cdrom "$KIOSK_USER"
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "✓ Пользователь создан (пароль: kiosk123)"
else
  log "Пользователь уже существует"
fi

# === 8. СКРИПТ КИОСКА (универсальный) ===
step "Создание скрипта автозапуска..."
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
cat > "$KIOSK_SCRIPT" <<'EOF'
#!/bin/bash

LOGFILE="/home/$USER/kiosk-$(date +%Y%m%d-%H%M%S).log"
exec > "$LOGFILE" 2>&1
echo "=== Запуск Kiosk: $(date) ==="
echo "Среда: $([ -f /.dockerenv ] && echo "docker" || (lsmod | grep -q vmwgfx && echo "vmware" || (lspci | grep -qi virtualbox && echo "virtualbox" || echo "physical")))"

# Ожидание X сервера
for i in {1..30}; do
  if xdpyinfo &>/dev/null; then break; fi
  echo "Ожидание X сервера... $i/30"
  sleep 1
done

# Настройки X11
xset -dpms; xset s off; xset s noblank
rm -rf ~/.config/google-chrome/Singleton*

# Универсальные флаги Chrome (работают везде)
CHROME_FLAGS="--no-first-run --disable --kiosk --incognito"

# Дополнительные флаги для VM (если графика лагает)
if lsmod | grep -q vmwgfx 2>/dev/null || lspci | grep -qi virtualbox 2>/dev/null; then
  CHROME_FLAGS="$CHROME_FLAGS --disable-gpu --no-sandbox --disable-dev-shm-usage"
fi

# Запуск Chrome
while true; do
  echo "Запуск Chrome с флагами: $CHROME_FLAGS"
  google-chrome-stable $CHROME_FLAGS "$KIOSK_URL"
  echo "⚠️ Chrome закрыт! Перезапуск..."
  sleep 2
done
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === 9. .xinitrc (универсальный) ===
step "Настройка X-сессии..."
cat > "/home/$KIOSK_USER/.xinitrc" <<'EOF'
#!/bin/bash
openbox-session &
sleep 2
exec /home/$USER/kiosk.sh
EOF
chmod +x "/home/$KIOSK_USER/.xinitrc"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/.xinitrc"

# === 10. SYSTEMD SERVICE (надежный) ===
step "Настройка автологина..."
cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chrome Kiosk for $ENV_TYPE
After=network.target

[Service]
User=$KIOSK_USER
PAMName=login
TTYPath=/dev/tty1
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$KIOSK_USER/.Xauthority
ExecStartPre=/bin/sleep 2
ExecStart=/usr/bin/xinit /home/$KIOSK_USER/.xinitrc -- /usr/bin/Xorg :0 -novtswitch -keeptty
StandardInput=tty
StandardOutput=tty
StandardError=tty
Restart=always
RestartSec=5

[Install]
WantedBy=graphical.target
EOF

systemctl daemon-reload
systemctl enable kiosk.service
systemctl mask getty@tty1.service 2>/dev/null || true

# === 11. ЗАВЕРШЕНИЕ ===
step "Установка завершена!"
log "✅ Среда: ${ENV_TYPE^^}"
log "✅ Пользователь: $KIOSK_USER"
log "✅ Браузер: Google Chrome"
log "✅ URL: $KIOSK_URL"
log ""
log "📋 ДЕБАГ:"
log "  • Логи: tail -f /home/$KIOSK_USER/kiosk-*.log"
log "  • Systemd: sudo journalctl -u kiosk -f"
log "  • TTY: Ctrl+Alt+F1 (главный), Ctrl+Alt+F2 (консоль)"

if [ "$REBOOT_AFTER" = true ]; then
  log "🔄 Перезагрузка через 5 секунд..."
  sleep 5
  reboot
else
  log "⚠️  НУЖНА ПЕРЕЗАГРУЗКА: sudo reboot"
fi