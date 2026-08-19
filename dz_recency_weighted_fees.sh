
#!/bin/bash

# Script to calculate 5% fees ($FEE_PERCENTAGE) from block rewards for a validator ($VALIDATOR_PUBKEY)
# Pre-Paid Epochs: 5 ($PREPAID_EPOCHS)
#
# DEPENDENCIES:
# - fzf (fuzzy finder for interactive validator selection)
#   Install on macOS: brew install fzf
#   Install on Linux: sudo apt-get install fzf  (Debian/Ubuntu)
#                     sudo yum install fzf       (RHEL/CentOS)
#   The script will offer to install fzf if not found.
#
# Validator Rewards: Weighted Averages over Last 10 Epochs
# https://api.trillium.so/recency_weighted_average_validator_rewards
#
# Returns epoch weighted averages for most numerical data over the last 10 epochs for all validators.
# The passing of a pubkey parameter works the same as above.
#
# Averaging is performed using weighted values from the prior 10 epochs. However, epochs are not
# weighted equally. Instead, the following weighting is used for each epoch to determine that
# epoch's contribution to each validator's score:
#
# Current Epoch : 0.2649
# Epoch - 1     : 0.1987
# Epoch - 2     : 0.1490
# Epoch - 3     : 0.1118
# Epoch - 4     : 0.0838
# Epoch - 5     : 0.0629
# Epoch - 6     : 0.0471
# Epoch - 7     : 0.0354
# Epoch - 8     : 0.0265
# Epoch - 9     : 0.0199
#
# Note: This epoch weighting idea and weight values are from Shinobi Systems xshin.fi
#
# Older epochs contribute less total scoring weight than newer epochs. The current epoch
# contributes a little more than a quarter of the overall score, and the current and prior
# three epochs contribute almost 3/4 of total score.

set -e

# Function to display help
show_help() {
    echo "Usage: $0 [OPTIONS]"
    echo ""
    echo "Calculate fees from block rewards for a Solana validator."
    echo ""
    echo "Options:"
    echo "  --validator-pubkey PUBKEY    Validator public key (required if not provided interactively)"
    echo "  --payer-wallet PUBKEY        Payer wallet public key or Ledger hardware wallet"
    echo "                               Format: <PUBKEY> or \"usb://ledger?key=N\" where N is account index"
    echo "                               (required if not provided interactively)"
    echo "  --prepaid-epochs NUMBER      Number of epochs to prepay (default: 5)"
    echo "  --dry-run                    Use 0.001 SOL for testing instead of calculated fee"
    echo "  --help                       Display this help message"
    echo ""
    echo "Examples:"
    echo "  $0 --validator-pubkey <VALIDATOR_IDENTITY_PUBKEY>"
    echo "  $0 --validator-pubkey <VALIDATOR_IDENTITY_PUBKEY> --payer-wallet <PAYER_WALLET_PUBKEY>"
    echo "  $0 --validator-pubkey <VALIDATOR_IDENTITY_PUBKEY> --payer-wallet \"usb://ledger?key=0\""
    echo "  $0 --validator-pubkey <VALIDATOR_IDENTITY_PUBKEY> --payer-wallet \"usb://ledger?key=1\""
    echo "  $0 --validator-pubkey <VALIDATOR_IDENTITY_PUBKEY> --prepaid-epochs 10 --dry-run"
    echo ""
    exit 0
}

API_BASE_URL="https://api.trillium.so/recency_weighted_average_validator_rewards"
VALIDATOR_PUBKEY=""
FEE_PERCENTAGE=5
PREPAID_EPOCHS=5
PAYER_WALLET=""
DRY_RUN=false
SCRIPT_NAME=$(basename "$0" .sh)
LOG_FILE="$HOME/${SCRIPT_NAME}.log"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --help)
            show_help
            ;;
        --validator-pubkey)
            VALIDATOR_PUBKEY="$2"
            shift 2
            ;;
        --payer-wallet)
            PAYER_WALLET="$2"
            shift 2
            ;;
        --prepaid-epochs)
            PREPAID_EPOCHS="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Function to check and install fzf if needed
