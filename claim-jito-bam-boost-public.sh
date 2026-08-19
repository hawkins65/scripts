#!/usr/bin/env bash
#
# claim-jito-bam-boost.sh - Claim Jito BAM Boost rewards across multiple epochs
#
# Scans all eligible epochs (default 912 through current-1) for unclaimed
# Jito BAM Boost rewards and claims them. Sends a single Discord summary
# when finished.
#
# REQUIREMENTS:
#   - Rust / cargo          https://rustup.rs
#   - jito-bam-boost-cli    git clone https://github.com/jito-foundation/jito-bam-boost-cli
#   - solana-cli            https://docs.solanalabs.com/cli/install
#   - jq                    brew install jq  /  apt install jq
#   - bc                    (pre-installed on most systems)
#   - curl                  (pre-installed on most systems)
#   - Discord webhook URL   (optional, for notifications)
#
# SETUP:
#   git clone https://github.com/jito-foundation/jito-bam-boost-cli.git
#   # The script uses "cargo run" from this directory — no manual build needed.
#
# CONFIGURATION:
#   All settings are read from environment variables. You can export them in
#   your shell profile, pass them inline, or use a .env wrapper script.
#
#   Required:
#     JITO_BAM_BOOST_DIR    Path to the jito-bam-boost-cli repo clone
#     SIGNER_KEYPAIR        Path to the validator signer keypair JSON file
#     WALLET_ADDRESS        Public key of the wallet to check/claim for
#     SOLANA_PATH           Directory containing solana/spl-token binaries
#                           (include trailing slash, e.g. /usr/local/bin/)
#
#   Optional:
#     RPC_URL               Solana RPC endpoint (default: public mainnet-beta)
#                           A private RPC (QuikNode, Helius, Triton, etc.) is
#                           recommended for reliability and rate limits.
#     DISCORD_WEBHOOK_URL   Discord webhook for notifications (skip to disable)
#     DISCORD_USERNAME      Bot display name    (default: "Jito BAM Boost Claim Bot")
#     DISCORD_AVATAR_URL    Bot avatar URL       (default: empty)
#     FIRST_EPOCH           First epoch to scan  (default: 912)
#     DEBUG                 Set to "true" for verbose output
#
# USAGE:
#   # Scan all epochs from FIRST_EPOCH to current-1:
#   ./claim-jito-bam-boost.sh
#
#   # Check/claim a single epoch:
#   ./claim-jito-bam-boost.sh 950
#
# EXAMPLE .env wrapper:
#   #!/usr/bin/env bash
#   export JITO_BAM_BOOST_DIR="$HOME/jito-bam-boost-cli"
#   export SIGNER_KEYPAIR="$HOME/.config/solana/id.json"
#   export WALLET_ADDRESS="YourWa11etAddressHere"
#   export SOLANA_PATH="$HOME/.local/share/solana/install/active_release/bin/"
#   # Optional — defaults to public mainnet-beta RPC if not set:
#   # export RPC_URL="https://your-private-rpc.example.com/"
#   # export DISCORD_WEBHOOK_URL="https://discord.com/api/webhooks/..."
#   exec ./claim-jito-bam-boost.sh "$@"
#
# PRICES:
#   Uses the free CoinGecko API (no API key required) for JitoSOL and SOL
#   USD price lookups.
#
# OUTPUT:
#   Console shows one compact line per epoch:
#     Epoch 912: already claimed
#     Epoch 913: no rewards
#     Epoch 914: CLAIMED 0.01234 JitoSOL ($2.45)
#   A single Discord message is sent at the end summarising all results.
#   Full output is also written to ~/logs/claim-jito-bam-boost_<timestamp>.log
#

set -euo pipefail

###############################################
# Logging Configuration
###############################################

LOG_DIR="$HOME/logs"
if ! mkdir -p "$LOG_DIR"; then
    echo "[ERROR] Failed to create log directory: $LOG_DIR"
    exit 1
fi

