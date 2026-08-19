#!/bin/bash

# Define the minimum duration of non leader slot in minutes to apply a green background
GREEN_DURATION=25
# Adjusted number of leader groups to show
MAX_GROUP_COUNT=12

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

TIME_ZONE="America/Chicago"

RPC_URL="$MAINNET_RPC_URL"

# Fetch performance samples to calculate slot duration
performance_samples=$(curl -s $RPC_URL -X POST -H "Content-Type: application/json" -d '{"jsonrpc":"2.0","id":1,"method":"getRecentPerformanceSamples","params":[1]}')
num_slots=$(echo "$performance_samples" | jq -r '.result[0].numSlots')
sample_period_secs=$(echo "$performance_samples" | jq -r '.result[0].samplePeriodSecs')
SLOT_DURATION=$(echo "scale=6; $sample_period_secs / $num_slots" | bc -l)

# Define ANSI escape codes for formatting
BOLD='\033[1m'
WHITE='\033[97m'
LIGHT_GRAY='\033[37m'
DARK_BLUE_BG='\033[44m'
LIGHT_GREEN='\033[42m' 
RESET='\033[0m'

function duration() {
    local total_seconds=$(echo "$1/1" | bc)  # Convert to integer seconds for formatting
    local days=$((total_seconds / 86400))
    local hours=$(( (total_seconds % 86400) / 3600 ))
    local minutes=$(( (total_seconds % 3600) / 60 ))
    local seconds=$(( total_seconds % 60 ))
    
    (($days > 0)) && printf '%d day%s ' $days $((($days > 1)) && echo s)
    (($hours > 0)) && printf '%d hr%s ' $hours $((($hours > 1)) && echo s)
    (($minutes > 0)) && printf '%d min%s ' $minutes $((($minutes > 1)) && echo s)
    printf '%d secs' $seconds
}

function slot_to_times() {
    local SLOT=$1
    local SECONDS_TO_SLOT=$(echo "($SLOT - $current_slot) * $SLOT_DURATION" | bc)
    local SECONDS_TO_SLOT_INT=${SECONDS_TO_SLOT%.*}
    local UTC_TIME=$(date -u -d "@$(($(date +%s) + SECONDS_TO_SLOT_INT))" "+%Y-%m-%d %H:%M:%S")
    local CT_TIME=$(TZ="$TIME_ZONE" date -d "@$(($(date +%s) + SECONDS_TO_SLOT_INT))" "+%A, %Y-%m-%d %H:%M:%S")
    echo "$UTC_TIME|$CT_TIME|$SECONDS_TO_SLOT"
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
    local DURATION_MIN=$(echo "$SECS / 60" | bc)

    # Apply yellow-green background if duration exceeds GREEN_DURATION
    if (( $(echo "$DURATION_MIN > $GREEN_DURATION" | bc -l) )); then
        BG_COLOR=$LIGHT_GREEN
    else
        BG_COLOR=''
    fi

    printf "${BG_COLOR}${LIGHT_GRAY}      $FIRST_SLOT-$LAST_SLOT  %-12s  %s UTC | %s $TIME_ZONE ($(duration $SECS))${RESET}\n" "$SLOTS slots" "$UTC_TIME" "$CT_TIME"
}

# Get current and upcoming slots
current_slot=$(solana -u $RPC_URL slot)
# Fetch leader schedule once and reuse it
leader_schedule=$(solana -u $RPC_URL leader-schedule | grep "$VALIDATOR_IDENTITY")
total_leader_slots=$(echo "$leader_schedule" | wc -l)
leader_groups=($(echo "$leader_schedule" | awk '{print $1}' | sort -n | awk -v current_slot="$current_slot" '$1 > current_slot {print $1}' | head -n 100))

