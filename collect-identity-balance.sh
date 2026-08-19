#!/usr/bin/env bash

###############################################
# Logging Configuration
###############################################

LOG_DIR="$HOME/logs"
mkdir -p "$LOG_DIR"
LOG_FILE="$LOG_DIR/$(basename "$0" .sh)_$(/usr/bin/date +'%Y-%m-%d_%H:%M:%S').log"
exec &> >(tee -a "$LOG_FILE")
echo "Logging initialized at $LOG_FILE"

###############################################
# Configuration
###############################################

SOLANA_PATH="/usr/local/bin/"
SOLANA_CLI="${SOLANA_PATH}solana"  # full path to the solana CLI
WALLET_ADDRESS="<your target, hardware based wallet>"
IDENTITY="<your authorized voter pubkey -- usually the same as identity>"
RETAIN_IDENTITY_BALANCE="5.2" # whatever amount you feel comfortable leaving to cover vote costs
MIN_REMAINDER="1"
SOLANA_URL="<I use a private RPC endpoint> "
DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/<your webhook detailed address which has a slash in the middle>"
DISCORD_USERNAME="Validator Collect Balance Bot"
DISCORD_AVATAR_URL="<whatever you want it to show up as in Discord"
MONEY_BAG="💰"
WARNING_EMOJI="🚨"

###############################################
# Functions
###############################################

log_error_and_retry() {
    local error_message="$1"
    echo "[ERROR] $error_message. Retrying in 10 seconds..." >&2
    sleep 10
}

# Executes a command with retries.
# Debug messages (and errors) are sent to stderr, while the command’s actual output is echoed to stdout.
execute_command_with_retry() {
    local cmd="$1"
    local retries=2
    local count=0
    local output
    local status

    while [ $count -lt $retries ]; do
        echo "[DEBUG] Executing: $cmd" >&2
        output=$(eval "$cmd" 2>&1)
        status=$?
        echo "$output" >&2
        if [ $status -eq 0 ]; then
            # Echo the command output (only) to stdout so that command substitution works properly.
            echo "$output"
            return 0
        fi
        log_error_and_retry "$output"
        count=$((count + 1))
    done
    return 1
}

check_balance() {
    local wallet_address="$1"
    echo "[DEBUG] Checking balance for wallet: $wallet_address" >&2
    execute_command_with_retry "$SOLANA_CLI balance -u $SOLANA_URL $wallet_address"
}

attempt_transfer() {
    echo "[DEBUG] Initiating transfer of $REMAINDER SOL to Secure Wallet: $WALLET_ADDRESS" >&2

    # Get the identity balance before the transfer
    identity_before_balance=$(execute_command_with_retry "$SOLANA_CLI balance -u $SOLANA_URL $IDENTITY" | awk '{print $1}')
    echo "[DEBUG] Identity Balance Before Transfer: $identity_before_balance SOL" >&2

    # Get the wallet balance before the transfer
    wallet_before_balance=$(execute_command_with_retry "$SOLANA_CLI balance -u $SOLANA_URL $WALLET_ADDRESS" | awk '{print $1}')
    echo "[DEBUG] Secure Wallet Balance Before Transfer: $wallet_before_balance SOL" >&2

    # Build and execute the transfer command
    transfer_cmd="$SOLANA_CLI transfer -u $SOLANA_URL $WALLET_ADDRESS $REMAINDER --allow-unfunded-recipient"
    transfer_output=$(execute_command_with_retry "$transfer_cmd")
    echo "[DEBUG] Transfer Output: $transfer_output" >&2

    # Extract transaction id from the output
    transaction_id=$(echo "$transfer_output" | grep -oE 'Signature: [a-zA-Z0-9]+' | awk '{print $2}')
    echo "[DEBUG] Transaction ID: $transaction_id" >&2

    # Get the identity balance after the transfer
    identity_after_balance=$(execute_command_with_retry "$SOLANA_CLI balance -u $SOLANA_URL $IDENTITY" | awk '{print $1}')
    echo "[DEBUG] Identity Balance After Transfer: $identity_after_balance SOL" >&2

    # Get the wallet balance after the transfer
    wallet_after_balance=$(execute_command_with_retry "$SOLANA_CLI balance -u $SOLANA_URL $WALLET_ADDRESS" | awk '{print $1}')
    echo "[DEBUG] Secure Wallet Balance After Transfer: $wallet_after_balance SOL" >&2
}

