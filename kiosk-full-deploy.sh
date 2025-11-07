#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - Zero to Ready Script
# Полная установка с нуля (без графической оболочки)
# ==========================================

set -e  # Остановка при любой ошибке

# --- Настройки (можно изменить) ---
KIOSK_USER="kiosk"
KIOSK_URL="https://www.google.com"
CHROME_TYPE="chrome"  # chrome или chromium
REBOOT_AFTER=false
KEYBOARD_LAYOUT="us"  # us, ru, de и т.д.
TIMEZONE="Europe/Moscow"
# ----------------------------------

# Цвета вывода
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# Функции логирования
log() { echo -e "${GREEN}[INFO]${NC} $(date '+%H:%M:%S') $1"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $(date '+%H:%M:%S') $1"; }
error() { echo -e "${RED}[ERROR]${NC} $(date '+%H:%M:%S') $1"; exit 1; }
step() { echo -e "\n${BLUE}▶${NC} ${BLUE}$1${NC}"; }

# Проверка прав root
if [ "$EUID" -ne 0 ]; then error "Запустите от root: sudo $0"; fi

# Парсинг аргументов
while [[ $# -gt 0 ]]; do
  case $1 in
    -u|--user) KIOSK_USER="$2"; shift 2 ;;
    -url|--url) KIOSK_URL="$2"; shift 2 ;;
    -t|--type) CHROME_TYPE="$2"; shift 2 ;;
    -r|--reboot) REBOOT_AFTER=true; shift ;;
    -k|--keyboard) KEYBOARD_LAYOUT="$2"; shift 2 ;;
    -tz|--timezone) TIMEZONE="$2"; shift 2 ;;
    -h|--help) 
      echo "Использование: $0 [опции]"
      echo "  -u, --user USER         Имя пользователя (по умолчанию: kiosk)"
      echo "  -url, --url URL         Стартовый URL (по умолчанию: https://www.google.com)"
      echo "  -t, --type TYPE         Тип браузера: chrome или chromium (по умолчанию: chrome)"
      echo "  -k, --keyboard LAYOUT   Раскладка клавиатуры (по умолчанию: us)"
      echo "  -tz, --timezone TZ      Часовой пояс (по умолчанию: Europe/Moscow)"
      echo "  -r, --reboot           Автоматическая перезагрузка"
      echo "  -h, --help             Показать справку"
      exit 0 ;;
    *) error "Неизвестный параметр: $1" ;;
  esac
done

# Проверка версии Debian
if ! grep -qi "debian" /etc/os-release; then
  warn "Этот скрипт оптимизирован для Debian. Продолжение через 5 секунд..."
  sleep 5
fi

echo "======================================"
log "Начало развертывания Chrome Kiosk"
log "Пользователь: $KIOSK_USER"
log "Браузер: $CHROME_TYPE"
log "URL: $KIOSK_URL"
log "Раскладка: $KEYBOARD_LAYOUT"
log "Часовой пояс: $TIMEZONE"
echo "======================================"

# === ЭТАП 1: Обновление и базовые пакеты ===
step "Этап 1: Обновление системы и установка базовых пакетов"
apt update && apt full-upgrade -y
apt install -y --no-install-recommends \
  xserver-xorg-core xserver-xorg-video-all xserver-xorg-input-all \
  xinit openbox dbus-x11 x11-xserver-utils xfonts-base \
  wget curl ca-certificates locales

# Настройка локали
sed -i "s/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/" /etc/locale.gen
locale-gen
update-locale LANG=en_US.UTF-8

# Настройка часового пояса
timedatectl set-timezone "$TIMEZONE"

# Отключение экранных заставителей в консоли
log "Отключение заставок консоли..."
sed -i 's/BLANK_TIME=.*/BLANK_TIME=0/' /etc/kbd/config 2>/dev/null || echo "BLANK_TIME=0" >> /etc/kbd/config
sed -i 's/POWERDOWN_TIME=.*/POWERDOWN_TIME=0/' /etc/kbd/config 2>/dev/null || echo "POWERDOWN_TIME=0" >> /etc/kbd/config

# === ЭТАП 2: Установка браузера ===
step "Этап 2: Установка браузера ($CHROME_TYPE)"

if [ "$CHROME_TYPE" = "chrome" ]; then
  if ! command -v google-chrome-stable &> /dev/null; then
    log "Установка Google Chrome..."
    wget --timeout=30 -q -O /tmp/chrome.deb "https://dl.google.com/linux/direct/google-chrome-stable_current_amd64.deb"
    dpkg -i /tmp/chrome.deb || apt-get install -f -y
    rm -f /tmp/chrome.deb
  else
    warn "Google Chrome уже установлен"
  fi
  BROWSER_CMD="google-chrome-stable"
elif [ "$CHROME_TYPE" = "chromium" ]; then
  log "Установка Chromium..."
  apt install -y chromium-browser
  BROWSER_CMD="chromium-browser"
else
  error "Неверный тип браузера. Используйте 'chrome' или 'chromium'"
fi

# === ЭТАП 3: Создание пользователя ===
step "Этап 3: Создание и настройка пользователя $KIOSK_USER"

