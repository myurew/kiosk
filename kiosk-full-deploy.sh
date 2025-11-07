#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - УНИВЕРСАЛЬНАЯ ВЕРСИЯ
# Работает на VM (VMWare/VirtualBox/KVM) и физических машинах
# ==========================================

# === 1. ВСЕ ФУНКЦИИ В НАЧАЛЕ (обязательно!) ===
log() { echo -e "\033[0;32m[INFO]\033[0m $(date '+%H:%M:%S') $1"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $(date '+%H:%M:%S') $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $(date '+%H:%M:%S') $1"; exit 1; }
step() { echo -e "\n\033[0;34m▶\033[0m \033[0;34m$1\033[0m"; }

# === 2. АВТООПРЕДЕЛЕНИЕ СРЕДЫ (VM или физическая) ===
detect_environment() {
    if [ -f /.dockerenv ]; then
        echo "docker"
    elif systemd-detect-virt --quiet --vm 2>/dev/null; then
        # Определяем тип VM
        local vm_type=$(systemd-detect-virt 2>/dev/null)
        case "$vm_type" in
            vmware) echo "vmware" ;;
            oracle) echo "virtualbox" ;;
            microsoft) echo "hyperv" ;;
            kvm) echo "kvm" ;;
            *) echo "other-vm" ;;
        esac
    else
        echo "physical"
    fi
}

# === 3. ПРОВЕРКИ И ПЕРЕМЕННЫЕ ===
set -e
if [ "$EUID" -ne 0 ]; then error "Запустите от root: sudo $0"; fi

KIOSK_USER="kiosk"
KIOSK_URL="https://www.google.com"
REBOOT_AFTER=false
KEYBOARD_LAYOUT="us"

# === 4. ОПРЕДЕЛЯЕМ СРЕДУ ===
ENV_TYPE=$(detect_environment)

# === 5. ПАРСИНГ АРГУМЕНТОВ ===
while [[ $# -gt 0 ]]; do
  case $1 in
    -u|--user) KIOSK_USER="$2"; shift 2 ;;
    -url|--url) KIOSK_URL="$2"; shift 2 ;;
    -r|--reboot) REBOOT_AFTER=true; shift ;;
    -k|--keyboard) KEYBOARD_LAYOUT="$2"; shift 2 ;;
    *) error "Неизвестный параметр: $1" ;;
  esac
done

# === 6. ОСНОВНОЙ КОД (после всех определений) ===
step "Начало установки Google Chrome Kiosk"
log "Обнаружена среда: ${ENV_TYPE^^}"

# === ЭТАП 1: Установка базовых пакетов ===
log "Установка X11 и зависимостей..."
apt update && apt install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-video-all xserver-xorg-input-all \
  xinit openbox dbus-x11 x11-xserver-utils xfonts-base \
  wget ca-certificates

# === ЭТАП 2: Установка VM-специфичных пакетов (только для VM) ===
case "$ENV_TYPE" in
    vmware)
        log "Установка VMWare Tools..."
        apt install -y --no-install-recommends open-vm-tools open-vm-tools-desktop xserver-xorg-video-vmware
        ;;
    virtualbox)
        log "Установка VirtualBox Guest Utils..."
        apt install -y --no-install-recommends virtualbox-guest-utils xserver-xorg-video-qxl
        ;;
esac

# === ЭТАП 3: Установка Google Chrome ===
step "Установка Google Chrome..."
if ! command -v google-chrome-stable &> /dev/null; then
  log "Загрузка Chrome..."
  wget -qO /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
  dpkg -i /tmp/chrome.deb || apt-get install -f -y
  rm -f /tmp/chrome.deb
else
  log "Chrome уже установлен"
fi

# === ЭТАП 4: Создание пользователя ===
step "Создание пользователя $KIOSK_USER..."
if ! id "$KIOSK_USER" &>/dev/null; then
  useradd -m -s /bin/bash -G audio,video,cdrom "$KIOSK_USER"
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "✓ Пользователь создан"
fi