LOG_FILE="$LOG_DIR/$(basename "$0" .sh)_$(date +'%Y-%m-%d_%H-%M-%S').log"
if ! touch "$LOG_FILE" 2>/dev/null; then
    echo "[ERROR] Cannot write to log file: $LOG_FILE"
    exit 1
fi

exec &> >(stdbuf -oL tee -a "$LOG_FILE" 2>>"$LOG_FILE")

###############################################
# Configuration (from environment variables)
###############################################

# Required - script exits if any of these are unset/empty
: "${JITO_BAM_BOOST_DIR:?Set JITO_BAM_BOOST_DIR to the jito-bam-boost-cli repo directory}"
: "${SIGNER_KEYPAIR:?Set SIGNER_KEYPAIR to the path of your validator keypair JSON}"
: "${WALLET_ADDRESS:?Set WALLET_ADDRESS to your validator public key}"
: "${SOLANA_PATH:?Set SOLANA_PATH to the directory containing solana/spl-token binaries}"

# Optional with defaults
RPC_URL="${RPC_URL:-https://api.mainnet-beta.solana.com}"
DISCORD_WEBHOOK_URL="${DISCORD_WEBHOOK_URL:-}"
DISCORD_USERNAME="${DISCORD_USERNAME:-Jito BAM Boost Claim Bot}"
DISCORD_AVATAR_URL="${DISCORD_AVATAR_URL:-}"
LEDGER_WALLET="${LEDGER_WALLET:-}"
FIRST_EPOCH="${FIRST_EPOCH:-912}"
DEBUG="${DEBUG:-false}"

# Public constants
JITOSOL_MINT="J1toso1uCk3RLmjorhTtrVwY9HJ7X8V9yYac6Y7kGCPn"
JITO_API_BASE="https://kobe.mainnet.jito.network/api/v1/claim/mainnet"
COINGECKO_URL="https://api.coingecko.com/api/v3/simple/price?ids=jito-staked-sol,solana&vs_currencies=usd"

MONEY_BAG="💰"
WARNING_EMOJI="🚨"
ROCKET_EMOJI="🚀"
SCRIPT_NAME="$(basename "$0")"

# Severity colors (decimal for Discord embeds)
COLOR_OK=5361510        # 0x51CF66 green
COLOR_INFO=3382000      # 0x339AF0 blue
COLOR_WARNING=16002055  # 0xF4AC07 gold
COLOR_ERROR=16738155    # 0xFF6B6B red
SCRIPT_PATH="$(readlink -f "$0")"

###############################################
# Common Functions
###############################################

debug_log() {
    if [ "$DEBUG" = true ]; then
        echo "[DEBUG] $1"
    fi
}

add_thousands_separator() {
    local number="$1"
    if [[ ! "$number" =~ ^[0-9]+(\.[0-9]{1,})?$ || "$number" = "0" || "$number" = "0.00" ]]; then
        echo "0.00"
        return
    fi
    local integer_part="${number%.*}"
    local decimal_part="${number#*.}"
    if [ "$decimal_part" = "$number" ]; then
        decimal_part="00"
    fi
    local formatted_integer=""
    local len=${#integer_part}
    local i=$len
    while [ $i -gt 0 ]; do
        local start=$((i - 3))
        if [ $start -lt 0 ]; then
            start=0
        fi
        local chunk="${integer_part:$start:$((i - start))}"
        formatted_integer="$chunk${formatted_integer:+,}$formatted_integer"
        i=$((i - 3))
    done
    echo "$formatted_integer.$decimal_part"
}

is_valid_number() {
    local value="$1"
    if [[ "$value" =~ ^[0-9]+(\.[0-9]+)?$ && "$value" != "0" ]]; then
        return 0
    fi
    return 1
}

send_discord_embed() {
    local severity="$1"
    local title="$2"
    local description="$3"

    if [ -z "$DISCORD_WEBHOOK_URL" ]; then
        debug_log "Discord webhook not configured, skipping notification."
        return
    fi

    local color
    case "$severity" in
        ok)      color=$COLOR_OK ;;
        info)    color=$COLOR_INFO ;;
        warning) color=$COLOR_WARNING ;;
        error)   color=$COLOR_ERROR ;;
        *)       color=$COLOR_INFO ;;
    esac

    local footer_ts
    footer_ts=$(date -u '+%Y-%m-%d %H:%M UTC')

    local payload
    payload=$(jq -n \
        --arg username "$DISCORD_USERNAME" \
        --arg avatar_url "$DISCORD_AVATAR_URL" \
        --arg title "$title" \
        --arg desc "$description" \
        --argjson color "$color" \
        --arg footer "${SCRIPT_PATH} • ${footer_ts}" \
        --argjson flags 4 \
        '{username: $username, avatar_url: $avatar_url, embeds: [{title: $title, description: $desc, color: $color, footer: {text: $footer}}]}')

    debug_log "Sending embed to Discord..."
    local discord_response
    discord_response=$(curl -s -H "Content-Type: application/json" -X POST -d "$payload" "$DISCORD_WEBHOOK_URL" 2>&1)
    if [ $? -ne 0 ]; then
        echo "[ERROR] Failed to send message to Discord: $discord_response"
    fi
}

