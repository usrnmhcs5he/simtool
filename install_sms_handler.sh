#!/bin/bash
# install_sms_handler.sh - installer for the SMS handler on a Raspberry Pi
#
# Version history (taken from the repository history)
#   35 - 2025-08-07 - First published version.
#   36 - 2025-08-07 - Published as a separate file, identical to 35.
#   39 - 2025-09-30 - Email (SMTP) forwarding and the auto-forward toggles
#                     removed; every received SMS is forwarded to the Discord
#                     webhook; no restriction on sender numbers by default.
#                     File renamed from 39.sh to install_sms_handler.sh on
#                     2026-11-22 (no functional change).
#
# Exit on error
set -e
# Update system
sudo apt update && sudo apt upgrade -y
# Install dependencies (system-wide, no change)
sudo apt install -y python3 python3-venv python3-pip python3-serial git curl
# Create permanent bag dir if not exists
BAG_DIR="/home/pi/bag"
mkdir -p $BAG_DIR
cd $BAG_DIR
# Create/reuse venv in bag
if [ ! -d "venv" ]; then
  python3 -m venv venv
fi
source venv/bin/activate
# Install Python libs (idempotent, skips if already installed)
pip install --upgrade flask pyserial requests flask-socketio gevent gevent-websocket
# Create project dir
PROJECT_DIR="/home/pi/sms_handler"
mkdir -p $PROJECT_DIR
cd $PROJECT_DIR
# Download Socket.IO to static folder
mkdir -p static
curl -o static/socket.io.js https://cdnjs.cloudflare.com/ajax/libs/socket.io/4.5.4/socket.io.js
# Read webhook from bag/webhook.txt
WEBHOOK=$(cat $BAG_DIR/webhook.txt)
# Create config.json (edit this later)
cat << EOF > config.json
{
  "serial_port": "/dev/ttyUSB1",
  "serial_baud": 115200,
  "poll_interval": 5,
  "forward_rules": [
    {
      "from_numbers": [],
      "webhook": "$WEBHOOK"
    }
  ]
}
EOF
# Create database schema script (use bag/sms.db)
cat << 'EOF' > init_db.py
import sqlite3
conn = sqlite3.connect('/home/pi/bag/sms.db')
c = conn.cursor()
c.execute('''
CREATE TABLE IF NOT EXISTS sms (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    sender TEXT,
    timestamp TEXT,
    content TEXT,
    status TEXT DEFAULT 'new'
)
''')
c.execute('''
CREATE TABLE IF NOT EXISTS logs (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    timestamp DATETIME DEFAULT CURRENT_TIMESTAMP,
    message TEXT
)
''')
c.execute('''
CREATE TABLE IF NOT EXISTS pull_status (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    last_pull REAL,
    status TEXT
)
''')
c.execute('''
CREATE TABLE IF NOT EXISTS at_status (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    last_check REAL,
    status TEXT
)
''')
c.execute('INSERT OR REPLACE INTO pull_status (id, last_pull, status) VALUES (1, 0, "Unknown")')
c.execute('INSERT OR REPLACE INTO at_status (id, last_check, status) VALUES (1, 0, "Unknown")')
conn.commit()
conn.close()
EOF
$BAG_DIR/venv/bin/python init_db.py
# Insert demo SMS (use bag/sms.db)
cat << 'EOF' > insert_demo.py
import sqlite3
conn = sqlite3.connect('/home/pi/bag/sms.db')
c = conn.cursor()
c.execute('INSERT INTO sms (sender, timestamp, content) VALUES (?, ?, ?)', ('+1234567890', '2023-01-01 12:00:00', 'test content for forwarding'))
conn.commit()
conn.close()
EOF
$BAG_DIR/venv/bin/python insert_demo.py
# Web interface script (version 38 with always-on Discord auto-forward, no email/toggles)
cat << 'EOF' > web_interface.py
from flask import Flask, render_template, request, redirect, send_file
from flask_socketio import SocketIO
import sqlite3
import json
import requests
import time
import threading
import serial
import re
import csv
import os
app = Flask(__name__)
socketio = SocketIO(app)
with open('config.json') as f:
    config = json.load(f)