check_fzf() {
    if ! command -v fzf &> /dev/null; then
        echo "fzf is not installed."
        echo "fzf enables interactive fuzzy search for validator selection."
        echo ""
        echo "Would you like to install fzf now? (y/n)"
        read -r install_fzf
        if [[ "$install_fzf" =~ ^[Yy]$ ]]; then
            if [[ "$OSTYPE" == "darwin"* ]]; then
                if command -v brew &> /dev/null; then
                    echo "Installing fzf via Homebrew..."
                    brew install fzf
                else
                    echo "ERROR: Homebrew not found. Please install fzf manually."
                    return 1
                fi
            elif [[ "$OSTYPE" == "linux-gnu"* ]]; then
                if command -v apt-get &> /dev/null; then
                    echo "Installing fzf via apt-get..."
                    sudo apt-get update && sudo apt-get install -y fzf
                elif command -v yum &> /dev/null; then
                    echo "Installing fzf via yum..."
                    sudo yum install -y fzf
                else
                    echo "ERROR: Could not detect package manager. Please install fzf manually."
                    return 1
                fi
            else
                echo "ERROR: Unsupported OS. Please install fzf manually."
                return 1
            fi

            if command -v fzf &> /dev/null; then
                echo "fzf installed successfully!"
                return 0
            else
                echo "ERROR: fzf installation failed."
                return 1
            fi
        else
            return 1
        fi
    fi
    return 0
}

# Prompt for validator pubkey if not provided
if [[ -z "$VALIDATOR_PUBKEY" ]]; then
    # Check if fzf is available
    if check_fzf; then
        echo "Fetching all validators from Trillium API..."
        ALL_VALIDATORS=$(curl -s "${API_BASE_URL}")

        if ! echo "$ALL_VALIDATORS" | jq empty 2>/dev/null; then
            echo "ERROR: Could not fetch validators from API"
            echo "Please enter validator public key manually:"
            read -r VALIDATOR_PUBKEY
        else
            echo "Select a validator (type to search):"
            # Create a formatted list: "identity_pubkey | name | vote_account_pubkey" sorted by identity_pubkey
            SELECTED=$(echo "$ALL_VALIDATORS" | jq -r '.[] | "\(.identity_pubkey) | \(.name) | \(.vote_account_pubkey)"' | sort | fzf --height=40% --reverse --header="Select Validator" --preview='echo {}' --preview-window=up:3:wrap)

            if [[ -n "$SELECTED" ]]; then
                # Extract the identity_pubkey (first field before |)
                VALIDATOR_PUBKEY=$(echo "$SELECTED" | awk -F' \\| ' '{print $1}')
            else
                echo "❌ No validator selected."
                exit 1
            fi
        fi
    else
        echo "Please enter the complete validator identity public key:"
        read -r VALIDATOR_PUBKEY
    fi

    if [[ -z "$VALIDATOR_PUBKEY" ]]; then
        echo "ERROR: Validator public key is required"
        exit 1
    fi
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔍 Fetching validator rewards data..."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
API_RESPONSE=$(curl -s "${API_BASE_URL}/${VALIDATOR_PUBKEY}")

# Check if the API response is valid JSON
if ! echo "$API_RESPONSE" | jq empty 2>/dev/null; then
    echo "❌ ERROR: Invalid API response or validator not found"
    echo "Response: $API_RESPONSE"
    exit 1
fi

echo "✅ Found validator data. Calculating fees..."

# Extract data from JSON response
AVERAGE_REWARDS=$(echo "$API_RESPONSE" | jq -r '.average_rewards')
VALIDATOR_NAME=$(echo "$API_RESPONSE" | jq -r '.name')
VOTE_ACCOUNT_PUBKEY=$(echo "$API_RESPONSE" | jq -r '.vote_account_pubkey')

# Check if average_rewards is a valid number
if [[ "$AVERAGE_REWARDS" == "null" ]] || ! [[ "$AVERAGE_REWARDS" =~ ^[0-9]+\.?[0-9]*$ ]]; then
    echo "ERROR: Invalid average rewards value: $AVERAGE_REWARDS"
    exit 1
