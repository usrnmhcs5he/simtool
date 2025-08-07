# simtool

# SMS Handler for Raspberry Pi

## Overview
This project is a web-based SMS management system for Raspberry Pi, designed to receive SMS messages from a serial modem (e.g., SIM800L or Huawei E3372), store them in a persistent SQLite database, and provide a Flask-powered UI for viewing, deleting, forwarding to email or Discord, and exporting to CSV. It supports auto-forwarding toggles via web buttons or special SMS commands, real-time updates with Socket.IO, and diagnostic logging for modem responses. The system is resilient to rebuilds, with the DB and venv in `/home/pi/bag/`. Built iteratively through collaborative development, starting from basic serial communication to advanced parsing and forwarding.

## Features
- **SMS Reception**: Polls the modem for new SMS, parses (including UCS2 encoding), stores in DB, and deletes from modem.
- **Web UI**: Responsive Flask app with SMS list, real-time logs, status indicators, and action buttons (delete, forward to email/Discord).
- **Auto-Forwarding**: Toggle auto-forward to email or Discord via UI or SMS commands
- **SMS commands to enable/disable features**: Send SMS 'cnFmail:S1' to enable auto-email forwarding (S0 to disable). Similarly for 'cnFdiscord'.
- **CSV Export**: Download all SMS as sms_export.csv.
- **Test SMS Injection**: Write a test SMS to the modem for diagnostics (may fail on data-only SIMs).
- **Raw Modem Logging**: Logs raw AT+CMGL and AT+CMGR responses for troubleshooting.
- **Persistent Storage**: DB in `/home/pi/bag/sms.db` survives rebuilds.
- **Real-Time Updates**: Socket.IO for live SMS and log additions without page reload.
- **Modem Compatibility**: Tested with SIM800L (GPIO serial0) and Huawei E3372 (USB ttyUSB0).
- **All the tools on one place**: All the tools and programs are downloaded for the first time during the first run. Next update, script will check if something is missing and redownload, or just skips, thus safe some time.
- **PIN code if SIM is locked**
- **Dedicated diag script attached**: It List outputs from AT commands from the modem, good when changing the USB devices

## Requirements
- Raspberry Pi (tested on Pi 4) with Raspbian.
- Python 3.11+.
- Serial modem (SIM800L with level shifter or Huawei E3372 USB).
- SIM card (voice/data for SMS; data-only may limit write operations).
- Libraries: flask, pyserial, requests, flask-socketio, gevent, gevent-websocket (installed via pip in venv).
- External: Discord webhook for forwarding (stored in `/home/pi/bag/webhook.txt`).

## Installation
1. Run the setup script:
   ```bash
   bash install_sms_handler_vxx.sh # where xx is version curently used, starting with v35 or use latest available version
   ```
2. Edit `config.json` for your modem/port, baud, and forward rules (email credentials, webhook).
3. Start the app:
   ```bash
   sudo systemctl stop sms_handler; cd /home/pi/sms_handler && source /home/pi/bag/venv/bin/activate && python web_interface.py
   ```
   - Or use systemd: `sudo systemctl start sms_handler` (auto-starts on boot if enabled).

## Upgrade
1. Delete folder /home/pi/sms_handler
2. re-run the given script, now incremental version vXX
3. previous database and config stays in /home/pi/bag folder

## Usage
- Access the UI at `http://<rpi-ip>:5000`.
- Send SMS to the SIM's number for reception and forwarding.
- Use buttons to toggle auto-forward, delete, forward, or export.
- Special SMS: 'cnFmail:S1' to enable email auto-forward (S0 to disable); similar for 'cnFdiscord'.
- Diagnostics: Logs show raw modem responses; use `minicom -D /dev/ttyUSB0 -b 115200` for manual AT commands.
- During every installation/upgrade script automatically add one test SMS to the database

- Note: If using Huawei E3372 modem, you may need to edit /etc/usb_modeswitch.conf and set HuaweiAltModeGlobal=1 to ensure modem mode persists on boot.
- Access at http://<rpi-ip>:5000 (or check service: sudo systemctl status sms_handler)
- To start the program (automatically stops any existing sms_handler service to avoid port 5000 conflict), run: sudo systemctl stop sms_handler; cd /home/pi/sms_handler && source /home/pi/bag/venv/bin/activate && python web_interface.py

## Approach
The system uses pyserial for modem communication, Flask/Socket.IO for the web app, and SQLite for persistence. The listener loop polls the modem with AT commands (AT+CMGL, AT+CMGR, AT+CMGD), parses UCS2-encoded responses, and forwards via requests (Discord) or smtplib (email). State (auto-forward) is stored in DB for restart resilience. Setup scripts ensure idempotent installation, with venv/DB in `/home/pi/bag/` for persistence.

## Remote access
Tested with Tailscale, more details later

## Troubleshooting
1. run the diagnose script:
```bash
   diagnost_modem_v2.sh
   ```
2. analyse output, it may help to find issues like locked SIM, full storage on SIM, inability to write to SIM etc


## Credits
- **Flask**: Web framework (flask.palletsprojects.com).
- **Socket.IO**: Real-time updates (socket.io).
- **pyserial**: Serial communication (pythonhosted.org/pyserial).
- **requests**: HTTP forwarding (requests.readthedocs.io).
- **gevent/gevent-websocket**: Concurrency for Socket.IO (gevent.org).
- **xAI/Grok**: Assisted in script development and debugging.

## License
MIT License - free to use/modify with attribution.