send_discord_message() {
    local message="$1"
    # Escape double quotes and newlines for JSON.
    json_message=$(echo "$message" | sed 's/"/\\"/g' | sed ':a;N;$!ba;s/\n/\\n/g')
    echo "[DEBUG] Sending message to Discord..." >&2
    discord_response=$(curl -s -H "Content-Type: application/json" -X POST -d "{\"content\":\"$json_message\", \"username\":\"$DISCORD_USERNAME\", \"avatar_url\":\"$DISCORD_AVATAR_URL\", \"flags\": 4}" "$DISCORD_WEBHOOK_URL")
    if [ -z "$discord_response" ]; then
        echo "[DEBUG] Message sent to Discord successfully." >&2
    else
        echo "[ERROR] Error sending message to Discord: $discord_response" >&2
    fi
}

###############################################
# Main Logic
###############################################

echo "[DEBUG] Starting balance collection process..." >&2

# Get the balance for the identity.
BALANCE=$(execute_command_with_retry "$SOLANA_CLI balance -u $SOLANA_URL $IDENTITY" | head -n 1 | awk '{print $1}')

# Validate BALANCE to ensure it is numeric.
if [[ -z "$BALANCE" || "$BALANCE" =~ [^0-9.] ]]; then
    echo "[ERROR] Invalid balance value: '$BALANCE'" >&2
    BALANCE=0
fi

# Calculate the remainder after retaining the specified balance.
REMAINDER=$(echo "scale=2; $BALANCE - $RETAIN_IDENTITY_BALANCE" | bc 2>/dev/null | tr -d '\n')

# Validate REMAINDER.
if [[ -z "$REMAINDER" || "$REMAINDER" =~ [^0-9.] ]]; then
    echo "[ERROR] Invalid remainder value: '$REMAINDER'" >&2
    REMAINDER=0
fi

echo "[DEBUG] Current balance: $BALANCE SOL, Remainder: $REMAINDER SOL" >&2

if [ "$(echo "$REMAINDER > $MIN_REMAINDER" | bc -l)" -eq 1 ]; then
    echo "[DEBUG] Remainder ($REMAINDER SOL) is greater than minimum threshold ($MIN_REMAINDER SOL). Proceeding with transfer..." >&2
    attempt_transfer
else
    echo "[DEBUG] Transfer condition not met. No transfer executed." >&2
    echo "[DEBUG] Remainder ($REMAINDER SOL) is not greater than the minimum threshold ($MIN_REMAINDER SOL)." >&2
fi

# Get current date/time in UTC
CURRENT_DATETIME_UTC=$(date -u +"%A, %B %d, %Y at %I:%M:%S %p UTC")
# Get current date/time in US Central Time (CST/CDT)
CURRENT_DATETIME_CST=$(TZ="America/Chicago" date +"%A, %B %d, %Y at %I:%M:%S %p %Z")
TIMESTAMP_INFO="Report generated at $CURRENT_DATETIME_UTC ($CURRENT_DATETIME_CST)"

FINAL_MESSAGE="$MONEY_BAG Trillium Identity Balance Update $MONEY_BAG

\`\`\`
Identity:   $IDENTITY
Wallet:     $WALLET_ADDRESS
\`\`\`
\`\`\`
Identity Balance Before: $identity_before_balance SOL
Wallet Balance Before:   $wallet_before_balance SOL
\`\`\`
\`\`\`
Amount Transferred:      $REMAINDER SOL
\`\`\`
\`\`\`
Identity Balance After:  $identity_after_balance SOL
Wallet Balance After:    $wallet_after_balance SOL
\`\`\`

Orb:           <https://orb.helius.dev/tx/$transaction_id?cluster=mainnet-beta>

$TIMESTAMP_INFO"

send_discord_message "$FINAL_MESSAGE"

# Show the final message on the screen
echo -e "$FINAL_MESSAGE"

echo "[DEBUG] Processing complete. Log file is located at: $LOG_FILE" >&2
exit 0
