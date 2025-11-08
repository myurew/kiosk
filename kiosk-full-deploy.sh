#!/bin/bash

# Kiosk Setup Script for Debian (Openbox + HTML Launcher)
# Version 1.2 - Fixed externally-managed-environment error

set -e  # Exit on any error

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}=== Starting Kiosk Setup ===${NC}"

# Check if running as root
if [ "$EUID" -ne 0 ]; then
    echo -e "${RED}Please run as root: sudo ./kiosk_setup.sh${NC}"
    exit 1
fi

# Configuration
KIOSK_USER="kiosk"
KIOSK_DIR="/home/$KIOSK_USER/kiosk"
HTML_LAUNCHER="$KIOSK_DIR/launcher.html"
PYTHON_SERVER="$KIOSK_DIR/kiosk_server.py"
OPENBOX_AUTOSTART="/home/$KIOSK_USER/.config/openbox/autostart"
LIGHTDM_CONF="/etc/lightdm/lightdm.conf"

# Function to print status
print_status() {
    echo -e "${GREEN}[INFO]${NC} $1"
}

print_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $1"
}

print_error() {
    echo -e "${RED}[ERROR]${NC} $1
}

# Update system
print_status "Updating package lists..."
apt update

# Install required packages
print_status "Installing required packages..."
apt install -y xorg openbox lightdm firefox-esr python3 python3-pip python3-venv python3-psutil feh

# Create kiosk user if not exists
if id "$KIOSK_USER" &>/dev/null; then
    print_status "User $KIOSK_USER already exists"
else
    print_status "Creating user $KIOSk_USER..."
    adduser --disabled-password --gecos "Kiosk User" $KIOSK_USER
fi

# Create kiosk directory
print_status "Creating kiosk directory..."
mkdir -p $KIOSK_DIR
chown $KIOSK_USER:$KIOSK_USER $KIOSK_DIR

