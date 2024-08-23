#!/bin/bash

VALIDATOR_IDENTITY=<your-identity-pubkey>

TIME_ZONE="America/Chicago"

RPC_URL=http://api.mainnet-beta.solana.com
#RPC_URL=http://api.testnet.solana.com

echo
# fetch performance samples to calculate slot duration
performance_samples=$(curl -s $RPC_URL -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getRecentPerformanceSamples","params":[1]}')
num_slots=$(echo "$performance_samples" | jq -r '.result[0].numSlots')
sample_period_secs=$(echo "$performance_samples" | jq -r '.result[0].samplePeriodSecs')

# Calculate slot duration in seconds with increased precision
SLOT_DURATION=$(echo "scale=6; $sample_period_secs / $num_slots" | bc -l)

# get the current slot
current_slot=$(solana -u $RPC_URL slot)

# get your validator's upcoming slots
upcoming_slots=$(solana -u $RPC_URL leader-schedule | grep "$VALIDATOR_IDENTITY")

# Define ANSI escape codes for formatting
BOLD='\033[1m'
WHITE='\033[97m'
LIGHT_GRAY='\033[37m'
DARK_BLUE_BG='\033[44m'
RESET='\033[0m'

function duration() {
    local T=${1%.*}
    local F=$(echo "$1 $T - p" | dc)
    local D=$((T/60/60/24))
    local H=$((T/60/60%24))
    local M=$((T/60%60))
    local S=$((T%60))
    
    (($D > 0)) && printf '%d day%s ' $D $((($D > 1)) && echo s)
    (($H > 0)) && printf '%d hr%s ' $H $((($H > 1)) && echo s)
    (($M > 0)) && printf '%d min%s ' $M $((($M > 1)) && echo s)

    S=$(echo "$S $F + p" | dc)
    printf '%0.2f secs' $S
}

function slot_to_times() {
    local SLOT=$1
    local SECONDS_TO_SLOT=$(echo "($SLOT - $current_slot) * $SLOT_DURATION" | bc)
    local SECONDS_TO_SLOT_INT=${SECONDS_TO_SLOT%.*}
    local UTC_TIME=$(date -u -d "@$(($(date +%s) + SECONDS_TO_SLOT_INT))" "+%Y-%m-%d %H:%M:%S")
    local CT_TIME=$(TZ="$TIME_ZONE" date -d "@$(($(date +%s) + SECONDS_TO_SLOT_INT))" "+%Y-%m-%d %H:%M:%S")
    echo "$UTC_TIME|$CT_TIME"
}

function show_leader_range() {
    local FIRST_SLOT=$1
    local LAST_SLOT=$2
    local SLOTS=$((LAST_SLOT - FIRST_SLOT + 1))
    local SECS=$(echo "$SLOT_DURATION * $SLOTS" | bc)
    local TIMES=$(slot_to_times $FIRST_SLOT)
    local UTC_TIME=$(echo $TIMES | cut -d'|' -f1)
    local CT_TIME=$(echo $TIMES | cut -d'|' -f2)
    printf "${BOLD}${WHITE}${DARK_BLUE_BG}Lead  $FIRST_SLOT-$LAST_SLOT  %-12s  %s UTC | %s $TIME_ZONE ($(duration $SECS))${RESET}\n" "$SLOTS slots" "$UTC_TIME" "$CT_TIME"
}

function show_non_leader_range() {
    local FIRST_SLOT=$1
    local LAST_SLOT=$2
    local SLOTS=$((LAST_SLOT - FIRST_SLOT + 1))
    local SECS=$(echo "$SLOT_DURATION * $SLOTS" | bc)
    local TIMES=$(slot_to_times $FIRST_SLOT)
    local UTC_TIME=$(echo $TIMES | cut -d'|' -f1)
    local CT_TIME=$(echo $TIMES | cut -d'|' -f2)
    printf "${LIGHT_GRAY}      $FIRST_SLOT-$LAST_SLOT  %-12s  %s UTC | %s $TIME_ZONE ($(duration $SECS))${RESET}\n" "$SLOTS slots" "$UTC_TIME" "$CT_TIME"
}

# Get the next 4 leader groups
leader_groups=($(echo "$upcoming_slots" | awk '{print $1}' | sort -n | awk -v current_slot="$current_slot" '$1 > current_slot {print $1}' | head -n 20))

# Print leader groups
echo "Upcoming Leader Slots"
group_count=0
for ((i=0; i<${#leader_groups[@]}; i++)); do
    current_group_slot=${leader_groups[i]}
    next_slot=${leader_groups[i+1]}

    if [[ -z $group_start ]]; then
        group_start=$current_group_slot
    fi

    if [[ -z $next_slot || $((next_slot - current_group_slot)) -ne 1 ]]; then
        show_leader_range $group_start $current_group_slot
        group_count=$((group_count + 1))

        if [[ $group_count -eq 4 ]]; then
            break
        fi

        if [[ -n $next_slot ]]; then
            show_non_leader_range $((current_group_slot + 1)) $((next_slot - 1))
        fi

        group_start=""
    fi
done

echo

# Calculate summary information
current_time_utc=$(date -u +"%Y-%m-%d %H:%M:%S %Z")
current_time_central=$(TZ="$TIME_ZONE" date +"%Y-%m-%d %H:%M:%S %Z")

# Get epoch information
EPOCH_DETAILS=$(solana -u $RPC_URL epoch-info)
EPOCH_NUMBER=$(echo "$EPOCH_DETAILS" | grep ^Epoch: | awk '{ print $2 }')
EPOCH_CURRENT_SLOT=$(echo "$EPOCH_DETAILS" | grep ^Slot: | awk '{ print $2 }')
EPOCH_COMPLETED_SLOTS=$(echo "$EPOCH_DETAILS" | grep "^Epoch Completed Slots:" | awk '{ print $4 }' | cut -d '/' -f 1)
EPOCH_SLOT_COUNT=$(echo "$EPOCH_DETAILS" | grep "^Epoch Completed Slots:" | awk '{ print $4 }' | cut -d '/' -f 2)

EPOCH_FIRST_SLOT=$(($EPOCH_CURRENT_SLOT-$EPOCH_COMPLETED_SLOTS))
EPOCH_LAST_SLOT=$(($EPOCH_FIRST_SLOT+$EPOCH_SLOT_COUNT-1))

# Calculate time to end of epoch
SLOTS_TO_EPOCH_END=$((EPOCH_LAST_SLOT - current_slot))
TIME_TO_EPOCH_END=$(echo "$SLOTS_TO_EPOCH_END * $SLOT_DURATION" | bc)
EPOCH_END_TIMES=$(slot_to_times $EPOCH_LAST_SLOT)
EPOCH_END_UTC=$(echo $EPOCH_END_TIMES | cut -d'|' -f1)
EPOCH_END_CT=$(echo $EPOCH_END_TIMES | cut -d'|' -f2)

next_leader_slot=${leader_groups[0]}
time_until_next_slot=$(echo "($next_leader_slot - $current_slot) * $SLOT_DURATION" | bc)

next_slot_time_utc=$(date -u -d "@$(($(date +%s) + ${time_until_next_slot%.*}))" +"%Y-%m-%d %H:%M:%S %Z")
next_slot_time_central=$(TZ="$TIME_ZONE" date -d "@$(($(date +%s) + ${time_until_next_slot%.*}))" +"%Y-%m-%d %H:%M:%S %Z")

# Calculate hours, minutes, and seconds
time_until_next_slot_seconds=${time_until_next_slot%.*}
hours=$((time_until_next_slot_seconds / 3600))
minutes=$(( (time_until_next_slot_seconds % 3600) / 60 ))
seconds=$(( time_until_next_slot_seconds % 60 ))

# Print summary information
echo
echo "Epoch: $EPOCH_NUMBER"
echo "Time to end of epoch: $(duration $TIME_TO_EPOCH_END)"
echo "Epoch end time (UTC): $EPOCH_END_UTC ***** Epoch end time ($TIME_ZONE): $EPOCH_END_CT"
echo
echo "Current slot: $current_slot"
echo "Current time (UTC): $current_time_utc ***** Current time ($TIME_ZONE): $current_time_central"
echo "Average slot duration: ${SLOT_DURATION} seconds ($(echo "${SLOT_DURATION} * 1000" | bc) milliseconds)"
echo
echo "Your next leader slot is at slot $next_leader_slot for VALIDATOR_IDENTITY = $VALIDATOR_IDENTITY"
echo "Time of next leader slot (UTC): $next_slot_time_utc ***** Time of next leader slot ($TIME_ZONE): $next_slot_time_central"
if (( time_until_next_slot_seconds > 0 )); then
    echo "***** in approximately $hours hours, $minutes minutes, $seconds seconds *****"
else
    echo "***** This slot is in the past. Please run the script again for updated information. *****"
fi
echo
