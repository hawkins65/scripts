#!/bin/bash

# Script name without the ".sh" extension
SCRIPT_NAME=$(basename "$0" .sh)

# Set base directory path
BASE_DIR="/$HOME/<directory for script and output>"
cd $BASE_DIR

# Pubkeys for each validator
MAINNET_IDENTITY_PUBKEY="<mainnet identity pubkey>"
TESTNET_IDENTITY_PUBKEY="<testnet identity pubkey>"

# Global timestamp for reporting
GLOBAL_TIMESTAMP=$(date +"%Y-%m-%d %H:%M:%S")

# Initialize an empty JSON array to hold results
RESULTS="[]"

# Function to log with date/time format yyyy-mm-dd hh:mm:ss
log() {
    local message="$1"
    local timestamp=$(date +"%Y-%m-%d %H:%M:%S")
    echo "[$timestamp] $message" | tee -a "$LOG_FILE"
}

# Function to get latest report file for a network
get_latest_report() {
    local network="$1"
    find "$BASE_DIR/vote-credit-monitor/${network}_data" -name "${network}_report_*.json" -type f -printf '%T@ %p\n' 2>/dev/null | sort -n | tail -1 | cut -f2- -d" "
}

# Function to extract credits per second for a validator from report
get_credits_per_second() {
    local report_file="$1"
    local pubkey="$2"
    
    if [ ! -f "$report_file" ]; then
        echo "null"
        return
    fi
    
    credits=$(jq -r ".validators[] | select(.pubkey == \"$pubkey\") | .credits_per_second" "$report_file")
    if [ -z "$credits" ] || [ "$credits" == "null" ]; then
        echo "null"
    else
        echo "$credits"
    fi
}

# Function to compare floating point numbers
float_cond() {
    local cond=0
    if [[ $# -gt 0 ]]; then
        cond=$(echo "$*" | bc -l)
        if [[ -z "$cond" ]]; then cond=0; fi
        if [[ "$cond" == "1" ]]; then
            return 0  # Success (true)
        fi
    fi
    return 1  # Failure (false)
}

# Function to run monitoring for a validator
run_monitoring() {
    local VALIDATOR="$1"
    
    # Set identity pubkey and network based on validator
    if [ "$VALIDATOR" == "testnet" ]; then
        IDENTITY_PUBKEY="$TESTNET_IDENTITY_PUBKEY"
        NETWORK="testnet"
    elif [ "$VALIDATOR" == "mainnet" ]; then
        IDENTITY_PUBKEY="$MAINNET_IDENTITY_PUBKEY"
        NETWORK="mainnet"
    else
        echo "Invalid network specified"
        return 1
    fi

    # File to store previous run data
    PREVIOUS_DATA_FILE="$BASE_DIR/${SCRIPT_NAME}_${VALIDATOR}_previous_run_data.json"
    # Log file
    LOG_FILE="$BASE_DIR/${SCRIPT_NAME}_${VALIDATOR}.log"

    # Get latest report file
    REPORT_FILE=$(get_latest_report "$NETWORK")
    
    if [ -z "$REPORT_FILE" ]; then
        log "No report file found for $NETWORK"
        return 1
    fi

    # Get current credits per second
    CREDITS_PER_SECOND=$(get_credits_per_second "$REPORT_FILE" "$IDENTITY_PUBKEY")
    
    if [ "$CREDITS_PER_SECOND" == "null" ]; then
        log "Could not find credits per second for $IDENTITY_PUBKEY in $REPORT_FILE"
        return 1
    fi

    # Load previous run data if it exists
    PREVIOUS_CREDITS_PER_SECOND="null"
    if [ -f "$PREVIOUS_DATA_FILE" ]; then
        PREVIOUS_CREDITS_PER_SECOND=$(jq -r '.credits_per_second' "$PREVIOUS_DATA_FILE")
    fi

    PERCENTAGE_DIFF="null"
    if [ "$PREVIOUS_CREDITS_PER_SECOND" != "null" ] && [ "$CREDITS_PER_SECOND" != "null" ]; then
        PERCENTAGE_DIFF=$(echo "scale=2; (($CREDITS_PER_SECOND - $PREVIOUS_CREDITS_PER_SECOND) / $PREVIOUS_CREDITS_PER_SECOND) * 100" | bc)
    fi

    # Log current and previous values
    log "Current credits per second: $CREDITS_PER_SECOND, Previous credits per second: $PREVIOUS_CREDITS_PER_SECOND, Percentage difference: ${PERCENTAGE_DIFF:-null}%"

    # Check for significant drop in credits per second
    if [ "$PREVIOUS_CREDITS_PER_SECOND" != "null" ] && [ "$CREDITS_PER_SECOND" != "null" ]; then
        # Calculate the percentage difference
        PERCENTAGE_DIFF=$(echo "scale=2; (100 * ($CREDITS_PER_SECOND - $PREVIOUS_CREDITS_PER_SECOND) / $PREVIOUS_CREDITS_PER_SECOND)" | bc)
        
        if float_cond "$PERCENTAGE_DIFF < -3"; then
            log "Credits per second dropped significantly for $VALIDATOR (Current: $CREDITS_PER_SECOND, Previous: $PREVIOUS_CREDITS_PER_SECOND, Drop: ${PERCENTAGE_DIFF}%)"
            $BASE_DIR/update_discord_telegram.sh "$SCRIPT_NAME" credits-drop "$CREDITS_PER_SECOND" "$PREVIOUS_CREDITS_PER_SECOND" "$VALIDATOR" "$IDENTITY_PUBKEY"
        fi
    fi

    # Save current values for next run
    cat <<EOF > "$PREVIOUS_DATA_FILE"
{
  "credits_per_second": $CREDITS_PER_SECOND
}
EOF

    log "Updated previous run data for future comparison"
    log "Completed a pass for network: $VALIDATOR"
    
    # Add the current validator's result to the RESULTS array
    # Using jq to append an object to the JSON array
    RESULTS=$(echo "$RESULTS" | jq --arg pubkey "$IDENTITY_PUBKEY" \
                                   --argjson current $CREDITS_PER_SECOND \
                                   --argjson previous $( [ "$PREVIOUS_CREDITS_PER_SECOND" = "null" ] && echo "null" || echo $PREVIOUS_CREDITS_PER_SECOND ) \
                                   --arg timestamp "$GLOBAL_TIMESTAMP" \
                                   '. += [{"IDENTITY_PUBKEY": $pubkey, "CREDITS_PER_SECOND": $current, "PREVIOUS_CREDITS_PER_SECOND": $previous, "TIMESTAMP": $timestamp}]')
}

# Process each validator once
for VALIDATOR in "testnet" "mainnet"; do
    run_monitoring "$VALIDATOR"
done

# After processing all validators, write the RESULTS to vote-credits-monitor.json
echo "$RESULTS" > "$BASE_DIR/vote-credits-monitor.json"

log "Monitoring completed for all networks and vote-credits-monitor.json updated"