fi

# Calculate 5% fee from average_rewards
FEE_AMOUNT=$(echo "$AVERAGE_REWARDS * $FEE_PERCENTAGE / 100" | bc -l | sed 's/0*$//' | sed 's/\.$//')
TOTAL_FEE_AMOUNT=$(echo "$FEE_AMOUNT * $PREPAID_EPOCHS" | bc -l | sed 's/0*$//' | sed 's/\.$//')

# Override with dry run amount if flag is set
if [[ "$DRY_RUN" == "true" ]]; then
    TRANSFER_AMOUNT="0.001"
    DRY_RUN_NOTE=" (DRY RUN MODE)"
else
    TRANSFER_AMOUNT="$TOTAL_FEE_AMOUNT"
    DRY_RUN_NOTE=""
fi

echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📊 VALIDATOR INFORMATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📛 Validator Name: $VALIDATOR_NAME"
echo "🔑 Validator Identity: $VALIDATOR_PUBKEY"
echo "🗳️  Vote Account: $VOTE_ACCOUNT_PUBKEY"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💰 FEE CALCULATION"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📈 Average Recency Weighted Block Rewards: $AVERAGE_REWARDS SOL"
echo "📊 Fee Percentage: $FEE_PERCENTAGE%"
echo "💵 Calculated Fee (per epoch): $FEE_AMOUNT SOL"
echo "📅 Pre-Paid Epochs: $PREPAID_EPOCHS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "💎 Total Fee Amount: $TOTAL_FEE_AMOUNT SOL"
if [[ "$DRY_RUN" == "true" ]]; then
    echo "🧪 Transfer Amount: $TRANSFER_AMOUNT SOL$DRY_RUN_NOTE"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Generate derived account
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🔐 GENERATING DERIVED ACCOUNT"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
DERIVED_ACCOUNT=$(solana find-program-derived-address --url mainnet-beta "dzrevZC94tBLwuHw1dyynZxaXTWyp7yocsinyEVPtt4" "string:solana_validator_deposit" "pubkey:${VALIDATOR_PUBKEY}" | grep -o '[1-9A-HJ-NP-Za-km-z]\{32,44\}')

echo "📬 Derived Account: $DERIVED_ACCOUNT"

# Get current balance of derived account
CURRENT_BALANCE=$(solana balance "$DERIVED_ACCOUNT" --url mainnet-beta 2>/dev/null | awk '{print $1}')
if [[ -z "$CURRENT_BALANCE" ]] || [[ "$CURRENT_BALANCE" == "0" ]]; then
    CURRENT_BALANCE="0"
    CURRENT_EPOCHS=0
else
    # Calculate how many epochs the current balance can cover
    CURRENT_EPOCHS=$(echo "$CURRENT_BALANCE / $FEE_AMOUNT" | bc)
fi

# Calculate final balance and epochs after transfer
FINAL_BALANCE=$(echo "$CURRENT_BALANCE + $TRANSFER_AMOUNT" | bc -l)
FINAL_EPOCHS=$(echo "$FINAL_BALANCE / $FEE_AMOUNT" | bc)

echo "💼 Current Balance: $CURRENT_BALANCE SOL"
echo "📊 Estimated Epochs Covered (Current): $CURRENT_EPOCHS epochs"
echo ""
echo "➕ Adding: $TRANSFER_AMOUNT SOL"
echo ""
echo "💼 Final Balance (After Transfer): $FINAL_BALANCE SOL"
echo "📊 Estimated Epochs Covered (After Transfer): $FINAL_EPOCHS epochs"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

