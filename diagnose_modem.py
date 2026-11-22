# diagnose_modem.py - Version 2: Enhanced diagnostic for SMS storage (SM vs ME), write/read/delete tests, and content dump

import serial
import time
import sys

# Configuration
PORT = '/dev/ttyUSB0'  # Adjust to your port
BAUD = 115200
TIMEOUT = 1
LOG_FILE = '/home/pi/modem_diag_v2.log'

# Commands to test
commands = [
    'AT',                    # Basic communication
    'AT+CPIN?',              # SIM status
    'AT+CMGF=1',            # Set text mode
    'AT+CPMS?',              # Check current SMS storage
    'AT+CPMS="SM","SM","SM"',  # Set to SIM storage
    'AT+CPMS?',              # Verify SIM storage
    'AT+CMGL="ALL"',         # Dump all SMS from SIM
    'AT+CMGW="SIM Write Test"',  # Write test SMS to SIM
    'AT+CMGL="ALL"',         # Dump again to verify write
    'AT+CMGR=1',             # Read SMS at index 1 from SIM
    'AT+CMGD=1',             # Delete SMS at index 1 from SIM
    'AT+CPMS="ME","ME","ME"',  # Set to modem storage
    'AT+CPMS?',              # Verify modem storage
    'AT+CMGL="ALL"',         # Dump all SMS from ME
    'AT+CMGW="ME Write Test"',  # Write test SMS to ME
    'AT+CMGL="ALL"',         # Dump again to verify write
    'AT+CMGR=1',             # Read SMS at index 1 from ME
    'AT+CMGD=1',             # Delete SMS at index 1 from ME
    'AT+CNMI=2,1,0,0,0',    # Enable new SMS notifications
    'AT+GMR'                 # Firmware version
]

def log(message):
    with open(LOG_FILE, 'a') as f:
        f.write(f'{time.strftime("%Y-%m-d %H:%M:%S")}: {message}\n')
    print(message)

def send_at_command(ser, cmd):
    ser.write((cmd + '\r\n').encode())
    time.sleep(1)  # Longer wait for stability
    response = ser.read(ser.in_waiting).decode(errors='ignore').strip()
    return response if response else "No response"

def main():
    try:
        ser = serial.Serial(PORT, BAUD, timeout=TIMEOUT)
        log(f"Opened {PORT} at {BAUD} baud")
    except Exception as e:
        log(f"Failed to open {PORT}: {str(e)}")
        sys.exit(1)

    try:
        for cmd in commands:
            log(f"Sending: {cmd}")
            response = send_at_command(ser, cmd)
            log(f"Response: {response}")
            time.sleep(1)
        # Wait for SMS notification
        log("Waiting 60s for new SMS notification (+CMTI)")
        ser.timeout = 60
        response = ser.read(ser.in_waiting).decode(errors='ignore').strip()
        if response:
            log(f"Received during wait: {response}")
            # Try reading any new SMS index
            match = re.search(r'\+CMTI: "SM",(\d+)', response)
            if match:
                idx = match.group(1)
                log(f"Sending: AT+CMGR={idx}")
                ser.write((f'AT+CMGR={idx}\r\n').encode())
                time.sleep(1)
                response = ser.read(ser.in_waiting).decode(errors='ignore').strip()
                log(f"Response: {response}")
        else:
            log("No notifications received")
    except Exception as e:
        log(f"Error during commands: {str(e)}")
    finally:
        ser.close()
        log("Closed serial port")

if __name__ == '__main__':
    main()
