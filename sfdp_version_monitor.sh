#!/bin/bash

# NOTE -- the jq tool is required for parsing JSON data, such as responses from APIs
# sudo apt install -y jq

# Define paths for Solana CLI and constants
SOLANA_CLI="<your path to client binary>/solana"
MAINNET_RPC_URL="<mainnet rpc url>"
TESTNET_RPC_URL="<testnet rpc url>"
MAINNET_GOSSIP_FILE="<your path to>/gossip-mainnet.json"
TESTNET_GOSSIP_FILE="<your path to>/gossip-testnet.json"
DISCORD_WEBHOOK="<your discord webhook url>"
MESSAGE_FILE="<your path to>/gossip_message.txt"
MAINNET_SFDP_API_URL="https://api.solana.org/api/epoch/required_versions?cluster=mainnet-beta"
TESTNET_SFDP_API_URL="https://api.solana.org/api/epoch/required_versions?cluster=testnet"

# Arrays to store messages and data
declare -a GREEN_VALIDATORS
declare -a RED_MESSAGES
declare -A CURRENT_REQUIREMENTS
declare -A FUTURE_EPOCH_INFO
declare -A AFFECTED_VALIDATORS

# Function to map alias to pubkey, logo, type (vote or identity), and network (mainnet or testnet)
map_pubkey() {
    case "$1" in
        validator1)
            echo "<pubkey>|<logo url>|vote|mainnet"
            ;;
        validator2)
            echo "<pubkey>|<logo url>|identity|mainnet"
            ;;
        validator3)
            echo "<pubkey>|<logo url>|identity|testnet"
            ;;
        *)
            echo ""
            ;;
    esac
}

# List of all pubkeys to monitor
PUBKEY_ALIASES=(
    "validator1" "validator2" "validator3"
)

