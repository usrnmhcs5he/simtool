#!/bin/bash

# diagnose_ztemf79u.sh - Version 1: Diagnostic script for ZTE MF79U USB modem

# Constants
PORT="/dev/ttyUSB0"  # Adjust to your AT port (test with ls /dev/ttyUSB*)
BAUD=115200
LOG_FILE="/home/pi/modem_diag_zte.log"

# Commands to test
commands=(
    "AT"                    # Basic communication
    "AT+CPIN?"              # SIM status
    "AT+CMGF=1"             # Set text mode
    "AT+CPMS?"              # Check current SMS storage
    "AT+CPMS=\"SM\",\"SM\",\"SM\""  # Set to SIM storage
    "AT+CPMS?"              # Verify SIM storage
    "AT+CMGL=\"ALL\""       # Dump all SMS from SIM
    "AT+CMGW=\"SIM Write Test\""  # Write test SMS to SIM
    "AT+CMGL=\"ALL\""       # Dump again to verify write
    "AT+CMGR=1"             # Read SMS at index 1 from SIM
    "AT+CMGD=1"             # Delete SMS at index 1 from SIM
    "AT+CPMS=\"ME\",\"ME\",\"ME\""  # Set to modem storage
    "AT+CPMS?"              # Verify modem storage
    "AT+CMGL=\"ALL\""       # Dump all SMS from ME
    "AT+CMGW=\"ME Write Test\""  # Write test SMS to ME
    "AT+CMGL=\"ALL\""       # Dump again to verify write
    "AT+CMGR=1"             # Read SMS at index 1 from ME
    "AT+CMGD=1"             # Delete SMS at index 1 from ME
    "AT+CNMI=2,1,0,0,0"     # Enable new SMS notifications
    "AT+GMR"                # Firmware version
)

# Function to log output
log() {
    echo "$(date +"%Y-%m-%d %H:%M:%S"): $1" | tee -a $LOG_FILE
}

# Function to send AT command
send_at() {
    cmd=$1
    response=$(echo -e "$cmd\r" > $PORT && sleep 1 && cat $PORT)
    echo "$response"
}

# Main execution
log "Starting diagnostic for ZTE MF79U on $PORT at $BAUD baud"

# Check USB mode
log "Checking USB mode with lsusb"
lsusb | grep ZTE | tee -a $LOG_FILE

# Test each command
for cmd in "${commands[@]}"; do
    log "Sending: $cmd"
    response=$(send_at "$cmd")
    log "Response: $response"
    sleep 1
done

# Wait for SMS notification
log "Waiting 60s for new SMS notification (+CMTI)"
sleep 60
notification=$(cat $PORT)
if [ -n "$notification" ]; then
    log "Received during wait: $notification"
    # Try reading any new SMS index
    match=$(echo "$notification" | grep -oP '(?<=+CMTI: "SM",)\d+')
    if [ -n "$match" ]; then
        idx=$match
        log "Sending: AT+CMGR=$idx"
        response=$(send_at "AT+CMGR=$idx")
        log "Response: $response"
    fi
else
    log "No notifications received"
fi

log "Diagnostic complete. Check $LOG_FILE for full output."
