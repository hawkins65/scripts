#!/bin/bash
# This bash script runs a list of programs after a new Solana epoch starts, retries failed programs once each, and sleeps until the next epoch.
# Configuration
HOME_DIR="$HOME" # User's home directory
SOLANA_CLI="$HOME_DIR/.local/share/solana/install/active_release/bin/solana" # Path to Solana CLI executable
# Solana RPC URL. Set QUICKNODE_RPC_URL (or any full RPC URL) in the environment.
# Never hardcode an endpoint here: a QuickNode/Helius/Alchemy URL carries its
# credential in the path, and this file is public.
RPC_URL="${QUICKNODE_RPC_URL:-https://api.mainnet-beta.solana.com}"
EPOCH_STATUS_FILE="$HOME_DIR/log/epoch_status.json" # File to track epoch status in log directory
PROGRAMS_TO_RUN_AT_EPOCH_START=(
    'script1.sh'
    'script2.sh'
    # Add more scripts as needed
)
RETRY_DELAY=300 # 5 minutes in seconds for retrying failed programs
ERROR_LOG="$HOME_DIR/log/$(basename "$0").log" # Log file named after script basename
MIN_SLEEP=600 # Minimum sleep time of 10 minutes in seconds

# Ensure Solana CLI uses the correct RPC URL
"$SOLANA_CLI" config set --url "$RPC_URL" >/dev/null 2>&1

# Convert seconds to hh:mm:ss format
seconds_to_hhmmss() {
  local seconds=$1
  local hours=$((seconds / 3600))
  local minutes=$(((seconds % 3600) / 60))
  local secs=$((seconds % 60))
  printf "%02d:%02d:%02d" "$hours" "$minutes" "$secs"
}

# Read epoch status from file
get_epoch_status() {
  if [[ ! -f "$EPOCH_STATUS_FILE" ]]; then
    mkdir -p "$(dirname "$EPOCH_STATUS_FILE")"
    echo '{"last_notified_epoch":0}' > "$EPOCH_STATUS_FILE"
  fi
  last_notified_epoch=$(jq -r '.last_notified_epoch // 0' "$EPOCH_STATUS_FILE" 2>/dev/null)
  if [[ -z "$last_notified_epoch" || ! "$last_notified_epoch" =~ ^[0-9]+$ ]]; then
    echo "Error: Failed to read epoch status file - Invalid JSON or missing fields" >> "$ERROR_LOG"
    echo "0"
  else
    echo "$last_notified_epoch"
  fi
}

# Write epoch status to file
set_epoch_status() {
  local last_notified_epoch="$1"
  mkdir -p "$(dirname "$EPOCH_STATUS_FILE")"
  if echo "{\"last_notified_epoch\":$last_notified_epoch}" > "$EPOCH_STATUS_FILE"; then
    return 0
  else
    echo "Error: Failed to write epoch status file" >> "$ERROR_LOG"
    return 1
  fi
}

# Run programs that haven't succeeded yet, retrying failed ones
run_programs() {
  local -A successful_programs=()
  local all_successful=true
  local at_least_one_attempted=false

  # Load previously successful programs for this epoch (if any)
  # Note: This is in-memory and resets per main call, sufficient since programs run only once per epoch
  while true; do
    at_least_one_attempted=false
    all_successful=true
    for program in "${PROGRAMS_TO_RUN_AT_EPOCH_START[@]}"; do
      # Skip programs that have already succeeded
      if [[ -n "${successful_programs[$program]}" ]]; then
        continue
      fi
      if [[ ! -x "$program" ]]; then
        echo "Error: Program $program is not executable or does not exist" >> "$ERROR_LOG"
        all_successful=false
        successful_programs[$program]=1 # Mark as "done" to avoid repeated attempts
        continue
      fi
      at_least_one_attempted=true
      echo "Running $program at $(date -u --iso-8601=seconds)" >> "$ERROR_LOG"
      if ./"$program" >> "$ERROR_LOG" 2>&1; then
        echo "Program $program completed successfully" >> "$ERROR_LOG"
        successful_programs[$program]=1 # Mark as successful
      else
        echo "Error: Program $program failed" >> "$ERROR_LOG"
        all_successful=false
      fi
    done
    # If all programs have succeeded or been attempted and marked done, exit
    if [[ "$all_successful" == "true" || ( "$at_least_one_attempted" == "false" && "${#successful_programs[@]}" -eq "${#PROGRAMS_TO_RUN_AT_EPOCH_START[@]}" ) ]]; then
      break
    fi
    local retry_delay_hhmmss=$(seconds_to_hhmmss $RETRY_DELAY)
    echo "Some programs failed, retrying after $retry_delay_hhmmss" >> "$ERROR_LOG"
    sleep "$RETRY_DELAY"
  done
  echo "$all_successful"
}