# Function to map vote pubkey to identity pubkey using API
map_vote_to_identity() {
    local vote_pubkey="$1"
    local api_url="<your api url>/$vote_pubkey"
    
    local response=$(curl -s --max-time 10 --retry 2 --retry-delay 1 "$api_url")
    if [ $? -ne 0 ]; then
        echo "Error: Failed to fetch data from $api_url" >&2
        return 1
    fi
    
    if [ -z "$response" ]; then
        echo "Error: Empty response from $api_url" >&2
        return 1
    fi
    
    local identity_pubkey=$(echo "$response" | jq -r '
        if type == "object" and has("error") then
            empty
        else
            (if type == "array" then .[0] else . end) | 
            .identity_pubkey // empty
        end
    ')
    
    if [ $? -ne 0 ]; then
        echo "Error: Failed to parse JSON response for pubkey $vote_pubkey" >&2
        return 1
    fi
    
    if [ -z "$identity_pubkey" ]; then
        echo "Error: No identity pubkey found for vote pubkey $vote_pubkey" >&2
        return 1
    fi
    
    echo "$identity_pubkey"
    return 0
}

# Function to compare versions
compare_versions() {
    # Compare two semver-style versions (e.g., 4.0.0-beta.4 >= 4.0.0-beta.3)
    # Returns 0 (true) if ver1 >= ver2, 1 (false) otherwise
    # Handles pre-release tags: alpha < beta < rc < (release)
    local ver1="$1"
    local ver2="$2"
    if [ -z "$ver1" ] || [ -z "$ver2" ]; then
        return 1
    fi

    # Split on hyphen: base version vs pre-release tag
    local ver1_base="${ver1%%-*}"
    local ver2_base="${ver2%%-*}"
    local ver1_pre="" ver2_pre=""
    [[ "$ver1" == *-* ]] && ver1_pre="${ver1#*-}"
    [[ "$ver2" == *-* ]] && ver2_pre="${ver2#*-}"

    # Compare base version parts (major.minor.patch)
    local IFS=.
    local i ver1_parts=($ver1_base) ver2_parts=($ver2_base)
    for ((i=0; i<${#ver1_parts[@]}; i++)); do
        if [ -z "${ver2_parts[i]}" ]; then
            return 0
        fi
        if [ "${ver1_parts[i]}" -gt "${ver2_parts[i]}" ] 2>/dev/null; then
            return 0
        elif [ "${ver1_parts[i]}" -lt "${ver2_parts[i]}" ] 2>/dev/null; then
            return 1
        fi
    done
    # Check if ver2 has more base parts (e.g., 4.0 vs 4.0.1)
    if [ ${#ver2_parts[@]} -gt ${#ver1_parts[@]} ]; then
        for ((i=${#ver1_parts[@]}; i<${#ver2_parts[@]}; i++)); do
            if [ "${ver2_parts[i]}" -gt 0 ] 2>/dev/null; then
                return 1
            fi
        done
    fi

    # Base versions equal — compare pre-release tags
    # No pre-release > any pre-release (4.0.0 > 4.0.0-beta.4)
    if [ -z "$ver1_pre" ] && [ -n "$ver2_pre" ]; then
        return 0
    elif [ -n "$ver1_pre" ] && [ -z "$ver2_pre" ]; then
        return 1
    elif [ -z "$ver1_pre" ] && [ -z "$ver2_pre" ]; then
        return 0
    fi

    # Both have pre-release tags — compare them
    # Extract tag type and number (e.g., "beta.4" -> "beta" "4")
    local ver1_tag="${ver1_pre%%.*}"
    local ver2_tag="${ver2_pre%%.*}"
    local ver1_num="${ver1_pre#*.}"
    local ver2_num="${ver2_pre#*.}"
    # If no dot in pre-release, num is empty
    [[ "$ver1_pre" != *"."* ]] && ver1_num="0"
    [[ "$ver2_pre" != *"."* ]] && ver2_num="0"

    # Rank: alpha=1, beta=2, rc=3
    local ver1_rank=0 ver2_rank=0
    case "$ver1_tag" in alpha) ver1_rank=1;; beta) ver1_rank=2;; rc) ver1_rank=3;; esac
    case "$ver2_tag" in alpha) ver2_rank=1;; beta) ver2_rank=2;; rc) ver2_rank=3;; esac

    if [ "$ver1_rank" -gt "$ver2_rank" ]; then
        return 0
    elif [ "$ver1_rank" -lt "$ver2_rank" ]; then
        return 1
    fi

    # Same tag type — compare numeric suffix
    if [ "$ver1_num" -gt "$ver2_num" ] 2>/dev/null; then
        return 0
    elif [ "$ver1_num" -lt "$ver2_num" ] 2>/dev/null; then
        return 1
    fi

    return 0
}

# Function to check version compliance
check_version_compliance() {
    local version="$1"
    local min_version="$2"
    local max_version="$3"
    local version_type="$4"
    
    local min_compliant="true"
    if [ -n "$min_version" ] && ! compare_versions "$version" "$min_version"; then
        min_compliant="false"
    fi
    
    local max_compliant="true"
    if [ -n "$max_version" ] && compare_versions "$version" "$max_version"; then
        max_compliant="false"
    fi
    
    if [ "$min_compliant" = "true" ] && [ "$max_compliant" = "true" ]; then
        echo "✅ Green: $version_type Version $version is within required range (Min: ${min_version:-N/A}, Max: ${max_version:-N/A})"
        return 0
    else
        local error_msg="❌ Red: $version_type Version $version is out of range"
        [ "$min_compliant" = "false" ] && error_msg="$error_msg, below min $min_version"
        [ "$max_compliant" = "false" ] && error_msg="$error_msg, above max $max_version"
        echo "$error_msg"
        return 1
    fi
}

# Process each pubkey
for ALIAS in "${PUBKEY_ALIASES[@]}"; do
    PUBKEY_INFO=$(map_pubkey "$ALIAS")
    if [ -z "$PUBKEY_INFO" ]; then
        echo "Error: Failed to map alias '$ALIAS' to pubkey" >&2
        continue
    fi

    # Split pubkey, logo, type, and network
    PUBKEY=$(echo "$PUBKEY_INFO" | cut -d'|' -f1)
    VALIDATOR_LOGO=$(echo "$PUBKEY_INFO" | cut -d'|' -f2)
    PUBKEY_TYPE=$(echo "$PUBKEY_INFO" | cut -d'|' -f3)
    NETWORK=$(echo "$PUBKEY_INFO" | cut -d'|' -f4)

    # Set RPC URL, gossip file, and SFDP API URL based on network
    if [ "$NETWORK" = "mainnet" ]; then
        RPC_URL="$MAINNET_RPC_URL"
        GOSSIP_FILE="$MAINNET_GOSSIP_FILE"
        SFDP_API_URL="$MAINNET_SFDP_API_URL"
    elif [ "$NETWORK" = "testnet" ]; then
        RPC_URL="$TESTNET_RPC_URL"
        GOSSIP_FILE="$TESTNET_GOSSIP_FILE"
        SFDP_API_URL="$TESTNET_SFDP_API_URL"
    else
        echo "Error: Invalid network '$NETWORK' for alias '$ALIAS'." >&2
        continue
    fi

    # Get current epoch for the network
    CURRENT_EPOCH=$("$SOLANA_CLI" epoch --url "$RPC_URL")
    if [ -z "$CURRENT_EPOCH" ]; then
        echo "Error: Failed to retrieve the current epoch for $NETWORK." >&2
        continue
    fi

    # Fetch required versions from SFDP API
    SFDP_RESPONSE=$(curl -s --max-time 10 --retry 2 --retry-delay 1 "$SFDP_API_URL")
    if [ $? -ne 0 ]; then
        echo "Error: Failed to fetch data from $SFDP_API_URL" >&2
        continue
    fi

    if [ -z "$SFDP_RESPONSE" ]; then
        echo "Error: Empty response from $SFDP_API_URL" >&2
        continue
    fi

    # Find the closest epoch <= current epoch and check for future epoch
    CLOSEST_EPOCH_DATA=$(echo "$SFDP_RESPONSE" | jq -r '
        .data |
        map(select(.epoch <= '"$CURRENT_EPOCH"')) |
        sort_by(.epoch) | last
    ')
    FUTURE_EPOCH_DATA=$(echo "$SFDP_RESPONSE" | jq -r '
        .data |
        map(select(.epoch > '"$CURRENT_EPOCH"' and .inherited_from_prev_epoch == false)) |
        sort_by(.epoch) | first
    ')

    if [ -z "$CLOSEST_EPOCH_DATA" ]; then
        echo "Error: No valid epoch data found for epoch <= $CURRENT_EPOCH on $NETWORK" >&2
        continue
    fi

    # Extract current version requirements
    CLOSEST_EPOCH=$(echo "$CLOSEST_EPOCH_DATA" | jq -r '.epoch // empty')
    AGAVE_MIN_VERSION=$(echo "$CLOSEST_EPOCH_DATA" | jq -r '.agave_min_version // empty')
    AGAVE_MAX_VERSION=$(echo "$CLOSEST_EPOCH_DATA" | jq -r '.agave_max_version // empty')
    FIREDANCER_MIN_VERSION=$(echo "$CLOSEST_EPOCH_DATA" | jq -r '.firedancer_min_version // empty')
    FIREDANCER_MAX_VERSION=$(echo "$CLOSEST_EPOCH_DATA" | jq -r '.firedancer_max_version // empty')

    # Store current requirements
    CURRENT_REQUIREMENTS["$NETWORK"]="\nCurrent Requirements for $NETWORK (Epoch $CLOSEST_EPOCH):\n"
    CURRENT_REQUIREMENTS["$NETWORK"]+="Agave Min Version: ${AGAVE_MIN_VERSION:-N/A}\n"
    CURRENT_REQUIREMENTS["$NETWORK"]+="Agave Max Version: ${AGAVE_MAX_VERSION:-N/A}\n"
    CURRENT_REQUIREMENTS["$NETWORK"]+="Firedancer Min Version: ${FIREDANCER_MIN_VERSION:-N/A}\n"
    CURRENT_REQUIREMENTS["$NETWORK"]+="Firedancer Max Version: ${FIREDANCER_MAX_VERSION:-N/A}\n"

    # Extract future version requirements if applicable
    FUTURE_EPOCH=$(echo "$FUTURE_EPOCH_DATA" | jq -r '.epoch // empty')
    FUTURE_AGAVE_MIN_VERSION=$(echo "$FUTURE_EPOCH_DATA" | jq -r '.agave_min_version // empty')
    FUTURE_AGAVE_MAX_VERSION=$(echo "$FUTURE_EPOCH_DATA" | jq -r '.agave_max_version // empty')
    FUTURE_FIREDANCER_MIN_VERSION=$(echo "$FUTURE_EPOCH_DATA" | jq -r '.firedancer_min_version // empty')
    FUTURE_FIREDANCER_MAX_VERSION=$(echo "$FUTURE_EPOCH_DATA" | jq -r '.firedancer_max_version // empty')

    # Store future epoch info for the network if applicable
    if [ -n "$FUTURE_EPOCH" ]; then
        FUTURE_EPOCH_INFO["$NETWORK"]="\n⚠️ Upcoming Requirement for Epoch $FUTURE_EPOCH ($NETWORK)\n"
        FUTURE_EPOCH_INFO["$NETWORK"]+="Future Agave Min Version: ${FUTURE_AGAVE_MIN_VERSION:-N/A}\n"
        FUTURE_EPOCH_INFO["$NETWORK"]+="Future Agave Max Version: ${FUTURE_AGAVE_MAX_VERSION:-N/A}\n"
        FUTURE_EPOCH_INFO["$NETWORK"]+="Future Firedancer Min Version: ${FUTURE_FIREDANCER_MIN_VERSION:-N/A}\n"
        FUTURE_EPOCH_INFO["$NETWORK"]+="Future Firedancer Max Version: ${FUTURE_FIREDANCER_MAX_VERSION:-N/A}\n"
    fi

    # Dump gossip data to file for the network
    "$SOLANA_CLI" gossip --url "$RPC_URL" --output json > "$GOSSIP_FILE"
    if [ $? -ne 0 ]; then
        echo "Error: Failed to dump gossip data to $GOSSIP_FILE for $NETWORK" >&2
        continue
    fi

    # Determine validator identity based on pubkey type
    if [ "$PUBKEY_TYPE" = "vote" ]; then
        VALIDATOR_IDENTITY=$(map_vote_to_identity "$PUBKEY")
        if [ $? -ne 0 ]; then
            echo "Error: Failed to map vote pubkey '$PUBKEY' to validator identity." >&2
            continue
        fi
    elif [ "$PUBKEY_TYPE" = "identity" ]; then
        VALIDATOR_IDENTITY="$PUBKEY"
    else
        echo "Error: Invalid pubkey type '$PUBKEY_TYPE' for alias '$ALIAS'." >&2
        continue
    fi
    echo "Validator identity for pubkey $PUBKEY ($ALIAS): $VALIDATOR_IDENTITY"

    # Check validator's current version from gossip
    VALIDATOR_VERSION=$(jq -r --arg id "$VALIDATOR_IDENTITY" '
        .[] | select(.identityPubkey == $id) | .version // empty
    ' "$GOSSIP_FILE")
    if [ -z "$VALIDATOR_VERSION" ]; then
        echo "Error: No version found for validator $VALIDATOR_IDENTITY in gossip data on $NETWORK" >&2
        continue
    fi

    # Determine version type based on major version
    # Agave: 2.x.x, 3.x.x, or 4.x.x, Firedancer: 0.x.x
    MAJOR_VERSION=$(echo "$VALIDATOR_VERSION" | cut -d'.' -f1)
    if [ "$MAJOR_VERSION" = "2" ] || [ "$MAJOR_VERSION" = "3" ] || [ "$MAJOR_VERSION" = "4" ]; then
        VERSION_TYPE="Agave"
        VERSION_STATUS=$(check_version_compliance "$VALIDATOR_VERSION" "$AGAVE_MIN_VERSION" "$AGAVE_MAX_VERSION" "$VERSION_TYPE")
        STATUS_CODE=$?
        MIN_VERSION="$AGAVE_MIN_VERSION"
        MAX_VERSION="$AGAVE_MAX_VERSION"
    elif [ "$MAJOR_VERSION" = "0" ]; then
        VERSION_TYPE="Firedancer"
        VERSION_STATUS=$(check_version_compliance "$VALIDATOR_VERSION" "$FIREDANCER_MIN_VERSION" "$FIREDANCER_MAX_VERSION" "$VERSION_TYPE")
        STATUS_CODE=$?
        MIN_VERSION="$FIREDANCER_MIN_VERSION"
        MAX_VERSION="$FIREDANCER_MAX_VERSION"
    else
        VERSION_STATUS="❌ Red: Unknown version type for $VALIDATOR_VERSION"
        STATUS_CODE=1
        MIN_VERSION="N/A"
        MAX_VERSION="N/A"
    fi

    # Check if validator is affected by future requirements
    if [ -n "$FUTURE_EPOCH" ]; then
        if [ "$VERSION_TYPE" = "Agave" ] && [ -n "$FUTURE_AGAVE_MIN_VERSION" ] && ! compare_versions "$VALIDATOR_VERSION" "$FUTURE_AGAVE_MIN_VERSION"; then
            AFFECTED_VALIDATORS["$NETWORK"]+="- $ALIAS ($NETWORK): Current $VERSION_TYPE Version $VALIDATOR_VERSION < Future Min $FUTURE_AGAVE_MIN_VERSION\n"
        elif [ "$VERSION_TYPE" = "Firedancer" ] && [ -n "$FUTURE_FIREDANCER_MIN_VERSION" ] && ! compare_versions "$VALIDATOR_VERSION" "$FUTURE_FIREDANCER_MIN_VERSION"; then
            AFFECTED_VALIDATORS["$NETWORK"]+="- $ALIAS ($NETWORK): Current $VERSION_TYPE Version $VALIDATOR_VERSION < Future Min $FUTURE_FIREDANCER_MIN_VERSION\n"
        fi
    fi

    # Prepare message with separator lines
    MESSAGE="---\n"
    MESSAGE+="Version Monitor - $ALIAS ($NETWORK)\n"
    MESSAGE+="Current Epoch: $CURRENT_EPOCH\n"
    MESSAGE+="Closest Epoch: $CLOSEST_EPOCH\n"
    MESSAGE+="Validator Identity: $VALIDATOR_IDENTITY\n"
    MESSAGE+="Running $VERSION_TYPE Version: $VALIDATOR_VERSION\n"
    MESSAGE+="Required $VERSION_TYPE Min Version: ${MIN_VERSION:-N/A}\n"
    MESSAGE+="Required $VERSION_TYPE Max Version: ${MAX_VERSION:-N/A}\n"
    MESSAGE+="Status: $VERSION_STATUS\n"

    if [ -n "$FUTURE_EPOCH" ]; then
        MESSAGE+="\n⚠️ Upcoming Requirement for Epoch $FUTURE_EPOCH\n"
        if [ "$VERSION_TYPE" = "Agave" ]; then
            MESSAGE+="Future $VERSION_TYPE Min Version: ${FUTURE_AGAVE_MIN_VERSION:-N/A}\n"
            MESSAGE+="Future $VERSION_TYPE Max Version: ${FUTURE_AGAVE_MAX_VERSION:-N/A}\n"
        elif [ "$VERSION_TYPE" = "Firedancer" ]; then
            MESSAGE+="Future $VERSION_TYPE Min Version: ${FUTURE_FIREDANCER_MIN_VERSION:-N/A}\n"
            MESSAGE+="Future $VERSION_TYPE Max Version: ${FUTURE_FIREDANCER_MAX_VERSION:-N/A}\n"
        fi
    fi
    MESSAGE+="---\n"

    # Store messages based on status
    if [ $STATUS_CODE -eq 0 ]; then
        GREEN_VALIDATORS+=("$ALIAS ($NETWORK): $VERSION_TYPE Version $VALIDATOR_VERSION")
    else
        RED_MESSAGES+=("{\"username\":\"VersionMonitorBot\",\"avatar_url\":\"$VALIDATOR_LOGO\",\"content\":\"$(echo "$MESSAGE" | sed 's/"/\\"/g')\"}")
    fi
done

# Send single Discord message for all green validators
GREEN_MESSAGE="---\n"
GREEN_MESSAGE+="Version Monitor - Validator Status\n"
GREEN_MESSAGE+="Current Epoch: $CURRENT_EPOCH\n"

# Add current requirements
for network in "${!CURRENT_REQUIREMENTS[@]}"; do
    GREEN_MESSAGE+="${CURRENT_REQUIREMENTS[$network]}"
done

if [ ${#GREEN_VALIDATORS[@]} -gt 0 ]; then
    GREEN_MESSAGE+="\nCompliant Validators:\n"
    for validator in "${GREEN_VALIDATORS[@]}"; do
        GREEN_MESSAGE+="- $validator\n"
    done
else
    GREEN_MESSAGE+="\nNo Compliant Validators\n"
fi

# Add affected validators for future epochs
for network in "${!FUTURE_EPOCH_INFO[@]}"; do
    GREEN_MESSAGE+="${FUTURE_EPOCH_INFO[$network]}"
    if [ -n "${AFFECTED_VALIDATORS[$network]}" ]; then
        GREEN_MESSAGE+="Affected Validators:\n${AFFECTED_VALIDATORS[$network]}"
    else
        GREEN_MESSAGE+="No Validators Affected\n"
    fi
done
GREEN_MESSAGE+="---\n"

cat > "$MESSAGE_FILE" << EOF
$GREEN_MESSAGE
EOF

if [ ! -f "$MESSAGE_FILE" ] || [ ! -r "$MESSAGE_FILE" ]; then
    echo "Error: Failed to create message file '$MESSAGE_FILE' for green validators." >&2
else
    echo "Green validators message file content:"
    cat "$MESSAGE_FILE"
    echo "----------------------------------------"

    curl -H "Content-Type: application/json" \
         -X POST \
         -d "{\"username\":\"VersionMonitorBot\",\"content\":\"$(cat "$MESSAGE_FILE" | sed 's/"/\\"/g')\"}" \
         "$DISCORD_WEBHOOK"

    if [ $? -eq 0 ]; then
        echo "Discord alert sent successfully for validator status in epoch $CURRENT_EPOCH."
    else
        echo "Error: Failed to send Discord alert for validator status." >&2
    fi

    sleep 1
fi

# Send individual Discord messages for each red occurrence
for red_message in "${RED_MESSAGES[@]}"; do
    cat > "$MESSAGE_FILE" << EOF
$(echo "$red_message" | jq -r '.content' | sed 's/\\"/"/g')
EOF

    if [ ! -f "$MESSAGE_FILE" ] || [ ! -r "$MESSAGE_FILE" ]; then
        echo "Error: Failed to create message file '$MESSAGE_FILE' for red validator." >&2
        continue
    fi

    echo "Red validator message file content:"
    cat "$MESSAGE_FILE"
    echo "----------------------------------------"

    curl -H "Content-Type: application/json" \
         -X POST \
         -d "$red_message" \
         "$DISCORD_WEBHOOK"

    if [ $? -eq 0 ]; then
        echo "Discord alert sent successfully for non-compliant validator in epoch $CURRENT_EPOCH."
    else
        echo "Error: Failed to send Discord alert for non-compliant validator." >&2
    fi

    sleep 1
done
