#!/bin/bash

# Get the script's basename without extension
SCRIPT_NAME=$(basename "$0" .sh)

# Define log directory and file
LOG_DIR="/home/sol/logs"
LOG_FILE="${LOG_DIR}/${SCRIPT_NAME}.log"
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# Function to log messages to both file and screen
log_message() {
    local level="$1"
    local message="$2"
    echo "[$TIMESTAMP] $level: $message" | tee -a "$LOG_FILE"
}

# Check if log directory exists
if [ ! -d "$LOG_DIR" ]; then
    log_message "ERROR" "Log directory $LOG_DIR not found"
    exit 1
fi

# Check if validator.log exists
if [ ! -f "${LOG_DIR}/validator.log" ]; then
    log_message "ERROR" "validator.log not found in $LOG_DIR"
    exit 1
fi

# Get all unique CPU numbers that should be offline
CPU_NUMS=$(cat "${LOG_DIR}/validator.log" | 
           grep "which should be offline" | 
           grep -o "cpu [0-9]\+" | 
           awk '{print $2}' | 
           sort -u)

if [ -z "$CPU_NUMS" ]; then
    log_message "ERROR" "No CPUs found that should be offline"
    exit 1
fi

for CPU_NUM in $CPU_NUMS; do
    log_message "INFO" "Processing CPU $CPU_NUM that should be offline"

    # Check current CPU status
    CPU_FILE="/sys/devices/system/cpu/cpu${CPU_NUM}/online"
    if [ ! -f "$CPU_FILE" ]; then
        log_message "ERROR" "CPU status file $CPU_FILE not found"
        continue
    fi

    CURRENT_STATUS=$(cat "$CPU_FILE" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to read CPU $CPU_NUM status"
        continue
    fi

    # If CPU is already offline, inform and continue
    if [ "$CURRENT_STATUS" -eq 0 ]; then
        log_message "INFO" "CPU $CPU_NUM is already offline (status: $CURRENT_STATUS)"
        continue
    fi

    # Attempt to take CPU offline with sudo
    log_message "INFO" "Attempting to take CPU $CPU_NUM offline with sudo"
    TEMP_FILE=$(mktemp)
    echo 0 | sudo tee "$CPU_FILE" >"$TEMP_FILE" 2>&1
    TEE_EXIT=$?

    # Check for sudo-related errors
    if grep -q "sudo: a password is required" "$TEMP_FILE" || 
       grep -q "user is not in the sudoers file" "$TEMP_FILE" || 
       [ $TEE_EXIT -ne 0 ]; then
        log_message "ERROR" "Sudo failed for CPU $CPU_NUM - insufficient privileges or password required"
        log_message "ERROR" "Command output: $(cat "$TEMP_FILE")"
        rm -f "$TEMP_FILE"
        continue
    fi
    rm -f "$TEMP_FILE"

    # Verify CPU is offline
    sleep 1
    STATUS=$(cat "$CPU_FILE" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to read CPU $CPU_NUM status after change"
        continue
    fi

    if [ "$STATUS" -eq 0 ]; then
        log_message "INFO" "Successfully took CPU $CPU_NUM offline (status: $STATUS)"
    else
        log_message "ERROR" "CPU $CPU_NUM still online (status: $STATUS)"
    fi
done

log_message "INFO" "Script completed successfully"
exit 0