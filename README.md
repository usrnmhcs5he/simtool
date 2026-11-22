# simtool

# SMS Handler for Raspberry Pi

Current version: **39** (installer `install_sms_handler.sh`; the version is shown at the bottom of the web UI and kept in the script header).

## Overview
This project is a web-based SMS management system for Raspberry Pi, designed to receive SMS messages from a serial modem (e.g., SIM800L or Huawei E3372), store them in a persistent SQLite database, and provide a Flask-powered UI for viewing, deleting, sending, forwarding to Discord, and exporting to CSV. Every received SMS is forwarded to a Discord webhook automatically. It has real-time updates with Socket.IO and diagnostic logging for modem responses. The system is resilient to rebuilds, with the DB and venv in `/home/pi/bag/`. Built iteratively through collaborative development, starting from basic serial communication to advanced parsing and forwarding.

## Features
- **SMS Reception**: Polls the modem for new SMS, parses them (including UCS2 encoding), stores them in the DB, and deletes them from the modem.
- **Web UI**: Flask app with a paged SMS list (filter by sender and date), real-time logs, status indicators, and action buttons (delete, forward to Discord).
- **Auto-Forwarding to Discord**: Every received SMS is posted to the Discord webhook. By default there is no restriction on sender numbers; `from_numbers` in `config.json` can limit it.
- **Send SMS**: Send an SMS from the web UI.
- **CSV Export**: Download all SMS as sms_export.csv.
- **Test SMS Injection**: Write a test SMS to the modem for diagnostics (may fail on data-only SIMs).
- **Raw Modem Logging**: Logs raw AT+CMGL and AT+CMGR responses for troubleshooting.
- **Persistent Storage**: DB in `/home/pi/bag/sms.db` survives rebuilds.
- **Real-Time Updates**: Socket.IO for live SMS and log additions without page reload.
- **Modem Compatibility**: Tested with SIM800L (GPIO serial0) and Huawei E3372 (USB ttyUSB0).
- **All the tools on one place**: All the tools and programs are downloaded for the first time during the first run. Next update, script will check if something is missing and redownload, or just skips, thus safe some time.
- **PIN code if SIM is locked**: Enter the SIM PIN in the web UI.
- **Dedicated diag scripts attached**: They list outputs from AT commands from the modem, good when changing the USB devices.

Email (SMTP) forwarding, the auto-forward toggles and the `cnFmail` / `cnFdiscord` SMS commands were removed in version 39.

## Requirements
- Raspberry Pi (tested on Pi 4) with Raspbian.
- Python 3.11+.
- Serial modem (SIM800L with level shifter or Huawei E3372 USB).
- SIM card (voice/data for SMS; data-only may limit write operations).
- Libraries: flask, pyserial, requests, flask-socketio, gevent, gevent-websocket (installed via pip in venv).
- External: Discord webhook for forwarding (stored in `/home/pi/bag/webhook.txt`).

## Files
| File | Purpose |
|------|---------|
| `install_sms_handler.sh` | Installer and upgrader (version 39). Always the latest version; older versions are in the git history. |
| `diagnose_modem.py` | Modem diagnostic (version 2), Python. |
| `diagnose_ztemf79u.sh` | Diagnostic for the ZTE MF79U USB modem (version 1), still being tested. |
| `go.sh` | Helper for committing and pushing this repository. |

## Installation
0. Up until v40, you have to create `/home/pi/bag/webhook.txt` file preferably with real webhook in it, before running the script, that will be fixed
1. Run the setup script:
   ```bash
   bash install_sms_handler.sh
   ```
2. Edit `config.json` for your modem/port, baud, and forward rules (webhook, optional `from_numbers`).
3. Start the app:
   ```bash
   sudo systemctl stop sms_handler; cd /home/pi/sms_handler && source /home/pi/bag/venv/bin/activate && python web_interface.py
   ```
   - Or use systemd: `sudo systemctl start sms_handler` (auto-starts on boot if enabled).

## Upgrade
1. Delete folder /home/pi/sms_handler but keep the /home/pi/bag folder (there are apps downloaded, it will spare time during upgrades)
2. download the latest `install_sms_handler.sh` from this repository and re-run it
3. previous database stays in /home/pi/bag folder; `config.json` is created again by the installer, so check the serial port afterwards

## Usage
- Access the UI at `http://<rpi-ip>:5000`.
- Send SMS to the SIM's number for reception and forwarding.
- Use the buttons to delete, forward to Discord, send an SMS, or export.
- Diagnostics: Logs show raw modem responses; use `minicom -D /dev/ttyUSB0 -b 115200` for manual AT commands.
- During every installation/upgrade script automatically add one test SMS to the database

- Note: If using Huawei E3372 modem, you may need to edit /etc/usb_modeswitch.conf and set HuaweiAltModeGlobal=1 to ensure modem mode persists on boot.
- Access at http://<rpi-ip>:5000 (or check service: sudo systemctl status sms_handler)
- To start the program (automatically stops any existing sms_handler service to avoid port 5000 conflict), run: sudo systemctl stop sms_handler; cd /home/pi/sms_handler && source /home/pi/bag/venv/bin/activate && python web_interface.py

## Approach
The system uses pyserial for modem communication, Flask/Socket.IO for the web app, and SQLite for persistence. The listener loop polls the modem with AT commands (AT+CMGL, AT+CMGR, AT+CMGD), parses UCS2-encoded responses, and forwards via requests (Discord). The setup script keeps the venv and DB in `/home/pi/bag/` for persistence.

## Remote access
Tested with Tailscale, more details later

## Troubleshooting
1. stop the service (it holds the serial port) and run the diagnose script with the Python from the venv (it needs pyserial):
   ```bash
   sudo systemctl stop sms_handler; /home/pi/bag/venv/bin/python diagnose_modem.py
   ```
   For the ZTE MF79U modem use `bash diagnose_ztemf79u.sh` instead.
2. analyse output, it may help to find issues like locked SIM, full storage on SIM, inability to write to SIM etc

## Changelog
| Version | Date | Changes |
|---------|------|---------|
| 35 | 2025-08-07 | First published version. |
| 36 | 2025-08-07 | Published as a separate file, identical to 35. |
| **39** | 2025-09-30 | Email (SMTP) forwarding, auto-forward toggles and SMS commands removed; every received SMS is forwarded to Discord; no restriction on sender numbers by default. |

On 2026-11-22 the scripts got stable filenames (`39.sh` became `install_sms_handler.sh`, `diagnose_modem_v2.sh` became `diagnose_modem.py`, `diagnose_ztemf79u_v1.sh` became `diagnose_ztemf79u.sh`) and the old installer copies were removed. No functional change.

## Credits
- **Flask**: Web framework (flask.palletsprojects.com).
- **Socket.IO**: Real-time updates (socket.io).
- **pyserial**: Serial communication (pythonhosted.org/pyserial).
- **requests**: HTTP forwarding (requests.readthedocs.io).
- **gevent/gevent-websocket**: Concurrency for Socket.IO (gevent.org).
- **xAI/Grok**: Assisted in script development and debugging.

## License
MIT. See [LICENSE](LICENSE).
