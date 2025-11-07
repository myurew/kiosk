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
        log "Установка VirtualBox Guest Additions..."
        # Устанавливаем зависимости для сборки
        apt install -y --no-install-recommends \
          linux-headers-amd64 \
          build-essential \
          dkms \
          xserver-xorg-video-qxl
        
        # Пробуем найти доступные пакеты VirtualBox
        if apt-cache show virtualbox-guest-utils > /dev/null 2>&1; then
            apt install -y --no-install-recommends virtualbox-guest-utils
        elif apt-cache show virtualbox-guest-x11 > /dev/null 2>&1; then
            apt install -y --no-install-recommends virtualbox-guest-x11
        else
            warn "Пакеты VirtualBox Guest Utils не найдены в репозиториях"
            warn "Установите Guest Additions вручную из меню VirtualBox"
        fi
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
echo "Пользователь: \$USER"
echo "DISPLAY: \$DISPLAY"

# Проверяем доступность X сервера
echo "Проверка X сервера..."
for i in {1..30}; do
    if xdpyinfo >/dev/null 2>&1; then
        echo "✓ X сервер готов на попытке \$i"
        break
    fi
    echo "Ожидание X сервера... \$i/30"
    sleep 1
done

# Проверяем окончательно
if ! xdpyinfo >/dev/null 2>&1; then
    echo "❌ X сервер не доступен после 30 секунд ожидания"
    exit 1
fi

# Настройки энергосбережения
echo "Настройка энергосбережения..."
xset -dpms
xset s off
xset s noblank

# Очистка старых сессий
echo "Очистка старых сессий Chrome..."
rm -rf ~/.config/google-chrome/Singleton*

# Установка раскладки
echo "Установка раскладки: $KEYBOARD_LAYOUT"
setxkbmap $KEYBOARD_LAYOUT

# Базовые флаги Chrome
CHROME_FLAGS="--no-first-run --disable --disable-translate --disable-infobars --disable-suggestions-service --disable-save-password-bubble --disable-sync --no-default-browser-check --disable-web-security --incognito --kiosk --start-maximized"

# Добавляем VM-специфичные флаги
if [ "$ENV_TYPE" != "physical" ]; then
    echo "VM-среда: добавляю оптимизации..."
    CHROME_FLAGS="\$CHROME_FLAGS --disable-gpu --no-sandbox --disable-dev-shm-usage"
fi

# Запуск Chrome в бесконечном цикле
echo "Запуск Chrome с флагами: \$CHROME_FLAGS"
echo "URL: $KIOSK_URL"

while true; do
    echo "=== Запуск Chrome: \$(date) ==="
    google-chrome-stable \$CHROME_FLAGS "$KIOSK_URL"
    EXIT_CODE=\$?
    echo "Chrome закрыт с кодом: \$EXIT_CODE. Перезапуск через 3 секунды..."
    sleep 3
done
EOF

chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# === ЭТАП 6: Настройка X-сессии ===
cat > "/home/$KIOSK_USER/.xinitrc" <<'EOF'
#!/bin/bash

# Логирование запуска X
echo "=== Запуск X session: $(date) ===" > /home/$USER/xsession.log

# Экспортируем переменные
export DISPLAY=:0
export XAUTHORITY=/home/$USER/.Xauthority

# Запускаем Openbox в фоне
echo "Запуск Openbox..." >> /home/$USER/xsession.log
openbox-session 2>> /home/$USER/xsession.log &

# Даем Openbox время на запуск
echo "Ожидание Openbox..." >> /home/$USER/xsession.log
sleep 3

# Проверяем запущенные процессы
echo "Запущенные процессы:" >> /home/$USER/xsession.log
ps aux >> /home/$USER/xsession.log

# Запускаем киоск-скрипт
echo "Запуск kiosk.sh..." >> /home/$USER/xsession.log
exec /home/$USER/kiosk.sh
EOF

chmod +x "/home/$KIOSK_USER/.xinitrc"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/.xinitrc"

# === ЭТАП 7: ПРАВИЛЬНЫЙ АВТОЛОГИН ЧЕРЕЗ SYSTEMD ===
log "Настройка автологина через systemd..."

# Отключаем стандартный getty на tty1
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl mask getty@tty1.service 2>/dev/null || true

# Создаем правильный сервис для автологина
cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chrome Kiosk ($ENV_TYPE)
After=systemd-user-sessions.service plymouth-quit-wait.service
Before=getty.target