ser = None
try:
    ser = serial.Serial(config['serial_port'], config['serial_baud'], timeout=1)
except Exception as e:
    print(f"Failed to open serial port: {e}")
def send_at(cmd):
    if ser is None or not ser.is_open:
        return "ERROR: Serial port not open"
    try:
        ser.write((cmd + '\r\n').encode())
        time.sleep(0.5)
        response = ser.read(ser.in_waiting).decode(errors='ignore').strip()
        return response if response else "ERROR: No response"
    except Exception as e:
        return f"ERROR: {str(e)}"
def parse_sms(response):
    # Flexible regex to handle Huawei E3372 AT+CMGR output
    match = re.search(r'\+CMGR:\s*"(.+?)",\s*"(.+?)",,\s*"(.+?)"\s*(.+?)(?:\r\nOK|$)', response, re.DOTALL | re.IGNORECASE)
    if not match:
        log_action(f'Parse error: Regex did not match response: {response}')
        return None, None, None
    status, sender_hex, timestamp, content_hex = match.groups()
    sender_hex = sender_hex.strip().replace('\r\n', '')
    content_hex = content_hex.strip().replace('\r\n', '')
    # Decode UCS2 hex if present
    if re.match(r'^[0-9A-Fa-f]{4,}$', sender_hex):
        try:
            sender = ''.join(chr(int(sender_hex[i:i+4], 16)) for i in range(0, len(sender_hex), 4))
        except ValueError as e:
            log_action(f'Parse error: Failed to decode sender {sender_hex}: {str(e)}')
            sender = sender_hex
    else:
        sender = sender_hex
    if re.match(r'^[0-9A-Fa-f]{4,}$', content_hex):
        try:
            content = ''.join(chr(int(content_hex[i:i+4], 16)) for i in range(0, len(content_hex), 4))
        except ValueError as e:
            log_action(f'Parse error: Failed to decode content {content_hex}: {str(e)}')
            content = content_hex
    else:
        content = content_hex
    return sender, timestamp, content
def forward_to_discord(sender, timestamp, content, sms_id, rule):
    try:
        response = requests.post(rule['webhook'], json={
            'content': f'SMS ID: {sms_id} from {sender} at {timestamp}: {content}'
        })
        if response.status_code == 200 or response.status_code == 204:
            return True
        else:
            print(f'Webhook failed with status: {response.status_code}')
            return False
    except Exception as e:
        print(f'Webhook error: {e}')
        return False
def log_action(message):
    conn = sqlite3.connect('/home/pi/bag/sms.db')
    c = conn.cursor()
    c.execute('INSERT INTO logs (message) VALUES (?)', (message,))
    conn.commit()
    conn.close()
    socketio.emit('new_log', {'message': message})
def update_status(last_pull, status):
    conn = sqlite3.connect('/home/pi/bag/sms.db')
    c = conn.cursor()
    c.execute('INSERT OR REPLACE INTO pull_status (id, last_pull, status) VALUES (1, ?, ?)', (last_pull, status))
    conn.commit()
    conn.close()
    socketio.emit('status_update', {'last_pull': last_pull, 'status': status})
def update_at_status(last_check, status):
    conn = sqlite3.connect('/home/pi/bag/sms.db')
    c = conn.cursor()
    c.execute('INSERT OR REPLACE INTO at_status (id, last_check, status) VALUES (1, ?, ?)', (last_check, status))
    conn.commit()
    conn.close()
    socketio.emit('at_status_update', {'last_check': last_check, 'status': status})