# === ЭТАП 5: КОНФИГУРАЦИЯ XORG ДЛЯ VM (при необходимости) ===
if [ "$ENV_TYPE" = "vmware" ] || [ "$ENV_TYPE" = "virtualbox" ]; then
    log "Создание конфигурации Xorg для VM..."
    mkdir -p /etc/X11/xorg.conf.d
    
    cat > /etc/X11/xorg.conf.d/99-vm-kiosk.conf <<EOF
Section "Device"
    Identifier "VM GPU"
    Driver "$([ "$ENV_TYPE" = "vmware" ] && echo "vmware" || echo "qxl")"
EndSection

Section "Screen"
    Identifier "Default Screen"
    DefaultDepth 24
    SubSection "Display"
        Depth 24
        Modes "1920x1080" "1280x720" "1024x768"
    EndSubSection
EndSection

Section "ServerFlags"
    Option "DontVTSwitch" "on"
    Option "DontZap" "on"
EndSection
EOF
fi

# === ЭТАП 6: Скрипт киоска (адаптивный) ===
step "Создание скрипта автозапуска..."
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
cat > "$KIOSK_SCRIPT" <<'EOF'
#!/bin/bash

LOGFILE="/home/$USER/kiosk-$(date +%Y%m%d-%H%M%S).log"
exec > "$LOGFILE" 2>&1
echo "=== Запуск Kiosk: $(date) ==="
echo "Среда: $(systemd-detect-virt 2>/dev/null || echo 'physical')"

# Ожидание X сервера
for i in {1..30}; do
  if xdpyinfo &>/dev/null; then break; fi
  echo "Ожидание X сервера... $i/30"
  sleep 1
done

# Настройки
xset -dpms; xset s off; xset s noblank
rm -rf ~/.config/google-chrome/Singleton*

# Базовые флаги Chrome
CHROME_FLAGS="--no-first-run --disable --kiosk --incognito --disable-translate --disable-infobars"

# Добавляем VM-флаги только если это VM
if systemd-detect-virt --quiet --vm 2>/dev/null; then
  echo "Обнаружена VM, добавляю флаги..."
  CHROME_FLAGS="$CHROME_FLAGS --disable-gpu --no-sandbox --disable-dev-shm-usage"
fi

# Запуск Chrome в цикле
while true; do
  echo "Запуск Chrome: $CHROME_FLAGS"
  google-chrome-stable $CHROME_FLAGS "$KIOSK_URL"
  echo "⚠️ Chrome закрыт! Перезапуск..."
  sleep 2
done
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === ЭТАП 7: .xinitrc ===
step "Настройка X-сессии..."
cat > "/home/$KIOSK_USER/.xinitrc" <<'EOF'
#!/bin/bash
openbox-session &
sleep 2
exec /home/$USER/kiosk.sh
EOF
chmod +x "/home/$KIOSK_USER/.xinitrc"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/.xinitrc"

# === ЭТАП 8: Systemd service ===
step "Настройка автологина..."
cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chrome Kiosk (\L$ENV_TYPE\E)
After=network.target

[Service]
User=$KIOSK_USER
PAMName=login
TTYPath=/dev/tty1
Environment=DISPLAY=:0
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
systemctl mask getty@tty1.service 2>/dev/null || true

# === ЗАВЕРШЕНИЕ ===
step "Установка завершена!"
log "✅ Среда: ${ENV_TYPE^^}"
log "✅ Специфичные пакеты: $([ "$ENV_TYPE" != "physical" ] && echo "ДА" || echo "НЕТ")"
log "✅ VM-флаги Chrome: $([ "$ENV_TYPE" != "physical" ] && echo "ДОБАВЛЕНЫ" || echo "НЕТ")"
log ""
log "📋 ДЕБАГ:"
log "  • Логи: tail -f /home/$KIOSK_USER/kiosk-*.log"
log "  • Systemd: sudo journalctl -u kiosk -f"
log "  • Xorg: cat /var/log/Xorg.0.log"

if [ "$REBOOT_AFTER" = true ]; then
  log "🔄 Перезагрузка через 5 секунд..."
  sleep 5
  reboot
else
  log "⚠️  НУЖНА ПЕРЕЗАГРУЗКА: sudo reboot"
fi