handle_error() {
    local error_msg="$1"
    local should_exit="${2:-true}"

    echo "[ERROR] $error_msg"

    send_discord_embed "error" "❌ BAM Boost Claim — Error" "$(printf '%s\n\nScript: %s\nTime: %s' "$error_msg" "$SCRIPT_NAME" "$(date -u +'%Y-%m-%d %H:%M:%S UTC')")"

    if [ "$should_exit" = "true" ]; then
        exit 1
    fi
}

# Sets global variables: JITOSOL_PRICE, SOL_PRICE, JITOSOL_TO_SOL_RATE
# Uses the free CoinGecko API (no API key required).
fetch_prices() {
    debug_log "Fetching JitoSOL and SOL prices from CoinGecko..."
    local response=$(curl -s --max-time 15 "$COINGECKO_URL" 2>&1)
    if [[ $? -ne 0 ]]; then
        echo "[ERROR] Failed to fetch data from CoinGecko: $response"
        JITOSOL_PRICE="0"
        SOL_PRICE="0"
        JITOSOL_TO_SOL_RATE="1"
        return
    fi

    # CoinGecko response: {"jito-staked-sol":{"usd":110.85},"solana":{"usd":88.0}}
    JITOSOL_PRICE=$(echo "$response" | jq -r '.["jito-staked-sol"].usd // empty' 2>/dev/null)
    SOL_PRICE=$(echo "$response" | jq -r '.solana.usd // empty' 2>/dev/null)

    if [[ -z "$JITOSOL_PRICE" || ! "$JITOSOL_PRICE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "[ERROR] Invalid JitoSOL price value: '$JITOSOL_PRICE'"
        JITOSOL_PRICE="0"
    fi

    if [[ -z "$SOL_PRICE" || ! "$SOL_PRICE" =~ ^[0-9]+(\.[0-9]+)?$ ]]; then
        echo "[ERROR] Invalid SOL price value: '$SOL_PRICE'"
        SOL_PRICE="0"
    fi

    if is_valid_number "$JITOSOL_PRICE" && is_valid_number "$SOL_PRICE"; then
        JITOSOL_TO_SOL_RATE=$(echo "scale=6; $JITOSOL_PRICE / $SOL_PRICE" | bc 2>/dev/null)
    else
        JITOSOL_TO_SOL_RATE="1"
    fi

    debug_log "JitoSOL: \$$JITOSOL_PRICE, SOL: \$$SOL_PRICE, Rate: $JITOSOL_TO_SOL_RATE SOL/JitoSOL"
}

jitosol_to_sol() {
    local jitosol_amount="$1"
    if is_valid_number "$jitosol_amount" && is_valid_number "$JITOSOL_TO_SOL_RATE"; then
        local result=$(echo "scale=5; $jitosol_amount * $JITOSOL_TO_SOL_RATE" | bc 2>/dev/null)
        [[ "$result" == .* ]] && result="0$result"
        echo "$result"
    else
        echo "0"
    fi
}

jitosol_to_usd() {
    local jitosol_amount="$1"
    if is_valid_number "$jitosol_amount" && is_valid_number "$JITOSOL_PRICE"; then
        local result=$(echo "scale=2; $jitosol_amount * $JITOSOL_PRICE" | bc 2>/dev/null)
        [[ "$result" == .* ]] && result="0$result"
        echo "$result"
    else
        echo "0"
    fi
}

validate_configuration() {
    local errors=""

    if ! command -v cargo &>/dev/null; then
        errors+="cargo not found — install Rust via https://rustup.rs"$'\n'
    fi

    # Interactive check: offer to clone the repo if it's missing
    if [ ! -f "$JITO_BAM_BOOST_DIR/Cargo.toml" ]; then
        local clone_cmd="git clone https://github.com/jito-foundation/jito-bam-boost-cli.git \"$JITO_BAM_BOOST_DIR\""
        echo ""
        echo "jito-bam-boost-cli repo not found at: $JITO_BAM_BOOST_DIR"
        echo ""
        echo "To clone it, run:"
        echo "  $clone_cmd"
        echo ""
        # Only prompt if stdin is a terminal (skip in cron / non-interactive)
        if [ -t 0 ]; then
            read -rp "Clone it now? [y/N] " answer
            if [[ "$answer" =~ ^[Yy]$ ]]; then
                echo "Cloning jito-bam-boost-cli..."
                if git clone https://github.com/jito-foundation/jito-bam-boost-cli.git "$JITO_BAM_BOOST_DIR"; then
                    echo "Clone successful."
                else
                    errors+="git clone failed"$'\n'
                fi
            else
                errors+="jito-bam-boost-cli repo not found at: $JITO_BAM_BOOST_DIR"$'\n'
            fi
        else
            errors+="jito-bam-boost-cli repo not found at: $JITO_BAM_BOOST_DIR"$'\n'
        fi
    fi

    if [ ! -x "${SOLANA_PATH}solana" ]; then
        errors+="Solana CLI not found at ${SOLANA_PATH}solana"$'\n'
    fi

    if [ ! -f "$SIGNER_KEYPAIR" ]; then
        errors+="Signer keypair file not found: $SIGNER_KEYPAIR"$'\n'
    fi

    if ! curl -s --max-time 10 "$RPC_URL" >/dev/null; then
        errors+="Cannot connect to Solana RPC: $RPC_URL"$'\n'
    fi

    if [ -n "$errors" ]; then
        handle_error "Configuration validation failed:"$'\n'"$errors"
    fi

    debug_log "Configuration validation passed"
}

get_current_epoch() {
    local epoch_info=$("${SOLANA_PATH}solana" epoch-info -u "$RPC_URL" 2>/dev/null)
    local current_epoch=$(echo "$epoch_info" | grep "Epoch:" | awk '{print $2}')
    echo "$current_epoch"
}

# Returns: "already_claimed", "eligible", or "not_eligible"
check_claim_status() {
    local epoch="$1"
    local wallet="$2"

    debug_log "Checking claim status for epoch $epoch..."

    local api_response=$(curl -s --max-time 15 "${JITO_API_BASE}/${epoch}/${wallet}" 2>&1)

    local claim_status_address=$(echo "$api_response" | jq -r '.claim_status_address // empty' 2>/dev/null)
    local amount=$(echo "$api_response" | jq -r '.amount // empty' 2>/dev/null)

    if [ -z "$claim_status_address" ] || [ -z "$amount" ]; then
        debug_log "No claim data found for epoch $epoch"
        echo "not_eligible"
        return
    fi

    debug_log "Found claim_status_address: $claim_status_address"
    debug_log "Claimable amount: $amount (in lamports)"

    CLAIM_STATUS_ADDRESS="$claim_status_address"
    CLAIMABLE_AMOUNT="$amount"

    local account_check=$("${SOLANA_PATH}solana" account "$claim_status_address" -u "$RPC_URL" 2>&1)

    if echo "$account_check" | grep -q "Public Key:"; then
        debug_log "Claim status account exists - already claimed"
        echo "already_claimed"
    else
        debug_log "Claim status account not found - eligible to claim"
        echo "eligible"
    fi
}

# Runs the claim CLI command for a single epoch via cargo run.
# Echoes a transaction ID on success, "already_claimed", or "error: <details>".
claim_epoch() {
    local epoch="$1"

    debug_log "Running claim for epoch $epoch..."

    local output=$(cargo run --release -p jito-bam-boost-cli \
        --manifest-path "$JITO_BAM_BOOST_DIR/Cargo.toml" -- \
        bam-boost \
        merkle-distributor \
        claim \
        --network mainnet \
        --epoch "$epoch" \
        --rpc-url "$RPC_URL" \
        --signer "$SIGNER_KEYPAIR" \
        --commitment confirmed \
        --jito-bam-boost-program-id BoostxbPp2ENYHGcTLYt1obpcY13HE4NojdqNWdzqSSb 2>&1)

    local exit_code=$?
    debug_log "Claim command output: $output"

    if [ $exit_code -eq 0 ]; then
        local transaction_id=$(echo "$output" | grep -oE '[1-9A-HJ-NP-Za-km-z]{87,88}' | head -1)
        if [ -n "$transaction_id" ]; then
            echo "$transaction_id"
        else
            echo "claimed"
        fi
    else
        if echo "$output" | grep -qi "already in use"; then
            echo "already_claimed"
        else
            echo "error: $output"
        fi
    fi
}

# Compresses a space-separated list of epoch numbers into ranges.
# e.g. "912 913 914 916 920 921" → "912-914, 916, 920-921"
format_epoch_range() {
    local epochs=($1)
    if [ ${#epochs[@]} -eq 0 ]; then
        echo "none"
        return
    fi

    IFS=$'\n' sorted=($(sort -n <<<"${epochs[*]}")); unset IFS

    local result=""
    local range_start="${sorted[0]}"
    local range_end="${sorted[0]}"

    for (( i=1; i<${#sorted[@]}; i++ )); do
        if [ "${sorted[$i]}" -eq $((range_end + 1)) ]; then
            range_end="${sorted[$i]}"
        else
            if [ "$range_start" -eq "$range_end" ]; then
                result+="${range_start}, "
            else
                result+="${range_start}-${range_end}, "
            fi
            range_start="${sorted[$i]}"
            range_end="${sorted[$i]}"
        fi
    done

    if [ "$range_start" -eq "$range_end" ]; then
        result+="${range_start}"
    else
        result+="${range_start}-${range_end}"
    fi

    echo "$result"
}

###############################################
# Main Script Logic
###############################################

echo "Jito BAM Boost Claim - $(date -u +"%Y-%m-%d %H:%M:%S UTC")"

validate_configuration

CURRENT_EPOCH=$(get_current_epoch)
if [ -z "$CURRENT_EPOCH" ]; then
    handle_error "Failed to fetch current epoch from Solana"
fi

# Determine epoch range
if [ -n "${1:-}" ]; then
    START_EPOCH="$1"
    END_EPOCH="$1"
    echo "Checking epoch $START_EPOCH"
else
    START_EPOCH=$FIRST_EPOCH
    END_EPOCH=$CURRENT_EPOCH
    echo "Scanning epochs $START_EPOCH to $END_EPOCH (current: $CURRENT_EPOCH)"
fi

# Fetch prices once before the loop
fetch_prices

# Get JitoSOL balance before any claims
wallet_before_output=$("${SOLANA_PATH}spl-token" balance --url "$RPC_URL" --owner "$WALLET_ADDRESS" "$JITOSOL_MINT" 2>&1)
wallet_before=$(echo "$wallet_before_output" | grep -oE '^[0-9]+\.?[0-9]*' | head -1)
if ! is_valid_number "$wallet_before"; then
    wallet_before="0"
fi

# Tracking lists
CLAIMED_EPOCHS=""
CLAIMED_AMOUNTS=""
CLAIMED_TXIDS=""
ALREADY_CLAIMED_EPOCHS=""
NOT_ELIGIBLE_EPOCHS=""
ERROR_EPOCHS=""

TOTAL_CLAIMED="0"
CLAIM_COUNT=0

# Loop through epochs
for (( epoch=START_EPOCH; epoch<=END_EPOCH; epoch++ )); do
    CLAIM_STATUS_ADDRESS=""
    CLAIMABLE_AMOUNT=""
    claim_status=$(check_claim_status "$epoch" "$WALLET_ADDRESS")

    case "$claim_status" in
        not_eligible)
            echo "  Epoch $epoch: no rewards"
            NOT_ELIGIBLE_EPOCHS+="$epoch "
            ;;
        already_claimed)
            echo "  Epoch $epoch: already claimed"
            ALREADY_CLAIMED_EPOCHS+="$epoch "
            ;;
        eligible)
            # Get balance before this claim
            balance_before_output=$("${SOLANA_PATH}spl-token" balance --url "$RPC_URL" --owner "$WALLET_ADDRESS" "$JITOSOL_MINT" 2>&1)
            balance_before=$(echo "$balance_before_output" | grep -oE '^[0-9]+\.?[0-9]*' | head -1)
            if ! is_valid_number "$balance_before"; then
                balance_before="0"
            fi

            echo "  Epoch $epoch: claiming..."
            result=$(claim_epoch "$epoch")

            if [[ "$result" == "error:"* ]]; then
                echo "  Epoch $epoch: FAILED - ${result#error: }"
                ERROR_EPOCHS+="$epoch "
            elif [[ "$result" == "already_claimed" ]]; then
                echo "  Epoch $epoch: already claimed (race)"
                ALREADY_CLAIMED_EPOCHS+="$epoch "
            else
                sleep 3

                balance_after_output=$("${SOLANA_PATH}spl-token" balance --url "$RPC_URL" --owner "$WALLET_ADDRESS" "$JITOSOL_MINT" 2>&1)
                balance_after=$(echo "$balance_after_output" | grep -oE '^[0-9]+\.?[0-9]*' | head -1)
                if ! is_valid_number "$balance_after"; then
                    balance_after="$balance_before"
                fi

                claimed_amount=$(echo "$balance_after - $balance_before" | bc 2>/dev/null)
                [[ "$claimed_amount" == .* ]] && claimed_amount="0$claimed_amount"
                if [[ -z "$claimed_amount" || "$claimed_amount" == "-"* || "$claimed_amount" == "0" ]]; then
                    claimed_amount="0"
                fi

                claimed_usd=$(jitosol_to_usd "$claimed_amount")
                claimed_usd=$(printf "%.2f" "$claimed_usd" 2>/dev/null || echo "0.00")

                txid="$result"
                echo "  Epoch $epoch: CLAIMED $claimed_amount JitoSOL (\$$claimed_usd)"

                CLAIMED_EPOCHS+="$epoch "
                CLAIMED_AMOUNTS+="$claimed_amount "
                CLAIMED_TXIDS+="$txid "
                TOTAL_CLAIMED=$(echo "$TOTAL_CLAIMED + $claimed_amount" | bc 2>/dev/null)
                [[ "$TOTAL_CLAIMED" == .* ]] && TOTAL_CLAIMED="0$TOTAL_CLAIMED"
                CLAIM_COUNT=$((CLAIM_COUNT + 1))
            fi
            ;;
        *)
            echo "  Epoch $epoch: error checking status"
            ERROR_EPOCHS+="$epoch "
            ;;
    esac
done

# Transfer claimed JitoSOL to Ledger wallet
TRANSFER_SUCCESS=""
TRANSFER_TXID=""
TRANSFER_AMOUNT=""
if [ $CLAIM_COUNT -gt 0 ] && [ -n "$LEDGER_WALLET" ]; then
    echo ""
    echo "Transferring $TOTAL_CLAIMED JitoSOL to Ledger wallet $LEDGER_WALLET..."
    transfer_output=$("${SOLANA_PATH}spl-token" transfer \
        --url "$RPC_URL" \
        --owner "$SIGNER_KEYPAIR" \
        --fund-recipient \
        --allow-unfunded-recipient \
        "$JITOSOL_MINT" "$TOTAL_CLAIMED" "$LEDGER_WALLET" 2>&1)
    transfer_exit=$?
    debug_log "Transfer output: $transfer_output"

    if [ $transfer_exit -eq 0 ]; then
        TRANSFER_TXID=$(echo "$transfer_output" | grep -oE '[1-9A-HJ-NP-Za-km-z]{87,88}' | head -1)
        TRANSFER_AMOUNT="$TOTAL_CLAIMED"
        TRANSFER_SUCCESS="true"
        echo "  Transfer successful: $TOTAL_CLAIMED JitoSOL"
        sleep 3
    else
        echo "  [ERROR] Transfer failed: $transfer_output"
        TRANSFER_SUCCESS="false"
        handle_error "Failed to transfer $TOTAL_CLAIMED JitoSOL to Ledger: $transfer_output" "false"
    fi
fi

# Get final JitoSOL balance
wallet_after_output=$("${SOLANA_PATH}spl-token" balance --url "$RPC_URL" --owner "$WALLET_ADDRESS" "$JITOSOL_MINT" 2>&1)
wallet_after=$(echo "$wallet_after_output" | grep -oE '^[0-9]+\.?[0-9]*' | head -1)
if ! is_valid_number "$wallet_after"; then
    wallet_after="0"
fi

# Format prices
jitosol_price_fmt=$(printf "%.2f" "$JITOSOL_PRICE" 2>/dev/null || echo "0.00")
jitosol_price_fmt=$(add_thousands_separator "$jitosol_price_fmt")
sol_price_fmt=$(printf "%.2f" "$SOL_PRICE" 2>/dev/null || echo "0.00")
sol_price_fmt=$(add_thousands_separator "$sol_price_fmt")

# Format balance
wallet_jitosol=$(printf "%.5f" "$wallet_after" 2>/dev/null || echo "0.00000")
wallet_sol=$(jitosol_to_sol "$wallet_after")
wallet_sol=$(printf "%.5f" "$wallet_sol" 2>/dev/null || echo "0.00000")
wallet_usd=$(jitosol_to_usd "$wallet_after")
wallet_usd=$(printf "%.2f" "$wallet_usd" 2>/dev/null || echo "0.00")
wallet_usd=$(add_thousands_separator "$wallet_usd")

# Timestamps
CURRENT_DATETIME_UTC=$(date -u +"%A, %B %d, %Y at %I:%M:%S %p UTC")
CURRENT_DATETIME_CST=$(TZ="America/Chicago" date +"%A, %B %d, %Y at %I:%M:%S %p %Z")
TIMESTAMP_INFO="Report generated at $CURRENT_DATETIME_UTC ($CURRENT_DATETIME_CST)"

# Build summary
already_claimed_fmt=$(format_epoch_range "$ALREADY_CLAIMED_EPOCHS")
not_eligible_fmt=$(format_epoch_range "$NOT_ELIGIBLE_EPOCHS")
error_fmt=$(format_epoch_range "$ERROR_EPOCHS")

# Build claimed details section
claimed_details=""
if [ $CLAIM_COUNT -gt 0 ]; then
    claimed_epoch_arr=($CLAIMED_EPOCHS)
    claimed_amount_arr=($CLAIMED_AMOUNTS)
    claimed_txid_arr=($CLAIMED_TXIDS)

    total_claimed_fmt=$(printf "%.5f" "$TOTAL_CLAIMED" 2>/dev/null || echo "0.00000")
    total_claimed_usd=$(jitosol_to_usd "$TOTAL_CLAIMED")
    total_claimed_usd=$(printf "%.2f" "$total_claimed_usd" 2>/dev/null || echo "0.00")
    total_claimed_usd=$(add_thousands_separator "$total_claimed_usd")
    total_claimed_sol=$(jitosol_to_sol "$TOTAL_CLAIMED")
    total_claimed_sol=$(printf "%.5f" "$total_claimed_sol" 2>/dev/null || echo "0.00000")

    claimed_details="\`\`\`
Newly Claimed ($CLAIM_COUNT epoch(s)):
  Total: $total_claimed_fmt JitoSOL (~$total_claimed_sol SOL / \$$total_claimed_usd)"

    for (( i=0; i<CLAIM_COUNT; i++ )); do
        amt_fmt=$(printf "%.5f" "${claimed_amount_arr[$i]}" 2>/dev/null || echo "0.00000")
        claimed_details+="
  Epoch ${claimed_epoch_arr[$i]}: $amt_fmt JitoSOL"
    done
    claimed_details+="\`\`\`"

    for (( i=0; i<CLAIM_COUNT; i++ )); do
        txid="${claimed_txid_arr[$i]}"
        if [[ "$txid" != "claimed" && -n "$txid" ]]; then
            claimed_details+="
**Epoch ${claimed_epoch_arr[$i]} tx:** https://orb.helius.dev/tx/${txid}?cluster=mainnet-beta"
        fi
    done
fi

# Build transfer details section
transfer_details=""
if [ -n "$LEDGER_WALLET" ] && [ $CLAIM_COUNT -gt 0 ]; then
    if [ "$TRANSFER_SUCCESS" = "true" ]; then
        transfer_amt_fmt=$(printf "%.5f" "$TRANSFER_AMOUNT" 2>/dev/null || echo "0.00000")
        transfer_details+="\`\`\`
Transferred to Ledger:
  Amount:  $transfer_amt_fmt JitoSOL
  Ledger:  $LEDGER_WALLET
\`\`\`"
        if [[ -n "$TRANSFER_TXID" ]]; then
            transfer_details+="
**Transfer tx:** https://orb.helius.dev/tx/${TRANSFER_TXID}?cluster=mainnet-beta"
        fi
    elif [ "$TRANSFER_SUCCESS" = "false" ]; then
        transfer_details+="\`\`\`
⚠️ Transfer to Ledger FAILED
  Ledger:  $LEDGER_WALLET
\`\`\`"
    fi
fi

# Build Discord embed description
EMBED_DESC="\`\`\`
Wallet:         $WALLET_ADDRESS
Epochs Scanned: $START_EPOCH - $END_EPOCH
JitoSOL Price:  \$$jitosol_price_fmt | SOL Price: \$$sol_price_fmt
\`\`\`"

if [ $CLAIM_COUNT -gt 0 ]; then
    EMBED_DESC+="
$claimed_details
${transfer_details:+
$transfer_details
}"
fi

EMBED_DESC+="
\`\`\`"
if [ $CLAIM_COUNT -eq 0 ]; then
    EMBED_DESC+="
Status: No new claims"
fi
EMBED_DESC+="
Already Claimed: $already_claimed_fmt
No Rewards:      $not_eligible_fmt"
if [ -n "$ERROR_EPOCHS" ]; then
    EMBED_DESC+="
Errors:          $error_fmt"
fi
EMBED_DESC+="\`\`\`

\`\`\`
Current Balance:
  JitoSOL:  $wallet_jitosol
  SOL:      $wallet_sol (equivalent)
  USD:      \$$wallet_usd
\`\`\`

$TIMESTAMP_INFO"

if [ $CLAIM_COUNT -gt 0 ]; then
    send_discord_embed "ok" "✅ BAM Boost Claim — $CLAIM_COUNT Epoch(s) Claimed" "$EMBED_DESC"
else
    send_discord_embed "info" "ℹ️ BAM Boost Claim — No New Claims" "$EMBED_DESC"
fi

echo ""
echo "Done. Log: $LOG_FILE"
exit 0