# Create HTML launcher
print_status "Creating HTML launcher..."
cat > $HTML_LAUNCHER << 'EOF'
<!DOCTYPE html>
<html>
<head>
    <meta charset="UTF-8">
    <title>Kiosk Launcher</title>
    <style>
        * {
            margin: 0;
            padding: 0;
            box-sizing: border-box;
        }
        
        body {
            background: linear-gradient(135deg, #2c3e50, #34495e);
            color: white;
            font-family: 'Arial', sans-serif;
            height: 100vh;
            overflow: hidden;
        }
        
        .container {
            display: flex;
            flex-wrap: wrap;
            justify-content: center;
            align-items: center;
            height: 100vh;
            padding: 20px;
        }
        
        .icon {
            width: 160px;
            height: 160px;
            margin: 20px;
            cursor: pointer;
            background: rgba(255, 255, 255, 0.1);
            border-radius: 15px;
            display: flex;
            flex-direction: column;
            justify-content: center;
            align-items: center;
            transition: all 0.3s ease;
            backdrop-filter: blur(10px);
            border: 1px solid rgba(255, 255, 255, 0.2);
        }
        
        .icon:hover {
            background: rgba(255, 255, 255, 0.2);
            transform: translateY(-5px);
            box-shadow: 0 10px 20px rgba(0, 0, 0, 0.3);
        }
        
        .icon:active {
            transform: translateY(-2px);
        }
        
        .icon img {
            width: 64px;
            height: 64px;
            margin-bottom: 15px;
            filter: invert(1);
        }
        
        .icon-text {
            font-size: 16px;
            font-weight: bold;
            text-align: center;
            text-shadow: 1px 1px 2px rgba(0, 0, 0, 0.5);
        }
        
        .header {
            position: absolute;
            top: 20px;
            left: 0;
            width: 100%;
            text-align: center;
            font-size: 28px;
            font-weight: bold;
            text-shadow: 2px 2px 4px rgba(0, 0, 0, 0.5);
            color: #ecf0f1;
        }
        
        .control-panel {
            position: absolute;
            top: 20px;
            right: 20px;
            display: flex;
            gap: 10px;
        }
        
        .control-btn {
            padding: 10px 15px;
            background: rgba(231, 76, 60, 0.8);
            border: none;
            border-radius: 8px;
            color: white;
            cursor: pointer;
            font-size: 14px;
            transition: all 0.3s ease;
        }
        
        .control-btn:hover {
            background: rgba(231, 76, 60, 1);
            transform: scale(1.05);
        }
        
        .browser-controls {
            position: absolute;
            bottom: 20px;
            right: 20px;
            display: flex;
            gap: 10px;
        }
        
        .browser-btn {
            padding: 12px 20px;
            background: rgba(52, 152, 219, 0.8);
            border: none;
            border-radius: 8px;
            color: white;
            cursor: pointer;
            font-size: 14px;
            font-weight: bold;
            transition: all 0.3s ease;
        }
        
        .browser-btn:hover {
            background: rgba(52, 152, 219, 1);
            transform: scale(1.05);
        }
        
        .browser-btn.close {
            background: rgba(231, 76, 60, 0.8);
        }
        
        .browser-btn.close:hover {
            background: rgba(231, 76, 60, 1);
        }
        
        .status-indicator {
            position: absolute;
            bottom: 20px;
            left: 20px;
            padding: 8px 15px;
            background: rgba(46, 204, 113, 0.8);
            border-radius: 20px;
            font-size: 12px;
            display: none;
        }
    </style>
</head>
<body>
    <div class="header">Киоск-система</div>
    
    <div class="control-panel">
        <button class="control-btn" onclick="showLauncher()">Показать лаунчер</button>
    </div>
    
    <div class="browser-controls" id="browserControls" style="display: none;">
        <button class="browser-btn close" onclick="closeBrowser()">✕ Закрыть браузер</button>
        <button class="browser-btn" onclick="showLauncher()">← Вернуться</button>
    </div>
    
    <div class="status-indicator" id="statusIndicator"></div>
    
    <div class="container" id="launcher">
        <div class="icon" onclick="launchApp('firefox-esr')">
            <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0OCA0OCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTI0IDhDMTUuMTY0IDggOCAxNS4xNjQgOCAyNHM3LjE2NCAxNiAxNiAxNiAxNi03LjE2NCAxNi0xNlMzMi44MzYgOCAyNCA4em0wIDI4Yy02LjYzIDAtMTItNS4zNy0xMi0xMnM1LjM3LTEyIDEyLTEyIDEyIDUuMzcgMTIgMTItNS4zNyAxMi0xMiAxMnoiLz48cGF0aCBmaWxsPSIjZmZmIiBkPSJNMjQgMTBjLTIuODcgMC01LjQzIDEuNTUtNi44MyAzLjg0bDQuMjMgMi4zOWMuNTUtMS4xMiAxLjY1LTEuODcgMi45LTEuODdzMS45OC43NSAyLjU1IDEuODhsNC4yMy0yLjM5QzI5LjQzIDExLjU1IDI2Ljg3IDEwIDI0IDEwem0wIDI4Yy0yLjg3IDAtNS40My0xLjU1LTYuODMtMy44NGw0LjIzIDIuMzljLjU1IDEuMTIgMS42NSAxLjg3IDIuOSAxLjg3czEuOTgtLjc1IDIuNTUtMS44NGw0LjIzIDIuMzlDMjkuNDMgMzYuNDUgMjYuODcgMzggMjQgMzh6Ii8+PC9zdmc+" alt="Browser">
            <div class="icon-text">Браузер</div>
        </div>
        
        <div class="icon" onclick="launchApp('thunar')">
            <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0OCA0OCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTQwIDEySDIybC00LTRIOGMtMi4yMSAwLTQgMS43OS00IDR2MjRjMCAyLjIxIDEuNzkgNCA0IDRoMzJjMi4yMSAwIDQtMS43OSA0LTRWMTZjMC0yLjIxLTEuNzktNC00LTR6Ii8+PHBhdGggZmlsbD0iIzMzMyIgZD0iTTM4LjUgMTRIMTkuNjFjLS42OSAwLTEuMjMtLjU0LTEuMjMtMS4yMyAwLS4zMy4xMy0uNjUuMzUtLjg4TDkuMTQgMjkuMjdjLS40OC40OC0uNDggMS4yNiAwIDEuNzQuMjQuMjQuNTUuMzYuODcuMzYuMzIgMCAuNjMtLjEyLjg3LS4zNkwxOC4yMyAyMGgyMC4yN2MxLjM4IDAgMi41LTEuMTIgMi41LTIuNXYtMWMwLTEuMzgtMS4xMi0yLjUtMi41LTIuNXoiLz48L3N2Zz4=" alt="Files">
            <div class="icon-text">Файлы</div>
        </div>
        
        <div class="icon" onclick="launchApp('gnome-terminal')">
            <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0OCA0OCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTQwIDQySDhjLTIuMiAwLTQtMS44LTQtNFYxMGMwLTIuMiAxLjgtNCA0LTRoMzJjMi4yIDAgNCAxLjggNCA0djI4YzAgMi4yLTEuOCA0LTQgNHoiLz48cGF0aCBmaWxsPSIjMzMzIiBkPSJNMTIgMThoMjR2MThIMTJ6Ii8+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTE2IDI0bDQgNCA0LTRoM2wtNyA3LTctN3oiLz48L3N2Zz4=" alt="Terminal">
            <div class="icon-text">Терминал</div>
        </div>
        
        <div class="icon" onclick="launchApp('mousepad')">
            <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMj000MC9zdmciIHZpZXdCb3g9IjAgMCA0OCA0OCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTQwIDQySDhjLTIuMiAwLTQtMS44LTQtNFYxMGMwLTIuMiAxLjgtNCA0LTRoMzJjMi4yIDAgNCAxLjggNCA0djI4YzAgMi4yLTEuOCA0LTQgNHoiLz48cGF0aCBmaWxsPSIjMzMzIiBkPSJNMTIgMThoMjR2MThIMTJ6Ii8+PHRleHQgZmlsbD0iI2ZmZiIgeD0iMTYiIHk9IjMwIiBmb250LXNpemU9IjEyIj7Qv9C+0LvRjNC30L7QstCw0YLQtdC70Y88L3RleHQ+PC9zdmc+" alt="Text Editor">
            <div class="icon-text">Текстовый редактор</div>
        </div>
    </div>

    <script>
        let currentApp = null;
        
        function showStatus(message, isError = false) {
            const indicator = document.getElementById('statusIndicator');
            indicator.textContent = message;
            indicator.style.display = 'block';
            indicator.style.background = isError ? 'rgba(231, 76, 60, 0.8)' : 'rgba(46, 204, 113, 0.8)';
            
            setTimeout(() => {
                indicator.style.display = 'none';
            }, 3000);
        }
        
        function launchApp(command) {
            console.log('Launching:', command);
            currentApp = command;
            
            // Show loading feedback
            event.target.style.background = 'rgba(52, 152, 219, 0.5)';
            
            // Send launch command to server
            fetch('http://localhost:8080/launch?app=' + encodeURIComponent(command))
                .then(response => {
                    if (!response.ok) {
                        throw new Error('Network response was not ok');
                    }
                    return response.text();
                })
                .then(data => {
                    console.log('App launched successfully:', command);
                    showStatus('Приложение запущено: ' + getAppName(command));
                    
                    // Show browser controls if browser was launched
                    if (command === 'firefox-esr') {
                        document.getElementById('browserControls').style.display = 'flex';
                        document.getElementById('launcher').style.display = 'none';
                    }
                })
                .catch(error => {
                    console.error('Error launching app:', error);
                    showStatus('Ошибка запуска приложения', true);
                })
                .finally(() => {
                    // Reset button style after a delay
                    setTimeout(() => {
                        event.target.style.background = '';
                    }, 1000);
                });
        }
        
        function closeBrowser() {
            console.log('Closing browser...');
            
            fetch('http://localhost:8080/close?app=firefox-esr')
                .then(response => {
                    if (!response.ok) {
                        throw new Error('Network response was not ok');
                    }
                    return response.text();
                })
                .then(data => {
                    console.log('Browser closed successfully');
                    showStatus('Браузер закрыт');
                    showLauncher();
                })
                .catch(error => {
                    console.error('Error closing browser:', error);
                    showStatus('Ошибка закрытия браузера', true);
                });
        }
        
        function showLauncher() {
            document.getElementById('browserControls').style.display = 'none';
            document.getElementById('launcher').style.display = 'flex';
            currentApp = null;
        }
        
        function getAppName(command) {
            const appNames = {
                'firefox-esr': 'Браузер',
                'thunar': 'Файловый менеджер',
                'gnome-terminal': 'Терминал',
                'mousepad': 'Текстовый редактор'
            };
            return appNames[command] || command;
        }
        
        // Prevent right-click context menu
        document.addEventListener('contextmenu', function(e) {
            e.preventDefault();
            return false;
        });
        
        // Prevent keyboard shortcuts except allowed ones
        document.addEventListener('keydown', function(e) {
            // Allow only F11 for fullscreen and F5 for refresh
            if (![116, 122].includes(e.keyCode)) { // F5 and F11
                e.preventDefault();
                return false;
            }
        });
        
        // Auto-show launcher if no app is running
        setTimeout(() => {
            checkBrowserStatus();
        }, 1000);
        
        function checkBrowserStatus() {
            fetch('http://localhost:8080/status?app=firefox-esr')
                .then(response => response.text())
                .then(status => {
                    if (status === 'RUNNING') {
                        document.getElementById('browserControls').style.display = 'flex';
                        document.getElementById('launcher').style.display = 'none';
                    }
                })
                .catch(() => {
                    // Server not ready yet, try again
                    setTimeout(checkBrowserStatus, 1000);
                });
        }
    </script>
</body>
</html>
EOF

# Create Python server without external dependencies
print_status "Creating Python server..."
cat > $PYTHON_SERVER << 'EOF'
#!/usr/bin/env python3
from flask import Flask, request, send_file
import subprocess
import os
import logging

app = Flask(__name__)

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Allowed applications for security
ALLOWED_APPS = {
    'firefox-esr': 'firefox-esr',
    'thunar': 'thunar',
    'gnome-terminal': 'gnome-terminal',
    'mousepad': 'mousepad'
}

def is_process_running(process_name):
    """Check if a process is running using pgrep"""
    try:
        result = subprocess.run(['pgrep', '-f', process_name], 
                              capture_output=True, text=True)
        return result.returncode == 0
    except Exception as e:
        logging.error(f"Error checking process {process_name}: {str(e)}")
        return False

def kill_process(process_name):
    """Kill a process by name using pkill"""
    try:
        result = subprocess.run(['pkill', '-f', process_name], 
                              capture_output=True, text=True)
        if result.returncode == 0:
            logging.info(f"Successfully killed: {process_name}")
            return True
        else:
            logging.warning(f"Process not found: {process_name}")
            return False
    except Exception as e:
        logging.error(f"Error killing process {process_name}: {str(e)}")
        return False

@app.route('/')
def index():
    return send_file('/home/kiosk/kiosk/launcher.html')

@app.route('/launch')
def launch_app():
    app_name = request.args.get('app', '')
    
    # Security check - only allow predefined apps
    if app_name not in ALLOWED_APPS:
        logging.warning(f"Attempt to launch unauthorized app: {app_name}")
        return 'ERROR: Unauthorized application', 403
    
    command = ALLOWED_APPS[app_name]
    
    try:
        # Check if application is installed
        result = subprocess.run(['which', command], capture_output=True, text=True)
        if result.returncode != 0:
            logging.error(f"Application not found: {command}")
            return f'ERROR: Application {app_name} not installed', 404
        
        # Launch application in background
        subprocess.Popen([command], 
                        stdout=subprocess.DEVNULL, 
                        stderr=subprocess.DEVNULL,
                        preexec_fn=os.setpgrp)
        
        logging.info(f"Successfully launched: {command}")
        return 'OK'
        
    except Exception as e:
        logging.error(f"Error launching {command}: {str(e)}")
        return f'ERROR: {str(e)}', 500

@app.route('/close')
def close_app():
    app_name = request.args.get('app', '')
    
    if app_name not in ALLOWED_APPS:
        logging.warning(f"Attempt to close unauthorized app: {app_name}")
        return 'ERROR: Unauthorized application', 403
    
    command = ALLOWED_APPS[app_name]
    
    try:
        if kill_process(command):
            logging.info(f"Successfully closed: {command}")
            return 'OK'
        else:
            logging.warning(f"Process not found or couldn't be closed: {command}")
            return 'ERROR: Process not found', 404
            
    except Exception as e:
        logging.error(f"Error closing {command}: {str(e)}")
        return f'ERROR: {str(e)}', 500

@app.route('/status')
def app_status():
    app_name = request.args.get('app', '')
    
    if app_name not in ALLOWED_APPS:
        return 'ERROR: Unauthorized application', 403
    
    command = ALLOWED_APPS[app_name]
    
    if is_process_running(command):
        return 'RUNNING'
    else:
        return 'NOT_RUNNING'

@app.route('/health')
def health_check():
    return 'OK'

if __name__ == '__main__':
    logging.info("Starting Kiosk Server on http://0.0.0.0:8080")
    app.run(host='0.0.0.0', port=8080, debug=False)
EOF

# Set permissions for kiosk files
chown -R $KIOSK_USER:$KIOSK_USER $KIOSK_DIR
chmod +x $PYTHON_SERVER

# Install Flask using system package manager instead of pip
print_status "Installing Python dependencies via apt..."
apt install -y python3-flask

# Create Openbox autostart directory and file
print_status "Configuring Openbox autostart..."
mkdir -p /home/$KIOSK_USER/.config/openbox

cat > $OPENBOX_AUTOSTART << 'EOF'
#!/bin/bash
# Openbox autostart script for kiosk

# Set display
export DISPLAY=:0

# Wait for X to be ready
sleep 2

# Start the kiosk server
python3 /home/kiosk/kiosk/kiosk_server.py &

# Wait for server to start
sleep 3

# Launch Firefox in kiosk mode
firefox-esr --kiosk http://localhost:8080/ &

# Hide cursor (optional)
# unclutter -idle 1 &

# Prevent screen blanking
xset s off
xset -dpms
xset s noblank

# Keep this process running
wait
EOF

chown -R $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/.config
chmod +x $OPENBOX_AUTOSTART

# Configure LightDM for auto-login
print_status "Configuring LightDM for auto-login..."
if [ -f $LIGHTDM_CONF ]; then
    cp $LIGHTDM_CONF $LIGHTDM_CONF.backup
fi

cat > $LIGHTDM_CONF << 'EOF'
[Seat:*]
autologin-user=kiosk
autologin-user-timeout=0
user-session=openbox
session-cleanup-script=/usr/bin/pkill -u kiosk
EOF

# Install additional applications
print_status "Installing applications..."
apt install -y thunar mousepad gnome-terminal

# Set up permissions
print_status "Setting up permissions..."
usermod -aG audio $KIOSK_USER
usermod -aG video $KIOSK_USER

# Enable LightDM
print_status "Enabling LightDM..."
systemctl enable lightdm

print_status "Setup completed successfully!"
echo ""
echo -e "${GREEN}=== Kiosk Setup Summary ===${NC}"
echo "User: $KIOSK_USER"
echo "Kiosk directory: $KIOSK_DIR"
echo "HTML launcher: $HTML_LAUNCHER"
echo "Python server: $PYTHON_SERVER"
echo ""
echo -e "${YELLOW}Fixed Issues:${NC}"
echo "✅ Решена проблема externally-managed-environment"
echo "✅ Используются только пакеты из системного репозитория"
echo "✅ Установка через apt вместо pip"
echo ""
echo -e "${YELLOW}New Features:${NC}"
echo "✅ Кнопка 'Закрыть браузер' в правом нижнем углу"
echo "✅ Кнопка 'Вернуться' для показа лаунчера"
echo "✅ Панель управления в правом верхнем углу"
echo "✅ Индикаторы статуса приложений"
echo "✅ Автоматическое определение запущенного браузера"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Reboot the system: sudo reboot"
echo "2. The kiosk will start automatically"
echo "3. Use 'Close Browser' button to return to launcher"
echo ""
echo -e "${GREEN}Setup complete! Please reboot.${NC}"