def listener_loop():
    while True:
        start_time = time.time()
        try:
            at_resp = send_at('AT')
            if 'OK' in at_resp:
                update_at_status(time.time(), 'OK')
            else:
                update_at_status(time.time(), f'FAIL: {at_resp}')
                log_action(f'AT command failed: {at_resp}')
                status = f"FAIL: {at_resp}"
                log_action(f'Pull {status}')
                update_status(start_time, status)
                time.sleep(config['poll_interval'])
                continue
            pin_resp = send_at('AT+CPIN?')
            if 'SIM PIN' in pin_resp:
                log_action('SIM PIN required - enter via web')
                status = "SKIP: PIN required"
                log_action(f'Pull {status}')
                update_status(start_time, status)
                time.sleep(config['poll_interval'])
                continue
            elif 'NOT INSERTED' in pin_resp:
                log_action('No SIM card detected')
                status = "FAIL: No SIM card"
                log_action(f'Pull {status}')
                update_status(start_time, status)
                time.sleep(config['poll_interval'])
                continue
            elif 'READY' not in pin_resp:
                log_action(f'Unexpected CPIN response: {pin_resp}')
                status = f"FAIL: Unexpected CPIN: {pin_resp}"
                log_action(f'Pull {status}')
                update_status(start_time, status)
                time.sleep(config['poll_interval'])
                continue
            # Ensure SIM storage and notifications
            send_at('AT+CMGF=1')
            send_at('AT+CPMS="SM","SM","SM"')
            send_at('AT+CNMI=2,1,0,0,0')
            response = send_at('AT+CMGL="ALL"')
            if 'OK' not in response:
                log_action(f'Failed to list SMS: {response}')
                status = f"FAIL: {response}"
                log_action(f'Pull {status}')
                update_status(start_time, status)
                time.sleep(config['poll_interval'])
                continue
            log_action(f'Raw AT+CMGL response: {response}')
            indexes = re.findall(r'\+CMGL: (\d+),', response)
            if not indexes:
                log_action('No new SMS found')
                status = "OK"
                log_action(f'Pull {status}')
                update_status(start_time, status)
                time.sleep(config['poll_interval'])
                continue
            for idx in indexes:
                msg_resp = send_at(f'AT+CMGR={idx}')
                log_action(f'Raw AT+CMGR response for index {idx}: {msg_resp}')
                sender, ts, content = parse_sms(msg_resp)
                if sender:
                    conn = sqlite3.connect('/home/pi/bag/sms.db')
                    c = conn.cursor()
                    c.execute('INSERT INTO sms (sender, timestamp, content) VALUES (?, ?, ?)', (sender, ts, content))
                    new_id = c.lastrowid
                    conn.commit()
                    conn.close()
                    log_action(f'SMS received from {sender}: {content}')
                    socketio.emit('new_sms', {'id': new_id, 'sender': sender, 'timestamp': ts, 'content': content})
                    for rule in config['forward_rules']:
                        if 'from_numbers' not in rule or not rule['from_numbers'] or sender in rule['from_numbers']:
                            if 'webhook' in rule:
                                forward_to_discord(sender, ts, content, new_id, rule)
                else:
                    log_action(f'Failed to parse SMS at index {idx}')
                send_at(f'AT+CMGD={idx}')
            status = "OK"
        except Exception as e:
            update_at_status(time.time(), f'FAIL: {str(e)}')
            log_action(f'Error: {str(e)}')
            status = f'FAIL: {str(e)}'
        log_action(f'Pull {status}')
        update_status(start_time, status)
        time.sleep(config['poll_interval'])
