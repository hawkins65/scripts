#!/bin/bash

# assuming you are running this on a machine with validator software installed (rust and cargo already installed)
# must clone Jito tip-distribution-cli from
# git clone https://github.com/jito-foundation/jito-programs
# cd ~/jito-programs/mev-programs/tip-distribution-cli
# cargo install --path ~/.cargo/bin

# Check if both vote account and epoch are provided
if [ -z "$1" ] || [ -z "$2" ]; then
  echo "Usage: $0 <vote_account> <epoch>"
  exit 1
fi

VOTE_ACCOUNT=$1
EPOCH=$2

# Configuration variables
TIP_CLI="$HOME/.cargo/bin/tip-distribution-cli"
RPC_URL="https://api.mainnet-beta.solana.com"
LAMPORTS_PER_SOL=1000000000
SLOTS_PER_EPOCH=432000
DEBUG=false

# Run commands and capture output
TIP_OUTPUT=$($TIP_CLI -r $RPC_URL get-tip-distribution-account --vote-account $VOTE_ACCOUNT --epoch $EPOCH)
TIP_STATUS=$?
CLAIM_OUTPUT=$($TIP_CLI -r $RPC_URL get-claim-status --vote-account $VOTE_ACCOUNT --epoch $EPOCH --claimant $VOTE_ACCOUNT)
CLAIM_STATUS=$?

# Check if commands executed successfully
if [ $TIP_STATUS -ne 0 ] || [ $CLAIM_STATUS -ne 0 ]; then
  echo "Error: Failed to execute tip-distribution-cli commands."
  exit 1
fi

# Extract values from tip-distribution output with robust parsing
MAX_TOTAL_CLAIM_LINE=$(echo "$TIP_OUTPUT" | grep -E "Max Total Claim")
MAX_TOTAL_CLAIM=$(echo "$MAX_TOTAL_CLAIM_LINE" | awk '{print $NF}')
TOTAL_FUNDS_CLAIMED_LINE=$(echo "$TIP_OUTPUT" | grep -E "Total Funds Claimed")
TOTAL_FUNDS_CLAIMED=$(echo "$TOTAL_FUNDS_CLAIMED_LINE" | awk '{print $NF}')
VALIDATOR_COMMISSION_BPS_LINE=$(echo "$TIP_OUTPUT" | grep -E "Validator Commission BPS")
VALIDATOR_COMMISSION_BPS=$(echo "$VALIDATOR_COMMISSION_BPS_LINE" | awk '{print $NF}')

# Extract values from claim-status output with robust parsing
SLOT_CLAIMED_AT_LINE=$(echo "$CLAIM_OUTPUT" | grep -E "Slot Claimed At")
SLOT_CLAIMED_AT=$(echo "$SLOT_CLAIMED_AT_LINE" | awk '{print $NF}')
AMOUNT_LINE=$(echo "$CLAIM_OUTPUT" | grep -E "^[[:space:]]*Amount:")
AMOUNT=$(echo "$AMOUNT_LINE" | awk '{print $NF}')

# Conditionally print debug information
if [ "$DEBUG" = "true" ]; then
  echo "Debug: MAX_TOTAL_CLAIM_LINE: $MAX_TOTAL_CLAIM_LINE"
  echo "Debug: TOTAL_FUNDS_CLAIMED_LINE: $TOTAL_FUNDS_CLAIMED_LINE"
  echo "Debug: VALIDATOR_COMMISSION_BPS_LINE: $VALIDATOR_COMMISSION_BPS_LINE"
  echo "Debug: SLOT_CLAIMED_AT_LINE: $SLOT_CLAIMED_AT_LINE"
  echo "Debug: AMOUNT_LINE: $AMOUNT_LINE"
fi

# Validate extracted values
if [ -z "$MAX_TOTAL_CLAIM" ] || [ -z "$TOTAL_FUNDS_CLAIMED" ] || [ -z "$VALIDATOR_COMMISSION_BPS" ] || \
   [ -z "$SLOT_CLAIMED_AT" ] || [ -z "$AMOUNT" ]; then
  echo "Error: Failed to extract required values from command output."
  echo "TIP_OUTPUT:"
  echo "$TIP_OUTPUT"
  echo "CLAIM_OUTPUT:"
  echo "$CLAIM_OUTPUT"
  exit 1