# Calculate slot duration
get_slot_duration() {
  local performance_samples=$(curl -s "$RPC_URL" -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getRecentPerformanceSamples","params":[1]}')
  local num_slots=$(echo "$performance_samples" | jq -r '.result[0].numSlots // 0')
  local sample_period_secs=$(echo "$performance_samples" | jq -r '.result[0].samplePeriodSecs // 0')
  if [[ $num_slots -eq 0 || $sample_period_secs -eq 0 ]]; then
    echo "Error: Failed to fetch performance samples: $performance_samples" >> "$ERROR_LOG"
    return 1
  fi
  local slot_duration=$(echo "scale=6; $sample_period_secs / $num_slots" | bc -l)
  echo "$slot_duration"
  return 0
}

# Get epoch information and calculate remaining time
get_epoch_info() {
  local epoch_info=$("$SOLANA_CLI" epoch-info --output json)
  if [[ $? -ne 0 ]]; then
    echo "Error: Failed to fetch epoch info: $epoch_info" >> "$ERROR_LOG"
    return 1
  fi
  local current_epoch=$(echo "$epoch_info" | jq -r '.epoch')
  local slot_index=$(echo "$epoch_info" | jq -r '.slotIndex')
  echo "$current_epoch $slot_index"
  return 0
}

# Main function
main() {
  echo "==== Run at $(date -u --iso-8601=seconds) ====" >> "$ERROR_LOG"

  # Get slot duration
  local slot_duration=$(get_slot_duration) || return 1

  # Get epoch information
  local epoch_data=$(get_epoch_info) || return 1
  read current_epoch slot_index <<< "$epoch_data"
  local slots_per_epoch=432000
  local slots_remaining=$((slots_per_epoch - slot_index))
  local seconds_remaining=$(echo "$slots_remaining * $slot_duration" | bc)
  local seconds_remaining_int=${seconds_remaining%.*}

  # Read epoch status
  local last_notified_epoch=$(get_epoch_status)

  # Check for new epoch
  if [[ $current_epoch -gt $last_notified_epoch ]]; then
    echo "New epoch $current_epoch detected" >> "$ERROR_LOG"
    # Run programs, ensuring each runs only once if successful
    local all_successful=$(run_programs)
    if [[ "$all_successful" == "true" ]]; then
      echo "All programs executed successfully for epoch $current_epoch" >> "$ERROR_LOG"
    else
      echo "Some programs failed after retries for epoch $current_epoch" >> "$ERROR_LOG"
    fi
    set_epoch_status "$current_epoch"
  fi

  # Sleep until new epoch with periodic recalculations
  while [[ $current_epoch -le $last_notified_epoch ]]; do
    # Recalculate slot duration and epoch info
    slot_duration=$(get_slot_duration) || return 1
    epoch_data=$(get_epoch_info) || return 1
    read current_epoch slot_index <<< "$epoch_data"
    slots_remaining=$((slots_per_epoch - slot_index))
    seconds_remaining=$(echo "$slots_remaining * $slot_duration" | bc)
    seconds_remaining_int=${seconds_remaining%.*}

    # If new epoch detected, break to process it
    if [[ $current_epoch -gt $last_notified_epoch ]]; then
      break
    fi

    # Sleep for half the remaining time, with a minimum of MIN_SLEEP
    local sleep_time=$((seconds_remaining_int / 2))
    if [[ $sleep_time -lt $MIN_SLEEP ]]; then
      sleep_time=$MIN_SLEEP
    fi
    local sleep_time_hhmmss=$(seconds_to_hhmmss $sleep_time)
    local remaining_time_hhmmss=$(seconds_to_hhmmss $seconds_remaining_int)
    echo "Sleeping for $sleep_time_hhmmss (half of $remaining_time_hhmmss remaining)" >> "$ERROR_LOG"
    sleep "$sleep_time"
  done
}

# Run main function in a loop
while true; do
  main 2>>"$ERROR_LOG" || {
    local error_retry_delay=60
    local error_retry_hhmmss=$(seconds_to_hhmmss $error_retry_delay)
    echo "Main function error at $(date -u --iso-8601=seconds), retrying in $error_retry_hhmmss" >> "$ERROR_LOG"
    sleep "$error_retry_delay"
  }
done
