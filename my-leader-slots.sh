#!/bin/bash

# Load RPC and identity from shared config
source "$HOME/.config/validator/rpc.conf" || { echo "ERROR: Cannot load ~/.config/validator/rpc.conf" >&2; exit 1; }

# Check for the first argument to determine the VALIDATOR_IDENTITY
if [ -z "$1" ]; then
    :  # use VALIDATOR_IDENTITY from config
elif [ "$1" == "cogent" ]; then
    VALIDATOR_IDENTITY="$COGENT_IDENTITY"
elif [ "$1" == "trillium" ]; then
    :  # use VALIDATOR_IDENTITY from config
else
    VALIDATOR_IDENTITY=$1
fi

RPC_URL="$MAINNET_RPC_URL"

# Fetch performance samples to calculate slot duration
performance_samples=$(curl -s $RPC_URL -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getRecentPerformanceSamples","params":[1]}')
num_slots=$(echo "$performance_samples" | jq -r '.result[0].numSlots')
sample_period_secs=$(echo "$performance_samples" | jq -r '.result[0].samplePeriodSecs')
SECONDS_PER_SLOT=$(echo "scale=6; $sample_period_secs / $num_slots" | bc -l)

# Define ANSI escape codes for formatting
BOLD='\033[1m'
WHITE='\033[97m'
LIGHT_GRAY='\033[37m'
DARK_BLUE_BG='\033[44m'
RESET='\033[0m'

function duration () {
    local T=${1%.*}
    local D=$((T/60/60/24))
    local H=$((T/60/60%24))
    local M=$((T/60%60))
    local S=$((T%60))
    
    (($D > 0)) && printf '%d day%s ' $D $((($D > 1)) && echo s)
    (($H > 0)) && printf '%d hr%s ' $H $((($H > 1)) && echo s)
    (($M > 0)) && printf '%d min%s ' $M $((($M > 1)) && echo s)

    printf '%d secs' $S
}

EPOCH_DETAILS=$(solana -um epoch-info)

EPOCH_CURRENT_SLOT=$(echo "$EPOCH_DETAILS" | grep ^Slot: | awk '{ print $2 }')
EPOCH_COMPLETED_SLOTS=$(echo "$EPOCH_DETAILS" | grep "^Epoch Completed Slots:" | awk '{ print $4 }' | cut -d '/' -f 1)
EPOCH_SLOT_COUNT=$(echo "$EPOCH_DETAILS" | grep "^Epoch Completed Slots:" | awk '{ print $4 }' | cut -d '/' -f 2)

EPOCH_FIRST_SLOT=$(($EPOCH_CURRENT_SLOT-$EPOCH_COMPLETED_SLOTS))
EPOCH_LAST_SLOT=$(($EPOCH_FIRST_SLOT+$EPOCH_SLOT_COUNT-1))

FIRST_LEADER_SLOT=
PREVIOUS_LEADER_SLOT=
TOTAL_LEADER_SLOTS=0

# Adjusted function to match original timing approach using `bc`
function slot_to_times () {
    local SLOT=$1
    local SECONDS_TO_SLOT=$(echo "scale=6; ($SLOT - $EPOCH_CURRENT_SLOT) * $SECONDS_PER_SLOT" | bc)
    local SECONDS_TO_SLOT_INT=${SECONDS_TO_SLOT%.*}
    local UTC_TIME=$(date -u -d "now + $SECONDS_TO_SLOT_INT seconds" "+%Y-%m-%d %H:%M:%S")
    local CT_TIME=$(TZ='America/Chicago' date -d "now + $SECONDS_TO_SLOT_INT seconds" "+%Y-%m-%d %H:%M:%S")
    echo "$UTC_TIME|$CT_TIME|$SECONDS_TO_SLOT"
}

function show_leader_range () {
    if [ -n "$PREVIOUS_LEADER_SLOT" ]; then
        SLOTS=$(($PREVIOUS_LEADER_SLOT-$FIRST_LEADER_SLOT+1))
        SECS=$(echo "$SECONDS_PER_SLOT * $SLOTS" | bc)
        TIMES=$(slot_to_times $FIRST_LEADER_SLOT)
        UTC_TIME=$(echo $TIMES | cut -d'|' -f1)
        CT_TIME=$(echo $TIMES | cut -d'|' -f2)
        printf "${BOLD}${WHITE}${DARK_BLUE_BG}Lead  $FIRST_LEADER_SLOT-$PREVIOUS_LEADER_SLOT  %-12s  %s UTC | %s CT ($(duration $SECS))${RESET}\n" "$SLOTS slots" "$UTC_TIME" "$CT_TIME"
        TOTAL_LEADER_SLOTS=$(($TOTAL_LEADER_SLOTS + $SLOTS))
    fi
}    

function show_non_leader_range () {
    if [ -z "$PREVIOUS_LEADER_SLOT" ]; then
        FIRST_NON_LEADER_SLOT=$EPOCH_FIRST_SLOT
    else
        FIRST_NON_LEADER_SLOT=$(($PREVIOUS_LEADER_SLOT+1))
    fi
    SLOTS=$(($NEXT_LEADER_SLOT-$FIRST_NON_LEADER_SLOT))
    if [ $SLOTS -gt 0 ]; then
        SECS=$(echo "$SECONDS_PER_SLOT * $SLOTS" | bc)
        TIMES=$(slot_to_times $FIRST_NON_LEADER_SLOT)
        UTC_TIME=$(echo $TIMES | cut -d'|' -f1)
        CT_TIME=$(echo $TIMES | cut -d'|' -f2)
        printf "${LIGHT_GRAY}      $FIRST_NON_LEADER_SLOT-$(($NEXT_LEADER_SLOT-1))  %-12s  %s UTC | %s CT ($(duration $SECS))${RESET}\n" "$SLOTS slots" "$UTC_TIME" "$CT_TIME"
    fi
}

CURRENT_EPOCH=$(solana -um epoch)
FILENAME="epoch${CURRENT_EPOCH}-${VALIDATOR_IDENTITY}-my-leader-schedule.txt"

{
for NEXT_LEADER_SLOT in $(solana -um leader-schedule --no-address-labels | grep $VALIDATOR_IDENTITY | awk '{ print $1 }'); do
    if [ -n "$PREVIOUS_LEADER_SLOT" ] && [ $NEXT_LEADER_SLOT -eq $((PREVIOUS_LEADER_SLOT+1)) ]; then
        PREVIOUS_LEADER_SLOT=$NEXT_LEADER_SLOT
    else
        show_leader_range
        show_non_leader_range
        FIRST_LEADER_SLOT=$NEXT_LEADER_SLOT
        PREVIOUS_LEADER_SLOT=$NEXT_LEADER_SLOT
    fi
done

show_leader_range

NEXT_LEADER_SLOT=$((EPOCH_LAST_SLOT+1))
show_non_leader_range

printf "\nTotal leader slots for the epoch for validator %s: %d\n" "$VALIDATOR_IDENTITY" "$TOTAL_LEADER_SLOTS"

} > "$FILENAME"

echo "Contents of $FILENAME:"
cat "$FILENAME"

echo "The leader schedule has been saved to the file: $FILENAME"