@app.route('/')
def index():
    page = request.args.get('page', 1, type=int)
    sender_filter = request.args.get('sender', '')
    date_from = request.args.get('date_from', '')
    date_to = request.args.get('date_to', '')
    per_page = 10
    offset = (page - 1) * per_page
    conn = sqlite3.connect('/home/pi/bag/sms.db')
    c = conn.cursor()
    query = 'SELECT * FROM sms WHERE 1=1'
    params = []
    if sender_filter:
        query += ' AND sender LIKE ?'
        params.append(f'%{sender_filter}%')
    if date_from:
        query += ' AND timestamp >= ?'
        params.append(date_from)
    if date_to:
        query += ' AND timestamp <= ?'
        params.append(date_to)
    query += ' ORDER BY id DESC LIMIT ? OFFSET ?'
    params.extend([per_page, offset])
    c.execute(query, params)
    sms_list = c.fetchall()
    c.execute('SELECT COUNT(*) FROM sms WHERE 1=1' + (' AND sender LIKE ?' if sender_filter else '') + (' AND timestamp >= ?' if date_from else '') + (' AND timestamp <= ?' if date_to else ''), [f'%{sender_filter}%'] if sender_filter else [] + [date_from] if date_from else [] + [date_to] if date_to else [])
    total = c.fetchone()[0]
    pages = (total // per_page) + (1 if total % per_page else 0)
    c.execute('SELECT timestamp, message FROM logs ORDER BY id DESC LIMIT 20')
    logs = c.fetchall()
    c.execute('SELECT last_pull, status FROM pull_status WHERE id = 1')
    status = c.fetchone() or (0, "Unknown")
    c.execute('SELECT last_check, status FROM at_status WHERE id = 1')
    at_status = c.fetchone() or (0, "Unknown")
    conn.close()
    return render_template('index.html', sms_list=sms_list, logs=logs, poll_interval=config['poll_interval'],
                           last_pull=status[0], pull_status=status[1], current_time=time.time(),
                           page=page, pages=pages, sender_filter=sender_filter, date_from=date_from, date_to=date_to,
                           at_last_check=at_status[0], at_status=at_status[1])
@app.route('/delete/<int:sms_id>')
def delete(sms_id):
    conn = sqlite3.connect('/home/pi/bag/sms.db')
    c = conn.cursor()
    c.execute('DELETE FROM sms WHERE id = ?', (sms_id,))
    conn.commit()
    conn.close()
    log_action(f'Deleted SMS ID {sms_id}')
    socketio.emit('delete_sms', {'id': sms_id})
    return redirect('/')
@app.route('/forward_discord/<int:sms_id>', methods=['POST'])
def forward_discord(sms_id):
    conn = sqlite3.connect('/home/pi/bag/sms.db')
    c = conn.cursor()
    c.execute('SELECT sender, timestamp, content FROM sms WHERE id = ?', (sms_id,))
    result = c.fetchone()
    conn.close()
    if result:
        sender, timestamp, content = result
        forwarded = False
        for rule in config['forward_rules']:
            if ('from_numbers' not in rule or not rule['from_numbers'] or sender in rule['from_numbers']) and 'webhook' in rule:
                if forward_to_discord(sender, timestamp, content, sms_id, rule):
                    forwarded = True
        if forwarded:
            log_action(f'Forwarded SMS ID {sms_id} to discord')
            print(f'Forwarded SMS {sms_id} to discord')
    return redirect('/')
@app.route('/export_csv')
def export_csv():
    conn = sqlite3.connect('/home/pi/bag/sms.db')
    c = conn.cursor()
    c.execute('SELECT id, sender, timestamp, content, status FROM sms ORDER BY id DESC')
    sms_list = c.fetchall()
    conn.close()
    csv_file = '/home/pi/sms_handler/sms_export.csv'
    with open(csv_file, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['ID', 'Sender', 'Timestamp', 'Content', 'Status'])
        for sms in sms_list:
            writer.writerow(sms)
   
    log_action('Exported SMS to sms_export.csv')
    return send_file(csv_file, as_attachment=True)
@app.route('/inject_test', methods=['POST'])
def inject_test():
    response = send_at('AT+CMGF=1')
    if 'OK' in response:
        response = send_at('AT+CMGW="SIM Write Test"')
        if '+CMGW: ' in response:
            log_action('Test SMS written to SIM card')
        else:
            log_action(f'Failed to write test SMS: {response}')
    else:
        log_action(f'Failed to set text mode for test SMS: {response}')
    return redirect('/')
@app.route('/send', methods=['POST'])
def send():
    to_number = request.form['to']
    message = request.form['message']
    ser_temp = serial.Serial(config['serial_port'], config['serial_baud'], timeout=1)
    def send_at_temp(cmd):
        ser_temp.write((cmd + '\r\n').encode())
        time.sleep(0.5)
        response = ser_temp.read(ser.in_waiting).decode(errors='ignore')
        return response
    try:
        send_at_temp('AT+CMGF=1')
        send_at_temp(f'AT+CMGS="{to_number}"')
        ser_temp.write((message + chr(26)).encode()) # Ctrl+Z
        time.sleep(2)
        response = ser_temp.read(ser_temp.in_waiting).decode()
        if 'OK' in response:
            log_action(f'Sent SMS to {to_number}')
        else:
            log_action(f'Failed to send SMS to {to_number}: {response}')
    except Exception as e:
        log_action(f'Send error: {str(e)}')
    finally:
        ser_temp.close()
    return redirect('/')
@app.route('/set_pin', methods=['POST'])
def set_pin():
    pin = request.form['pin']
    ser_temp = serial.Serial(config['serial_port'], config['serial_baud'], timeout=1)
    def send_at_temp(cmd):
        ser_temp.write((cmd + '\r\n').encode())
        time.sleep(0.5)
        response = ser_temp.read(ser.in_waiting).decode(errors='ignore')
        return response
    try:
        response = send_at_temp(f'AT+CPIN="{pin}"')
        if 'OK' in response:
            log_action(f'PIN set successfully')
        else:
            log_action(f'PIN set failed: {response}')
    except Exception as e:
        log_action(f'PIN error: {str(e)}')
    finally:
        ser_temp.close()
    return redirect('/')
@socketio.on('connect')
def handle_connect():
    print('Client connected')
if __name__ == '__main__':
    threading.Thread(target=listener_loop, daemon=True).start()
    socketio.run(app, host='0.0.0.0', port=5000)
EOF
# templates/index.html (update to Version 38)
mkdir -p templates
cat << 'EOF' > templates/index.html
<!DOCTYPE html>
<html>
<head>
<title>SMS Manager</title>
<style>
body { display: flex; }
.left { width: 70%; }
.right { width: 30%; padding-left: 20px; }
.log { border: 1px solid #ccc; padding: 10px; max-height: 400px; overflow-y: scroll; }
.green { color: green; }
.red { color: red; }
.gray { color: gray; }
</style>
<script src="https://cdnjs.cloudflare.com/ajax/libs/socket.io/4.5.4/socket.io.js"></script>
<meta http-equiv="refresh" content="30">
</head>
<body>
<div class="left">
<h1>SMS List</h1>
<p id="status">Last pull status: {{ pull_status }} | Next pull in: <span id="countdown">Calculating...</span></p>
<p id="at_status">AT Status: {{ at_status }}</p>
<form method="get">
  <label>Sender:</label> <input type="text" name="sender" value="{{ sender_filter }}">
  <label>From Date:</label> <input type="date" name="date_from" value="{{ date_from }}">
  <label>To Date:</label> <input type="date" name="date_to" value="{{ date_to }}">
  <button type="submit">Filter</button>
</form>
<table border="1">
<tr><th>ID</th><th>Sender</th><th>Time</th><th>Content</th><th>Actions</th></tr>
{% for sms in sms_list %}
<tr id="sms-{{ sms[0] }}">
<td>{{ sms[0] }}</td>
<td>{{ sms[1] }}</td>
<td>{{ sms[2] }}</td>
<td>{{ sms[3] }}</td>
<td><a href="/delete/{{ sms[0] }}">Delete</a> | <form action="/forward_discord/{{ sms[0] }}" method="post" style="display:inline;"><button>Discord</button></form></td>
</tr>
{% endfor %}
</table>
<div>
{% for p in range(1, pages + 1) %}
<a href="?page={{ p }}{% if sender_filter %}&sender={{ sender_filter }}{% endif %}{% if date_from %}&date_from={{ date_from }}{% endif %}{% if date_to %}&date_to={{ date_to }}{% endif %}">{{ p }}</a>
{% endfor %}
</div>
<h2>Send SMS</h2>
<form action="/send" method="post">
  <label>To:</label> <input type="text" name="to" required>
  <label>Message:</label> <textarea name="message" required></textarea>
  <button type="submit">Send</button>
</form>
<h2>Set SIM PIN (if required)</h2>
<form action="/set_pin" method="post">
  <label>PIN:</label> <input type="password" name="pin" required>
  <button type="submit">Submit PIN</button>
</form>
<h2>Inject Test SMS to SIM</h2>
<form action="/inject_test" method="post">
  <button type="submit">Inject Test SMS</button>
</form>
<h2>Export SMS</h2>
<form action="/export_csv" method="get">
  <button type="submit">Export to CSV</button>
</form>
</div>
<div class="right">
<h2>Recent Logs</h2>
<div class="log" id="logs">
{% for log in logs %}
<p>{{ log[0] }}: {{ log[1] }}</p>
{% endfor %}
</div>
<p>Version: 39</p>
</div>
<script>
const socket = io();
socket.on('new_sms', data => {
  const table = document.querySelector('table');
  const row = document.createElement('tr');
  row.id = `sms-${data.id}`;
  row.innerHTML = `<td>${data.id}</td><td>${data.sender}</td><td>${data.timestamp}</td><td>${data.content}</td><td><a href="/delete/${data.id}">Delete</a> | <form action="/forward_discord/${data.id}" method="post" style="display:inline;"><button>Discord</button></form></td>`;
  table.insertBefore(row, table.rows[1]);
});
socket.on('delete_sms', data => {
  const row = document.getElementById(`sms-${data.id}`);
  if (row) row.remove();
});
socket.on('new_log', data => {
  const logsDiv = document.getElementById('logs');
  const p = document.createElement('p');
  p.textContent = new Date().toISOString() + ': ' + data.message;
  logsDiv.prepend(p);
});
socket.on('status_update', data => {
  document.getElementById('status').innerHTML = `Last pull status: ${data.status} | Next pull in: <span id="countdown">Calculating...</span>`;
  lastPull = data.last_pull;
  updateCountdown();
});
socket.on('at_status_update', data => {
  document.getElementById('at_status').innerHTML = `AT Status: {data.status}`;
});
// Countdown logic
const pollInterval = {{ poll_interval }};
let lastPull = {{ last_pull }};
const currentTime = {{ current_time }};
let timeSinceLast = currentTime - lastPull;
let remaining = Math.floor(pollInterval - (timeSinceLast % pollInterval));
if (timeSinceLast > pollInterval + 5) remaining = 'Overdue!';
const countdownEl = document.getElementById('countdown');
function updateCountdown() {
  if (typeof remaining === 'number' && remaining > 0) {
    countdownEl.textContent = remaining + 's';
    remaining--;
    setTimeout(updateCountdown, 1000);
  } else {
    countdownEl.textContent = remaining || 'Now';
  }
}
updateCountdown();
// Partial refresh every 30s (for fallback)
setInterval(() => location.reload(), 30000);
</script>
</body>
</html>
EOF
# Set up systemd service for web_interface (run as root)
cat << 'EOF' | sudo tee /etc/systemd/system/sms_handler.service
[Unit]
Description=SMS Handler Service
After=multi-user.target
[Service]
User=root
WorkingDirectory=/home/pi/sms_handler
ExecStart=/home/pi/bag/venv/bin/python /home/pi/sms_handler/web_interface.py
Restart=always
[Install]
WantedBy=multi-user.target
EOF
sudo systemctl daemon-reload
sudo systemctl enable sms_handler
# Instructions
echo "Note: If using Huawei E3372 modem, you may need to edit /etc/usb_modeswitch.conf and set HuaweiAltModeGlobal=1 to ensure modem mode persists on boot."
echo "Version 39 setup complete. Venv and sms.db in /home/pi/bag persist. Edit config.json with correct serial port (e.g., /dev/ttyUSB1 for Huawei E3372) after testing with minicom."
echo "Access at http://<rpi-ip>:5000 (or check service: sudo systemctl status sms_handler)"
echo "To start the program (automatically stops any existing sms_handler service to avoid port 5000 conflict), run:"
echo "sudo systemctl stop sms_handler; cd /home/pi/sms_handler && source /home/pi/bag/venv/bin/activate && python web_interface.py"
# install_sms_handler.sh version 39