echo "Upcoming $MAX_GROUP_COUNT Leader Slots for VALIDATOR_IDENTITY = $VALIDATOR_IDENTITY"
group_count=0
for ((i=0; i<${#leader_groups[@]}; i++)); do
    current_group_slot=${leader_groups[i]}
    next_slot=${leader_groups[i+1]}

    if [[ -z $group_start ]]; then
        group_start=$current_group_slot
    fi

    if [[ -z $next_slot || $((next_slot - current_group_slot)) -ne 1 ]]; then
        # Show non-leader slots from current slot up to the next leader slot group
        if [[ $group_count -eq 0 ]]; then
            show_non_leader_range $current_slot $((group_start - 1))
        else
            show_non_leader_range $((previous_group_end + 1)) $((group_start - 1))
        fi

        # Show the leader slot group
        show_leader_range $group_start $current_group_slot
        group_count=$((group_count + 1))

        # Stop after showing MAX_GROUP_COUNT groups
        if [[ $group_count -eq $MAX_GROUP_COUNT ]]; then
            break
        fi

        previous_group_end=$current_group_slot
        group_start=""
    fi
done

# Summary information
current_time_utc=$(date -u +"%Y-%m-%d %H:%M:%S %Z")
current_time_central=$(TZ="$TIME_ZONE" date +"%Y-%m-%d %H:%M:%S %Z")

EPOCH_DETAILS=$(solana -u $RPC_URL epoch-info)
EPOCH_NUMBER=$(echo "$EPOCH_DETAILS" | grep ^Epoch: | awk '{ print $2 }')
EPOCH_CURRENT_SLOT=$(echo "$EPOCH_DETAILS" | grep ^Slot: | awk '{ print $2 }')
EPOCH_COMPLETED_SLOTS=$(echo "$EPOCH_DETAILS" | grep "^Epoch Completed Slots:" | awk '{ print $4 }' | cut -d '/' -f 1)
EPOCH_SLOT_COUNT=$(echo "$EPOCH_DETAILS" | grep "^Epoch Completed Slots:" | awk '{ print $4 }' | cut -d '/' -f 2)

# Calculate percent complete with two decimal places
EPOCH_PERCENT_COMPLETE=$(echo "scale=2; ($EPOCH_COMPLETED_SLOTS * 100.0) / $EPOCH_SLOT_COUNT" | bc -l)

EPOCH_FIRST_SLOT=$(($EPOCH_CURRENT_SLOT - $EPOCH_COMPLETED_SLOTS))
EPOCH_LAST_SLOT=$(($EPOCH_FIRST_SLOT + $EPOCH_SLOT_COUNT - 1))

# Calculate slot height within the epoch
EPOCH_SLOT_HEIGHT=$(($current_slot - $EPOCH_FIRST_SLOT))
# Format slot height with commas
FORMATTED_SLOT_HEIGHT=$(echo $EPOCH_SLOT_HEIGHT | sed ':a;s/\B[0-9]\{3\}\>/,&/;ta')

SLOTS_TO_EPOCH_END=$((EPOCH_LAST_SLOT - $current_slot))
TIME_TO_EPOCH_END=$(echo "$SLOTS_TO_EPOCH_END * $SLOT_DURATION" | bc)
TIME_TO_EPOCH_END_INT=${TIME_TO_EPOCH_END%.*}
EPOCH_END_TIMES=$(slot_to_times $EPOCH_LAST_SLOT)
EPOCH_END_UTC=$(echo $EPOCH_END_TIMES | cut -d'|' -f1)
EPOCH_END_CT=$(echo $EPOCH_END_TIMES | cut -d'|' -f2)

# Time to next leader slot
next_leader_slot=${leader_groups[0]}
time_until_next_slot=$(echo "($next_leader_slot - $current_slot) * $SLOT_DURATION" | bc)
time_until_next_slot_seconds=${time_until_next_slot%.*}
next_slot_time_utc=$(date -u -d "@$(($(date +%s) + time_until_next_slot_seconds))" +"%Y-%m-%d %H:%M:%S %Z")
next_slot_time_central=$(TZ="$TIME_ZONE" date -d "@$(($(date +%s) + time_until_next_slot_seconds))" +"%A, %Y-%m-%d %H:%M:%S %Z")

echo
echo "Epoch: $EPOCH_NUMBER"
echo "Total leader slots for $VALIDATOR_IDENTITY in this epoch: $total_leader_slots"
echo "Percent Complete: $EPOCH_PERCENT_COMPLETE%"
echo "Time to end of epoch: $(duration $TIME_TO_EPOCH_END_INT)"
echo "Epoch end time (UTC): $EPOCH_END_UTC ***** Epoch end time ($TIME_ZONE): $EPOCH_END_CT"
echo
echo "Current slot: $current_slot (Slot height: $FORMATTED_SLOT_HEIGHT)"
echo "Current time (UTC): $current_time_utc ***** Current time ($TIME_ZONE): $current_time_central"
echo "Average slot duration: ${SLOT_DURATION} seconds ($(echo "${SLOT_DURATION} * 1000" | bc) milliseconds)"
echo
echo "Your next leader slot is at slot $next_leader_slot for VALIDATOR_IDENTITY = $VALIDATOR_IDENTITY"
echo "Time of next leader slot (UTC): $next_slot_time_utc ***** Time of next leader slot ($TIME_ZONE): $next_slot_time_central"
if (( time_until_next_slot_seconds > 0 )); then
    echo "***** in approximately $((time_until_next_slot_seconds / 3600)) hours, $(((time_until_next_slot_seconds % 3600) / 60)) minutes, $((time_until_next_slot_seconds % 60)) seconds *****"
else
    echo "***** This slot is in the past. Please run the script again for updated information. *****"
fi
echo
