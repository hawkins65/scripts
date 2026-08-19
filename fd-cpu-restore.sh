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

# Find all offline CPUs
OFFLINE_CPUS=$(ls /sys/devices/system/cpu/cpu[0-9]*/online 2>/dev/null | 
               while read -r CPU_FILE; do
                   if [ "$(cat "$CPU_FILE")" -eq 0 ]; then
                       basename "$(dirname "$CPU_FILE")" | cut -d'u' -f2
                   fi
               done)

if [ -z "$OFFLINE_CPUS" ]; then
    log_message "INFO" "No offline CPUs found"
    exit 0
fi

for CPU_NUM in $OFFLINE_CPUS; do
    log_message "INFO" "Processing offline CPU $CPU_NUM"

    CPU_FILE="/sys/devices/system/cpu/cpu${CPU_NUM}/online"
    if [ ! -f "$CPU_FILE" ]; then
        log_message "ERROR" "CPU status file $CPU_FILE not found"
        continue
    fi

    # Attempt to bring CPU online with sudo
    log_message "INFO" "Attempting to bring CPU $CPU_NUM online with sudo"
    TEMP_FILE=$(mktemp)
    echo 1 | sudo tee "$CPU_FILE" >"$TEMP_FILE" 2>&1
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

    # Verify CPU is online
    sleep 1
    STATUS=$(cat "$CPU_FILE" 2>/dev/null)
    if [ $? -ne 0 ]; then
        log_message "ERROR" "Failed to read CPU $CPU_NUM status after change"
        continue
    fi

    if [ "$STATUS" -eq 1 ]; then
        log_message "INFO" "Successfully brought CPU $CPU_NUM online (status: $STATUS)"
    else
        log_message "ERROR" "CPU $CPU_NUM still offline (status: $STATUS)"
    fi
done

log_message "INFO" "Script completed successfully"
exit 0