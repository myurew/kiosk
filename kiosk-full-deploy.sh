#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - С АВТООПРЕДЕЛЕНИЕМ ПАКЕТОВ
# ==========================================

set -e
KIOSK_USER="kiosk"
KIOSK_URL="https://www.google.com"
CHROME_TYPE="chromium"  # Теперь по умолчанию chromium
REBOOT_AFTER=false
KEYBOARD_LAYOUT="us"

if [ "$EUID" -ne 0 ]; then echo "Запустите от root: sudo $0"; exit 1; fi

log() { echo -e "\033[0;32m[INFO]\033[0m $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $1"; exit 1; }

# Функция определения правильного имени пакета chromium
detect_chromium_package() {
  log "Поиск доступного пакета Chromium..."
  
  # Проверяем доступные варианты
  if apt-cache search --names-only "^chromium$" | grep -q "^chromium"; then
    echo "chromium"
    return 0
  elif apt-cache search --names-only "^chromium-browser$" | grep -q "^chromium-browser"; then
    echo "chromium-browser"
    return 0
  else
    # Возможно, нужен contrib репозиторий
    log "Пакет не найден. Проверка репозиториев..."
    if ! grep -q "contrib" /etc/apt/sources.list; then
      warn "Репозиторий 'contrib' не найден. Добавляю..."
      sed -i 's/main$/main contrib/' /etc/apt/sources.list
      apt update
    fi
    
    # Повторная проверка
    if apt-cache search --names-only "^chromium$" | grep -q "^chromium"; then
      echo "chromium"
      return 0
    fi
    
    return 1  # Пакет не найден
  fi
}

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
  case $1 in
    -u|--user) KIOSK_USER="$2"; shift 2 ;;
    -url|--url) KIOSK_URL="$2"; shift 2 ;;
    -t|--type) CHROME_TYPE="$2"; shift 2 ;;
    -r|--reboot) REBOOT_AFTER=true; shift ;;
    -k|--keyboard) KEYBOARD_LAYOUT="$2"; shift 2 ;;
    *) error "Неизвестный параметр: $1" ;;
  esac
done

log "Начало установки Chrome Kiosk для $KIOSK_USER..."

# === ЭТАП 1: Установка пакетов ===
log "Установка X11 и браузера..."
apt update && apt install -y --no-install-recommends \
  xorg xinit openbox dbus-x11 x11-xserver-utils xfonts-base \
  wget ca-certificates

# === УСТАНОВКА БРАУЗЕРА С АВТООПРЕДЕЛЕНИЕМ ===
if [ "$CHROME_TYPE" = "chrome" ]; then
  # Google Chrome (стабильный вариант)
  if ! command -v google-chrome-stable &> /dev/null; then
    log "Установка Google Chrome (рекомендуется)..."
    wget -qO /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
    dpkg -i /tmp/chrome.deb || apt-get install -f -y
    rm /tmp/chrome.deb
  fi
  BROWSER_CMD="google-chrome-stable"
  CONFIG_DIR="google-chrome"
  
elif [ "$CHROME_TYPE" = "chromium" ]; then
  # Chromium (автоопределение пакета)
  CHROMIUM_PKG=$(detect_chromium_package)
  
  if [ -n "$CHROMIUM_PKG" ]; then
    log "Установка $CHROMIUM_PKG..."
    apt install -y "$CHROMIUM_PKG"
  else
    # Альтернатива: snap
    warn "Пакет не найден в репозиториях. Пробую snap..."
    apt install -y snapd
    snap install chromium
    
    # Создаем symlink для удобства
    ln -sf /snap/bin/chromium /usr/local/bin/chromium-browser
  fi
  
  # Определяем команду запуска
  if command -v chromium &> /dev/null; then
    BROWSER_CMD="chromium"
    CONFIG_DIR="chromium"
  elif command -v chromium-browser &> /dev/null; then
    BROWSER_CMD="chromium-browser"
    CONFIG_DIR="chromium-browser"
  else
    error "Не удалось установить Chromium. Используйте --type chrome"
  fi
fi

# === ОСТАЛЬНАЯ ЧАСТЬ СКРИПТА (ИЗМЕНЕНА) ===

# Создание пользователя
if ! id "$KIOSK_USER" &>/dev/null; then
  useradd -m -s /bin/bash -G audio,video,cdrom "$KIOSK_USER"
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "Создан пользователь $KIOSK_USER"
fi

# Настройка автологина
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
Type=idle
TimeoutStartSec=0
EOF

# Создание скрипта киоска с логированием
KIOSK_SCRIPT="/home/$KIOSK_USER/kiosk.sh"
cat > "$KIOSK_SCRIPT" <<EOF
#!/bin/bash
exec > /home/$KIOSK_USER/kiosk.log 2>&1
set -x

# Ждем X сервер
while ! xdpyinfo &>/dev/null; do sleep 1; done

# Очистка сессий
rm -rf ~/.config/$CONFIG_DIR/Singleton*

# Запуск браузера
while true; do
  $BROWSER_CMD --no-first-run --kiosk --incognito "$KIOSK_URL"
  sleep 2
done
EOF
chmod +x "$KIOSK_SCRIPT"
chown $KIOSK_USER:$KIOSK_USER "$KIOSK_SCRIPT"

# Исправленный .xinitrc
cat > "/home/$KIOSK_USER/.xinitrc" <<EOF
#!/bin/bash
xset -dpms; xset s off; xset s noblank
openbox-session &
sleep 2
exec $KIOSK_SCRIPT
EOF
chmod +x "/home/$KIOSK_USER/.xinitrc"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/.xinitrc"

# Надежный автологин через .profile
PROFILE_FILE="/home/$KIOSK_USER/.profile"
if ! grep -q "CHROME_KIOSK" "$PROFILE_FILE"; then
  cat >> "$PROFILE_FILE" <<EOF

# CHROME_KIOSK - Автозапуск
if [ "\$(tty)" = "/dev/tty1" ]; then
  startx >> /home/$KIOSK_USER/xorg.log 2>&1
fi
EOF
  chown $KIOSK_USER:$KIOSK_USER "$PROFILE_FILE"
fi

# Systemd service как резерв
cat > /etc/systemd/system/kiosk.service <<EOF
[Unit]
Description=Chrome Kiosk
After=network.target

[Service]
User=$KIOSK_USER
PAMName=login
TTYPath=/dev/tty1
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

log "✅ Установка завершена!"
log "Браузер: $BROWSER_CMD"
log "Команда для запуска: $BROWSER_CMD"
log "Логи будут в /home/$KIOSK_USER/kiosk.log"

if [ "$REBOOT_AFTER" = true ]; then
  log "Перезагрузка..."
  sleep 3
  reboot
else
  log "Перезагрузитесь вручную: sudo reboot"
fi