# Check if payer wallet was provided, if not ask for it
if [[ -z "$PAYER_WALLET" ]]; then
    echo ""
    echo "💳 Enter Ledger key number (0-9) or full wallet pubkey:"
    echo "   [Press Enter for default: key=1]"
    read -r PAYER_INPUT

    # If empty, use default key 1
    if [[ -z "$PAYER_INPUT" ]]; then
        PAYER_WALLET="usb://ledger?key=1"
        echo "   Using default: $PAYER_WALLET"
    # If just a number, treat it as a key index
    elif [[ "$PAYER_INPUT" =~ ^[0-9]+$ ]]; then
        PAYER_WALLET="usb://ledger?key=$PAYER_INPUT"
        echo "   Using: $PAYER_WALLET"
    # Otherwise use the full input as-is
    else
        PAYER_WALLET="$PAYER_INPUT"
    fi
fi

# Verify payer wallet address if using Ledger
if [[ "$PAYER_WALLET" == usb://ledger* ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔍 VERIFYING LEDGER WALLET"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "📱 Please unlock your Ledger and open the Solana app..."
    echo "   (This will timeout in 30 seconds if not ready)"
    echo ""

    # Use timeout command (works on macOS and Linux)
    if command -v timeout &> /dev/null; then
        RESOLVED_PAYER_ADDRESS=$(timeout 30 solana address --keypair "$PAYER_WALLET" 2>&1)
        RESOLVE_EXIT_CODE=$?
    elif command -v gtimeout &> /dev/null; then
        RESOLVED_PAYER_ADDRESS=$(gtimeout 30 solana address --keypair "$PAYER_WALLET" 2>&1)
        RESOLVE_EXIT_CODE=$?
    else
        # Fallback without timeout
        RESOLVED_PAYER_ADDRESS=$(solana address --keypair "$PAYER_WALLET" 2>&1)
        RESOLVE_EXIT_CODE=$?
    fi

    # Check if timeout occurred
    if [[ $RESOLVE_EXIT_CODE -eq 124 ]] || [[ $RESOLVE_EXIT_CODE -eq 143 ]]; then
        echo "⏱️  TIMEOUT: Ledger verification timed out after 30 seconds."
        echo ""
        echo "Make sure:"
        echo "  1. Your Ledger is connected and unlocked"
        echo "  2. The Solana app is open on your Ledger"
        echo "  3. You're using the correct key index (0, 1, 2, etc.)"
        echo ""
        echo "Do you want to try again? (y/n)"
        read -r try_again
        if [[ "$try_again" =~ ^[Yy]$ ]]; then
            echo ""
            echo "🔄 Retrying Ledger verification..."
            RESOLVED_PAYER_ADDRESS=$(solana address --keypair "$PAYER_WALLET" 2>&1)
            RESOLVE_EXIT_CODE=$?
        else
            echo "❌ Cancelled."
            exit 1
        fi
    fi

    if [[ $RESOLVE_EXIT_CODE -eq 0 ]] && [[ "$RESOLVED_PAYER_ADDRESS" =~ ^[1-9A-HJ-NP-Za-km-z]{32,44}$ ]]; then
        echo "✅ Resolved Ledger Address: $RESOLVED_PAYER_ADDRESS"

        # Get balance of the payer wallet
        PAYER_BALANCE=$(solana balance "$RESOLVED_PAYER_ADDRESS" --url mainnet-beta 2>/dev/null | awk '{print $1}')
        if [[ -n "$PAYER_BALANCE" ]]; then
            echo "💰 Payer Balance: $PAYER_BALANCE SOL"
        fi

        echo ""
        echo "⚠️  Is this the correct wallet? (y/n)"
        read -r wallet_confirm

        if [[ ! "$wallet_confirm" =~ ^[Yy]$ ]]; then
            echo ""
            echo "❌ Please restart the script with the correct Ledger key."
            echo "   Example: usb://ledger?key=0  (for first account)"
            echo "            usb://ledger?key=1  (for second account)"
            echo "            usb://ledger?key=2  (for third account)"
            exit 1
        fi
    else
        echo "⚠️  WARNING: Could not verify payer wallet address"
        echo "Error: $RESOLVED_PAYER_ADDRESS"
        echo ""
        echo "Make sure:"
        echo "  1. Your Ledger is connected and unlocked"
        echo "  2. The Solana app is open on your Ledger"
        echo "  3. You're using the correct key index (0, 1, 2, etc.)"
        echo ""
        echo "Do you want to continue anyway? (y/n)"
        read -r continue_anyway
        if [[ ! "$continue_anyway" =~ ^[Yy]$ ]]; then
            exit 1
        fi
    fi
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
fi

# Prepare the transfer command
if [[ -n "$PAYER_WALLET" ]]; then
    TRANSFER_CMD="solana transfer --from $PAYER_WALLET $DERIVED_ACCOUNT $TRANSFER_AMOUNT --allow-unfunded-recipient"
else
    TRANSFER_CMD="solana transfer $DERIVED_ACCOUNT $TRANSFER_AMOUNT --allow-unfunded-recipient"
fi

# Show transaction details and command
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "📝 TRANSACTION DETAILS"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "🏷️  Validator Identity: $VALIDATOR_PUBKEY"
echo "💳 Payer Wallet: $PAYER_WALLET"
if [[ -n "$RESOLVED_PAYER_ADDRESS" ]]; then
    echo "✅ Resolved Payer Address: $RESOLVED_PAYER_ADDRESS"
fi
echo "📬 Recipient (Derived Account): $DERIVED_ACCOUNT"
echo "💰 Transfer Amount: $TRANSFER_AMOUNT SOL"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "📋 Generated Solana transfer command:"
echo "$TRANSFER_CMD"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "⚠️  Do you want to execute this transaction? (y/n)"
read -r approval

if [[ "$approval" =~ ^[Yy]$ ]]; then
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🚀 EXECUTING TRANSFER..."
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

    # Start logging
    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
    echo "" >> "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════" >> "$LOG_FILE"
    echo "[$TIMESTAMP] NEW TRANSACTION" >> "$LOG_FILE"
    echo "═══════════════════════════════════════════════════════════════" >> "$LOG_FILE"
    echo "[$TIMESTAMP] Validator Name: $VALIDATOR_NAME" >> "$LOG_FILE"
    echo "[$TIMESTAMP] Validator Identity: $VALIDATOR_PUBKEY" >> "$LOG_FILE"
    echo "[$TIMESTAMP] Vote Account: $VOTE_ACCOUNT_PUBKEY" >> "$LOG_FILE"
    echo "[$TIMESTAMP] Payer Wallet: $PAYER_WALLET" >> "$LOG_FILE"
    if [[ -n "$RESOLVED_PAYER_ADDRESS" ]]; then
        echo "[$TIMESTAMP] Resolved Payer Address: $RESOLVED_PAYER_ADDRESS" >> "$LOG_FILE"
    fi
    echo "[$TIMESTAMP] Derived Account: $DERIVED_ACCOUNT" >> "$LOG_FILE"
    echo "[$TIMESTAMP] Transfer Amount: $TRANSFER_AMOUNT SOL" >> "$LOG_FILE"
    echo "[$TIMESTAMP] Fee per Epoch: $FEE_AMOUNT SOL" >> "$LOG_FILE"
    echo "[$TIMESTAMP] Pre-Paid Epochs: $PREPAID_EPOCHS" >> "$LOG_FILE"

    # Build the command
    if [[ -n "$PAYER_WALLET" ]]; then
        TRANSFER_CMD="solana transfer --from \"$PAYER_WALLET\" \"$DERIVED_ACCOUNT\" \"$TRANSFER_AMOUNT\" --allow-unfunded-recipient"
    else
        TRANSFER_CMD="solana transfer \"$DERIVED_ACCOUNT\" \"$TRANSFER_AMOUNT\" --allow-unfunded-recipient"
    fi

    echo "[$TIMESTAMP] Command: $TRANSFER_CMD" >> "$LOG_FILE"
    echo "[$TIMESTAMP] Executing..." >> "$LOG_FILE"

    # Execute the transfer command and capture output while showing it to user
    if [[ -n "$PAYER_WALLET" ]]; then
        TRANSFER_OUTPUT=$(solana transfer --from "$PAYER_WALLET" "$DERIVED_ACCOUNT" "$TRANSFER_AMOUNT" --allow-unfunded-recipient 2>&1 | tee /dev/tty)
        TRANSFER_EXIT_CODE=${PIPESTATUS[0]}
    else
        TRANSFER_OUTPUT=$(solana transfer "$DERIVED_ACCOUNT" "$TRANSFER_AMOUNT" --allow-unfunded-recipient 2>&1 | tee /dev/tty)
        TRANSFER_EXIT_CODE=${PIPESTATUS[0]}
    fi

    echo ""

    TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

    # Check if transfer was successful
    if [[ $TRANSFER_EXIT_CODE -eq 0 ]]; then
        # Extract signature from output
        SIGNATURE=$(echo "$TRANSFER_OUTPUT" | grep -oE 'Signature: [1-9A-HJ-NP-Za-km-z]{87,88}' | sed 's/Signature: //')

        # Check if there was an RPC error even though exit code was 0
        if echo "$TRANSFER_OUTPUT" | grep -q "error sending request"; then
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "⚠️  TRANSACTION APPROVED BUT RPC ERROR"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "Your Ledger approved the transaction, but there was an error"
            echo "communicating with the Solana RPC endpoint."
            echo ""

            # Log the RPC error
            echo "[$TIMESTAMP] ⚠️  TRANSACTION APPROVED BUT RPC ERROR (Attempt 1)" >> "$LOG_FILE"
            echo "[$TIMESTAMP] Transfer Output:" >> "$LOG_FILE"
            echo "$TRANSFER_OUTPUT" | sed "s/^/[$TIMESTAMP]   /" >> "$LOG_FILE"

            # Prompt for retry
            echo "This is a common issue with the RPC endpoint."
            echo ""
            echo "🔄 Would you like to retry the transaction? (y/n)"
            read -r retry_choice

            if [[ "$retry_choice" =~ ^[Yy]$ ]]; then
                echo ""
                echo "🔄 Retrying transaction..."
                echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                RETRY_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')
                echo "[$RETRY_TIMESTAMP] Retrying transaction..." >> "$LOG_FILE"

                # Retry the transfer
                if [[ -n "$PAYER_WALLET" ]]; then
                    TRANSFER_OUTPUT=$(solana transfer --from "$PAYER_WALLET" "$DERIVED_ACCOUNT" "$TRANSFER_AMOUNT" --allow-unfunded-recipient 2>&1 | tee /dev/tty)
                    TRANSFER_EXIT_CODE=${PIPESTATUS[0]}
                else
                    TRANSFER_OUTPUT=$(solana transfer "$DERIVED_ACCOUNT" "$TRANSFER_AMOUNT" --allow-unfunded-recipient 2>&1 | tee /dev/tty)
                    TRANSFER_EXIT_CODE=${PIPESTATUS[0]}
                fi

                echo ""
                RETRY_TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

                # Check retry result
                SIGNATURE=$(echo "$TRANSFER_OUTPUT" | grep -oE 'Signature: [1-9A-HJ-NP-Za-km-z]{87,88}' | sed 's/Signature: //')

                if [[ $TRANSFER_EXIT_CODE -eq 0 ]] && [[ -n "$SIGNATURE" ]]; then
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "✅ RETRY SUCCESSFUL!"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "🔗 View on Solscan:"
                    echo "   https://solscan.io/tx/${SIGNATURE}"
                    echo ""
                    echo "🔗 View on Solana Explorer:"
                    echo "   https://explorer.solana.com/tx/${SIGNATURE}"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                    # Log retry success
                    echo "[$RETRY_TIMESTAMP] ✅ RETRY SUCCESSFUL!" >> "$LOG_FILE"
                    echo "[$RETRY_TIMESTAMP] Signature: $SIGNATURE" >> "$LOG_FILE"
                    echo "[$RETRY_TIMESTAMP] Solscan: https://solscan.io/tx/${SIGNATURE}" >> "$LOG_FILE"
                    echo "[$RETRY_TIMESTAMP] Explorer: https://explorer.solana.com/tx/${SIGNATURE}" >> "$LOG_FILE"
                    echo "[$RETRY_TIMESTAMP] Transfer Output:" >> "$LOG_FILE"
                    echo "$TRANSFER_OUTPUT" | sed "s/^/[$RETRY_TIMESTAMP]   /" >> "$LOG_FILE"
                else
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "❌ RETRY ALSO FAILED"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
                    echo "Please try again later or use a different RPC endpoint."
                    echo ""
                    echo "💡 To use a different RPC endpoint:"
                    echo "   export SOLANA_RPC_URL=https://your-rpc-endpoint.com"
                    echo ""
                    echo "Common alternatives:"
                    echo "   - Helius: https://mainnet.helius-rpc.com/?api-key=YOUR_KEY"
                    echo "   - QuickNode: https://your-endpoint.quiknode.pro/"
                    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

                    # Log retry failure
                    echo "[$RETRY_TIMESTAMP] ❌ RETRY ALSO FAILED" >> "$LOG_FILE"
                    echo "[$RETRY_TIMESTAMP] Transfer Output:" >> "$LOG_FILE"
                    echo "$TRANSFER_OUTPUT" | sed "s/^/[$RETRY_TIMESTAMP]   /" >> "$LOG_FILE"
                fi
            else
                echo ""
                echo "❌ Retry cancelled. Transaction not completed."
                echo "[$TIMESTAMP] User declined retry" >> "$LOG_FILE"
            fi
        elif [[ -n "$SIGNATURE" ]]; then
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "✅ TRANSACTION SUCCESSFUL!"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "🔗 View on Solscan:"
            echo "   https://solscan.io/tx/${SIGNATURE}"
            echo ""
            echo "🔗 View on Solana Explorer:"
            echo "   https://explorer.solana.com/tx/${SIGNATURE}"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

            # Log success
            echo "[$TIMESTAMP] ✅ TRANSACTION SUCCESSFUL!" >> "$LOG_FILE"
            echo "[$TIMESTAMP] Signature: $SIGNATURE" >> "$LOG_FILE"
            echo "[$TIMESTAMP] Solscan: https://solscan.io/tx/${SIGNATURE}" >> "$LOG_FILE"
            echo "[$TIMESTAMP] Explorer: https://explorer.solana.com/tx/${SIGNATURE}" >> "$LOG_FILE"
            echo "[$TIMESTAMP] Transfer Output:" >> "$LOG_FILE"
            echo "$TRANSFER_OUTPUT" | sed "s/^/[$TIMESTAMP]   /" >> "$LOG_FILE"
        else
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "⚠️  TRANSACTION COMPLETED BUT NO SIGNATURE"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "💡 Check your transaction in the output above for the signature."
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

            # Log warning
            echo "[$TIMESTAMP] ⚠️  Could not extract signature from output" >> "$LOG_FILE"
            echo "[$TIMESTAMP] Transfer Output:" >> "$LOG_FILE"
            echo "$TRANSFER_OUTPUT" | sed "s/^/[$TIMESTAMP]   /" >> "$LOG_FILE"
        fi
    else
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "❌ TRANSACTION FAILED"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Exit code: $TRANSFER_EXIT_CODE"
        echo "Please check the error message above."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Log failure
        echo "[$TIMESTAMP] ❌ TRANSACTION FAILED (Exit code: $TRANSFER_EXIT_CODE)" >> "$LOG_FILE"
        echo "[$TIMESTAMP] Error Output:" >> "$LOG_FILE"
        echo "$TRANSFER_OUTPUT" | sed "s/^/[$TIMESTAMP]   /" >> "$LOG_FILE"
    fi

    echo "[$TIMESTAMP] End of transaction" >> "$LOG_FILE"
    echo "───────────────────────────────────────────────────────────────" >> "$LOG_FILE"

    # Notify user about log file
    echo ""
    echo "📝 Transaction logged to: $LOG_FILE"
else
    echo ""
    echo "❌ Transaction cancelled."
fi