fi

# Validate numeric values
if ! [[ "$MAX_TOTAL_CLAIM" =~ ^[0-9]+$ ]] || ! [[ "$TOTAL_FUNDS_CLAIMED" =~ ^[0-9]+$ ]] || \
   ! [[ "$VALIDATOR_COMMISSION_BPS" =~ ^[0-9]+$ ]] || ! [[ "$SLOT_CLAIMED_AT" =~ ^[0-9]+$ ]] || \
   ! [[ "$AMOUNT" =~ ^[0-9]+$ ]]; then
  echo "Error: Extracted values are not valid numbers."
  exit 1
fi

# Convert to SOL
MAX_TOTAL_CLAIM_SOL=$(echo "scale=9; $MAX_TOTAL_CLAIM / $LAMPORTS_PER_SOL" | bc)
TOTAL_FUNDS_CLAIMED_SOL=$(echo "scale=9; $TOTAL_FUNDS_CLAIMED / $LAMPORTS_PER_SOL" | bc)
AMOUNT_SOL=$(echo "scale=9; $AMOUNT / $LAMPORTS_PER_SOL" | bc)

# Calculate Validator Commission Percentage
VALIDATOR_COMMISSION_PERCENT=$(echo "scale=2; $VALIDATOR_COMMISSION_BPS / 100" | bc)

# Calculate Validator Portion
VALIDATOR_PORTION=$(echo "scale=0; $MAX_TOTAL_CLAIM * $VALIDATOR_COMMISSION_BPS / 10000" | bc)
VALIDATOR_PORTION_SOL=$(echo "scale=9; $VALIDATOR_PORTION / $LAMPORTS_PER_SOL" | bc)

# Calculate Differences
DIFFERENCE_1=$(echo "$MAX_TOTAL_CLAIM - $TOTAL_FUNDS_CLAIMED" | bc)
DIFFERENCE_1_SOL=$(echo "scale=9; $DIFFERENCE_1 / $LAMPORTS_PER_SOL" | bc)
DIFFERENCE_2=$(echo "$VALIDATOR_PORTION - $AMOUNT" | bc)
DIFFERENCE_2_SOL=$(echo "scale=9; $DIFFERENCE_2 / $LAMPORTS_PER_SOL" | bc)

# Calculate Percentage for Amount Not Claimed
DIFFERENCE_1_PERCENT=$(echo "scale=2; ($DIFFERENCE_1 * 100) / $MAX_TOTAL_CLAIM" | bc)

# Calculate epoch from slot
SLOT_EPOCH=$(echo "$SLOT_CLAIMED_AT / $SLOTS_PER_EPOCH" | bc)

# Format and print output
cat << EOF
----- -----
Validator: $VOTE_ACCOUNT
Epoch: $EPOCH
Validator Commission BPS: $VALIDATOR_COMMISSION_BPS ($VALIDATOR_COMMISSION_PERCENT%)
Max Total Claim: $MAX_TOTAL_CLAIM ($MAX_TOTAL_CLAIM_SOL SOL)
Validator Portion: $VALIDATOR_PORTION ($VALIDATOR_PORTION_SOL SOL)
Total Funds Claimed: $TOTAL_FUNDS_CLAIMED ($TOTAL_FUNDS_CLAIMED_SOL SOL)
Amount Not Claimed: $DIFFERENCE_1 ($DIFFERENCE_1_SOL SOL) ($DIFFERENCE_1_PERCENT%)
Claimed At Slot: $SLOT_CLAIMED_AT (Epoch: $SLOT_EPOCH)
Amount Validator Claimed: $AMOUNT ($AMOUNT_SOL SOL)
Difference: $DIFFERENCE_2 ($DIFFERENCE_2_SOL SOL)
EOF
