#!/bin/bash

# Kiosk Setup Script for Debian (Openbox + HTML Launcher)
# Version 3.3 - Fixed browser fullscreen issue

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
    echo -e "${RED}[ERROR]${NC} $1"
}

# Update system
print_status "Updating package lists..."
apt update

# Install required packages
print_status "Installing required packages..."
apt install -y xorg openbox lightdm firefox-esr python3 python3-flask feh wmctrl

# Install audio and display management packages
print_status "Installing audio and display packages..."
apt install -y audacious pavucontrol arandr vlc

# Create kiosk user if not exists
if id "$KIOSK_USER" &>/dev/null; then
    print_status "User $KIOSK_USER already exists"
else
    print_status "Creating user $KIOSK_USER..."
    adduser --disabled-password --gecos "Kiosk User" $KIOSK_USER
fi

# Create kiosk directory
print_status "Creating kiosk directory..."
mkdir -p $KIOSK_DIR
chown $KIOSK_USER:$KIOSK_USER $KIOSK_DIR

# Skip problematic Firefox profile creation - we'll handle it differently
print_status "Setting up Firefox configuration..."

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
            width: 140px;
            height: 140px;
            margin: 15px;
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
            width: 48px;
            height: 48px;
            margin-bottom: 10px;
            filter: invert(1);
        }
        
        .icon-text {
            font-size: 14px;
            font-weight: bold;
            text-align: center;
            text-shadow: 1px 1px 2px rgba(0, 0, 0, 0.5);
            padding: 0 5px;
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
    
    <div class="status-indicator" id="statusIndicator"></div>
    
    <div class="container" id="launcher">
        <div class="icon" onclick="launchApp('firefox')">
            <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0OCA0OCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTI0IDhDMTUuMTY0IDggOCAxNS4xNjQgOCAyNHM3LjE2NCAxNiAxNiAxNiAxNi03LjE2NCAxNi0xNlMzMi44MzYgOCAyNCA4em0wIDI4Yy02LjYzIDAtMTItNS4zNy0xMi0xMnM1LjM3LTEyIDEyLTEyIDEyIDUuMzcgMTIgMTItNS4zNyAxMi0xMiAxMnoiLz48cGF0aCBmaWxsPSIjZmZmIiBkPSJNMjQgMTBjLTIuODcgMC01LjQzIDEuNTUtNi44MyAzLjg0bDQuMjMgMi4zOWMuNTUtMS4xMiAxLjY1LTEuODcgMi45LTEuODdzMS45OC43NSAyLjU1IDEuODhsNC4yMy0yLjM5QzI5LjQzIDExLjU1IDI2Ljg3IDEwIDI0IDEwem0wIDI4Yy0yLjg3IDAtNS40My0xLjU1LTYuODMtMy44NGw0LjIzIDIuMzljLjU1IDEuMTIgMS42NSAxLjg3IDIuOSAxLjg3czEuOTgtLjc1IDIuNTUtMS44NGw0LjIzIDIuMzlDMjkuNDMgMzYuNDUgMjYuODcgMzggMjQgMzh6Ii8+PC9zdmc+" alt="Browser">
            <div class="icon-text">Браузер</div>
        </div>
        
        <div class="icon" onclick="launchApp('audacious')">
            <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0OCA0OCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTI0IDZ2MzZMMTAgMzBWNmgyem0yMiAwaC0xNnYzNmwxNi0xMlY2eiIvPjxjaXJjbGUgZmlsbD0iI2ZmZiIgY3g9IjI0IiBjeT0iMjQiIHI9IjgiLz48L3N2Zz4=" alt="Music">
            <div class="icon-text">Музыка</div>
        </div>
        
        <div class="icon" onclick="launchApp('pavucontrol')">
            <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0OCA0OCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTM0IDZ2MzZINnYtMjRoOHYtMTJoMjB6bS0yIDJoLTE2djhoMTZ2LTh6bS04IDEwaC04djE0aDh2LTE0em0yIDJoNHYxMGgtNHYtMTB6bTggMGg0djEwaC00di0xMHoiLz48L3N2Zz4=" alt="Audio Control">
            <div class="icon-text">Звук</div>
        </div>
        
        <div class="icon" onclick="launchApp('arandr')">
            <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0OCA0OCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTggMTBoMzJ2MjhIOHptMiAyaDI4djI0SDEwdi0yNHptMTIgNGg0djE2aC00di0xNnptOCAwaDR2MTZoLTR2LTE2eiIvPjxyZWN0IGZpbGw9IiNmZmYiIHg9IjM4IiB5PSIxNCIgd2lkdGg9IjYiIGhlaWdodD0iOCIvPjxyZWN0IGZpbGw9IiNmZmYiIHg9IjM4IiB5PSIyNiIgd2lkdGg9IjYiIGhlaWdodD0iOCIvPjxyZWN0IGZpbGw9IiNmZmYiIHg9IjQiIHk9IjE0IiB3aWR0aD0iNiIgaGVpZ2h0PSI4Ii8+PHJlY3QgZmlsbD0iI2ZmZiIgeD0iNCIgeT0iMjYiIHdpZHRoPSI2IiBoZWlnaHQ9IjgiLz48L3N2Zz4=" alt="Display">
            <div class="icon-text">Экран</div>
        </div>
        
        <div class="icon" onclick="launchApp('vlc')">
            <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0OCA0OCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTM2IDh2MzJIMTJWOGgyNHptLTIgMkgxNHYyOGgyMFYxMHptLTggNGg0djIwaC00VjE0eiIvPjwvc3ZnPg==" alt="Video">
            <div class="icon-text">Видео</div>
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
            <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHZpZXdCb3g9IjAgMCA0OCA0OCI+PHBhdGggZmlsbD0iI2ZmZiIgZD0iTTQwIDQySDhjLTIuMiAwLTQtMS44LTQtNFYxMGMwLTIuMiAxLjgtNCA0LTRoMzJjMi4yIDAgNCAxLjggNCA0djI4YzAgMi4yLTEuOCA0LTQgNHoiLz48cGF0aCBmaWxsPSIjMzMzIiBkPSJNMTIgMThoMjR2MThIMTJ6Ii8+PHRleHQgZmlsbD0iI2ZmZiIgeD0iMTYiIHk9IjMwIiBmb250LXNpemU9IjEyIj7Qv9C+0LvRjNC30L7QstCw0YLQtdC70Y88L3RleHQ+PC9zdmc+" alt="Text Editor">
            <div class="icon-text">Текстовый редактор</div>
        </div>
    </div>

    <script>
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
        
        function getAppName(command) {
            const appNames = {
                'firefox': 'Браузер',
                'audacious': 'Музыка',
                'pavucontrol': 'Звук',
                'arandr': 'Экран',
                'vlc': 'Видео',
                'thunar': 'Файлы',
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
        
        // Prevent most keyboard shortcuts but allow F11 for fullscreen
        document.addEventListener('keydown', function(e) {
            if (e.keyCode !== 122) { // Allow only F11
                e.preventDefault();
                return false;
            }
        });
        
        // Auto-fullscreen for launcher
        document.addEventListener('DOMContentLoaded', function() {
            // Try to enter fullscreen
            if (document.documentElement.requestFullscreen) {
                document.documentElement.requestFullscreen();
            } else if (document.documentElement.webkitRequestFullscreen) {
                document.documentElement.webkitRequestFullscreen();
            } else if (document.documentElement.msRequestFullscreen) {
                document.documentElement.msRequestFullscreen();
            }
        });
    </script>
</body>
</html>
EOF

# Create Python server with completely separate browser process
print_status "Creating Python server..."
cat > $PYTHON_SERVER << 'EOF'
#!/usr/bin/env python3
from flask import Flask, request, send_file
import subprocess
import os
import logging
import time

app = Flask(__name__)

# Configure logging
logging.basicConfig(level=logging.INFO, format='%(asctime)s - %(levelname)s - %(message)s')

# Allowed applications for security
ALLOWED_APPS = {
    'firefox': 'firefox-esr',
    'audacious': 'audacious',
    'pavucontrol': 'pavucontrol',
    'arandr': 'arandr',
    'vlc': 'vlc',
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

def launch_browser_normal():
    """Launch browser in completely separate process with normal window"""
    try:
        # Use DISPLAY environment
        env = os.environ.copy()
        env['DISPLAY'] = ':0'
        
        # Launch Firefox with new window but NO kiosk mode
        process = subprocess.Popen([
            'firefox-esr',
            '-new-window',
            'about:blank'
        ], env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
           preexec_fn=os.setsid)  # New session group
        
        logging.info("Launched Firefox in separate session")
        return process
        
    except Exception as e:
        logging.error(f"Error launching browser: {str(e)}")
        return None

def ensure_normal_window():
    """Ensure browser window is not fullscreen - aggressive approach"""
    try:
        time.sleep(3)  # Wait for window to appear
        
        # Multiple attempts to fix the window
        for attempt in range(10):
            # Get all windows
            result = subprocess.run(['wmctrl', '-l'], capture_output=True, text=True)
            
            firefox_windows = []
            for line in result.stdout.split('\n'):
                if 'Firefox' in line or 'Mozilla Firefox' in line:
                    window_id = line.split()[0]
                    firefox_windows.append(window_id)
            
            if firefox_windows:
                for window_id in firefox_windows:
                    # Force remove fullscreen
                    subprocess.run(['wmctrl', '-i', '-r', window_id, '-b', 'remove,fullscreen'], 
                                 capture_output=True)
                    
                    # Remove maximized state
                    subprocess.run(['wmctrl', '-i', '-r', window_id, '-b', 'remove,maximized_vert,maximized_horz'], 
                                 capture_output=True)
                    
                    # Set specific size and position
                    subprocess.run(['wmctrl', '-i', '-r', window_id, '-e', '0,100,100,1000,600'], 
                                 capture_output=True)
                    
                    logging.info(f"Fixed Firefox window {window_id} to normal size")
                
                break  # Success
            else:
                time.sleep(0.5)  # Wait and try again
                
    except Exception as e:
        logging.error(f"Error ensuring normal window: {str(e)}")

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
        
        # Special handling for Firefox
        if command == 'firefox-esr':
            process = launch_browser_normal()
            if process:
                # Run window management in background
                import threading
                threading.Thread(target=ensure_normal_window).start()
            else:
                return 'ERROR: Failed to launch browser', 500
        else:
            # For other apps, launch normally
            process = subprocess.Popen([command], 
                                    stdout=subprocess.DEVNULL, 
                                    stderr=subprocess.DEVNULL,
                                    preexec_fn=os.setpgrp)
        
        logging.info(f"Successfully launched: {command}")
        return 'OK'
        
    except Exception as e:
        logging.error(f"Error launching {command}: {str(e)}")
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

# Launch Firefox in fullscreen kiosk mode for launcher
firefox-esr --kiosk http://localhost:8080 &

# Hide cursor
unclutter -idle 1 &

# Prevent screen blanking
xset s off
xset -dpms
xset s noblank

# Keep this process running
wait
EOF

chown -R $KIOSK_USER:$KIOSK_USER /home/$KIOSK_USER/.config
chmod +x $OPENBOX_AUTOSTART

# Install unclutter for hiding cursor
print_status "Installing additional tools..."
apt install -y unclutter

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
echo "✅ Убрана проблемная строка создания профиля Firefox"
echo "✅ Браузер запускается в отдельной сессии"
echo "✅ Агрессивное управление окнами (10 попыток)"
echo "✅ Установлен конкретный размер окна 1000x600"
echo ""
echo -e "${YELLOW}If browser still opens fullscreen, run:${NC}"
echo "sudo -u kiosk ./kiosk_control.sh fix-browser"
echo ""
echo -e "${YELLOW}Next steps:${NC}"
echo "1. Reboot the system: sudo reboot"
echo "2. System starts with fullscreen launcher"
echo "3. Click 'Browser' to open normal Firefox window"
echo ""
echo -e "${GREEN}Setup complete! Please reboot.${NC}"