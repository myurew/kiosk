#!/bin/bash

# ==========================================
# Debian Chrome Kiosk - ГОТОВАЯ РАБОЧАЯ ВЕРСИЯ
# ==========================================

# === ВСЕ ФУНКЦИИ В НАЧАЛЕ (обязательно!) ===
log() { echo -e "\033[0;32m[INFO]\033[0m $(date '+%H:%M:%S') $1"; }
warn() { echo -e "\033[0;33m[WARN]\033[0m $(date '+%H:%M:%S') $1"; }
error() { echo -e "\033[0;31m[ERROR]\033[0m $(date '+%H:%M:%S') $1"; exit 1; }
step() { echo -e "\n\033[0;34m▶\033[0m \033[0;34m$1\033[0m"; }

# === ПРОВЕРКИ ===
set -e
if [ "$EUID" -ne 0 ]; then error "Запустите от root: sudo $0"; fi

# === ПАРАМЕТРЫ ===
KIOSK_USER="kiosk"
KIOSK_URL="https://www.google.com"
REBOOT_AFTER=false

# === ПАРСИНГ АРГУМЕНТОВ ===
while [[ $# -gt 0 ]]; do
  case $1 in
    -u|--user) KIOSK_USER="$2"; shift 2 ;;
    -url|--url) KIOSK_URL="$2"; shift 2 ;;
    -r|--reboot) REBOOT_AFTER=true; shift ;;
    *) error "Неизвестный параметр: $1" ;;
  esac
done

# === ОСНОВНОЙ КОД (только после определений) ===
step "Установка Google Chrome Kiosk..."
log "Пользователь: $KIOSK_USER"

apt update && apt install -y --no-install-recommends \
  xorg xinit openbox wget google-chrome-stable

# Создание пользователя
if ! id "$KIOSK_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$KIOSK_USER"
  echo "$KIOSK_USER:kiosk123" | chpasswd
fi

# Скрипт киоска
cat > "/home/$KIOSK_USER/kiosk.sh" <<'EOF'
#!/bin/bash
LOGFILE="/home/$USER/kiosk.log"
exec > "$LOGFILE" 2>&1
while ! xdpyinfo &>/dev/null; do sleep 1; done
google-chrome-stable --kiosk "https://www.google.com" &
wait
EOF
chmod +x "/home/$KIOSK_USER/kiosk.sh"
chown $KIOSK_USER:$KIOSK_USER "/home/$KIOSK_USER/kiosk.sh"

# Systemd service
cat > "/etc/systemd/system/kiosk.service" <<EOF
[Service]
User=$KIOSK_USER
ExecStart=/usr/bin/xinit /home/$KIOSK_USER/kiosk.sh -- /usr/bin/Xorg :0
Restart=always
[Install]
WantedBy=default.target
EOF
systemctl enable kiosk.service

log "✅ Готово! Перезагрузитесь: sudo reboot"