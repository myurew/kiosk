#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - ТОЛЬКО GOOGLE CHROME
# Полностью рабочая версия с логированием
# Поддержка VirtualBox и VMware
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

# Функция определения среды
detect_environment() {
    if systemd-detect-virt --quiet --vm 2>/dev/null; then
        local vm_type=$(systemd-detect-virt 2>/dev/null)
        case "$vm_type" in
            vmware) echo "vmware" ;;
            oracle) echo "virtualbox" ;;
            kvm) echo "kvm" ;;
            *) echo "other-vm" ;;
        esac
    else
        echo "physical"
    fi
}

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

# Определяем среду
ENV_TYPE=$(detect_environment)
log "Обнаружена среда: $ENV_TYPE"

log "Начало установки Google Chrome Kiosk для $KIOSK_USER..."

# === ЭТАП 1: Установка X11 ===
log "Установка X11 и зависимостей..."
apt update && apt install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-video-all xserver-xorg-input-all \
  xinit openbox dbus-x11 x11-xserver-utils xfonts-base \
  wget curl ca-certificates locales

# === ЭТАП 2: Установка VM-специфичных пакетов ===
case "$ENV_TYPE" in
    vmware)
        log "Установка VMWare Tools..."
        apt install -y --no-install-recommends open-vm-tools open-vm-tools-desktop
        ;;
    virtualbox)
        log "Установка VirtualBox Guest Utils..."
        apt install -y --no-install-recommends virtualbox-guest-utils virtualbox-guest-x11
        ;;
esac

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
  useradd -m -s /bin/bash -G audio,video,cdrom "$KIOSK_USER"
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "✓ Пользователь создан (пароль: kiosk123)"
else
  log "Пользователь $KIOSK_USER уже существует"
fi

# === ЭТАП 5: Скрипт автозапуска Chrome (адаптивный для VM) ===
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
log "Создание скрипта киоска..."

cat > "$KIOSK_SCRIPT" <<EOF
#!/bin/bash

# ЛОГИРОВАНИЕ ВСЕХ ОШИБОК
LOGFILE="/home/\$USER/kiosk-\$(date +%Y%m%d-%H%M%S).log"
exec > "\$LOGFILE" 2>&1
echo "=== Запуск Kiosk: \$(date) ==="
echo "Среда: $ENV_TYPE"
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
setxkbmap $KEYBOARD_LAYOUT

# Базовые флаги Chrome
CHROME_FLAGS="--no-first-run --disable --disable-translate --disable-infobars --disable-suggestions-service --disable-save-password-bubble --disable-sync --no-default-browser-check --disable-web-security --incognito --kiosk --start-maximized"

# Добавляем VM-специфичные флаги
if [ "$ENV_TYPE" != "physical" ]; then
    echo "VM-среда: добавляю оптимизации..."
    CHROME_FLAGS="\$CHROME_FLAGS --disable-gpu --no-sandbox --disable-dev-shm-usage"
fi

# Запуск Chrome в бесконечном цикле
while true; do
  echo "Запуск Chrome с флагами: \$CHROME_FLAGS"
  google-chrome-stable \$CHROME_FLAGS "$KIOSK_URL"
  
  echo "Chrome закрыт. Перезапуск через 2 секунды..."
  sleep 2
done
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === ЭТАП 6: Настройка X-сессии ===
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

# === ЭТАП 7: НАДЕЖНЫЙ АВТОЛОГИН ЧЕРЕЗ SYSTEMD ===
log "Настройка автологина через systemd..."

# Отключаем стандартный getty
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl mask getty@tty1.service 2>/dev/null || true

# Создаем собственный сервис
cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chrome Kiosk ($ENV_TYPE)
After=network.target

[Service]
User=$KIOSK_USER
PAMName=login
TTYPath=/dev/tty1
ExecStart=/usr/bin/xinit /home/$KIOSK_USER/.xinitrc -- /usr/bin/Xorg :0 -novtswitch -keeptty
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

# === ЭТАП 8: Дополнительная настройка для VirtualBox ===
if [ "$ENV_TYPE" = "virtualbox" ]; then
    log "Дополнительная настройка для VirtualBox..."
    
    # Включаем автоматическое разрешение экрана для VirtualBox
    cat > /etc/X11/Xsession.d/99vbox <<'EOF'
#!/bin/bash
# Автоматическое определение разрешения в VirtualBox
if [ -x /usr/bin/VBoxClient ]; then
    /usr/bin/VBoxClient --display
    /usr/bin/VBoxClient --clipboard
    /usr/bin/VBoxClient --draganddrop
fi
EOF
    chmod +x /etc/X11/Xsession.d/99vbox
fi

# === ЭТАП 9: ФИНАЛ ===
log "✅ Установка завершена!"
log "✅ Среда: $ENV_TYPE"
log "✅ VM-оптимизации: $([ "$ENV_TYPE" != "physical" ] && echo "ВКЛ" || echo "ВЫКЛ")"
log ""
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