if ! id "$KIOSK_USER" &>/dev/null; then
  log "Создание пользователя $KIOSK_USER..."
  useradd -m -s /bin/bash -G audio,video,cdrom "$KIOSK_USER"
  echo "$KIOSK_USER:kiosk123" | chpasswd
  log "✓ Пользователь создан (пароль: kiosk123)"
else
  warn "Пользователь $KIOSK_USER уже существует"
fi

# Ограничение прав пользователя (опционально, но рекомендуется)
log "Настройка ограничений пользователя..."
usermod -L "$KIOSK_USER"  # Блокировка смены пароля

# === ЭТАП 4: Настройка автологина ===
step "Этап 4: Настройка автологина в консоли"

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/autologin.conf <<EOF
[Service]
ExecStart=
ExecStart=-/sbin/agetty --autologin $KIOSK_USER --noclear %I \$TERM
Type=idle
EOF

# === ЭТАП 5: Создание скрипта киоска ===
step "Этап 5: Создание скрипта автозапуска Chrome"

KIOSK_SCRIPT="/home/$KIOSK_USER/chrome-kiosk.sh"
cat > "$KIOSK_SCRIPT" <<EOF
#!/bin/bash

# Настройка клавиатуры
setxkbmap "$KEYBOARD_LAYOUT"

# Очистка старых сессий Chrome
rm -rf ~/.config/$CHROME_TYPE/Singleton*

# Запуск Chrome в бесконечном цикле
while true; do
  $BROWSER_CMD \\
    --no-first-run \\
    --disable \\
    --disable-translate \\
    --disable-infobars \\
    --disable-suggestions-service \\
    --disable-save-password-bubble \\
    --disable-session-crashed-bubble \\
    --disable-features=TranslateUI \\
    --disable-background-networking \\
    --disable-sync \\
    --disable-default-apps \\
    --no-default-browser-check \\
    --disable-web-security \\
    --incognito \\
    --kiosk \\
    --start-maximized \\
    "$KIOSK_URL"
    
  # Перезапуск через 1 секунду
  sleep 1
done
EOF

chown "$KIOSK_USER:$KIOSK_USER" "$KIOSK_SCRIPT"
chmod +x "$KIOSK_SCRIPT"

# === ЭТАП 6: Настройка X-сессии ===
step "Этап 6: Настройка автозапуска графики"

# .xinitrc для автозапуска
cat > "/home/$KIOSK_USER/.xinitrc" <<EOF
#!/bin/bash

# Отключение энергосбережения дисплея
xset -dpms
xset s off
xset s noblank

# Установка разрешения экрана (автоматически)
xrandr --auto

# Запуск Openbox (минимальный оконный менеджер)
exec openbox-session &

# Запуск Chrome
exec $KIOSK_SCRIPT
EOF

chown "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.xinitrc"
chmod +x "/home/$KIOSK_USER/.xinitrc"

# .bashrc для запуска X при логине
BASHRC_FILE="/home/$KIOSK_USER/.bashrc"
if ! grep -q "CHROME_KIOSK_STARTX" "$BASHRC_FILE"; then
  cat >> "$BASHRC_FILE" <<EOF

# CHROME_KIOSK_STARTX - АвтозапускChrome Kiosk
if [ "\$(tty)" = "/dev/tty1" ]; then
  exec startx
fi
EOF
  chown "$KIOSK_USER:$KIOSK_USER" "$BASHRC_FILE"
fi

# === ЭТАП 7: Настройка Openbox ===
step "Этап 7: Настройка Openbox"

mkdir -p "/home/$KIOSK_USER/.config/openbox"
cat > "/home/$KIOSK_USER/.config/openbox/autostart" <<EOF
# Отключение всех горячих клавиш
xmodmap -e "keycode 37 = "  # Ctrl
xmodmap -e "keycode 64 = "  # Alt
EOF

chown -R "$KIOSK_USER:$KIOSK_USER" "/home/$KIOSK_USER/.config"

# === ЭТАП 8: Финальная настройка ===
step "Этап 8: Применение финальных настроек"

# Отключение сообщений системы в консоли
sed -i 's/#KernelPrintLast/Kern elPrintLast/' /etc/sysctl.conf 2>/dev/null || true
echo "kernel.printk = 3 3 3 3" >> /etc/sysctl.conf

# Перезагрузка systemd
systemctl daemon-reload

# Очистка кэша пакетов
apt clean
rm -rf /tmp/*

# === ЗАВЕРШЕНИЕ ===
echo "======================================"
log "✅ Развертывание успешно завершено!"
echo "======================================"
log "Пользователь: $KIOSK_USER (пароль: kiosk123)"
log "Браузер: $CHROME_TYPE"
log "URL: $KIOSK_URL"
log "Раскладка: $KEYBOARD_LAYOUT"
echo "======================================"

if [ "$REBOOT_AFTER" = true ]; then
  log "Перезагрузка через 10 секунд... (Нажмите Ctrl+C для отмены)"
  sleep 10
  reboot
else
  warn "⚠️  НЕОБХОДИМА ПЕРЕЗАГРУЗКА!"
  log "Выполните: sudo reboot"
  log "После перезагрузки Chrome запустится автоматически"
fi