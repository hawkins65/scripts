#!/bin/bash

# This script checks if a validator's MEV Commission is null for a given epoch
# and ensures at least one leader slot has occurred in the epoch.
# Dependencies:
# - solana CLI: Install from https://docs.solana.com/cli/install-solana-cli-tools
# - validator-history-cli: Install from https://github.com/jito-foundation/stakenet
# - curl: For API requests
# - jq: For JSON parsing
# Set the following paths to your local installations
SOLANA_CLI="<path_to_your_solana_client>"  # e.g., /home/user/.local/share/solana/install/active_release/bin/solana
VALIDATOR_HISTORY_CLI="<path_to_your_validator-history-cli>"  # e.g., /home/user/.local/bin/validator-history-cli

# Configuration
RPC_URL="https://api.mainnet-beta.solana.com"  # Public Solana mainnet RPC endpoint
MESSAGE_FILE="validator_message.txt"

# Function to map vote pubkey to identity pubkey using Trillium API
map_vote_to_identity() {
    local vote_pubkey="$1"
    local api_url="https://api.trillium.so/validator_rewards/$vote_pubkey"
    
    # Fetch JSON data using curl
    local response=$(curl -s "$api_url")
    if [ $? -ne 0 ]; then
        echo "Error: Failed to fetch data from $api_url" >&2
        return 1
    fi
    
    # Check if response is empty
    if [ -z "$response" ]; then
        echo "Error: Empty response from $api_url" >&2
        return 1
    fi
    
    # Parse JSON to extract identity_pubkey
    local identity_pubkey=$(echo "$response" | jq -r '
        # Check if response is an object with an "error" field
        if type == "object" and has("error") then
            empty
        else
            # If input is an array, take the first element; if it is an object, use it directly
            (if type == "array" then .[0] else . end) | 
            .identity_pubkey // empty
        end
    ')
    
    # Check if jq parsing was successful
    if [ $? -ne 0 ]; then
        echo "Error: Failed to parse JSON response for pubkey $vote_pubkey" >&2
        return 1
    fi
    
    # Check if identity_pubkey is empty
    if [ -z "$identity_pubkey" ]; then
        echo "Error: No identity pubkey found for vote pubkey $vote_pubkey" >&2
        return 1
    fi
    
    echo "$identity_pubkey"
    return 0
}

# Check if vote pubkey is provided
if [ $# -lt 1 ]; then
    echo "Error: Please provide a vote account pubkey as an argument."
    echo "Usage: $0 <vote_pubkey> [epoch]"
    exit 1
fi

VOTE_PUBKEY="$1"

# Get current epoch
if [ $# -ge 2 ]; then
    CURRENT_EPOCH="$2"
else
    CURRENT_EPOCH=$("$SOLANA_CLI" epoch) || { echo "Error: Failed to retrieve epoch."; exit 1; }
fi

# Map vote pubkey to validator identity
VALIDATOR_IDENTITY=$(map_vote_to_identity "$VOTE_PUBKEY")
if [ $? -ne 0 ]; then
    echo "Error: Failed to map vote pubkey '$VOTE_PUBKEY' to validator identity."
    exit 1
fi
echo "Validator identity for vote pubkey $VOTE_PUBKEY: $VALIDATOR_IDENTITY"

# Retrieve epoch details to get current slot
EPOCH_DETAILS=$("$SOLANA_CLI" --url "$RPC_URL" epoch-info)
if [ -z "$EPOCH_DETAILS" ]; then
    echo "Error: Failed to retrieve epoch details."
    exit 1
fi

EPOCH_CURRENT_SLOT=$(echo "$EPOCH_DETAILS" | grep ^Slot: | awk '{ print $2 }')
if [ -z "$EPOCH_CURRENT_SLOT" ]; then
    echo "Error: Failed to parse current slot from epoch details."
    exit 1
fi

# Check leader schedule for the validator
LEADER_SCHEDULE=$("$SOLANA_CLI" --url "$RPC_URL" leader-schedule --no-address-labels | grep "$VALIDATOR_IDENTITY" | awk '{ print $1 }')
if [ -z "$LEADER_SCHEDULE" ]; then
    echo "No leader slots found for validator $VALIDATOR_IDENTITY in epoch $CURRENT_EPOCH. Skipping MEV Commission check."
    exit 0
fi

# Check if any leader slot has occurred (slot <= current slot)
HAS_LEADER_SLOT=0
for SLOT in $LEADER_SCHEDULE; do
    if [ "$SLOT" -le "$EPOCH_CURRENT_SLOT" ]; then
        HAS_LEADER_SLOT=1
        break
    fi
done

if [ "$HAS_LEADER_SLOT" -eq 0 ]; then
    echo "No leader slots have occurred yet for validator $VALIDATOR_IDENTITY in epoch $CURRENT_EPOCH. Skipping MEV Commission check."
    exit 0
fi

# Run validator-history-cli
VALIDATOR_OUTPUT=$("$VALIDATOR_HISTORY_CLI" --json-rpc-url "$RPC_URL" history --start-epoch "$CURRENT_EPOCH" "$VOTE_PUBKEY" 2>&1)

# Check for null MEV Commission
if echo "$VALIDATOR_OUTPUT" | grep -Eiq "MEV Commission:[[:space:]]*(null|\[NULL\])[[:space:]]*\|"; then
    cat > "$MESSAGE_FILE" << EOF
Validator MEV Commission NULL
Epoch: $CURRENT_EPOCH
Validator: $VOTE_PUBKEY
Output:
$VALIDATOR_OUTPUT
EOF

    [ ! -f "$MESSAGE_FILE" ] && { echo "Error: Failed to create message file."; exit 1; }

    echo "Message file content:"
    cat "$MESSAGE_FILE"
else
    echo "MEV Commission not null. No output generated."
fi