[Service]
User=$KIOSK_USER
Group=$KIOSK_USER
WorkingDirectory=/home/$KIOSK_USER
ExecStartPre=/bin/sleep 3
ExecStart=/usr/bin/startx /home/$KIOSK_USER/.xinitrc -- :0 -novtswitch -keeptty -verbose 3
Restart=always
RestartSec=3
StandardOutput=journal
StandardError=journal
Environment=DISPLAY=:0
Environment=XAUTHORITY=/home/$KIOSK_USER/.Xauthority

[Install]
WantedBy=multi-user.target
EOF

# Включаем сервис
systemctl daemon-reload
systemctl enable kiosk.service

# === ЭТАП 8: Настройка автоматического логина в getty ===
log "Настройка автоматического логина..."

# Создаем конфигурацию для автоматического логина
mkdir -p /etc/systemd/system/getty@tty1.service.d

cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
EOF

# === ЭТАП 9: Дополнительная настройка для VirtualBox ===
if [ "$ENV_TYPE" = "virtualbox" ]; then
    log "Дополнительная настройка для VirtualBox..."
    
    # Создаем простой скрипт для автоматического разрешения
    cat > /home/$KIOSK_USER/.xprofile <<'EOF'
#!/bin/bash
# Автоматическое определение разрешения в VirtualBox
echo "Запуск .xprofile: $(date)" >> /home/$USER/xprofile.log
if command -v xrandr > /dev/null; then
    echo "Настройка разрешения через xrandr..." >> /home/$USER/xprofile.log
    sleep 5
    xrandr --auto
    echo "Разрешение установлено: $(xrandr | grep '*')" >> /home/$USER/xprofile.log
fi
EOF
    chmod +x /home/$KIOSK_USER/.xprofile
    chown $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/.xprofile
fi

# === ЭТАП 10: Создание диагностического скрипта ===
log "Создание диагностического скрипта..."

cat > /home/$KIOSK_USER/diagnose.sh <<'EOF'
#!/bin/bash
echo "=== ДИАГНОСТИКА KIOSK ==="
echo "Время: $(date)"
echo "Пользователь: $USER"
echo "DISPLAY: $DISPLAY"
echo ""
echo "=== Процессы ==="
ps aux | grep -E "(Xorg|xinit|openbox|chrome)" | grep -v grep
echo ""
echo "=== X сервер ==="
if xdpyinfo >/dev/null 2>&1; then
    echo "✓ X сервер работает"
    xdpyinfo | grep dimensions
else
    echo "✗ X сервер не доступен"
fi
echo ""
echo "=== Логи ==="
echo "Последние логи kiosk:"
tail -n 10 /home/$USER/kiosk-*.log 2>/dev/null || echo "Логи kiosk не найдены"
echo ""
echo "Логи X session:"
tail -n 10 /home/$USER/xsession.log 2>/dev/null || echo "Логи X session не найдены"
echo ""
echo "Systemd статус:"
systemctl status kiosk.service --no-pager -l
EOF

chmod +x /home/$KIOSK_USER/diagnose.sh
chown $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/diagnose.sh

# === ЭТАП 11: ФИНАЛ ===
log "✅ Установка завершена!"
log "✅ Среда: $ENV_TYPE"
log "✅ VM-оптимизации: $([ "$ENV_TYPE" != "physical" ] && echo "ВКЛ" || echo "ВЫКЛ")"
log ""
log "📋 ДЛЯ ДИАГНОСТИКИ:"
log "   • После перезагрузки зайдите как root (Ctrl+Alt+F2)"
log "   • Выполните: sudo -u $KIOSK_USER /home/$KIOSK_USER/diagnose.sh"
log "   • Проверьте логи: tail -f /home/$KIOSK_USER/kiosk-*.log"
log "   • Логи X: tail -f /home/$KIOSK_USER/xsession.log"
log "   • Systemd: journalctl -u kiosk.service -f"
log ""
log "🔧 ЕСЛИ НЕ РАБОТАЕТ:"
log "   • Попробуйте запустить вручную:"
log "     sudo -u $KIOSK_USER startx /home/$KIOSK_USER/.xinitrc"

if [ "$ENV_TYPE" = "virtualbox" ]; then
    log ""
    log "🔧 ДЛЯ VIRTUALBOX:"
    log "   • Убедитесь, что установлены Guest Additions"
    log "   • В настройках VM включите 3D-ускорение"
fi

if [ "$REBOOT_AFTER" = true ]; then
  log "🔄 Перезагрузка через 5 секунд..."
  sleep 5
  reboot
else
  log "⚠️  НУЖНА ПЕРЕЗАГРУЗКА!"
  log "Выполните: sudo reboot"
fi